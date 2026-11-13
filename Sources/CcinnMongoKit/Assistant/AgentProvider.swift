import Foundation
import os

public enum AgentError: Error, LocalizedError, Sendable, Equatable {
    case notInstalled(AgentProvider)
    case failed(String)
    case timedOut(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(provider): "\(provider.displayName) was not found. \(provider.installHint)"
        case let .failed(message): message
        case let .timedOut(seconds): "The assistant did not answer within \(seconds) seconds."
        case .cancelled: "The request was cancelled."
        }
    }
}

/// Locally installed agent CLIs that can answer questions non-interactively.
public enum AgentProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude"
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        }
    }

    public var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    public var installHint: String {
        switch self {
        case .claudeCode: "Install it with `npm install -g @anthropic-ai/claude-code` and sign in by running `claude` once."
        case .codex: "Install it with `npm install -g @openai/codex` (or `brew install codex`) and sign in by running `codex` once."
        }
    }

    public struct Invocation: Sendable, Equatable {
        public let executable: URL
        public let arguments: [String]
    }

    /// Command line for one isolated, non-interactive request. The agent gets no tools, no MCP servers
    /// and no persisted session; it can only read the prompt and write a reply.
    public func invocation(executable: URL, systemPrompt: String, prompt: String, model: String?,
                           workingDirectory: URL, outputFile: URL) -> Invocation {
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .claudeCode:
            var arguments = ["-p", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                             "--no-session-persistence", "--system-prompt", systemPrompt]
            if let model, !model.isEmpty { arguments += ["--model", model] }
            arguments.append(prompt)
            return Invocation(executable: executable, arguments: arguments)
        case .codex:
            var arguments = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--color", "never",
                             "-C", workingDirectory.path, "-o", outputFile.path]
            if let model, !model.isEmpty { arguments += ["-m", model] }
            // Codex has no separate system prompt flag.
            arguments.append(systemPrompt + "\n\n" + prompt)
            return Invocation(executable: executable, arguments: arguments)
        }
    }

    /// The model's final text from the CLI output.
    public func extractReply(stdout: String, outputFile: String?) throws -> String {
        switch self {
        case .claudeCode:
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                guard !trimmed.isEmpty else { throw AgentError.failed("Claude Code returned no output.") }
                return trimmed
            }
            let result = object["result"] as? String ?? ""
            if (object["is_error"] as? Bool) == true {
                throw AgentError.failed("Claude Code reported an error: \(result.isEmpty ? (object["subtype"] as? String ?? "unknown") : result)")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        case .codex:
            let text = (outputFile ?? stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AgentError.failed("Codex returned no output.") }
            return text
        }
    }
}

/// Finds agent executables even when the app was launched from Finder with a minimal PATH.
public enum AgentLocator {
    public static let defaultDirectories = [
        "~/.local/bin", "~/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin",
        "~/.claude/local", "~/.volta/bin", "~/.bun/bin", "~/.nvm/current/bin",
    ]

    public static func locate(_ provider: AgentProvider, override: String?, searchPath: String,
                              extraDirectories: [String] = defaultDirectories) -> URL? {
        let fileManager = FileManager.default
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (override.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let directories = searchPath.split(separator: ":").map(String.init) + extraDirectories.map { ($0 as NSString).expandingTildeInPath }
        var seen = Set<String>()
        for directory in directories where !directory.isEmpty && seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(provider.executableName)
            if fileManager.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    private static let cachedLoginPath = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// PATH as seen by the user's login shell (where npm/Homebrew installs live). Blocking; call off the main actor.
    public static func loginShellPath() -> String {
        if let cached = cachedLoginPath.withLock({ $0 }) { return cached }
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var path = fallback
        if (try? process.run()) != nil {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { process.terminate() }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { path = output + ":" + fallback }
        }
        let resolved = path
        cachedLoginPath.withLock { $0 = resolved }
        return resolved
    }
}

/// Anything that can turn a system prompt + prompt into a reply (a CLI agent, or a fake in tests).
public protocol AgentRunning: Sendable {
    func complete(system: String, prompt: String) async throws -> String
}

/// Runs Claude Code or Codex as an isolated subprocess for each request.
public struct CLIAgent: AgentRunning {
    public let provider: AgentProvider
    public let executable: URL
    public let model: String?
    public let searchPath: String
    public var timeout: Duration

    public init(provider: AgentProvider, executable: URL, model: String?, searchPath: String, timeout: Duration = .seconds(240)) {
        self.provider = provider
        self.executable = executable
        self.model = model
        self.searchPath = searchPath
        self.timeout = timeout
    }

    public func complete(system: String, prompt: String) async throws -> String {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory.appendingPathComponent("ccinnmongo-agent-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: workingDirectory) }
        let outputFile = workingDirectory.appendingPathComponent("reply.txt")
        let invocation = provider.invocation(executable: executable, systemPrompt: system, prompt: prompt, model: model,
                                             workingDirectory: workingDirectory, outputFile: outputFile)

        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDECODE") && !$0.key.hasPrefix("CLAUDE_CODE_") }
        environment["PATH"] = searchPath
        environment["NO_COLOR"] = "1"
        let output = try await ProcessRunner.run(executable: invocation.executable, arguments: invocation.arguments,
                                                 environment: environment, currentDirectory: workingDirectory, timeout: timeout)
        let stdout = String(decoding: output.stdout, as: UTF8.self)
        let fileText = try? String(contentsOf: outputFile, encoding: .utf8)
        guard output.status == 0 else {
            if provider == .claudeCode, let reply = try? provider.extractReply(stdout: stdout, outputFile: nil), !reply.isEmpty {
                throw AgentError.failed("Claude Code failed: \(reply)")
            }
            let stderr = String(decoding: output.stderr, as: UTF8.self)
            let detail = (stderr.isEmpty ? stdout : stderr).split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
            throw AgentError.failed("\(provider.displayName) exited with status \(output.status): \(detail)")
        }
        return try provider.extractReply(stdout: stdout, outputFile: fileText)
    }
}

import Darwin
import Foundation
import os

public struct SSHTunnelConfiguration: Sendable, Codable, Equatable, Hashable {
    public enum Authentication: String, Sendable, Codable, CaseIterable {
        /// ssh-agent / ~/.ssh/config defaults.
        case agent
        case password
        case privateKey
    }

    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    public var privateKeyPath: String?

    public init(host: String, port: Int = 22, username: String, authentication: Authentication, privateKeyPath: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.privateKeyPath = privateKeyPath
    }
}

/// Local port forward through the system OpenSSH client (`/usr/bin/ssh -N -L`).
///
/// Using the system client means `~/.ssh/config`, known_hosts, ssh-agent and hardware keys all work
/// exactly as in Terminal. Passwords/passphrases are answered through `SSH_ASKPASS` by a one-shot
/// helper script that reads the secret from the ssh child's environment; nothing is written to disk.
public final class SSHTunnel: Sendable {
    public let localPort: Int
    public let remote: ServerAddress
    private let process: OSAllocatedUnfairLock<Process?>

    private init(localPort: Int, remote: ServerAddress, process: Process) {
        self.localPort = localPort
        self.remote = remote
        self.process = OSAllocatedUnfairLock(uncheckedState: process)
    }

    deinit {
        close()
    }

    public var localAddress: ServerAddress { ServerAddress(host: "127.0.0.1", port: localPort) }

    public var isRunning: Bool {
        process.withLockUnchecked { $0?.isRunning ?? false }
    }

    public func close() {
        let running = process.withLockUnchecked { current -> Process? in
            defer { current = nil }
            return current
        }
        if let running, running.isRunning { running.terminate() }
    }

    /// Starts ssh and waits until the forwarded port accepts connections.
    public static func open(configuration: SSHTunnelConfiguration, secret: String?, remote: ServerAddress,
                            timeout: Double = 20) async throws -> SSHTunnel {
        let localPort = try freeLocalPort()
        let arguments = try arguments(for: configuration, localPort: localPort, remote: remote, connectTimeout: Int(timeout))
        let askPass = try AskPassHelper.shared.path()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askPass
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment["GROVE_ASKPASS_SECRET"] = secret ?? ""
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw MongoError(.sshTunnel, "Could not start /usr/bin/ssh: \(error.localizedDescription)")
        }
        let tunnel = SSHTunnel(localPort: localPort, remote: remote, process: process)

        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw MongoError(.sshTunnel, describeFailure(output, configuration: configuration))
            }
            if canConnect(port: localPort) { return tunnel }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                tunnel.close()
                throw MongoError.cancelled()
            }
        }
        tunnel.close()
        throw MongoError(.sshTunnel, "Timed out establishing the SSH tunnel through \(configuration.host)")
    }

    // MARK: Helpers

    static func arguments(for configuration: SSHTunnelConfiguration, localPort: Int, remote: ServerAddress,
                          connectTimeout: Int = 15) throws -> [String] {
        let host = configuration.host.trimmingCharacters(in: .whitespaces)
        let user = configuration.username.trimmingCharacters(in: .whitespaces)
        guard isSafeToken(host) else { throw MongoError(.sshTunnel, "Invalid SSH host '\(configuration.host)'") }
        guard user.isEmpty || isSafeToken(user) else { throw MongoError(.sshTunnel, "Invalid SSH user name '\(configuration.username)'") }
        guard (1...65535).contains(configuration.port) else { throw MongoError(.sshTunnel, "Invalid SSH port \(configuration.port)") }
        guard isSafeToken(remote.host) else { throw MongoError(.sshTunnel, "Invalid MongoDB host '\(remote.host)'") }

        let remoteHost = remote.isIPv6 ? "[\(remote.host)]" : remote.host
        var arguments = [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(max(1, connectTimeout))",
            "-o", "NumberOfPasswordPrompts=1",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remote.port)",
            "-p", String(configuration.port),
        ]
        switch configuration.authentication {
        case .agent:
            break
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        case .privateKey:
            guard let path = configuration.privateKeyPath, !path.isEmpty else {
                throw MongoError(.sshTunnel, "Choose a private key file for the SSH tunnel")
            }
            arguments += ["-i", (path as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        arguments.append(user.isEmpty ? host : "\(user)@\(host)")
        return arguments
    }

    /// Hosts and user names must not look like options and must not contain whitespace or control characters.
    private static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-") && !token.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 } == true })
    }

    static func describeFailure(_ output: String, configuration: SSHTunnelConfiguration) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("Warning: Permanently added") && !$0.isEmpty }
        let detail = lines.last ?? "ssh exited unexpectedly"
        return "SSH tunnel through \(configuration.host):\(configuration.port) failed: \(detail)"
    }

    /// Asks the kernel for an unused port on the loopback interface.
    static func freeLocalPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MongoError(.sshTunnel, "Could not allocate a local port") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw MongoError(.sshTunnel, "Could not allocate a local port") }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw MongoError(.sshTunnel, "Could not allocate a local port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Writes (once per process) a tiny askpass script that prints the secret passed via the environment.
final class AskPassHelper: Sendable {
    static let shared = AskPassHelper()
    private let cached = OSAllocatedUnfairLock<String?>(initialState: nil)

    func path() throws -> String {
        if let existing = cached.withLock({ $0 }), FileManager.default.isExecutableFile(atPath: existing) { return existing }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grove-askpass-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("askpass.sh")
        let contents = "#!/bin/sh\nprintf '%s\\n' \"$GROVE_ASKPASS_SECRET\"\n"
        try Data(contents.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        cached.withLock { $0 = script.path }
        return script.path
    }
}

/// Ready-to-paste configuration for common MCP clients, pointing at this executable's `mcp` subcommand.
public struct MCPClientSnippets: Sendable, Equatable {
    public static let serverName = "ccinnmongo"

    public let executablePath: String
    public let readOnly: Bool

    public init(executablePath: String, readOnly: Bool = false) {
        self.executablePath = executablePath
        self.readOnly = readOnly
    }

    public var arguments: [String] { readOnly ? ["mcp", "--read-only"] : ["mcp"] }

    /// The command as typed in a POSIX shell.
    public var commandLine: String {
        ([Self.shellQuoted(executablePath)] + arguments).joined(separator: " ")
    }

    /// `claude mcp add ccinnmongo -- "<path>" mcp`
    public var claudeCode: String {
        "claude mcp add \(Self.serverName) -- \(commandLine)"
    }

    /// `~/.codex/config.toml` section.
    public var codexTOML: String {
        """
        [mcp_servers.\(Self.serverName)]
        command = \(Self.tomlString(executablePath))
        args = [\(arguments.map(Self.tomlString).joined(separator: ", "))]
        """
    }

    /// `claude_desktop_config.json` (and most other JSON-configured clients).
    public var claudeDesktopJSON: String {
        let args = arguments.map { JSONWriter.string(.string($0)) }.joined(separator: ", ")
        return """
        {
          "mcpServers": {
            "\(Self.serverName)": {
              "command": \(JSONWriter.string(.string(executablePath))),
              "args": [\(args)]
            }
          }
        }
        """
    }

    /// Double-quoted for POSIX shells: `\`, `"`, `$` and backtick are escaped.
    static func shellQuoted(_ text: String) -> String {
        var quoted = "\""
        for character in text {
            if "\\\"$`".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\""
    }

    /// TOML basic string.
    static func tomlString(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\t": quoted += "\\t"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                quoted += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

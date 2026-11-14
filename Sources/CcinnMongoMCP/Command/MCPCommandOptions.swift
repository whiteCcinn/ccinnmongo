public struct MCPUsageError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Options of `CcinnMongo mcp [--profile <name|id>] [--read-only]`.
public struct MCPCommandOptions: Sendable, Equatable {
    /// Default connection (profile name or id) for calls that do not name one.
    public var profile: String?
    /// Caps every connection at read-only access.
    public var readOnly: Bool
    public var showHelp: Bool

    public init(profile: String? = nil, readOnly: Bool = false, showHelp: Bool = false) {
        self.profile = profile
        self.readOnly = readOnly
        self.showHelp = showHelp
    }

    public static let usage = """
    Usage: CcinnMongo mcp [--profile <name|id>] [--read-only]

    Runs a Model Context Protocol server on stdin/stdout so AI clients can query the
    connections you enabled for "AI access via MCP" in CcinnMongo.

      --profile <name|id>  Connection to use when a tool call does not name one.
      --read-only          Cap every connection at read-only access.
      -h, --help           Show this help.
    """

    /// Parses the arguments after `mcp`.
    public static func parse(_ arguments: [String]) throws -> MCPCommandOptions {
        var options = MCPCommandOptions()
        var index = 0
        func setProfile(_ value: String) throws {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("--") else { throw MCPUsageError(message: "--profile needs a connection name or id") }
            guard options.profile == nil else { throw MCPUsageError(message: "--profile may only be given once") }
            options.profile = trimmed
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--read-only":
                options.readOnly = true
            case "-h", "--help":
                options.showHelp = true
            case "--profile":
                guard index + 1 < arguments.count else { throw MCPUsageError(message: "--profile needs a connection name or id") }
                index += 1
                try setProfile(arguments[index])
            default:
                if argument.hasPrefix("--profile=") {
                    try setProfile(String(argument.dropFirst("--profile=".count)))
                } else {
                    throw MCPUsageError(message: "Unknown option '\(argument)'")
                }
            }
            index += 1
        }
        return options
    }
}

import Foundation

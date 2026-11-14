/// Where the server writes protocol messages (one encoded JSON object per call, without the newline).
public protocol MCPOutput: Sendable {
    func send(_ line: [UInt8]) async throws
}

public enum MCPOutputError: Error, Sendable, Equatable {
    case closed
    case writeFailed(Int32)
}

/// Per-call information available to tools.
public struct MCPCallContext: Sendable {
    /// Negotiated protocol version (the latest supported one before `initialize`).
    public let protocolVersion: String

    public init(protocolVersion: String) {
        self.protocolVersion = protocolVersion
    }
}

/// A tool as advertised by `tools/list`.
public struct MCPToolDefinition: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let readOnly: Bool
    public let destructive: Bool
    public let idempotent: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool, destructive: Bool, idempotent: Bool) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
    }

    public var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent),
                "openWorldHint": false,
            ],
        ]
    }
}

/// Outcome of a tool call. Failures are results (`isError: true`), not protocol errors.
public struct MCPToolResult: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case structured(JSONObject)
        case error(String)
    }

    public let payload: Payload

    public static func success(_ object: JSONObject) -> MCPToolResult { MCPToolResult(payload: .structured(object)) }
    public static func failure(_ message: String) -> MCPToolResult { MCPToolResult(payload: .error(message)) }

    public var isError: Bool {
        if case .error = payload { return true }
        return false
    }

    /// The `tools/call` result object for the negotiated protocol version.
    public func json(protocolVersion: String) -> JSONValue {
        switch payload {
        case let .structured(object):
            let text = JSONWriter.string(.object(object))
            var result: JSONObject = ["content": [["type": "text", "text": .string(text)]]]
            if MCPProtocolVersion.supportsStructuredContent(protocolVersion) {
                result["structuredContent"] = .object(object)
            }
            return .object(result)
        case let .error(message):
            return ["content": [["type": "text", "text": .string(message)]], "isError": true]
        }
    }
}

/// Errors a tool provider throws for problems with the request itself (JSON-RPC `-32602`).
public enum MCPToolError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(String)

    public var message: String {
        switch self {
        case let .unknownTool(name): "Unknown tool: \(name)"
        case let .invalidArguments(message): message
        }
    }
}

public protocol MCPToolProvider: Sendable {
    func listTools(context: MCPCallContext) async -> [MCPToolDefinition]
    /// Throws `MCPToolError` for unknown tools or invalid arguments; returns failures as results.
    func callTool(name: String, arguments: JSONObject, context: MCPCallContext) async throws -> MCPToolResult
}

public enum MCPProtocolVersion {
    public static let latest = "2025-06-18"
    public static let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public static func negotiate(_ requested: String?) -> String {
        guard let requested, supported.contains(requested) else { return latest }
        return requested
    }

    /// `structuredContent` was introduced in 2025-06-18 (versions are ISO dates, so they compare as strings).
    public static func supportsStructuredContent(_ version: String) -> Bool { version >= "2025-06-18" }
}

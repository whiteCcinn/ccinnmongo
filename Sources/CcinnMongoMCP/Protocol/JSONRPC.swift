/// A JSON-RPC request id (MCP forbids `null`).
public enum JSONRPCID: Sendable, Hashable, CustomStringConvertible {
    case int(Int64)
    case string(String)

    public var json: JSONValue {
        switch self {
        case let .int(value): .int(value)
        case let .string(value): .string(value)
        }
    }

    public var description: String {
        switch self {
        case let .int(value): String(value)
        case let .string(value): value
        }
    }

    /// Accepts strings and integers (including integral doubles such as `2.0`).
    public init?(_ value: JSONValue) {
        switch value {
        case let .string(string): self = .string(string)
        case let .int(integer): self = .int(integer)
        case let .double(double):
            guard let integer = Int64(exactly: double) else { return nil }
            self = .int(integer)
        default: return nil
        }
    }
}

public enum JSONRPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case serverBusy = -32000
}

/// What an incoming message is.
public enum JSONRPCIncoming: Sendable, Equatable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    /// A response to a request we never send; ignored.
    case response
    case invalid(id: JSONRPCID?, message: String)
}

public enum JSONRPC {
    public static func classify(_ message: JSONValue) -> JSONRPCIncoming {
        if case .array = message { return .invalid(id: nil, message: "Batch requests are not supported") }
        guard let object = message.objectValue else { return .invalid(id: nil, message: "A request must be a JSON object") }

        let rawID = object["id"]
        let id = rawID.flatMap(JSONRPCID.init)
        guard object["jsonrpc"]?.stringValue == "2.0" else { return .invalid(id: id, message: "\"jsonrpc\" must be \"2.0\"") }

        guard let methodValue = object["method"] else {
            if object["result"] != nil || object["error"] != nil { return .response }
            return .invalid(id: id, message: "Missing \"method\"")
        }
        guard let method = methodValue.stringValue else { return .invalid(id: id, message: "\"method\" must be a string") }
        if rawID != nil, id == nil { return .invalid(id: nil, message: "\"id\" must be a string or an integer") }

        let params = object["params"]
        if let params {
            switch params {
            case .object, .array: break
            default: return .invalid(id: id, message: "\"params\" must be an object or an array")
            }
        }
        if let id { return .request(id: id, method: method, params: params) }
        return .notification(method: method, params: params)
    }

    public static func response(id: JSONRPCID, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id.json, "result": result]
    }

    public static func errorResponse(id: JSONRPCID?, code: JSONRPCErrorCode, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id?.json ?? .null, "error": ["code": .int(Int64(code.rawValue)), "message": .string(message)]]
    }
}

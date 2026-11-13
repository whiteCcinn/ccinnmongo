import BSON
import Foundation

/// Every failure surfaced by MongoKit. Messages are user-facing and never contain secrets.
public struct MongoError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case invalidConnectionString
        case invalidArgument
        case network
        case timeout
        case tls
        case dns
        case sshTunnel
        case authentication
        case command
        case write
        case protocolViolation
        case unsupportedServer
        case serverSelection
        case cancelled
        case connectionClosed
    }

    public let kind: Kind
    public let message: String
    /// Server error code, when the server reported one.
    public let code: Int?
    public let codeName: String?
    /// Raw server reply associated with the error, if any.
    public let reply: BSONDocument?

    public init(_ kind: Kind, _ message: String, code: Int? = nil, codeName: String? = nil, reply: BSONDocument? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
        self.codeName = codeName
        self.reply = reply
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    /// Errors after which the connection (and possibly the selected server) must not be reused.
    public var isNetworkError: Bool {
        kind == .network || kind == .timeout || kind == .connectionClosed || kind == .tls
    }

    /// Server says it is no longer (or not) the writable primary; topology must be re-resolved.
    public var isNotPrimary: Bool {
        guard let code else {
            return message.contains("not master") || message.contains("not primary")
        }
        return Self.notPrimaryCodes.contains(code)
    }

    static let notPrimaryCodes: Set<Int> = [10107, 13435, 13436, 189, 91, 11600, 11602]

    // Well-known server codes.
    public static let unauthorizedCode = 13
    public static let authenticationFailedCode = 18
    public static let namespaceNotFoundCode = 26
    public static let maxTimeMSExpiredCode = 50
    public static let commandNotFoundCode = 59
    public static let duplicateKeyCode = 11000

    /// Builds an error from a command reply with `ok: 0`.
    static func fromReply(_ reply: BSONDocument, defaultMessage: String = "Command failed") -> MongoError {
        let message = reply["errmsg"]?.stringValue ?? reply["$err"]?.stringValue ?? defaultMessage
        let code = reply["code"]?.intValue
        let codeName = reply["codeName"]?.stringValue
        return MongoError(.command, message, code: code, codeName: codeName, reply: reply)
    }

    static func cancelled() -> MongoError { MongoError(.cancelled, "The operation was cancelled") }
}

extension BSONDocument {
    /// `ok` is 1 (int/double) or true.
    var isOK: Bool { self["ok"]?.isTruthy ?? false }
}

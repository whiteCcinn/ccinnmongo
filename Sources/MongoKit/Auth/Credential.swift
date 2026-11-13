import BSON
import CryptoKit
import Foundation

public enum AuthMechanism: String, Sendable, CaseIterable, Codable {
    case scramSHA256 = "SCRAM-SHA-256"
    case scramSHA1 = "SCRAM-SHA-1"
    case mongoCR = "MONGODB-CR"
    case plain = "PLAIN"

    /// Mechanism to use when the user did not choose one.
    static func negotiate(requested: AuthMechanism?, maxWireVersion: Int, saslSupportedMechs: [String]?) -> AuthMechanism {
        if let requested { return requested }
        if let mechanisms = saslSupportedMechs {
            if mechanisms.contains(AuthMechanism.scramSHA256.rawValue) { return .scramSHA256 }
            if mechanisms.contains(AuthMechanism.scramSHA1.rawValue) { return .scramSHA1 }
        }
        return maxWireVersion >= 3 ? .scramSHA1 : .mongoCR
    }

    public var displayName: String { rawValue }
}

/// Credentials for one connection. `password` is never included in errors or descriptions.
public struct MongoCredential: Sendable, Equatable, CustomStringConvertible {
    public var username: String
    public var password: String
    public var source: String
    public var mechanism: AuthMechanism?

    public init(username: String, password: String, source: String, mechanism: AuthMechanism? = nil) {
        self.username = username
        self.password = password
        self.source = source
        self.mechanism = mechanism
    }

    public var description: String { "\(username)@\(source)\(mechanism.map { " (\($0.rawValue))" } ?? "")" }

    /// Builds credentials from a connection string, or `nil` when no username is present.
    public init?(connectionString uri: ConnectionString) throws {
        guard let username = uri.username else { return nil }
        var mechanism: AuthMechanism?
        if let name = uri.authMechanism {
            guard let parsed = AuthMechanism(rawValue: name.uppercased()) else {
                throw MongoError(.invalidConnectionString, "Unsupported authentication mechanism '\(name)'. Supported: \(AuthMechanism.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            mechanism = parsed
        }
        let defaultSource = mechanism == .plain ? "$external" : (uri.database ?? "admin")
        self.init(username: username, password: uri.password ?? "", source: uri.authSource ?? defaultSource, mechanism: mechanism)
    }
}

enum MongoCRAuthenticator {
    static func passwordDigest(username: String, password: String) -> String {
        md5Hex("\(username):mongo:\(password)")
    }

    static func key(nonce: String, username: String, passwordDigest: String) -> String {
        md5Hex(nonce + username + passwordDigest)
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

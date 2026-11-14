import BSON
import CcinnMongoKit
import Foundation
import MongoKit

/// The MongoDB operations the tools use. `MongoClient` provides every one for all server versions;
/// tests substitute a fake.
public protocol MongoToolClient: Sendable {
    func listDatabases() async throws -> [DatabaseInfo]
    func listCollections(database: String) async throws -> [CollectionInfo]
    func listIndexes(_ namespace: MongoNamespace) async throws -> [IndexInfo]
    func indexUsage(_ namespace: MongoNamespace) async throws -> [String: IndexUsage]?
    func find(_ namespace: MongoNamespace, options: FindOptions) async throws -> [BSONDocument]
    func aggregate(_ namespace: MongoNamespace, pipeline: [BSONDocument], options: AggregateOptions) async throws -> [BSONDocument]
    func count(_ namespace: MongoNamespace, filter: BSONDocument, options: CountOptions) async throws -> Int64?
    func explainFind(_ namespace: MongoNamespace, options: FindOptions) async throws -> BSONDocument
    func explainAggregate(_ namespace: MongoNamespace, pipeline: [BSONDocument], options: AggregateOptions) async throws -> BSONDocument
    func insert(_ documents: [BSONDocument], into namespace: MongoNamespace) async throws -> InsertResult
    func updateDocuments(_ namespace: MongoNamespace, filter: BSONDocument, update: BSONDocument, many: Bool, upsert: Bool,
                         collation: BSONDocument?) async throws -> UpdateResult
    func deleteDocuments(_ namespace: MongoNamespace, filter: BSONDocument, many: Bool, collation: BSONDocument?) async throws -> Int
}

extension MongoClient: MongoToolClient {}

/// Server facts captured when the connection was opened.
public struct ServerDescription: Sendable, Equatable {
    public let version: String
    public let maxWireVersion: Int
    public let serverType: String
    public let setName: String?
    public let members: [String]
    public let gitVersion: String?
    public let isEnterprise: Bool

    public init(version: String, maxWireVersion: Int, serverType: String, setName: String?, members: [String],
                gitVersion: String?, isEnterprise: Bool) {
        self.version = version
        self.maxWireVersion = maxWireVersion
        self.serverType = serverType
        self.setName = setName
        self.members = members
        self.gitVersion = gitVersion
        self.isEnterprise = isEnterprise
    }

    public init(_ info: ServerInfo) {
        self.init(version: info.version, maxWireVersion: info.capabilities.maxWireVersion, serverType: info.serverType.displayName,
                  setName: info.setName, members: info.members, gitVersion: info.gitVersion, isEnterprise: info.isEnterprise)
    }

    public var capabilities: ServerCapabilities { ServerCapabilities(maxWireVersion: maxWireVersion) }
}

/// A usable connection to one profile's deployment.
public struct MongoSession: Sendable {
    /// Identifies this opening, so that a failure on an old session never evicts a newer one.
    public let id: UInt64
    public let client: any MongoToolClient
    public let server: ServerDescription

    public init(id: UInt64 = 0, client: any MongoToolClient, server: ServerDescription) {
        self.id = id
        self.client = client
        self.server = server
    }
}

/// A session plus how to close it (client, then SSH tunnel).
public struct OpenedSession: Sendable {
    public let session: MongoSession
    public let close: @Sendable () async -> Void

    public init(session: MongoSession, close: @escaping @Sendable () async -> Void) {
        self.session = session
        self.close = close
    }
}

public protocol MCPSessionOpening: Sendable {
    func open(_ profile: ConnectionProfile) async throws -> OpenedSession
}

/// Where tools get sessions from.
public protocol MCPSessionSource: Sendable {
    func session(for profile: ConnectionProfile) async throws -> MongoSession
    /// Drops the pooled session after a connection-level failure (only if it is still `sessionID`).
    func evict(_ profileID: UUID, sessionID: UInt64) async
}

/// Opens profiles exactly like the app does: Keychain secrets, optional SSH tunnel, version detection.
public struct ProfileSessionOpener: MCPSessionOpening {
    private let repository: ProfileRepository

    public init(repository: ProfileRepository) {
        self.repository = repository
    }

    public func open(_ profile: ConnectionProfile) async throws -> OpenedSession {
        // Keychain reads can block (or prompt), so they run off the concurrency pool.
        let repository = self.repository
        let (uri, sshSecret, secrets) = try await Self.offPool { () throws -> (ConnectionString, String?, [String]) in
            let uri = try repository.connectionString(for: profile)
            let sshSecret = profile.ssh != nil ? repository.sshSecret(for: profile) : nil
            let secrets = [uri.password, uri.tlsCertificateKeyFilePassword, sshSecret].compactMap { $0 }
            return (uri, sshSecret, secrets)
        }
        do {
            let opened = try await ConnectionOpener.open(uri: uri, ssh: profile.ssh, sshSecret: sshSecret, allowLegacyTLS: profile.allowLegacyTLS)
            return OpenedSession(session: MongoSession(client: opened.client, server: ServerDescription(opened.info))) {
                await opened.close()
            }
        } catch let error as MongoError {
            throw SecretRedaction.redact(error, secrets: secrets)
        }
    }

    private static func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// Defence in depth: strips secrets from error messages before they leave the process.
enum SecretRedaction {
    static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 3 {
            result = result.replacingOccurrences(of: secret, with: "****")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != secret {
                result = result.replacingOccurrences(of: encoded, with: "****")
            }
        }
        return result
    }

    static func redact(_ error: MongoError, secrets: [String]) -> MongoError {
        let message = redact(error.message, secrets: secrets)
        guard message != error.message else { return error }
        return MongoError(error.kind, message, code: error.code, codeName: error.codeName)
    }
}

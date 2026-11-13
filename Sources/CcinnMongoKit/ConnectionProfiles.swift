import Foundation
import MongoKit
import os
import Security

public enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// A saved connection. The URI never contains the password; secrets live in a `SecretStore`.
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var isFavorite: Bool
    public var uri: String
    public var ssh: SSHTunnelConfiguration?
    public var allowLegacyTLS: Bool
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(id: UUID = UUID(), name: String, uri: String, color: ProfileColor = .none, isFavorite: Bool = false,
                ssh: SSHTunnelConfiguration? = nil, allowLegacyTLS: Bool = false, createdAt: Date = Date(), lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
        self.color = color
        self.isFavorite = isFavorite
        self.ssh = ssh
        self.allowLegacyTLS = allowLegacyTLS
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// Profiles that have been used, most recent first.
    public static func recents(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    /// Hosts for display, e.g. `db1:27017, db2:27017` or the SRV name.
    public var hostSummary: String {
        guard let parsed = try? ConnectionString(uri) else { return uri }
        let hosts = parsed.hosts.map { parsed.scheme == .srv ? $0.host : $0.description }.joined(separator: ", ")
        if let ssh { return "\(hosts) via \(ssh.host)" }
        return hosts
    }

    public var displayName: String { name.isEmpty ? hostSummary : name }
}

// MARK: - Secrets

public struct SecretKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case password
        case sshSecret
    }

    public let profileID: UUID
    public let kind: Kind

    public init(profileID: UUID, kind: Kind) {
        self.profileID = profileID
        self.kind = kind
    }

    var account: String { "\(profileID.uuidString).\(kind.rawValue)" }
}

public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Stores `value`, or deletes the secret when `value` is nil.
    func setSecret(_ value: String?, for key: SecretKey) throws
}

/// macOS Keychain (generic passwords, this-device-only, available after first unlock).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.whiteccinn.ccinnmongo.connections") {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MongoError(.invalidArgument, "Keychain read failed (\(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        guard let value else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw MongoError(.invalidArgument, "Keychain delete failed (\(status))")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "CcinnMongo connection secret"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw MongoError(.invalidArgument, "Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw MongoError(.invalidArgument, "Keychain update failed (\(update))")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[SecretKey: String]>(initialState: [:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? { storage.withLock { $0[key] } }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = value }
    }
}

// MARK: - Repository

/// Persists profiles as JSON (atomic writes) and their secrets in a `SecretStore`.
public final class ProfileRepository: Sendable {
    public let directory: URL
    private let secrets: any SecretStore

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnMongo", isDirectory: true)
    }

    public init(directory: URL = ProfileRepository.defaultDirectory, secrets: any SecretStore = KeychainSecretStore()) {
        self.directory = directory
        self.secrets = secrets
    }

    private var fileURL: URL { directory.appendingPathComponent("connections.json") }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profiles).write(to: fileURL, options: [.atomic])
    }

    /// Stores `uri` on the profile without its password, moving the password (and SSH secret) to the secret store.
    public func update(_ profile: inout ConnectionProfile, uri: String, sshSecret: String?) throws {
        var parsed = try ConnectionString(uri)
        let password = parsed.password
        parsed.password = nil
        profile.uri = parsed.description
        try secrets.setSecret(password, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(sshSecret?.isEmpty == true ? nil : sshSecret, for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func password(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .password))
    }

    public func sshSecret(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    /// The full connection string including the stored password.
    public func connectionString(for profile: ConnectionProfile) throws -> ConnectionString {
        var parsed = try ConnectionString(profile.uri)
        if parsed.username != nil, let password = password(for: profile) {
            parsed.password = password
        }
        return parsed
    }

    public func delete(_ profile: ConnectionProfile) throws {
        try secrets.setSecret(nil, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(nil, for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }
}

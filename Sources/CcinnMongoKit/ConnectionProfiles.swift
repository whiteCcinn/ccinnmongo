import Foundation
import MongoKit
import os
import Security

public enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// Whether (and how) AI clients may use a profile through the MCP server.
public enum MCPAccessLevel: String, CaseIterable, Identifiable, Sendable, Codable, Comparable {
    case disabled
    case readOnly
    case readWrite

    public var id: String { rawValue }

    private var rank: Int {
        switch self {
        case .disabled: 0
        case .readOnly: 1
        case .readWrite: 2
        }
    }

    public static func < (lhs: MCPAccessLevel, rhs: MCPAccessLevel) -> Bool { lhs.rank < rhs.rank }

    public var allowsReads: Bool { self != .disabled }
    public var allowsWrites: Bool { self == .readWrite }

    /// The lower of `self` and `limit` (a cap never raises access).
    public func capped(at limit: MCPAccessLevel) -> MCPAccessLevel { min(self, limit) }

    /// The level to save from an editor that loaded `original`: the editor's choice when the user changed it
    /// there, otherwise the currently stored level (which Settings → MCP may have changed meanwhile), so an
    /// unrelated edit can never silently re-enable access that was just turned off.
    public static func merge(edited: MCPAccessLevel, original: MCPAccessLevel, stored: MCPAccessLevel?) -> MCPAccessLevel {
        edited != original ? edited : (stored ?? edited)
    }

    public var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .readOnly: "Read-only"
        case .readWrite: "Read & write"
        }
    }

    /// Unknown or malformed values (e.g. written by a newer version) decode as `.disabled`, so a profile
    /// file can never become unreadable and access is never granted by accident.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try? container.decode(String.self)
        self = raw.flatMap(MCPAccessLevel.init(rawValue:)) ?? .disabled
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
    /// AI access through the MCP server; `.disabled` unless the user opts in.
    public var mcpAccess: MCPAccessLevel

    public init(id: UUID = UUID(), name: String, uri: String, color: ProfileColor = .none, isFavorite: Bool = false,
                ssh: SSHTunnelConfiguration? = nil, allowLegacyTLS: Bool = false, createdAt: Date = Date(), lastConnectedAt: Date? = nil,
                mcpAccess: MCPAccessLevel = .disabled) {
        self.id = id
        self.name = name
        self.uri = uri
        self.color = color
        self.isFavorite = isFavorite
        self.ssh = ssh
        self.allowLegacyTLS = allowLegacyTLS
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.mcpAccess = mcpAccess
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, isFavorite, uri, ssh, allowLegacyTLS, createdAt, lastConnectedAt, mcpAccess
    }

    /// Decodes profile files from every version; keys added after 1.0 are optional.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(ProfileColor.self, forKey: .color)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        uri = try container.decode(String.self, forKey: .uri)
        ssh = try container.decodeIfPresent(SSHTunnelConfiguration.self, forKey: .ssh)
        allowLegacyTLS = try container.decode(Bool.self, forKey: .allowLegacyTLS)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        mcpAccess = try container.decodeIfPresent(MCPAccessLevel.self, forKey: .mcpAccess) ?? .disabled
    }

    /// A copy for "Duplicate": new id and history, and no AI access — a new connection is never exposed to
    /// AI clients without an explicit choice, even when it is copied from one that is.
    public func duplicated() -> ConnectionProfile {
        var copy = self
        copy.id = UUID()
        copy.name = displayName + " copy"
        copy.createdAt = Date()
        copy.lastConnectedAt = nil
        copy.mcpAccess = .disabled
        return copy
    }

    /// Keeps bookkeeping that an editor does not show (creation and last-connected times).
    public mutating func preserveHistory(from original: ConnectionProfile) {
        createdAt = original.createdAt
        lastConnectedAt = original.lastConnectedAt
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
        case tlsCertificatePassword
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

// MARK: - Data location

/// Where CcinnMongo keeps its data, with test-only environment overrides:
/// - `CCINNMONGO_PROFILE_DIR=<absolute path>` uses another data folder (profiles, history, MCP audit log).
/// - `CCINNMONGO_TEST_DISABLE_KEYCHAIN=1` replaces the Keychain with an empty in-memory store.
public enum AppDataLocation {
    public static let directoryVariable = "CCINNMONGO_PROFILE_DIR"
    public static let disableKeychainVariable = "CCINNMONGO_TEST_DISABLE_KEYCHAIN"

    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[directoryVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnMongo", isDirectory: true)
    }

    public static func secretStore(environment: [String: String] = ProcessInfo.processInfo.environment) -> any SecretStore {
        environment[disableKeychainVariable] == "1" ? InMemorySecretStore() : KeychainSecretStore()
    }
}

// MARK: - Repository

/// Persists profiles as JSON (atomic writes) and their secrets in a `SecretStore`.
public final class ProfileRepository: Sendable {
    public let directory: URL
    private let secrets: any SecretStore

    public static var defaultDirectory: URL { AppDataLocation.directory() }

    public init(directory: URL = ProfileRepository.defaultDirectory, secrets: any SecretStore = AppDataLocation.secretStore()) {
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
        let certificatePassword = parsed.tlsCertificateKeyFilePassword
        parsed.setOption("tlsCertificateKeyFilePassword", nil)
        // Any other secret-looking option must never reach the profile file either.
        for option in parsed.options where ConnectionString.isSecretOption(option.name) {
            parsed.setOption(option.name, nil)
        }
        profile.uri = parsed.description
        try secrets.setSecret(password, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(certificatePassword, for: SecretKey(profileID: profile.id, kind: .tlsCertificatePassword))
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
        if let certificatePassword = try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .tlsCertificatePassword)) {
            parsed.setOption("tlsCertificateKeyFilePassword", certificatePassword)
        }
        return parsed
    }

    public func delete(_ profile: ConnectionProfile) throws {
        try secrets.setSecret(nil, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(nil, for: SecretKey(profileID: profile.id, kind: .sshSecret))
        try secrets.setSecret(nil, for: SecretKey(profileID: profile.id, kind: .tlsCertificatePassword))
    }
}

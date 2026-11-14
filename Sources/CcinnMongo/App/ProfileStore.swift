import Foundation
import CcinnMongoKit
import MongoKit
import Observation

/// Shared, observable list of saved connection profiles (persisted via `ProfileRepository`).
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [ConnectionProfile] = []
    var lastError: String?
    let repository: ProfileRepository

    init(repository: ProfileRepository = ProfileRepository()) {
        self.repository = repository
        do {
            profiles = try repository.load()
        } catch {
            lastError = "Could not read saved connections: \(error.localizedDescription)"
        }
    }

    var favorites: [ConnectionProfile] { profiles.filter(\.isFavorite).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }
    var recents: [ConnectionProfile] { Array(ConnectionProfile.recents(profiles.filter { !$0.isFavorite }).prefix(10)) }
    var others: [ConnectionProfile] {
        let recentIDs = Set(recents.map(\.id))
        return profiles.filter { !$0.isFavorite && !recentIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func profile(id: UUID?) -> ConnectionProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Inserts or updates a profile; the password in `uri` and the SSH secret go to the Keychain.
    @discardableResult
    func save(_ profile: ConnectionProfile, uri: String, sshSecret: String?) throws -> ConnectionProfile {
        var updated = profile
        try repository.update(&updated, uri: uri, sshSecret: sshSecret)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        try persist()
        return updated
    }

    func delete(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? repository.delete(profile)
        try? persist()
    }

    func duplicate(_ profile: ConnectionProfile) -> ConnectionProfile? {
        let copy = profile.duplicated()
        let uri = (try? repository.connectionString(for: profile).description) ?? profile.uri
        return try? save(copy, uri: uri, sshSecret: repository.sshSecret(for: profile))
    }

    func toggleFavorite(_ profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isFavorite.toggle()
        try? persist()
    }

    /// Changes only the AI access level (secrets and the rest of the profile stay untouched).
    func setMCPAccess(_ level: MCPAccessLevel, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles[index].mcpAccess != level else { return }
        profiles[index].mcpAccess = level
        try? persist()
    }

    func markConnected(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastConnectedAt = Date()
        try? persist()
    }

    func connectionString(for profile: ConnectionProfile) throws -> ConnectionString {
        try repository.connectionString(for: profile)
    }

    func sshSecret(for profile: ConnectionProfile) -> String? {
        repository.sshSecret(for: profile)
    }

    private func persist() throws {
        do {
            try repository.save(profiles)
            lastError = nil
        } catch {
            lastError = "Could not save connections: \(error.localizedDescription)"
            throw error
        }
    }
}

/// App-wide services shared by every window.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let profiles = ProfileStore()
    let history = QueryHistoryStore()
}

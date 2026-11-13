import Foundation
import MongoKit
import Testing
@testable import GroveKit

@Suite("Connection profiles")
struct ProfileRepositoryTests {
    private func makeRepository() -> (ProfileRepository, URL, InMemorySecretStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grove-tests-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        return (ProfileRepository(directory: directory, secrets: secrets), directory, secrets)
    }

    @Test func passwordsNeverReachTheProfileFile() throws {
        let (repository, directory, secrets) = makeRepository()
        var profile = ConnectionProfile(name: "Prod", uri: "")
        try repository.update(&profile, uri: "mongodb://root:Sup3r%24ecret@db:27017/?authSource=admin", sshSecret: "ssh-pass")
        try repository.save([profile])

        let file = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!file.contains("Sup3r"))
        #expect(!file.contains("ssh-pass"))
        #expect(file.contains("root@db:27017"))
        #expect(try secrets.secret(for: SecretKey(profileID: profile.id, kind: .password)) == "Sup3r$ecret")

        let loaded = try repository.load()
        #expect(loaded == [profile])
        let resolved = try repository.connectionString(for: profile)
        #expect(resolved.password == "Sup3r$ecret")
        #expect(resolved.username == "root")
    }

    @Test func deletingAProfileRemovesItsSecrets() throws {
        let (repository, _, secrets) = makeRepository()
        var profile = ConnectionProfile(name: "A", uri: "")
        try repository.update(&profile, uri: "mongodb://u:p@h/", sshSecret: nil)
        try repository.delete(profile)
        #expect(try secrets.secret(for: SecretKey(profileID: profile.id, kind: .password)) == nil)
    }

    @Test func recentsAreOrderedByLastConnection() {
        let now = Date()
        let a = ConnectionProfile(name: "A", uri: "mongodb://a", lastConnectedAt: now.addingTimeInterval(-60))
        let b = ConnectionProfile(name: "B", uri: "mongodb://b", lastConnectedAt: now)
        let c = ConnectionProfile(name: "C", uri: "mongodb://c")
        #expect(ConnectionProfile.recents([a, b, c]).map(\.name) == ["B", "A"])
    }

    @Test func loadingMissingFileGivesEmptyList() throws {
        let (repository, _, _) = makeRepository()
        #expect(try repository.load().isEmpty)
    }
}

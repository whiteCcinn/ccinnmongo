import Foundation
import MongoKit
import Testing
@testable import CcinnMongoKit

@Suite("Profile MCP access")
struct MCPAccessProfileTests {
    /// A profile file exactly as CcinnMongo 1.0 wrote it (no `mcpAccess` key).
    static let version1File = """
    [
      {
        "allowLegacyTLS" : false,
        "color" : "green",
        "createdAt" : 784800000,
        "id" : "7D1C2D9B-2B9E-4C59-9A55-0E0B1B6A2F10",
        "isFavorite" : true,
        "lastConnectedAt" : 784900000,
        "name" : "Prod",
        "uri" : "mongodb://root@db:27017/?authSource=admin"
      }
    ]
    """

    @Test func profilesFromVersion1AreDisabled() throws {
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(Self.version1File.utf8))
        #expect(profiles.count == 1)
        #expect(profiles[0].mcpAccess == .disabled)
        #expect(profiles[0].name == "Prod")
        #expect(profiles[0].isFavorite)
        #expect(profiles[0].lastConnectedAt == Date(timeIntervalSinceReferenceDate: 784_900_000))
    }

    @Test func unknownAccessValueDecodesAsDisabled() throws {
        let file = Self.version1File.replacingOccurrences(of: "\"name\" : \"Prod\",", with: "\"name\" : \"Prod\",\n\"mcpAccess\" : \"superuser\",")
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(file.utf8))
        #expect(profiles[0].mcpAccess == .disabled)
    }

    @Test func nonStringAccessValueDecodesAsDisabled() throws {
        let file = Self.version1File.replacingOccurrences(of: "\"name\" : \"Prod\",", with: "\"name\" : \"Prod\",\n\"mcpAccess\" : 7,")
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(file.utf8))
        #expect(profiles[0].mcpAccess == .disabled)
    }

    @Test func accessRoundTripsThroughTheRepository() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ProfileRepository(directory: directory, secrets: InMemorySecretStore())
        let readOnly = ConnectionProfile(name: "A", uri: "mongodb://a/", mcpAccess: .readOnly)
        let readWrite = ConnectionProfile(name: "B", uri: "mongodb://b/", mcpAccess: .readWrite)
        let disabled = ConnectionProfile(name: "C", uri: "mongodb://c/")
        try repository.save([readOnly, readWrite, disabled])

        let file = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(file.contains("\"mcpAccess\" : \"readOnly\""))
        #expect(file.contains("\"mcpAccess\" : \"readWrite\""))
        let loaded = try repository.load()
        #expect(loaded.map(\.mcpAccess) == [.readOnly, .readWrite, .disabled])
    }

    @Test func capLowersButNeverRaisesAccess() {
        #expect(MCPAccessLevel.readWrite.capped(at: .readOnly) == .readOnly)
        #expect(MCPAccessLevel.readOnly.capped(at: .readOnly) == .readOnly)
        #expect(MCPAccessLevel.disabled.capped(at: .readOnly) == .disabled)
        #expect(MCPAccessLevel.readOnly.capped(at: .readWrite) == .readOnly)
        #expect(MCPAccessLevel.readWrite.capped(at: .readWrite) == .readWrite)
        #expect(MCPAccessLevel.readWrite.allowsReads)
        #expect(MCPAccessLevel.readWrite.allowsWrites)
        #expect(MCPAccessLevel.readOnly.allowsReads)
        #expect(!MCPAccessLevel.readOnly.allowsWrites)
        #expect(!MCPAccessLevel.disabled.allowsReads)
    }

    @Test func editingKeepsHistoryAndAccess() {
        let original = ConnectionProfile(name: "Prod", uri: "mongodb://db/", createdAt: Date(timeIntervalSince1970: 100),
                                         lastConnectedAt: Date(timeIntervalSince1970: 200), mcpAccess: .readOnly)
        var edited = ConnectionProfile(id: original.id, name: "Prod 2", uri: "mongodb://db2/", mcpAccess: .readWrite)
        edited.preserveHistory(from: original)
        #expect(edited.createdAt == original.createdAt)
        #expect(edited.lastConnectedAt == original.lastConnectedAt)
        #expect(edited.mcpAccess == .readWrite)
        #expect(edited.name == "Prod 2")
    }
}

@Suite("Data directory overrides")
struct DataDirectoryTests {
    @Test func environmentOverridesTheDataDirectory() {
        let url = AppDataLocation.directory(environment: ["CCINNMONGO_PROFILE_DIR": "/tmp/ccinn-test-profiles"])
        #expect(url.path == "/tmp/ccinn-test-profiles")
    }

    @Test func blankOverrideIsIgnored() {
        let url = AppDataLocation.directory(environment: ["CCINNMONGO_PROFILE_DIR": "  "])
        #expect(url.lastPathComponent == "CcinnMongo")
        #expect(url.path.hasSuffix("Application Support/CcinnMongo"))
    }

    @Test func relativeOverrideIsIgnored() {
        let url = AppDataLocation.directory(environment: ["CCINNMONGO_PROFILE_DIR": "relative/dir"])
        #expect(url.lastPathComponent == "CcinnMongo")
    }

    @Test func keychainIsUsedUnlessTheTestSwitchIsSet() {
        #expect(AppDataLocation.secretStore(environment: [:]) is KeychainSecretStore)
        #expect(AppDataLocation.secretStore(environment: ["CCINNMONGO_TEST_DISABLE_KEYCHAIN": "0"]) is KeychainSecretStore)
        #expect(AppDataLocation.secretStore(environment: ["CCINNMONGO_TEST_DISABLE_KEYCHAIN": "1"]) is InMemorySecretStore)
    }
}

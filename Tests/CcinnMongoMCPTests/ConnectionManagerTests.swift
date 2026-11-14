import BSON
import CcinnMongoKit
import Foundation
import MongoKit
import Testing
@testable import CcinnMongoMCP

/// Opener double that counts openings and closings and can be made slow or failing.
final class FakeOpener: MCPSessionOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _opens = 0
    private var _closes = 0
    var delay: Duration = .zero
    var failNext = false

    var opens: Int { lock.withLock { _opens } }
    var closes: Int { lock.withLock { _closes } }

    func open(_ profile: ConnectionProfile) async throws -> OpenedSession {
        lock.withLock { _opens += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        let shouldFail = lock.withLock { () -> Bool in
            defer { failNext = false }
            return failNext
        }
        if shouldFail { throw MongoError(.network, "unreachable") }
        let session = MongoSession(client: FakeMongoClient(),
                                   server: ServerDescription(version: "8.0.0", maxWireVersion: 25, serverType: "Standalone", setName: nil,
                                                             members: [], gitVersion: nil, isEnterprise: false))
        return OpenedSession(session: session) { [self] in lock.withLock { _closes += 1 } }
    }
}

@Suite("Connection manager")
struct ConnectionManagerTests {
    let profile = ConnectionProfile(name: "A", uri: "mongodb://a:27017/", mcpAccess: .readOnly)

    @Test func reusesOneSessionPerProfile() async throws {
        let opener = FakeOpener()
        let manager = MCPConnectionManager(opener: opener)
        _ = try await manager.session(for: profile)
        _ = try await manager.session(for: profile)
        #expect(opener.opens == 1)
        await manager.closeAll()
        #expect(opener.closes == 1)
    }

    @Test func concurrentFirstCallsShareOneOpening() async throws {
        let opener = FakeOpener()
        opener.delay = .milliseconds(50)
        let manager = MCPConnectionManager(opener: opener)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await manager.session(for: profile) } }
            try await group.waitForAll()
        }
        #expect(opener.opens == 1)
        await manager.closeAll()
    }

    @Test func profileChangesReopen() async throws {
        let opener = FakeOpener()
        let manager = MCPConnectionManager(opener: opener)
        _ = try await manager.session(for: profile)
        var edited = profile
        edited.uri = "mongodb://b:27017/"
        _ = try await manager.session(for: edited)
        #expect(opener.opens == 2)
        try await waitUntil { opener.closes == 1 }
        // Changing only the AI access level does not reopen.
        edited.mcpAccess = .readWrite
        _ = try await manager.session(for: edited)
        #expect(opener.opens == 2)
        await manager.closeAll()
    }

    @Test func failedOpeningsAreNotCached() async throws {
        let opener = FakeOpener()
        opener.failNext = true
        let manager = MCPConnectionManager(opener: opener)
        await #expect(throws: MongoError.self) { try await manager.session(for: profile) }
        _ = try await manager.session(for: profile)
        #expect(opener.opens == 2)
        await manager.closeAll()
    }

    @Test func evictionClosesAndReopens() async throws {
        let opener = FakeOpener()
        let manager = MCPConnectionManager(opener: opener)
        _ = try await manager.session(for: profile)
        await manager.evict(profile.id)
        try await waitUntil { opener.closes == 1 }
        _ = try await manager.session(for: profile)
        #expect(opener.opens == 2)
        await manager.closeAll()
        #expect(opener.closes == 2)
    }

    @Test func waitingCallerCanBeCancelledWhileTheOpeningContinues() async throws {
        let opener = FakeOpener()
        opener.delay = .seconds(2)
        let manager = MCPConnectionManager(opener: opener)
        let waiter = Task { try await manager.session(for: profile) }
        try await waitUntil { opener.opens == 1 }
        let started = ContinuousClock.now
        waiter.cancel()
        _ = await waiter.result
        #expect(ContinuousClock.now - started < .seconds(1))
        await manager.closeAll()
    }

    @Test func pruneClosesSessionsOfProfilesNoLongerEnabled() async throws {
        let opener = FakeOpener()
        let manager = MCPConnectionManager(opener: opener)
        let other = ConnectionProfile(name: "B", uri: "mongodb://b:27017/", mcpAccess: .readOnly)
        _ = try await manager.session(for: profile)
        _ = try await manager.session(for: other)
        await manager.prune(keeping: [other.id])
        try await waitUntil { opener.closes == 1 }
        _ = try await manager.session(for: other)
        #expect(opener.opens == 2)
        await manager.closeAll()
    }

    @Test func openingThatFailsAfterItsWaiterLeftIsNotCached() async throws {
        let opener = FakeOpener()
        opener.delay = .milliseconds(300)
        opener.failNext = true
        let manager = MCPConnectionManager(opener: opener)
        let waiter = Task { try await manager.session(for: profile) }
        try await waitUntil { opener.opens == 1 }
        waiter.cancel()
        _ = await waiter.result
        // Let the shared opening fail with nobody waiting for it.
        try await Task.sleep(for: .milliseconds(600))
        opener.delay = .zero
        _ = try await manager.session(for: profile)
        #expect(opener.opens == 2)
        await manager.closeAll()
    }

    @Test func closedManagerRefusesNewSessions() async throws {
        let manager = MCPConnectionManager(opener: FakeOpener())
        await manager.closeAll()
        await #expect(throws: (any Error).self) { try await manager.session(for: profile) }
    }
}

@Suite("Profile session opener")
struct ProfileSessionOpenerTests {
    @Test func invalidConnectionStringsNeverEchoTheParserText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-mcp-opener-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ProfileRepository(directory: directory, secrets: InMemorySecretStore())
        // A hand-edited profile whose inline password contains '/', so the parser reports part of it as the port.
        let profile = ConnectionProfile(name: "Broken", uri: "mongodb://admin:S3cr3tPart/rest@127.0.0.1:1/", mcpAccess: .readOnly)
        do {
            _ = try await ProfileSessionOpener(repository: repository).open(profile)
            Issue.record("expected a failure")
        } catch {
            let message = "\(error)"
            #expect(!message.contains("S3cr3t"))
            #expect(!message.contains("rest@"))
            #expect(message.contains("Broken"))
        }
    }
}

@Suite("Profile file source")
struct ProfileFileSourceTests {
    @Test func reloadsWhenTheFileChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-mcp-src-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ProfileRepository(directory: directory, secrets: InMemorySecretStore())
        let source = ProfileFileSource(repository: repository)
        #expect(try source.loadProfiles().isEmpty)
        try repository.save([ConnectionProfile(name: "A", uri: "mongodb://a/", mcpAccess: .readOnly)])
        #expect(try source.loadProfiles().map(\.name) == ["A"])
        try repository.save([ConnectionProfile(name: "A", uri: "mongodb://a/", mcpAccess: .readOnly),
                             ConnectionProfile(name: "Bee", uri: "mongodb://b/", mcpAccess: .readWrite)])
        #expect(try source.loadProfiles().map(\.name) == ["A", "Bee"])
    }
}

@Suite("Audit log")
struct AuditLogTests {
    @Test func concurrentWritersFromSeveralProcessesNeverClobberLines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-mcp-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two independent logs model two MCP processes appending to the same file.
        let first = MCPAuditLog(directory: directory, maxBytes: 50 * 1024 * 1024)
        let second = MCPAuditLog(directory: directory, maxBytes: 50 * 1024 * 1024)
        await withTaskGroup(of: Void.self) { group in
            for (log, name) in [(first, "first"), (second, "second")] {
                group.addTask {
                    for index in 0..<300 {
                        await log.record(MCPAuditRecord(date: Date(), connection: name, connectionID: nil, tool: "find",
                                                        operation: "op \(index) " + String(repeating: "x", count: 300),
                                                        durationMilliseconds: 1, documents: 1, error: nil))
                    }
                }
            }
        }
        let lines = try String(contentsOf: directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 600)
        for line in lines { #expect(throws: Never.self) { try JSONParser.parse(String(line)) } }
    }

    @Test func concurrentRotationNeverDiscardsAFullLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-mcp-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let maxBytes = 20_000
        let logs = (0..<4).map { _ in MCPAuditLog(directory: directory, maxBytes: maxBytes) }
        await withTaskGroup(of: Void.self) { group in
            for (number, log) in logs.enumerated() {
                group.addTask {
                    for index in 0..<150 {
                        await log.record(MCPAuditRecord(date: Date(), connection: "p\(number)", connectionID: nil, tool: "find",
                                                        operation: "op \(index) " + String(repeating: "x", count: 250),
                                                        durationMilliseconds: 1, documents: 1, error: nil))
                    }
                }
            }
        }
        // Rotation only ever moves a nearly full log aside; a racing second rename would replace it with a stub.
        let rotated = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("mcp-audit.1.jsonl").path)
        let size = (rotated[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > maxBytes - 1_000)
    }

    @Test func appendsJSONLinesAndRotates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-mcp-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = MCPAuditLog(directory: directory, maxBytes: 2_000)
        for index in 0..<40 {
            await log.record(MCPAuditRecord(date: Date(timeIntervalSince1970: 0), connection: "A", connectionID: nil, tool: "find",
                                            operation: "shop.orders find #\(index)", durationMilliseconds: 3, documents: 1, error: nil))
        }
        let current = try String(contentsOf: directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
        let rotated = try String(contentsOf: directory.appendingPathComponent("mcp-audit.1.jsonl"), encoding: .utf8)
        #expect(current.utf8.count <= 2_200)
        #expect(!rotated.isEmpty)
        for line in current.split(separator: "\n") {
            let value = try JSONParser.parse(String(line))
            #expect(value.objectValue?["source"] == "mcp")
            #expect(value.objectValue?["tool"] == "find")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("mcp-audit.jsonl").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

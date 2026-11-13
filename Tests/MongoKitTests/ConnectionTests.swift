import BSON
import Foundation
import Testing
@testable import MongoKit

@Suite("Connection and protocol negotiation")
struct ConnectionTests {
    private func connect(_ server: FakeMongoServer) async throws -> MongoConnection {
        let connection = MongoConnection(id: 1, address: ServerAddress(host: "fake"), transport: server.makeTransport())
        try await connection.handshake(appName: "tests", saslSupportedMechsFor: nil)
        return connection
    }

    @Test(arguments: [2, 3, 4, 5])
    func legacyServersReceiveOpQueryCommands(wireVersion: Int) async throws {
        let server = FakeMongoServer(.init(maxWireVersion: wireVersion))
        let connection = try await connect(server)
        _ = try await connection.runCommand(["ping": 1], database: "admin")
        guard case let .command(database, body, viaOpMsg, _) = server.requests.last else {
            Issue.record("expected a command")
            return
        }
        #expect(database == "admin")
        #expect(body == ["ping": 1])
        #expect(!viaOpMsg)
    }

    @Test(arguments: [6, 7, 13, 21, 25])
    func modernServersReceiveOpMsgCommands(wireVersion: Int) async throws {
        let server = FakeMongoServer(.init(maxWireVersion: wireVersion))
        let connection = try await connect(server)
        _ = try await connection.runCommand(["ping": 1], database: "test")
        guard case let .command(database, _, viaOpMsg, _) = server.requests.last else {
            Issue.record("expected a command")
            return
        }
        #expect(database == "test")
        #expect(viaOpMsg)
        // The handshake itself is always OP_QUERY so every server version understands it.
        guard case let .command(_, _, handshakeViaOpMsg, _) = server.requests.first else {
            Issue.record("expected handshake")
            return
        }
        #expect(!handshakeViaOpMsg)
    }

    @Test func rejectsServersOlderThan26() async {
        let server = FakeMongoServer(.init(maxWireVersion: 1))
        await #expect {
            _ = try await connect(server)
        } throws: { error in
            (error as? MongoError)?.kind == .unsupportedServer && (error as? MongoError)?.message.contains("2.6") == true
        }
    }

    @Test func commandFailureBecomesMongoError() async throws {
        let server = FakeMongoServer(.init(maxWireVersion: 5)) { _ in
            .document(["ok": 0, "errmsg": "no such command: 'bogus'", "code": 59, "codeName": "CommandNotFound"])
        }
        let connection = try await connect(server)
        await #expect {
            _ = try await connection.runCommand(["bogus": 1], database: "admin")
        } throws: { error in
            let mongo = error as? MongoError
            return mongo?.code == 59 && mongo?.message.contains("bogus") == true
        }
        // Raw mode returns the failure without throwing.
        let raw = try await connection.runCommandRaw(["bogus": 1], database: "admin")
        #expect(raw["ok"] == .int32(0))
        #expect(await !connection.isBroken)
    }

    @Test func reassemblesChunkedReplies() async throws {
        let big = String(repeating: "x", count: 50_000)
        var config = FakeMongoServer.Configuration(maxWireVersion: 25)
        config.chunkSize = 7
        let server = FakeMongoServer(config) { _ in .document(["ok": 1, "payload": .string(big)]) }
        let connection = try await connect(server)
        let reply = try await connection.runCommand(["echo": 1], database: "admin")
        #expect(reply["payload"] == .string(big))
    }

    @Test func disconnectMarksConnectionBroken() async throws {
        let server = FakeMongoServer(.init(maxWireVersion: 25)) { _ in .disconnect }
        let connection = try await connect(server)
        await #expect {
            _ = try await connection.runCommand(["ping": 1], database: "admin")
        } throws: { error in
            (error as? MongoError)?.isNetworkError == true
        }
        #expect(await connection.isBroken)
        await #expect(throws: MongoError.self) { _ = try await connection.runCommand(["ping": 1], database: "admin") }
    }

    @Test func cancellationUnblocksAPendingRead() async throws {
        let server = FakeMongoServer(.init(maxWireVersion: 25)) { _ in .none } // never replies
        let connection = try await connect(server)
        let task = Task { try await connection.runCommand(["sleep": 1], database: "admin") }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let result = await task.result
        #expect(clock.now - start < .milliseconds(200))
        guard case let .failure(error) = result else {
            Issue.record("expected cancellation")
            return
        }
        #expect((error as? MongoError)?.kind == .cancelled)
        #expect(await connection.isBroken)
    }

    @Test func legacyQueryFailureIsReported() async throws {
        let server = FakeMongoServer(.init(maxWireVersion: 2)) { request in
            if case .query = request { return .legacy(cursorID: 0, documents: [["$err": "bad query", "code": 2]], flags: 2) }
            return .document(["ok": 1])
        }
        let connection = try await connect(server)
        await #expect {
            _ = try await connection.legacyQuery(.init(fullCollectionName: "db.c", numberToReturn: 1, query: ["$bad": 1]))
        } throws: { error in
            (error as? MongoError)?.message == "bad query"
        }
    }

    @Test func secondaryGetsSecondaryOkFlag() async throws {
        var config = FakeMongoServer.Configuration(maxWireVersion: 5, setName: "rs0", isWritablePrimary: false, isSecondary: true)
        config.hosts = ["a:27017", "b:27017"]
        let server = FakeMongoServer(config)
        let connection = try await connect(server)
        _ = try await connection.runCommand(["count": "c"], database: "db")
        guard case let .command(_, _, _, secondaryOk) = server.requests.last else {
            Issue.record("expected command")
            return
        }
        #expect(secondaryOk)
    }
}

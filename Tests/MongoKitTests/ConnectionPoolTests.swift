import BSON
import Foundation
import Testing
@testable import MongoKit

@Suite("Connection pool")
struct ConnectionPoolTests {
    private func makePool(_ server: FakeMongoServer, maxSize: Int) -> ConnectionPool {
        let factory = ConnectionFactory(transportFactory: server.transportFactory, transportOptions: TransportOptions(),
                                        credential: nil, appName: nil, readPreference: .primary)
        let address = ServerAddress(host: "fake")
        return ConnectionPool(address: address, maxSize: maxSize) { try await factory.makeConnection(to: address) }
    }

    @Test func boundsConcurrentSockets() async throws {
        let server = FakeMongoServer(.init(maxWireVersion: 25)) { _ in .document(["ok": 1]) }
        let pool = makePool(server, maxSize: 4)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await pool.withConnection { connection in
                        _ = try await connection.runCommand(["ping": 1], database: "admin")
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(server.transportsCreated <= 4)
        let stats = await pool.statistics
        #expect(stats.open <= 4)
        #expect(stats.waiting == 0)
        await pool.close()
        #expect(server.openTransports == 0)
    }

    @Test func brokenConnectionsAreReplaced() async throws {
        let failNext = FlagBox()
        let server = FakeMongoServer(.init(maxWireVersion: 25)) { request in
            if request.commandName == "boom", failNext.take() { return .disconnect }
            return .document(["ok": 1])
        }
        failNext.set()
        let pool = makePool(server, maxSize: 1)
        await #expect(throws: MongoError.self) {
            try await pool.withConnection { _ = try await $0.runCommand(["boom": 1], database: "admin") }
        }
        // The broken socket must not be reused: a fresh one is created.
        try await pool.withConnection { _ = try await $0.runCommand(["ping": 1], database: "admin") }
        #expect(server.transportsCreated == 2)
        let stats = await pool.statistics
        #expect(stats.open == 1)
    }

    @Test func cancelledWaiterDoesNotLeakSlots() async throws {
        let server = FakeMongoServer(.init(maxWireVersion: 25)) { _ in .document(["ok": 1]) }
        let pool = makePool(server, maxSize: 1)
        let holder = try await pool.checkout()
        let waiter = Task { try await pool.withConnection { _ in 1 } }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        _ = await waiter.result
        await pool.checkin(holder)
        let value = try await pool.withConnection { _ in 42 }
        #expect(value == 42)
        let stats = await pool.statistics
        #expect(stats.open == 1)
        #expect(stats.waiting == 0)
    }

    @Test func closeFailsWaitersAndRejectsCheckouts() async throws {
        let server = FakeMongoServer(.init(maxWireVersion: 25)) { _ in .document(["ok": 1]) }
        let pool = makePool(server, maxSize: 1)
        let holder = try await pool.checkout()
        let waiter = Task { try await pool.withConnection { _ in 1 } }
        try await Task.sleep(for: .milliseconds(30))
        await pool.close()
        await #expect(throws: MongoError.self) { _ = try await waiter.value }
        await pool.checkin(holder)
        await #expect(throws: MongoError.self) { _ = try await pool.checkout() }
        #expect(server.openTransports == 0)
    }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func take() -> Bool { lock.withLock { defer { value = false }; return value } }
}

import BSON
import Foundation
import MongoWire
import Testing
@testable import MongoKit

/// Regression tests for issues found in the adversarial review.
@Suite("Review regressions (MongoKit)")
struct ReviewRegressionTests {
    @Test func redactedMasksEveryCredential() throws {
        let uri = try ConnectionString("mongodb://alice:pw@h/?tls=true&tlsCertificateKeyFile=%2Fk.p12&tlsCertificateKeyFilePassword=p12-secret")
        #expect(!uri.redacted.contains("p12-secret"))
        #expect(!uri.redacted.contains(":pw@"))
        #expect(uri.redacted.contains("tlsCertificateKeyFilePassword=****"))
    }

    @Test func scramRejectsAbsurdIterationCounts() {
        var client = ScramClient(variant: .sha256, username: "u", password: "p", clientNonce: "abc")
        #expect(throws: MongoError.self) {
            try client.clientFinalMessage(serverFirst: "r=abcdef,s=QSXCR+Q6sek8bf92,i=2147483647")
        }
    }

    @Test func legacyFindAlwaysWrapsTheFilter() {
        // Without $query, a top-level `query` field would be interpreted as the wrapped query by 2.6/3.0.
        let query = LegacyQueryFindStrategy.query(MongoNamespace(database: "d", collection: "c"),
                                                  FindOptions(filter: ["query": ["a": 1]], limit: 5), explain: false)
        #expect(query.query["$query"] == .document(["query": ["a": 1]]))
    }

    @Test func handshakeThatNeverAnswersTimesOut() async throws {
        var config = FakeMongoServer.Configuration(maxWireVersion: 25)
        config.silent = true
        let server = FakeMongoServer(config)
        let client = MongoClient(try ConnectionString("mongodb://fake:27017/?connectTimeoutMS=400"),
                                 options: MongoClientOptions(transportFactory: server.transportFactory))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect {
            try await client.connect()
        } throws: { error in
            (error as? MongoError)?.kind == .timeout || (error as? MongoError)?.kind == .serverSelection
        }
        #expect(clock.now - start < .seconds(5))
        await client.close()
    }

    @Test func cancellingConnectReturnsPromptly() async throws {
        var config = FakeMongoServer.Configuration(maxWireVersion: 25)
        config.silent = true
        let server = FakeMongoServer(config)
        let client = MongoClient(try ConnectionString("mongodb://fake:27017/?connectTimeoutMS=60000"),
                                 options: MongoClientOptions(transportFactory: server.transportFactory))
        let task = Task { try await client.connect() }
        try await Task.sleep(for: .milliseconds(150))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        _ = await task.result
        #expect(clock.now - start < .seconds(2))
        await client.close()
        #expect(server.openTransports == 0)
    }

    @Test func poolAccountingSurvivesCloseDuringCreation() async throws {
        let gate = Gate()
        let server = FakeMongoServer(.init(maxWireVersion: 25))
        let factory = ConnectionFactory(transportFactory: server.transportFactory, transportOptions: TransportOptions(),
                                        credential: nil, appName: nil, readPreference: .primary)
        let address = ServerAddress(host: "fake")
        let pool = ConnectionPool(address: address, maxSize: 2) {
            await gate.wait()
            return try await factory.makeConnection(to: address)
        }
        let checkout = Task { try await pool.checkout() }
        try await Task.sleep(for: .milliseconds(50))
        await pool.close()
        await gate.open()
        _ = await checkout.result
        let stats = await pool.statistics
        #expect(stats.open == 0)
    }

    @Test func hugeIntegralDoublesDoNotTrapIndexNames() {
        #expect(MongoClient.defaultIndexName(["x": .double(1e300)]) == "x_1e+300")
    }

    @Test func nanCountsDoNotTrap() {
        #expect(CollectionStats(raw: ["count": .double(.nan)]).documentCount == nil)
        #expect(CollectionStats(raw: ["count": .double(1e30)]).documentCount == nil)
    }
}

actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

import BSON
import CcinnMongoKit
import Foundation
import MongoKit
@testable import CcinnMongoMCP

/// Records operations and returns canned results.
final class FakeMongoClient: MongoToolClient, @unchecked Sendable {
    struct Call: Equatable {
        var operation: String
        var namespace: String
        var detail: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var documents: [BSONDocument] = []
    var countResult: Int64? = 0
    var databases: [DatabaseInfo] = [DatabaseInfo(name: "shop", sizeOnDisk: 4096, isEmpty: false)]
    var collections: [CollectionInfo] = [CollectionInfo(name: "orders"), CollectionInfo(name: "system.views"),
                                         CollectionInfo(name: "recent", kind: .view, options: ["viewOn": "orders"])]
    var indexes: [IndexInfo] = [IndexInfo(raw: ["v": 2, "key": ["_id": 1], "name": "_id_"]),
                                IndexInfo(raw: ["v": 2, "key": ["status": 1, "total": -1], "name": "status_1_total_-1", "unique": true])]
    var explainResult: BSONDocument = ["queryPlanner": ["winningPlan": ["stage": "COLLSCAN"]],
                                       "executionStats": ["nReturned": 2, "totalDocsExamined": 10, "totalKeysExamined": 0, "executionTimeMillis": 1]]
    var error: (any Error)?
    /// When set, operations wait until cancelled.
    var hangs = false
    var lastFindOptions: FindOptions?
    var lastPipeline: [BSONDocument]?
    var lastAggregateOptions: AggregateOptions?
    var lastCountOptions: CountOptions?

    var calls: [Call] { lock.withLock { _calls } }

    private func record(_ operation: String, _ namespace: String, _ detail: String = "") async throws {
        lock.withLock { _calls.append(Call(operation: operation, namespace: namespace, detail: detail)) }
        if hangs {
            // One long sleep that ends as soon as the task is cancelled. Polling every few milliseconds kept the
            // small Swift concurrency pool of CI runners busy and slowed every other test.
            try? await Task.sleep(for: .seconds(3_600))
            throw MongoError(.cancelled, "The operation was cancelled")
        }
        if let error { throw error }
    }

    func listDatabases() async throws -> [DatabaseInfo] {
        try await record("listDatabases", "")
        return databases
    }

    func listCollections(database: String) async throws -> [CollectionInfo] {
        try await record("listCollections", database)
        return collections
    }

    func listIndexes(_ namespace: MongoNamespace) async throws -> [IndexInfo] {
        try await record("listIndexes", namespace.fullName)
        return indexes
    }

    func indexUsage(_ namespace: MongoNamespace) async throws -> [String: IndexUsage]? {
        ["_id_": IndexUsage(name: "_id_", operations: 7, since: nil)]
    }

    private(set) var lastBatchSize: Int?
    private var _batchesDelivered = 0
    var batchesDelivered: Int { lock.withLock { _batchesDelivered } }

    private func stream(_ limit: Int, batchSize: Int, _ body: @Sendable ([BSONDocument]) async throws -> Void) async throws {
        lock.withLock { lastBatchSize = batchSize }
        let selected = limit > 0 ? Array(documents.prefix(limit)) : documents
        var start = 0
        while start < selected.count {
            let end = min(selected.count, start + max(1, batchSize))
            lock.withLock { _batchesDelivered += 1 }
            try await body(Array(selected[start..<end]))
            start = end
        }
    }

    func forEachBatch(_ namespace: MongoNamespace, options: FindOptions, batchSize: Int,
                      _ body: @Sendable ([BSONDocument]) async throws -> Void) async throws {
        lock.withLock { lastFindOptions = options }
        try await record("find", namespace.fullName)
        try await stream(options.limit, batchSize: batchSize, body)
    }

    func forEachAggregateBatch(_ namespace: MongoNamespace, pipeline: [BSONDocument], options: AggregateOptions, batchSize: Int,
                               _ body: @Sendable ([BSONDocument]) async throws -> Void) async throws {
        lock.withLock {
            lastPipeline = pipeline
            lastAggregateOptions = options
        }
        try await record("aggregate", namespace.fullName)
        try await stream(options.maxResults, batchSize: batchSize, body)
    }

    func count(_ namespace: MongoNamespace, filter: BSONDocument, options: CountOptions) async throws -> Int64? {
        lock.withLock { lastCountOptions = options }
        try await record("count", namespace.fullName, BSONFormatter(style: .shell).format(filter))
        return countResult
    }

    func explainFind(_ namespace: MongoNamespace, options: FindOptions) async throws -> BSONDocument {
        try await record("explainFind", namespace.fullName)
        return explainResult
    }

    func explainAggregate(_ namespace: MongoNamespace, pipeline: [BSONDocument], options: AggregateOptions) async throws -> BSONDocument {
        try await record("explainAggregate", namespace.fullName)
        return explainResult
    }

    func insert(_ documents: [BSONDocument], into namespace: MongoNamespace) async throws -> InsertResult {
        try await record("insert", namespace.fullName)
        return InsertResult(insertedCount: documents.count, insertedIDs: documents.compactMap { $0["_id"] ?? .int32(1) })
    }

    func updateDocuments(_ namespace: MongoNamespace, filter: BSONDocument, update: BSONDocument, many: Bool, upsert: Bool,
                         collation: BSONDocument?) async throws -> UpdateResult {
        try await record("update", namespace.fullName, "many=\(many) upsert=\(upsert)")
        return UpdateResult(matchedCount: Int(countResult ?? 0), modifiedCount: Int(countResult ?? 0), upsertedID: nil)
    }

    func deleteDocuments(_ namespace: MongoNamespace, filter: BSONDocument, many: Bool, collation: BSONDocument?) async throws -> Int {
        try await record("delete", namespace.fullName, "many=\(many)")
        return Int(countResult ?? 0)
    }
}

/// Hands out one fake client per profile and counts openings.
final class FakeSessions: MCPSessionSource, @unchecked Sendable {
    private let lock = NSLock()
    let client: FakeMongoClient
    var server = ServerDescription(version: "8.0.4", maxWireVersion: 25, serverType: "Standalone", setName: nil, members: [],
                                   gitVersion: "abc", isEnterprise: false)
    var openError: (any Error)?
    private var _opened: [UUID] = []
    private var _evicted: [UUID] = []

    init(client: FakeMongoClient = FakeMongoClient()) {
        self.client = client
    }

    var opened: [UUID] { lock.withLock { _opened } }
    var evicted: [UUID] { lock.withLock { _evicted } }

    func session(for profile: ConnectionProfile) async throws -> MongoSession {
        lock.withLock { _opened.append(profile.id) }
        if let openError { throw openError }
        return MongoSession(client: client, server: server)
    }

    func evict(_ profileID: UUID, sessionID: UInt64) async {
        lock.withLock { _evicted.append(profileID) }
    }

    private var _kept: Set<UUID>?
    var kept: Set<UUID>? { lock.withLock { _kept } }

    func prune(keeping profileIDs: Set<UUID>) async {
        lock.withLock { _kept = profileIDs }
    }
}

struct StaticProfiles: MCPProfileSource {
    var profiles: [ConnectionProfile]
    var error: (any Error)?

    func loadProfiles() throws -> [ConnectionProfile] {
        if let error { throw error }
        return profiles
    }
}

actor RecordingAudit: MCPAuditSink {
    private(set) var records: [MCPAuditRecord] = []
    func record(_ entry: MCPAuditRecord) async { records.append(entry) }
}

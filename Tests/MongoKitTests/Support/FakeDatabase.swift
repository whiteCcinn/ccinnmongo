import BSON
import Foundation
import os
@testable import MongoKit

/// Tiny in-memory implementation of the commands/opcodes MongoKit uses, answering in either the
/// modern command form or the legacy opcode form. Batches are deliberately small (`serverBatch`)
/// so cursor continuation logic is exercised.
final class FakeDatabase: @unchecked Sendable {
    struct Cursor {
        var namespace: String
        var remaining: [BSONDocument]
    }

    struct State {
        var collections: [String: [BSONDocument]] = [:] // key: "db.coll"
        var indexes: [String: [BSONDocument]] = [:]
        var cursors: [Int64: Cursor] = [:]
        var nextCursorID: Int64 = 1000
        var killedCursors: [Int64] = []
    }

    let serverBatch: Int
    let state = OSAllocatedUnfairLock(initialState: State())
    var unauthorizedListDatabases = false
    var countTimesOut = false

    init(serverBatch: Int = 7) {
        self.serverBatch = serverBatch
    }

    func seed(_ namespace: String, _ documents: [BSONDocument]) {
        state.withLock {
            $0.collections[namespace] = documents
            $0.indexes[namespace] = [["v": 1, "key": ["_id": 1], "name": "_id_", "ns": .string(namespace)]]
        }
    }

    var killedCursors: [Int64] { state.withLock { $0.killedCursors } }
    var openCursorCount: Int { state.withLock { $0.cursors.count } }

    // MARK: Handler

    func handle(_ request: FakeMongoServer.Request) -> FakeMongoServer.Response {
        switch request {
        case let .command(database, body, _, _):
            return .document(command(database: database, body: body))
        case let .query(namespace, query, skip, numberToReturn, _, _):
            return legacyQuery(namespace: namespace, query: query, skip: Int(skip), numberToReturn: Int(numberToReturn))
        case let .getMore(_, numberToReturn, cursorID):
            let (documents, id) = nextBatch(cursorID: cursorID, requested: Int(numberToReturn))
            return .legacy(cursorID: id, documents: documents)
        case let .killCursors(ids):
            state.withLock { state in
                for id in ids { state.cursors[id] = nil }
                state.killedCursors += ids
            }
            return .none
        }
    }

    private func documents(_ namespace: String) -> [BSONDocument] {
        state.withLock { $0.collections[namespace] ?? [] }
    }

    /// Simple equality filter on top-level fields; good enough for these tests.
    private func matches(_ document: BSONDocument, _ filter: BSONDocument) -> Bool {
        filter.elements.allSatisfy { document[$0.key] == $0.value }
    }

    private func sorted(_ documents: [BSONDocument], by sort: BSONDocument?) -> [BSONDocument] {
        guard let sort, let field = sort.keys.first else { return documents }
        let descending = sort[field]?.int64Value == -1
        return documents.sorted { a, b in
            let x = a[field]?.int64Value ?? 0
            let y = b[field]?.int64Value ?? 0
            return descending ? x > y : x < y
        }
    }

    /// Returns the first batch and opens a cursor for the rest.
    private func openCursor(namespace: String, results: [BSONDocument], firstBatchLimit: Int) -> ([BSONDocument], Int64) {
        let take = min(results.count, min(serverBatch, firstBatchLimit > 0 ? firstBatchLimit : Int.max))
        let first = Array(results.prefix(take))
        let rest = Array(results.dropFirst(take))
        guard !rest.isEmpty else { return (first, 0) }
        let id: Int64 = state.withLock { state in
            state.nextCursorID += 1
            state.cursors[state.nextCursorID] = Cursor(namespace: namespace, remaining: rest)
            return state.nextCursorID
        }
        return (first, id)
    }

    private func nextBatch(cursorID: Int64, requested: Int) -> ([BSONDocument], Int64) {
        state.withLock { state in
            guard var cursor = state.cursors[cursorID] else { return ([], 0) }
            let take = min(cursor.remaining.count, min(serverBatch, requested > 0 ? requested : Int.max))
            let batch = Array(cursor.remaining.prefix(take))
            cursor.remaining.removeFirst(take)
            if cursor.remaining.isEmpty {
                state.cursors[cursorID] = nil
                return (batch, 0)
            }
            state.cursors[cursorID] = cursor
            return (batch, cursorID)
        }
    }

    private func legacyQuery(namespace: String, query: BSONDocument, skip: Int, numberToReturn: Int) -> FakeMongoServer.Response {
        if namespace.hasSuffix(".system.namespaces") {
            let database = String(namespace.dropLast(".system.namespaces".count))
            let names = state.withLock { Array($0.collections.keys) }.filter { $0.hasPrefix(database + ".") }.sorted()
            var rows: [BSONDocument] = names.map { ["name": .string($0)] }
            rows += names.map { ["name": .string("\($0).$_id_")] }
            rows.append(["name": .string("\(database).system.indexes")])
            return .legacy(cursorID: 0, documents: rows)
        }
        if namespace.hasSuffix(".system.indexes") {
            let target = query["ns"]?.stringValue ?? ""
            return .legacy(cursorID: 0, documents: state.withLock { $0.indexes[target] ?? [] })
        }
        var filter = query
        var sort: BSONDocument?
        if let inner = query["$query"]?.documentValue {
            filter = inner
            sort = query["$orderby"]?.documentValue
            if query["$explain"]?.isTruthy == true {
                return .legacy(cursorID: 0, documents: [["cursor": "BasicCursor", "n": 1, "nscanned": 10, "millis": 0]])
            }
        }
        let results = Array(sorted(documents(namespace).filter { matches($0, filter) }, by: sort).dropFirst(skip))
        let limit = abs(numberToReturn)
        let (batch, id) = openCursor(namespace: namespace, results: results, firstBatchLimit: limit)
        return .legacy(cursorID: numberToReturn < 0 ? 0 : id, documents: batch)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func command(database: String, body: BSONDocument) -> BSONDocument {
        guard let name = body.elements.first?.key else { return ["ok": 0, "errmsg": "empty command"] }
        switch name {
        case "ping", "buildInfo":
            return ["ok": 1, "version": "9.9.9"]
        case "listDatabases":
            if unauthorizedListDatabases {
                return ["ok": 0, "errmsg": "not authorized on admin to execute command", "code": 13, "codeName": "Unauthorized"]
            }
            let names = Set(state.withLock { Array($0.collections.keys) }.compactMap { $0.split(separator: ".").first.map(String.init) })
            return ["ok": 1, "databases": .array(names.sorted().map { ["name": .string($0), "sizeOnDisk": 8192.0, "empty": false] })]
        case "listCollections":
            let names = state.withLock { Array($0.collections.keys) }.filter { $0.hasPrefix(database + ".") }.sorted()
            let rows: [BSONValue] = names.map { ["name": .string(String($0.dropFirst(database.count + 1))), "type": "collection", "options": [:]] }
            let (batch, id) = openCursor(namespace: "\(database).$cmd.listCollections", results: rows.compactMap(\.documentValue), firstBatchLimit: 0)
            return cursorReply(id: id, namespace: "\(database).$cmd.listCollections", batch: batch, key: "firstBatch")
        case "listIndexes":
            let namespace = "\(database).\(body["listIndexes"]?.stringValue ?? "")"
            guard let indexes = state.withLock({ $0.indexes[namespace] }) else {
                return ["ok": 0, "errmsg": "ns does not exist", "code": 26, "codeName": "NamespaceNotFound"]
            }
            return cursorReply(id: 0, namespace: namespace, batch: indexes, key: "firstBatch")
        case "find":
            let namespace = "\(database).\(body["find"]?.stringValue ?? "")"
            let filter = body["filter"]?.documentValue ?? [:]
            let skip = body["skip"]?.intValue ?? 0
            var results = Array(sorted(documents(namespace).filter { matches($0, filter) }, by: body["sort"]?.documentValue).dropFirst(skip))
            if let limit = body["limit"]?.intValue, limit > 0 { results = Array(results.prefix(limit)) }
            let (batch, id) = openCursor(namespace: namespace, results: results, firstBatchLimit: body["batchSize"]?.intValue ?? 0)
            return cursorReply(id: id, namespace: namespace, batch: batch, key: "firstBatch")
        case "getMore":
            let id = body["getMore"]?.int64Value ?? 0
            let collection = body["collection"]?.stringValue ?? ""
            let (batch, nextID) = nextBatch(cursorID: id, requested: body["batchSize"]?.intValue ?? 0)
            return cursorReply(id: nextID, namespace: "\(database).\(collection)", batch: batch, key: "nextBatch")
        case "killCursors":
            let ids = body["cursors"]?.arrayValue?.compactMap(\.int64Value) ?? []
            state.withLock { state in
                for id in ids { state.cursors[id] = nil }
                state.killedCursors += ids
            }
            return ["ok": 1, "cursorsKilled": .array(ids.map(BSONValue.int64))]
        case "count":
            if countTimesOut {
                return ["ok": 0, "errmsg": "operation exceeded time limit", "code": 50, "codeName": "MaxTimeMSExpired"]
            }
            let namespace = "\(database).\(body["count"]?.stringValue ?? "")"
            let filter = body["query"]?.documentValue ?? [:]
            return ["ok": 1, "n": .int32(Int32(documents(namespace).filter { matches($0, filter) }.count))]
        case "insert":
            let namespace = "\(database).\(body["insert"]?.stringValue ?? "")"
            let incoming = body["documents"]?.arrayValue?.compactMap(\.documentValue) ?? []
            let (inserted, writeErrors) = state.withLock { state -> (Int, [BSONValue]) in
                var inserted = 0
                var writeErrors: [BSONValue] = []
                var existing = state.collections[namespace] ?? []
                for (index, document) in incoming.enumerated() {
                    if existing.contains(where: { $0["_id"] == document["_id"] }) {
                        writeErrors.append(["index": .int(index), "code": 11000, "errmsg": "E11000 duplicate key error collection: \(namespace) index: _id_"])
                        break
                    }
                    existing.append(document)
                    inserted += 1
                }
                state.collections[namespace] = existing
                return (inserted, writeErrors)
            }
            var reply: BSONDocument = ["ok": 1, "n": .int(inserted)]
            if !writeErrors.isEmpty { reply["writeErrors"] = .array(writeErrors) }
            return reply
        case "explain":
            return ["ok": 1, "queryPlanner": ["winningPlan": ["stage": "COLLSCAN"]], "executionStats": ["nReturned": 1]]
        default:
            return ["ok": 0, "errmsg": "no such command: '\(name)'", "code": 59, "codeName": "CommandNotFound"]
        }
    }

    private func cursorReply(id: Int64, namespace: String, batch: [BSONDocument], key: String) -> BSONDocument {
        var cursor: BSONDocument = ["id": .int64(id), "ns": .string(namespace)]
        cursor[key] = .array(batch.map(BSONValue.document))
        return ["ok": 1, "cursor": .document(cursor)]
    }
}

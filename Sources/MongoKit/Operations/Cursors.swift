import BSON
import MongoWire

/// One batch of a server cursor.
struct CursorPage: Sendable {
    var id: Int64
    /// Full namespace the cursor lives in (`db.coll`, or `db.$cmd.listCollections` on old servers).
    var namespace: String
    var documents: [BSONDocument]

    /// Parses `{cursor: {id, ns, firstBatch|nextBatch}}`.
    static func parse(_ reply: BSONDocument, fallbackNamespace: String) throws -> CursorPage {
        guard let cursor = reply["cursor"]?.documentValue else {
            // MongoDB 2.6 aggregate without cursor support replies with {result: [...]}.
            if let result = reply["result"]?.arrayValue {
                return CursorPage(id: 0, namespace: fallbackNamespace, documents: result.compactMap(\.documentValue))
            }
            throw MongoError(.protocolViolation, "Reply has no cursor")
        }
        let batch = cursor["firstBatch"]?.arrayValue ?? cursor["nextBatch"]?.arrayValue ?? []
        return CursorPage(id: cursor["id"]?.int64Value ?? 0,
                          namespace: cursor["ns"]?.stringValue ?? fallbackNamespace,
                          documents: batch.compactMap(\.documentValue))
    }
}

/// How to continue and close cursors on a given server generation.
protocol CursorDriver: Sendable {
    func getMore(_ cursor: CursorPage, batchSize: Int?, on connection: MongoConnection) async throws -> CursorPage
    func kill(_ cursor: CursorPage, on connection: MongoConnection) async
}

/// MongoDB 3.2+: `getMore` / `killCursors` commands.
struct CommandCursorDriver: CursorDriver {
    func getMore(_ cursor: CursorPage, batchSize: Int?, on connection: MongoConnection) async throws -> CursorPage {
        guard let namespace = MongoNamespace(fullName: cursor.namespace) else {
            throw MongoError(.protocolViolation, "Invalid cursor namespace '\(cursor.namespace)'")
        }
        var command: BSONDocument = ["getMore": .int64(cursor.id), "collection": .string(namespace.collection)]
        if let batchSize, batchSize > 0 { command["batchSize"] = .int(batchSize) }
        let reply = try await connection.runCommand(command, database: namespace.database)
        var page = try CursorPage.parse(reply, fallbackNamespace: cursor.namespace)
        page.namespace = cursor.namespace
        return page
    }

    func kill(_ cursor: CursorPage, on connection: MongoConnection) async {
        guard cursor.id != 0, let namespace = MongoNamespace(fullName: cursor.namespace) else { return }
        _ = try? await connection.runCommand(["killCursors": .string(namespace.collection), "cursors": [.int64(cursor.id)]],
                                             database: namespace.database)
    }
}

/// MongoDB < 3.2: `OP_GET_MORE` / `OP_KILL_CURSORS`.
struct LegacyCursorDriver: CursorDriver {
    func getMore(_ cursor: CursorPage, batchSize: Int?, on connection: MongoConnection) async throws -> CursorPage {
        let reply = try await connection.legacyGetMore(OpGetMore(fullCollectionName: cursor.namespace,
                                                                 numberToReturn: Int32(clamping: batchSize ?? 0),
                                                                 cursorID: cursor.id))
        return CursorPage(id: reply.cursorID, namespace: cursor.namespace, documents: reply.documents)
    }

    func kill(_ cursor: CursorPage, on connection: MongoConnection) async {
        guard cursor.id != 0 else { return }
        try? await connection.legacyKillCursors([cursor.id])
    }
}

enum CursorDrain {
    /// Collects documents until the cursor is exhausted or `limit` (if > 0) documents were read,
    /// then kills the cursor if it is still open on the server.
    static func collect(first: CursorPage, limit: Int, driver: any CursorDriver, connection: MongoConnection) async throws -> [BSONDocument] {
        var documents: [BSONDocument] = []
        try await forEachBatch(first: first, limit: limit, batchSize: nil, driver: driver, connection: connection) { batch in
            documents.append(contentsOf: batch)
        }
        return documents
    }

    /// Streams batches to `body`, honouring `limit` (0 = unlimited) and cancellation, always cleaning up the cursor.
    static func forEachBatch(first: CursorPage, limit: Int, batchSize: Int?, driver: any CursorDriver, connection: MongoConnection,
                             _ body: ([BSONDocument]) async throws -> Void) async throws {
        var cursor = first
        var delivered = 0
        do {
            while true {
                var batch = cursor.documents
                if limit > 0, delivered + batch.count > limit {
                    batch = Array(batch.prefix(limit - delivered))
                }
                delivered += batch.count
                if !batch.isEmpty { try await body(batch) }

                let reachedLimit = limit > 0 && delivered >= limit
                if cursor.id == 0 || reachedLimit { break }
                if Task.isCancelled { throw MongoError.cancelled() }

                let remaining = limit > 0 ? limit - delivered : nil
                let size = [remaining, batchSize].compactMap { $0 }.min()
                let previousID = cursor.id
                cursor = try await driver.getMore(cursor, batchSize: size, on: connection)
                if cursor.id != 0, cursor.id != previousID {
                    // Defensive: a server must never switch cursor ids mid-iteration.
                    throw MongoError(.protocolViolation, "Server returned a different cursor id")
                }
            }
        } catch {
            if cursor.id != 0, !Task.isCancelled { await driver.kill(cursor, on: connection) }
            throw error
        }
        if cursor.id != 0 { await driver.kill(cursor, on: connection) }
    }
}

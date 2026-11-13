import BSON
import Foundation

// MARK: - Commands

extension MongoClient {
    /// Runs a command, throwing when the server replies `ok: 0`.
    public func runCommand(_ command: BSONDocument, database: String) async throws -> BSONDocument {
        try await withConnection(retryable: false) { connection, _ in
            try await connection.runCommand(command, database: database)
        }
    }

    /// Runs a command and returns the raw reply even when it failed (for the command console).
    public func runCommandRaw(_ command: BSONDocument, database: String) async throws -> BSONDocument {
        try await withConnection(retryable: false) { connection, _ in
            try await connection.runCommandRaw(command, database: database)
        }
    }

    public func serverStatus() async throws -> BSONDocument {
        try await withConnection(retryable: true) { connection, _ in
            try await connection.runCommand(["serverStatus": 1], database: "admin")
        }
    }
}

// MARK: - Databases and collections

extension MongoClient {
    /// Lists databases. Users without the `listDatabases` privilege get the databases they can see
    /// (MongoDB 4.0.5+) or, on older servers, the database named in the connection string.
    public func listDatabases() async throws -> [DatabaseInfo] {
        let fallbackNames = [connectionString.database, connectionString.authSource]
            .compactMap { $0 }
            .filter { $0 != "$external" }
        return try await withConnection(retryable: true) { connection, capabilities in
            do {
                let reply = try await connection.runCommand(["listDatabases": 1], database: "admin")
                return Self.databases(from: reply)
            } catch let error as MongoError where error.code == MongoError.unauthorizedCode || error.kind == .command {
                if capabilities.hasAuthorizedDatabases,
                   let reply = try? await connection.runCommand(["listDatabases": 1, "nameOnly": true, "authorizedDatabases": true], database: "admin") {
                    let databases = Self.databases(from: reply)
                    if !databases.isEmpty { return databases }
                }
                guard !fallbackNames.isEmpty else { throw error }
                var seen = Set<String>()
                return fallbackNames.filter { seen.insert($0).inserted }.map { DatabaseInfo(name: $0) }
            }
        }
    }

    private static func databases(from reply: BSONDocument) -> [DatabaseInfo] {
        (reply["databases"]?.arrayValue ?? []).compactMap { value in
            guard let document = value.documentValue, let name = document["name"]?.stringValue else { return nil }
            return DatabaseInfo(name: name,
                                sizeOnDisk: document["sizeOnDisk"]?.countValue,
                                isEmpty: document["empty"]?.boolValue)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func listCollections(database: String) async throws -> [CollectionInfo] {
        try await withConnection(retryable: true) { connection, capabilities in
            let strategies = OperationStrategies(capabilities: capabilities)
            return try await strategies.listCollections.list(database: database, on: connection, driver: strategies.cursorDriver)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func createCollection(_ namespace: MongoNamespace, options: BSONDocument = [:]) async throws {
        var command: BSONDocument = ["create": .string(namespace.collection)]
        for element in options.elements where element.key != "create" { command.append(element.key, element.value) }
        _ = try await runCommand(command, database: namespace.database)
    }

    public func dropCollection(_ namespace: MongoNamespace) async throws {
        do {
            _ = try await runCommand(["drop": .string(namespace.collection)], database: namespace.database)
        } catch let error as MongoError where error.code == MongoError.namespaceNotFoundCode || error.message == "ns not found" {
            return
        }
    }

    public func dropDatabase(_ name: String) async throws {
        _ = try await runCommand(["dropDatabase": 1], database: name)
    }

    public func renameCollection(_ namespace: MongoNamespace, to newName: String, dropTarget: Bool = false) async throws {
        _ = try await runCommand(["renameCollection": .string(namespace.fullName),
                                  "to": .string("\(namespace.database).\(newName)"),
                                  "dropTarget": .bool(dropTarget)], database: "admin")
    }

    public func collectionStats(_ namespace: MongoNamespace) async throws -> CollectionStats {
        try await withConnection(retryable: true) { connection, capabilities in
            do {
                return CollectionStats(raw: try await connection.runCommand(["collStats": .string(namespace.collection)], database: namespace.database))
            } catch let error as MongoError where capabilities.maxWireVersion >= 6 && error.code != MongoError.unauthorizedCode {
                // collStats is deprecated on newer servers; fall back to the $collStats stage.
                let reply = try await connection.runCommand([
                    "aggregate": .string(namespace.collection),
                    "pipeline": [["$collStats": ["storageStats": [:]]]],
                    "cursor": [:],
                ], database: namespace.database)
                let page = try CursorPage.parse(reply, fallbackNamespace: namespace.fullName)
                guard let storage = page.documents.first?["storageStats"]?.documentValue else { throw error }
                return CollectionStats(raw: storage)
            }
        }
    }

    public func databaseStats(_ database: String) async throws -> BSONDocument {
        try await withConnection(retryable: true) { connection, _ in
            try await connection.runCommand(["dbStats": 1], database: database)
        }
    }
}

// MARK: - Reading documents

extension MongoClient {
    /// Returns at most `options.limit` documents (all when 0), reading as many batches as needed.
    public func find(_ namespace: MongoNamespace, options: FindOptions = FindOptions()) async throws -> [BSONDocument] {
        try Self.validate(options: options)
        return try await withConnection(retryable: true) { connection, capabilities in
            try Self.check(collation: options.collation, capabilities: capabilities)
            let strategies = OperationStrategies(capabilities: capabilities)
            let first = try await strategies.find.open(namespace, options: options, on: connection)
            return try await CursorDrain.collect(first: first, limit: options.limit, driver: strategies.cursorDriver, connection: connection)
        }
    }

    /// Streams every matching document in batches (for export). The cursor is closed when `body` throws.
    public func forEachBatch(_ namespace: MongoNamespace, options: FindOptions, batchSize: Int = 1000,
                             _ body: @Sendable ([BSONDocument]) async throws -> Void) async throws {
        try Self.validate(options: options)
        var options = options
        options.batchSize = batchSize
        try await withConnection(retryable: false) { connection, capabilities in
            try Self.check(collation: options.collation, capabilities: capabilities)
            let strategies = OperationStrategies(capabilities: capabilities)
            let first = try await strategies.find.open(namespace, options: options, on: connection)
            try await CursorDrain.forEachBatch(first: first, limit: options.limit, batchSize: batchSize,
                                               driver: strategies.cursorDriver, connection: connection, body)
        }
    }

    /// Counts matching documents. Returns `nil` when the server-side time limit was exceeded.
    public func count(_ namespace: MongoNamespace, filter: BSONDocument = [:], options: CountOptions = CountOptions()) async throws -> Int64? {
        var command: BSONDocument = ["count": .string(namespace.collection), "query": .document(filter)]
        if options.skip > 0 { command["skip"] = .int(options.skip) }
        if options.limit > 0 { command["limit"] = .int(options.limit) }
        if let maxTimeMS = options.maxTimeMS, maxTimeMS > 0 { command["maxTimeMS"] = .int(maxTimeMS) }
        if let hint = options.hint { command["hint"] = hint }
        if let collation = options.collation, !collation.isEmpty { command["collation"] = .document(collation) }
        do {
            return try await withConnection(retryable: true) { connection, capabilities in
                try Self.check(collation: options.collation, capabilities: capabilities)
                let reply = try await connection.runCommand(command, database: namespace.database)
                return reply["n"]?.countValue ?? 0
            }
        } catch let error as MongoError where error.code == MongoError.maxTimeMSExpiredCode || error.codeName == "MaxTimeMSExpired" {
            return nil
        }
    }

    /// Runs an aggregation pipeline and returns up to `options.maxResults` documents (all when 0).
    public func aggregate(_ namespace: MongoNamespace, pipeline: [BSONDocument], options: AggregateOptions = AggregateOptions()) async throws -> [BSONDocument] {
        try await withConnection(retryable: !Self.pipelineWrites(pipeline)) { connection, capabilities in
            try Self.check(collation: options.collation, capabilities: capabilities)
            let strategies = OperationStrategies(capabilities: capabilities)
            let reply = try await connection.runCommand(Self.aggregateCommand(namespace, pipeline, options), database: namespace.database)
            let first = try CursorPage.parse(reply, fallbackNamespace: namespace.fullName)
            return try await CursorDrain.collect(first: first, limit: options.maxResults, driver: strategies.cursorDriver, connection: connection)
        }
    }

    /// Random sample using `$sample` (MongoDB 3.2+) or the first documents on older servers.
    public func sample(_ namespace: MongoNamespace, size: Int) async throws -> [BSONDocument] {
        let capabilities = try await state.server(progress: nil).capabilities
        if capabilities.hasSampleStage {
            return try await aggregate(namespace, pipeline: [["$sample": ["size": .int(size)]]], options: AggregateOptions(maxTimeMS: 60_000, maxResults: size))
        }
        return try await find(namespace, options: FindOptions(limit: size, maxTimeMS: 60_000))
    }

    static func aggregateCommand(_ namespace: MongoNamespace, _ pipeline: [BSONDocument], _ options: AggregateOptions) -> BSONDocument {
        var cursor = BSONDocument()
        if let batchSize = options.batchSize ?? (options.maxResults > 0 ? min(options.maxResults, 1000) : nil) {
            cursor["batchSize"] = .int(batchSize)
        }
        var command: BSONDocument = [
            "aggregate": .string(namespace.collection),
            "pipeline": .array(pipeline.map(BSONValue.document)),
            "cursor": .document(cursor),
        ]
        if options.allowDiskUse { command["allowDiskUse"] = true }
        if let maxTimeMS = options.maxTimeMS, maxTimeMS > 0 { command["maxTimeMS"] = .int(maxTimeMS) }
        if let collation = options.collation, !collation.isEmpty { command["collation"] = .document(collation) }
        return command
    }

    static func pipelineWrites(_ pipeline: [BSONDocument]) -> Bool {
        pipeline.contains { $0.keys.contains("$out") || $0.keys.contains("$merge") }
    }

    static func validate(options: FindOptions) throws {
        guard options.skip >= 0, options.limit >= 0 else {
            throw MongoError(.invalidArgument, "Skip and limit must not be negative")
        }
    }

    static func check(collation: BSONDocument?, capabilities: ServerCapabilities) throws {
        if let collation, !collation.isEmpty, !capabilities.hasCollation {
            throw MongoError(.unsupportedServer, "Collation requires MongoDB 3.4 or later (this server is \(capabilities.approximateVersion))")
        }
    }
}

// MARK: - Explain

extension MongoClient {
    public func explainFind(_ namespace: MongoNamespace, options: FindOptions) async throws -> BSONDocument {
        try await withConnection(retryable: true) { connection, capabilities in
            try await OperationStrategies(capabilities: capabilities).explainFind.explain(namespace, options: options, on: connection)
        }
    }

    public func explainAggregate(_ namespace: MongoNamespace, pipeline: [BSONDocument], options: AggregateOptions = AggregateOptions()) async throws -> BSONDocument {
        try await withConnection(retryable: true) { connection, capabilities in
            var aggregate = Self.aggregateCommand(namespace, pipeline, options)
            if capabilities.hasAggregateExplainCommand {
                return try await connection.runCommand(["explain": .document(aggregate), "verbosity": "executionStats"], database: namespace.database)
            }
            aggregate["cursor"] = nil
            aggregate["explain"] = true
            return try await connection.runCommand(aggregate, database: namespace.database)
        }
    }
}

// MARK: - Writing documents

extension MongoClient {
    /// Inserts documents in order, adding an ObjectId `_id` where missing. Batches by count and size.
    @discardableResult
    public func insert(_ documents: [BSONDocument], into namespace: MongoNamespace) async throws -> InsertResult {
        guard !documents.isEmpty else { return InsertResult(insertedCount: 0, insertedIDs: []) }
        let prepared = documents.map { document -> BSONDocument in
            guard document["_id"] == nil else { return document }
            var copy = document
            copy.insert(BSONElement(key: "_id", value: .objectId(ObjectId())), at: 0)
            return copy
        }
        return try await withConnection(retryable: false) { connection, _ in
            let hello = await connection.hello
            let maxCount = max(1, hello?.maxWriteBatchSize ?? 1000)
            let maxBytes = max(1024, (hello?.maxBsonObjectSize ?? 16_777_216) - 16 * 1024)
            var inserted = 0
            var batch: [BSONValue] = []
            var batchBytes = 0

            func flush() async throws {
                guard !batch.isEmpty else { return }
                let reply = try await connection.runCommand([
                    "insert": .string(namespace.collection), "documents": .array(batch), "ordered": true,
                ], database: namespace.database)
                let count = Int(reply["n"]?.countValue ?? 0)
                try Self.checkWriteErrors(reply, alreadyApplied: inserted + count, total: prepared.count, verb: "inserted")
                inserted += count
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
            }

            for document in prepared {
                guard let size = document.encodedSize else {
                    throw MongoError(.invalidArgument, "A document could not be encoded as BSON")
                }
                guard size <= maxBytes else {
                    throw MongoError(.invalidArgument, "A document is \(size) bytes, larger than the 16 MB limit")
                }
                if batch.count >= maxCount || batchBytes + size > maxBytes { try await flush() }
                batch.append(.document(document))
                batchBytes += size
            }
            try await flush()
            return InsertResult(insertedCount: inserted, insertedIDs: prepared.compactMap { $0["_id"] })
        }
    }

    /// Replaces the first document matching `filter`.
    @discardableResult
    public func replaceOne(_ namespace: MongoNamespace, filter: BSONDocument, replacement: BSONDocument, upsert: Bool = false) async throws -> UpdateResult {
        if let key = replacement.keys.first(where: { $0.hasPrefix("$") }) {
            throw MongoError(.invalidArgument, "A replacement document cannot contain update operators such as \(key)")
        }
        return try await update(namespace, statement: ["q": .document(filter), "u": .document(replacement), "upsert": .bool(upsert), "multi": false])
    }

    /// Applies update operators to the first (or every) document matching `filter`.
    @discardableResult
    public func updateDocuments(_ namespace: MongoNamespace, filter: BSONDocument, update: BSONDocument, many: Bool, upsert: Bool = false) async throws -> UpdateResult {
        guard let first = update.keys.first, first.hasPrefix("$") else {
            throw MongoError(.invalidArgument, "An update document must use update operators such as $set")
        }
        return try await self.update(namespace, statement: ["q": .document(filter), "u": .document(update), "upsert": .bool(upsert), "multi": .bool(many)])
    }

    private func update(_ namespace: MongoNamespace, statement: BSONDocument) async throws -> UpdateResult {
        try await withConnection(retryable: false) { connection, _ in
            let reply = try await connection.runCommand(["update": .string(namespace.collection), "updates": [.document(statement)], "ordered": true],
                                                        database: namespace.database)
            try Self.checkWriteErrors(reply, alreadyApplied: 0, total: 1, verb: "updated")
            let upserted = reply["upserted"]?.arrayValue?.first?.documentValue?["_id"]
            let matched = Int(reply["n"]?.countValue ?? 0) - (upserted == nil ? 0 : 1)
            return UpdateResult(matchedCount: max(0, matched), modifiedCount: Int(reply["nModified"]?.countValue ?? 0), upsertedID: upserted)
        }
    }

    /// Deletes the first (or every) document matching `filter`; returns the number deleted.
    @discardableResult
    public func deleteDocuments(_ namespace: MongoNamespace, filter: BSONDocument, many: Bool) async throws -> Int {
        try await withConnection(retryable: false) { connection, _ in
            let reply = try await connection.runCommand([
                "delete": .string(namespace.collection),
                "deletes": [["q": .document(filter), "limit": .int32(many ? 0 : 1)]],
                "ordered": true,
            ], database: namespace.database)
            try Self.checkWriteErrors(reply, alreadyApplied: 0, total: 1, verb: "deleted")
            return Int(reply["n"]?.countValue ?? 0)
        }
    }

    static func checkWriteErrors(_ reply: BSONDocument, alreadyApplied: Int, total: Int, verb: String) throws {
        if let first = reply["writeErrors"]?.arrayValue?.first?.documentValue {
            let message = first["errmsg"]?.stringValue ?? "Write failed"
            let suffix = total > 1 ? " (\(alreadyApplied) of \(total) documents \(verb))" : ""
            throw MongoError(.write, message + suffix, code: first["code"]?.intValue, codeName: first["codeName"]?.stringValue, reply: reply)
        }
        if let concern = reply["writeConcernError"]?.documentValue {
            throw MongoError(.write, "Write concern error: \(concern["errmsg"]?.stringValue ?? "unknown")",
                             code: concern["code"]?.intValue, codeName: concern["codeName"]?.stringValue, reply: reply)
        }
    }
}

// MARK: - Indexes

extension MongoClient {
    public func listIndexes(_ namespace: MongoNamespace) async throws -> [IndexInfo] {
        try await withConnection(retryable: true) { connection, capabilities in
            let strategies = OperationStrategies(capabilities: capabilities)
            return try await strategies.listIndexes.list(namespace, on: connection, driver: strategies.cursorDriver)
        }
    }

    /// Index usage via `$indexStats` (MongoDB 3.2+); `nil` when unsupported or not permitted.
    public func indexUsage(_ namespace: MongoNamespace) async throws -> [String: IndexUsage]? {
        let capabilities = try await state.server(progress: nil).capabilities
        guard capabilities.hasIndexStats else { return nil }
        guard let stats = try? await aggregate(namespace, pipeline: [["$indexStats": [:]]]) else { return nil }
        var usage: [String: IndexUsage] = [:]
        for document in stats {
            guard let name = document["name"]?.stringValue else { continue }
            let accesses = document["accesses"]?.documentValue
            let operations = accesses?["ops"]?.countValue ?? 0
            let since = accesses?["since"]?.datetimeValue?.date
            // Sharded clusters report one row per shard: sum them.
            let previous = usage[name]?.operations ?? 0
            usage[name] = IndexUsage(name: name, operations: previous + operations, since: since)
        }
        return usage
    }

    @discardableResult
    public func createIndex(_ namespace: MongoNamespace, keys: BSONDocument, options: IndexOptions = IndexOptions()) async throws -> String {
        guard !keys.isEmpty else { throw MongoError(.invalidArgument, "An index needs at least one field") }
        let name = options.name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultIndexName(keys)
        var index: BSONDocument = ["key": .document(keys), "name": .string(name)]
        if options.unique { index["unique"] = true }
        if options.sparse { index["sparse"] = true }
        if let ttl = options.expireAfterSeconds { index["expireAfterSeconds"] = .int(ttl) }
        if let partial = options.partialFilterExpression, !partial.isEmpty { index["partialFilterExpression"] = .document(partial) }
        if options.background { index["background"] = true }
        if let collation = options.collation, !collation.isEmpty { index["collation"] = .document(collation) }
        if options.hidden { index["hidden"] = true }
        _ = try await runCommand(["createIndexes": .string(namespace.collection), "indexes": [.document(index)]], database: namespace.database)
        return name
    }

    public func dropIndex(_ namespace: MongoNamespace, name: String) async throws {
        guard name != "_id_" else { throw MongoError(.invalidArgument, "The _id index cannot be dropped") }
        _ = try await runCommand(["dropIndexes": .string(namespace.collection), "index": .string(name)], database: namespace.database)
    }

    /// Driver-compatible default index name, e.g. `{a: 1, b: -1}` → `a_1_b_-1`.
    public static func defaultIndexName(_ keys: BSONDocument) -> String {
        keys.elements.map { element -> String in
            let direction: String
            switch element.value {
            case let .string(text): direction = text
            case let .double(number) where number.rounded() == number: direction = String(Int(number))
            default: direction = element.value.int64Value.map(String.init) ?? "1"
            }
            return "\(element.key)_\(direction)"
        }.joined(separator: "_")
    }
}

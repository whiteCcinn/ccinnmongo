import BSON
import MongoWire

/// Version-specific implementations, chosen from `ServerCapabilities` in one place.
struct OperationStrategies: Sendable {
    let capabilities: ServerCapabilities

    var cursorDriver: any CursorDriver {
        capabilities.hasFindCommand ? CommandCursorDriver() : LegacyCursorDriver()
    }

    var find: any FindStrategy {
        capabilities.hasFindCommand ? FindCommandStrategy() : LegacyQueryFindStrategy()
    }

    var listCollections: any ListCollectionsStrategy {
        capabilities.hasListCommands ? ListCollectionsCommandStrategy() : SystemNamespacesStrategy()
    }

    var listIndexes: any ListIndexesStrategy {
        capabilities.hasListCommands ? ListIndexesCommandStrategy() : SystemIndexesStrategy()
    }

    var explainFind: any ExplainFindStrategy {
        capabilities.hasFindCommand ? ExplainCommandStrategy() : LegacyExplainStrategy()
    }
}

// MARK: - Find

protocol FindStrategy: Sendable {
    func open(_ namespace: MongoNamespace, options: FindOptions, on connection: MongoConnection) async throws -> CursorPage
}

/// MongoDB 3.2+: the `find` command.
struct FindCommandStrategy: FindStrategy {
    func open(_ namespace: MongoNamespace, options: FindOptions, on connection: MongoConnection) async throws -> CursorPage {
        let reply = try await connection.runCommand(Self.command(namespace, options), database: namespace.database)
        return try CursorPage.parse(reply, fallbackNamespace: namespace.fullName)
    }

    static func command(_ namespace: MongoNamespace, _ options: FindOptions) -> BSONDocument {
        var command: BSONDocument = ["find": .string(namespace.collection), "filter": .document(options.filter)]
        if let sort = options.sort, !sort.isEmpty { command["sort"] = .document(sort) }
        if let projection = options.projection, !projection.isEmpty { command["projection"] = .document(projection) }
        if options.skip > 0 { command["skip"] = .int(options.skip) }
        if options.limit > 0 {
            command["limit"] = .int(options.limit)
            command["batchSize"] = .int(min(options.limit, options.batchSize ?? options.limit))
        } else if let batchSize = options.batchSize {
            command["batchSize"] = .int(batchSize)
        }
        if let hint = options.hint { command["hint"] = hint }
        if let collation = options.collation, !collation.isEmpty { command["collation"] = .document(collation) }
        if let maxTimeMS = options.maxTimeMS, maxTimeMS > 0 { command["maxTimeMS"] = .int(maxTimeMS) }
        return command
    }
}

/// MongoDB 2.6 – 3.0: `OP_QUERY` with `$query`/`$orderby` modifiers.
struct LegacyQueryFindStrategy: FindStrategy {
    func open(_ namespace: MongoNamespace, options: FindOptions, on connection: MongoConnection) async throws -> CursorPage {
        let reply = try await connection.legacyQuery(Self.query(namespace, options, explain: false))
        return CursorPage(id: reply.cursorID, namespace: namespace.fullName, documents: reply.documents)
    }

    static func query(_ namespace: MongoNamespace, _ options: FindOptions, explain: Bool) -> OpQuery {
        var modifiers = BSONDocument()
        if let sort = options.sort, !sort.isEmpty { modifiers["$orderby"] = .document(sort) }
        if let hint = options.hint { modifiers["$hint"] = hint }
        if let maxTimeMS = options.maxTimeMS, maxTimeMS > 0 { modifiers["$maxTimeMS"] = .int(maxTimeMS) }
        if explain { modifiers["$explain"] = true }

        // Always wrap: a bare filter with a top-level `query` field would be read as the wrapped form.
        var query: BSONDocument = ["$query": .document(options.filter)]
        for element in modifiers.elements { query.append(element.key, element.value) }
        let numberToReturn: Int32
        if explain {
            numberToReturn = options.limit > 0 ? -Int32(clamping: options.limit) : 0
        } else if options.limit > 0 {
            numberToReturn = Int32(clamping: min(options.limit, options.batchSize ?? options.limit))
        } else {
            numberToReturn = Int32(clamping: options.batchSize ?? 0)
        }
        let selector = options.projection.flatMap { $0.isEmpty ? nil : $0 }
        return OpQuery(fullCollectionName: namespace.fullName,
                       numberToSkip: Int32(clamping: options.skip),
                       numberToReturn: numberToReturn,
                       query: query,
                       returnFieldsSelector: selector)
    }
}

// MARK: - Explain

protocol ExplainFindStrategy: Sendable {
    func explain(_ namespace: MongoNamespace, options: FindOptions, on connection: MongoConnection) async throws -> BSONDocument
}

struct ExplainCommandStrategy: ExplainFindStrategy {
    func explain(_ namespace: MongoNamespace, options: FindOptions, on connection: MongoConnection) async throws -> BSONDocument {
        var find = FindCommandStrategy.command(namespace, options)
        find["batchSize"] = nil
        var command: BSONDocument = ["explain": .document(find), "verbosity": "executionStats"]
        // The server applies maxTimeMS from the top level of a command; inside `explain` it would not bound the plan run.
        if let maxTimeMS = options.maxTimeMS, maxTimeMS > 0 { command["maxTimeMS"] = .int(maxTimeMS) }
        return try await connection.runCommand(command, database: namespace.database)
    }
}

struct LegacyExplainStrategy: ExplainFindStrategy {
    func explain(_ namespace: MongoNamespace, options: FindOptions, on connection: MongoConnection) async throws -> BSONDocument {
        let reply = try await connection.legacyQuery(LegacyQueryFindStrategy.query(namespace, options, explain: true))
        guard let document = reply.documents.first else {
            throw MongoError(.protocolViolation, "Explain returned no document")
        }
        return document
    }
}

// MARK: - List collections

protocol ListCollectionsStrategy: Sendable {
    func list(database: String, on connection: MongoConnection, driver: any CursorDriver) async throws -> [CollectionInfo]
}

/// MongoDB 3.0+.
struct ListCollectionsCommandStrategy: ListCollectionsStrategy {
    func list(database: String, on connection: MongoConnection, driver: any CursorDriver) async throws -> [CollectionInfo] {
        let reply = try await connection.runCommand(["listCollections": 1, "cursor": [:]], database: database)
        let first = try CursorPage.parse(reply, fallbackNamespace: "\(database).$cmd.listCollections")
        let documents = try await CursorDrain.collect(first: first, limit: 0, driver: driver, connection: connection)
        return documents.compactMap { document in
            guard let name = document["name"]?.stringValue else { return nil }
            let kind = CollectionInfo.Kind(rawValue: document["type"]?.stringValue ?? "collection") ?? .collection
            return CollectionInfo(name: name, kind: kind,
                                  options: document["options"]?.documentValue ?? [:],
                                  isReadOnly: document["info"]?.documentValue?["readOnly"]?.isTruthy ?? false)
        }
    }
}

/// MongoDB 2.6: query `system.namespaces`, dropping index namespaces (`coll.$index`).
struct SystemNamespacesStrategy: ListCollectionsStrategy {
    func list(database: String, on connection: MongoConnection, driver: any CursorDriver) async throws -> [CollectionInfo] {
        let reply = try await connection.legacyQuery(OpQuery(fullCollectionName: "\(database).system.namespaces", numberToReturn: 0, query: [:]))
        let first = CursorPage(id: reply.cursorID, namespace: "\(database).system.namespaces", documents: reply.documents)
        let documents = try await CursorDrain.collect(first: first, limit: 0, driver: driver, connection: connection)
        let prefix = database + "."
        return documents.compactMap { document in
            guard let fullName = document["name"]?.stringValue, fullName.hasPrefix(prefix) else { return nil }
            let name = String(fullName.dropFirst(prefix.count))
            guard !name.contains("$"), !name.isEmpty else { return nil }
            return CollectionInfo(name: name, kind: .collection, options: document["options"]?.documentValue ?? [:])
        }
    }
}

// MARK: - List indexes

protocol ListIndexesStrategy: Sendable {
    func list(_ namespace: MongoNamespace, on connection: MongoConnection, driver: any CursorDriver) async throws -> [IndexInfo]
}

struct ListIndexesCommandStrategy: ListIndexesStrategy {
    func list(_ namespace: MongoNamespace, on connection: MongoConnection, driver: any CursorDriver) async throws -> [IndexInfo] {
        let reply: BSONDocument
        do {
            reply = try await connection.runCommand(["listIndexes": .string(namespace.collection), "cursor": [:]], database: namespace.database)
        } catch let error as MongoError where error.code == MongoError.namespaceNotFoundCode {
            return []
        }
        let first = try CursorPage.parse(reply, fallbackNamespace: "\(namespace.database).$cmd.listIndexes.\(namespace.collection)")
        let documents = try await CursorDrain.collect(first: first, limit: 0, driver: driver, connection: connection)
        return documents.map(IndexInfo.init(raw:))
    }
}

/// MongoDB 2.6: query `system.indexes`.
struct SystemIndexesStrategy: ListIndexesStrategy {
    func list(_ namespace: MongoNamespace, on connection: MongoConnection, driver: any CursorDriver) async throws -> [IndexInfo] {
        let reply = try await connection.legacyQuery(OpQuery(fullCollectionName: "\(namespace.database).system.indexes",
                                                             numberToReturn: 0,
                                                             query: ["ns": .string(namespace.fullName)]))
        let first = CursorPage(id: reply.cursorID, namespace: "\(namespace.database).system.indexes", documents: reply.documents)
        let documents = try await CursorDrain.collect(first: first, limit: 0, driver: driver, connection: connection)
        return documents.map(IndexInfo.init(raw:))
    }
}

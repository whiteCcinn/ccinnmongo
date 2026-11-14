import BSON
import CcinnMongoKit
import Foundation
import MongoKit
import os

/// Executes the MongoDB tools: validates arguments, enforces the access level and the read-only policy,
/// selects the connection, applies limits and deadlines, maps failures to `isError` results and audits.
public final class MongoToolProvider: MCPToolProvider {
    public struct Configuration: Sendable {
        /// `--profile`: connection used when a call does not name one.
        public var defaultProfile: String?
        /// `--read-only`: caps every connection at read-only.
        public var readOnly: Bool
        public var maxResultBytes: Int
        /// Extra time the client-side deadline allows after the server-side `maxTimeMS`.
        public var deadlineGraceMilliseconds: Int

        public init(defaultProfile: String? = nil, readOnly: Bool = false, maxResultBytes: Int = DocumentBatch.defaultMaxBytes,
                    deadlineGraceMilliseconds: Int = 2_000) {
            self.defaultProfile = defaultProfile
            self.readOnly = readOnly
            self.maxResultBytes = maxResultBytes
            self.deadlineGraceMilliseconds = max(0, deadlineGraceMilliseconds)
        }

        var cap: MCPAccessLevel { readOnly ? .readOnly : .readWrite }
    }

    /// A validated call, ready to run against a session.
    struct Prepared: Sendable {
        let summary: String
        let timeoutMS: Int
        let run: @Sendable (MongoSession, SelectedProfile) async throws -> Outcome
    }

    struct Outcome: Sendable {
        let result: JSONObject
        let documents: Int?
    }

    private let configuration: Configuration
    /// Consecutive client-side deadline expiries per profile; a session that keeps hanging is dropped.
    private let timeoutStreaks = OSAllocatedUnfairLock<[UUID: Int]>(initialState: [:])
    static let timeoutsBeforeEviction = 2
    private let profiles: any MCPProfileSource
    private let sessions: any MCPSessionSource
    private let audit: any MCPAuditSink

    public init(configuration: Configuration, profiles: any MCPProfileSource, sessions: any MCPSessionSource, audit: any MCPAuditSink) {
        self.configuration = configuration
        self.profiles = profiles
        self.sessions = sessions
        self.audit = audit
    }

    // MARK: MCPToolProvider

    public func listTools(context: MCPCallContext) async -> [MCPToolDefinition] {
        var specs = MongoToolCatalog.readSpecs
        if writeToolsAvailable() { specs += MongoToolCatalog.writeSpecs }
        return specs.map(\.definition)
    }

    /// Write tools are offered only when some enabled connection has read & write access.
    public func writeToolsAvailable() -> Bool {
        guard !configuration.readOnly, let loaded = try? profiles.loadProfiles() else { return false }
        return loaded.contains { $0.mcpAccess.capped(at: configuration.cap).allowsWrites }
    }

    public static func instructions(writeToolsAvailable: Bool) -> String {
        var text = """
        CcinnMongo exposes the MongoDB connections the user enabled for AI access in the CcinnMongo app (MongoDB 2.6 to 8.x). \
        Start with list_connections, then use server_info (its unavailable_features list operators the server version lacks), \
        list_databases, list_collections and collection_schema before querying. Filters, projections, sorts and pipelines accept \
        Extended JSON objects or mongo-shell syntax strings. Results are limited (default 200, at most 1000 documents and about 256 KB \
        per call; check has_more and truncated) and every call has a 30-second time limit (timeout_ms up to 120000). \
        Access is read-only: $out, $merge, $changeStream, server-side JavaScript and credential collections are refused.
        """
        if writeToolsAvailable {
            text += " Connections with read & write access also offer insert_one, update_many and delete_many; the latter two refuse to touch more than max_documents documents, so run them with dry_run first."
        }
        return text
    }

    public func callTool(name: String, arguments: JSONObject, context: MCPCallContext) async throws -> MCPToolResult {
        guard let spec = MongoToolCatalog.all[name] else { throw MCPToolError.unknownTool(name) }
        let started = ContinuousClock.now
        var summary = name
        var selected: SelectedProfile?
        do {
            let args = ToolArguments(tool: name, values: arguments)
            try args.requireOnly(spec.argumentNames)
            if spec.kind == .connections {
                let outcome = try listConnections()
                await record(name, summary: summary, selected: nil, started: started, documents: outcome.documents, error: nil)
                return Self.guardSize(.success(outcome.result), maxBytes: configuration.maxResultBytes)
            }
            let prepared = try prepare(spec, args)
            summary = prepared.summary
            let chosen = try await selectProfile(try args.optionalString("connection"))
            selected = chosen
            if spec.kind == .write, !chosen.access.allowsWrites {
                throw MCPToolFailure(configuration.readOnly
                    ? "The MCP server was started with --read-only, so \(name) is not available."
                    : "Connection \"\(MCPProfileSelector.safeName(chosen.profile))\" has read-only AI access; \(name) needs read & write access (change it in CcinnMongo: edit the connection → AI Access).")
            }
            let outcome = try await execute(prepared, on: chosen)
            let result = Self.guardSize(.success(outcome.result), maxBytes: configuration.maxResultBytes)
            await record(name, summary: summary, selected: chosen, started: started, documents: outcome.documents,
                         error: result.isError ? "result too large" : nil)
            return result
        } catch let error as MCPToolError {
            await record(name, summary: summary, selected: selected, started: started, documents: nil, error: error.message)
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError {
                await record(name, summary: summary, selected: selected, started: started, documents: nil, error: "cancelled")
                throw CancellationError()
            }
            let timeout = (try? ToolArguments(tool: name, values: arguments).integer("timeout_ms", default: MongoToolCatalog.defaultTimeoutMS,
                                                                                    range: 1...MongoToolCatalog.maxTimeoutMS)) ?? MongoToolCatalog.defaultTimeoutMS
            let message = Self.describe(error, connection: selected.map { MCPProfileSelector.safeName($0.profile) }, timeoutMS: timeout,
                                        isWrite: spec.kind == .write)
            await record(name, summary: summary, selected: selected, started: started, documents: nil, error: message)
            return .failure(message)
        }
    }

    // MARK: Execution

    private func selectProfile(_ requested: String?) async throws -> SelectedProfile {
        let loaded: [ConnectionProfile]
        do {
            loaded = try profiles.loadProfiles()
        } catch {
            throw MCPToolFailure("Could not read the saved CcinnMongo connections: \(error.localizedDescription)")
        }
        // Pooled sessions of deleted or disabled profiles are closed (with their SSH tunnels).
        await sessions.prune(keeping: Set(MCPProfileSelector.enabledProfiles(loaded, cap: configuration.cap).map(\.id)))
        return try MCPProfileSelector.select(requested: requested, defaultProfile: configuration.defaultProfile,
                                             profiles: loaded, cap: configuration.cap).get()
    }

    /// The final guard on result size: anything far beyond the budget becomes an error instead of flooding the client.
    static func guardSize(_ result: MCPToolResult, maxBytes: Int) -> MCPToolResult {
        guard case let .structured(object) = result.payload else { return result }
        let size = JSONWriter.encodedSize(.object(object))
        guard size > maxBytes + maxBytes / 2 else { return result }
        return .failure("The result is too large (\(size / 1024) KB, limit about \(maxBytes / 1024) KB). Narrow the request, use a projection or lower the limit.")
    }

    private func execute(_ prepared: Prepared, on selected: SelectedProfile) async throws -> Outcome {
        let sessions = self.sessions
        let usedSession = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        let profileID = selected.profile.id
        do {
            let outcome = try await MCPDeadline.run(milliseconds: prepared.timeoutMS + configuration.deadlineGraceMilliseconds) {
                let session = try await sessions.session(for: selected.profile)
                usedSession.withLock { $0 = session.id }
                return try await prepared.run(session, selected)
            }
            timeoutStreaks.withLock { $0[profileID] = nil }
            return outcome
        } catch is MCPDeadline.Expired {
            // One slow query is normal; repeated expiries usually mean a half-open socket or SSH tunnel.
            let streak = timeoutStreaks.withLock { streaks -> Int in
                streaks[profileID, default: 0] += 1
                return streaks[profileID, default: 0]
            }
            if streak >= Self.timeoutsBeforeEviction, let id = usedSession.withLock({ $0 }) {
                timeoutStreaks.withLock { $0[profileID] = nil }
                await sessions.evict(profileID, sessionID: id)
            }
            throw MCPDeadline.Expired()
        } catch let error as MongoError where Self.isConnectionFailure(error) {
            if let id = usedSession.withLock({ $0 }) {
                await sessions.evict(selected.profile.id, sessionID: id)
            }
            throw error
        }
    }

    static func isConnectionFailure(_ error: MongoError) -> Bool {
        switch error.kind {
        case .network, .timeout, .tls, .dns, .sshTunnel, .serverSelection, .connectionClosed, .authentication, .protocolViolation: true
        default: false
        }
    }

    static func describe(_ error: any Error, connection: String?, timeoutMS: Int, isWrite: Bool) -> String {
        let name = connection.map { "\"\($0)\"" } ?? "the connection"
        switch error {
        case let failure as MCPToolFailure:
            return failure.message
        case is MCPDeadline.Expired:
            if isWrite {
                return "The write did not finish within \(timeoutMS) ms and was abandoned; it may still complete on the server. Check the data before retrying."
            }
            return "The operation did not finish within \(timeoutMS) ms and was abandoned. Narrow the query or raise timeout_ms (max \(MongoToolCatalog.maxTimeoutMS))."
        case let mongo as MongoError:
            if mongo.code == MongoError.maxTimeMSExpiredCode || mongo.codeName == "MaxTimeMSExpired" {
                return "The operation exceeded its time limit of \(timeoutMS) ms. Narrow the query or raise timeout_ms (max \(MongoToolCatalog.maxTimeoutMS))."
            }
            switch mongo.kind {
            case .authentication:
                // Never echo details derived from the password (e.g. the code point SASLprep rejected).
                let detail = mongo.message.contains("SASLprep") ? "the stored password contains characters SASLprep does not allow" : mongo.message
                return "Authentication failed for connection \(name): \(detail)"
            case .network, .timeout, .tls, .dns, .sshTunnel, .serverSelection, .connectionClosed:
                return "Could not reach connection \(name): \(mongo.message)"
            default:
                if let codeName = mongo.codeName, !codeName.isEmpty { return "\(mongo.message) (\(codeName))" }
                return mongo.message
            }
        default:
            return error.localizedDescription
        }
    }

    private func record(_ tool: String, summary: String, selected: SelectedProfile?, started: ContinuousClock.Instant,
                        documents: Int?, error: String?) async {
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        await audit.record(MCPAuditRecord(date: Date(), connection: selected.map { MCPProfileSelector.safeName($0.profile) }, connectionID: selected?.profile.id,
                                          tool: tool, operation: summary, durationMilliseconds: milliseconds, documents: documents, error: error))
    }

    // MARK: list_connections

    private func listConnections() throws -> Outcome {
        let loaded: [ConnectionProfile]
        do {
            loaded = try profiles.loadProfiles()
        } catch {
            throw MCPToolFailure("Could not read the saved CcinnMongo connections: \(error.localizedDescription)")
        }
        let enabled = MCPProfileSelector.enabledProfiles(loaded, cap: configuration.cap)
        let defaultID = (try? MCPProfileSelector.select(requested: nil, defaultProfile: configuration.defaultProfile,
                                                         profiles: loaded, cap: configuration.cap).get())?.profile.id
        let connections: [JSONValue] = enabled.map { profile in
            let access = MCPProfileSelector.effectiveAccess(profile, cap: configuration.cap)
            var object: JSONObject = [
                "name": .string(MCPProfileSelector.safeName(profile)),
                "id": .string(profile.id.uuidString),
                "hosts": .string(Self.hosts(of: profile)),
                "access": .string(access.allowsWrites ? "read-write" : "read-only"),
                "is_default": .bool(profile.id == defaultID),
            ]
            if let parsed = try? ConnectionString(profile.uri) {
                object["scheme"] = .string(parsed.scheme == .srv ? "mongodb+srv" : "mongodb")
                object["replica_set"] = .optional(parsed.replicaSet)
                object["tls"] = .bool(parsed.tls)
                object["default_database"] = .optional(parsed.database)
            }
            object["ssh_tunnel"] = .bool(profile.ssh != nil)
            return .object(object)
        }
        return Outcome(result: ["connections": .array(connections), "read_only_mode": .bool(configuration.readOnly)], documents: connections.count)
    }

    /// Host list without user names; SSH bastions are mentioned by host only.
    static func hosts(of profile: ConnectionProfile) -> String {
        guard let parsed = try? ConnectionString(profile.uri) else { return "(invalid connection string)" }
        let hosts = parsed.hosts.map { parsed.scheme == .srv ? $0.host : $0.description }.joined(separator: ", ")
        if let ssh = profile.ssh { return "\(hosts) via SSH \(ssh.host)" }
        return hosts
    }
}

// MARK: - Tool preparation

extension MongoToolProvider {
    private func timeout(_ args: ToolArguments) throws -> Int {
        try args.integer("timeout_ms", default: MongoToolCatalog.defaultTimeoutMS, range: 1...MongoToolCatalog.maxTimeoutMS)
    }

    private func readableNamespace(_ args: ToolArguments) throws -> MongoNamespace {
        let name = try args.namespace()
        try MCPQueryPolicy.checkReadableNamespace(database: name.database, collection: name.collection)
        return MongoNamespace(database: name.database, collection: name.collection)
    }

    private func writableNamespace(_ args: ToolArguments) throws -> MongoNamespace {
        let name = try args.namespace()
        if name.collection.hasPrefix("system.") || ["local", "config"].contains(name.database)
            || MCPQueryPolicy.protectedCollections.contains(name.collection) {
            throw MCPToolFailure("Writing to system collections or to the local and config databases is not allowed over MCP.")
        }
        return MongoNamespace(database: name.database, collection: name.collection)
    }

    private static func shell(_ document: BSONDocument?) -> String {
        guard let document, !document.isEmpty else { return "{}" }
        let text = BSONFormatter(style: .shell).format(document)
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }

    func prepare(_ spec: MongoToolCatalog.Spec, _ args: ToolArguments) throws -> Prepared {
        let timeoutMS = try timeout(args)
        let maxBytes = configuration.maxResultBytes
        switch spec.name {
        case "server_info":
            return Prepared(summary: "server_info", timeoutMS: timeoutMS) { session, selected in
                Outcome(result: Self.serverInfo(session.server, connection: MCPProfileSelector.safeName(selected.profile)), documents: nil)
            }

        case "list_databases":
            return Prepared(summary: "list_databases", timeoutMS: timeoutMS) { session, _ in
                let databases = try await session.client.listDatabases()
                let items: [JSONValue] = databases.prefix(Self.maxListedItems).map { database in
                    var object: JSONObject = ["name": .string(database.name)]
                    if let size = database.sizeOnDisk { object["size_on_disk"] = .int(size) }
                    if let empty = database.isEmpty { object["empty"] = .bool(empty) }
                    return .object(object)
                }
                var result: JSONObject = ["databases": .array(items)]
                if databases.count > items.count {
                    result["truncated"] = true
                    result["total"] = .int(databases.count)
                }
                return Outcome(result: result, documents: items.count)
            }

        case "list_collections":
            let database = try args.database()
            let includeSystem = try args.bool("include_system", default: false)
            return Prepared(summary: "list_collections \(database)", timeoutMS: timeoutMS) { session, _ in
                let collections = try await session.client.listCollections(database: database)
                    .filter { includeSystem || !$0.isSystem }
                let items: [JSONValue] = collections.prefix(Self.maxListedItems).map { info in
                    var object: JSONObject = ["name": .string(info.name), "type": .string(info.kind.rawValue)]
                    if info.isCapped { object["capped"] = true }
                    if let viewOn = info.viewOn { object["view_on"] = .string(viewOn) }
                    if info.isReadOnly { object["read_only"] = true }
                    return .object(object)
                }
                var result: JSONObject = ["database": .string(database), "collections": .array(items)]
                if collections.count > items.count {
                    result["truncated"] = true
                    result["total"] = .int(collections.count)
                }
                return Outcome(result: result, documents: items.count)
            }

        case "collection_schema":
            let namespace = try readableNamespace(args)
            let sampleSize = try args.integer("sample_size", default: MongoToolCatalog.defaultSampleSize, range: 1...MongoToolCatalog.maxSampleSize)
            return Prepared(summary: "\(namespace) collection_schema sample_size=\(sampleSize)", timeoutMS: timeoutMS) { session, _ in
                let sample = SampleCollector(limit: sampleSize, maxBytes: Self.maxSampleBytes)
                let batchSize = min(sampleSize, Self.streamBatchSize)
                try await Self.readingWithRetry(delivered: { sample.count }) {
                    if session.server.capabilities.hasSampleStage {
                        try await session.client.forEachAggregateBatch(namespace, pipeline: [["$sample": ["size": .int(sampleSize)]]],
                                                                       options: AggregateOptions(maxTimeMS: timeoutMS, maxResults: sampleSize),
                                                                       batchSize: batchSize) { try sample.add($0) }
                    } else {
                        try await session.client.forEachBatch(namespace, options: FindOptions(limit: sampleSize, maxTimeMS: timeoutMS),
                                                              batchSize: batchSize) { try sample.add($0) }
                    }
                }
                let (documents, truncated) = sample.result
                var result = Self.schema(SchemaAnalyzer.analyze(documents), namespace: namespace)
                if truncated { result["sample_truncated"] = true }
                return Outcome(result: result, documents: documents.count)
            }

        case "list_indexes":
            let name = try args.namespace()
            let namespace = MongoNamespace(database: name.database, collection: name.collection)
            return Prepared(summary: "\(namespace) list_indexes", timeoutMS: timeoutMS) { session, _ in
                let indexes = try await session.client.listIndexes(namespace)
                let usage = (try? await session.client.indexUsage(namespace)) ?? nil
                return Outcome(result: ["namespace": .string(namespace.fullName), "indexes": .array(indexes.map { Self.index($0, usage: usage?[$0.name]) })],
                               documents: indexes.count)
            }

        case "find":
            let namespace = try readableNamespace(args)
            let filter = try args.document("filter") ?? [:]
            let projection = try args.document("projection")
            let sort = try args.document("sort")
            try MCPQueryPolicy.checkRead(filter: filter, projection: projection, sort: sort)
            let skip = try args.integer("skip", default: 0, range: 0...MongoToolCatalog.maxSkip)
            let limit = try args.integer("limit", default: MongoToolCatalog.defaultLimit, range: 1...MongoToolCatalog.maxLimit)
            let summary = "\(namespace) find filter=\(Self.shell(filter))" + (projection.map { " projection=\(Self.shell($0))" } ?? "")
                + (sort.map { " sort=\(Self.shell($0))" } ?? "") + (skip > 0 ? " skip=\(skip)" : "") + " limit=\(limit)"
            return Prepared(summary: summary, timeoutMS: timeoutMS) { session, _ in
                let batch = StreamingDocumentBatch(limit: limit, maxBytes: maxBytes)
                let options = FindOptions(filter: filter, projection: projection, sort: sort, skip: skip, limit: limit + 1, maxTimeMS: timeoutMS)
                try await Self.readingWithRetry(delivered: { batch.count }) {
                    try await session.client.forEachBatch(namespace, options: options, batchSize: min(limit + 1, Self.streamBatchSize)) { try batch.add($0) }
                }
                return Self.documentsOutcome(batch, namespace: namespace, maxBytes: maxBytes)
            }

        case "aggregate":
            let namespace = try readableNamespace(args)
            let pipeline = try args.pipeline("pipeline")
            try MCPQueryPolicy.checkPipeline(pipeline)
            let limit = try args.integer("limit", default: MongoToolCatalog.defaultLimit, range: 1...MongoToolCatalog.maxLimit)
            let allowDiskUse = try args.bool("allow_disk_use", default: false)
            let summary = "\(namespace) aggregate [\(pipeline.map { Self.shell($0) }.joined(separator: ", "))] limit=\(limit)"
            return Prepared(summary: summary, timeoutMS: timeoutMS) { session, _ in
                // A trailing $limit stops the server early; maxResults also stops reading client-side.
                let bounded = pipeline + [["$limit": .int(limit + 1)]]
                let batch = StreamingDocumentBatch(limit: limit, maxBytes: maxBytes)
                let options = AggregateOptions(allowDiskUse: allowDiskUse, maxTimeMS: timeoutMS, maxResults: limit + 1)
                try await Self.readingWithRetry(delivered: { batch.count }) {
                    try await session.client.forEachAggregateBatch(namespace, pipeline: bounded, options: options,
                                                                   batchSize: min(limit + 1, Self.streamBatchSize)) { try batch.add($0) }
                }
                return Self.documentsOutcome(batch, namespace: namespace, maxBytes: maxBytes)
            }

        case "count_documents":
            let namespace = try readableNamespace(args)
            let filter = try args.document("filter") ?? [:]
            try MCPQueryPolicy.checkRead(filter: filter, projection: nil, sort: nil)
            return Prepared(summary: "\(namespace) count filter=\(Self.shell(filter))", timeoutMS: timeoutMS) { session, _ in
                let count = try await Self.count(session, namespace, filter: filter, timeoutMS: timeoutMS)
                return Outcome(result: ["namespace": .string(namespace.fullName), "count": .int(count)], documents: Int(clamping: count))
            }

        case "explain":
            return try prepareExplain(args, timeoutMS: timeoutMS)

        case "insert_one":
            let namespace = try writableNamespace(args)
            let document = try args.requiredDocument("document")
            try MCPQueryPolicy.checkWrite(document)
            return Prepared(summary: "\(namespace) insert_one fields=[\(document.keys.joined(separator: ", "))]", timeoutMS: timeoutMS) { session, _ in
                let result = try await session.client.insert([document], into: namespace)
                var object: JSONObject = ["namespace": .string(namespace.fullName), "inserted": .int(result.insertedCount)]
                if let id = result.insertedIDs.first { object["inserted_id"] = ExtendedJSONRenderer.full.render(id).value }
                return Outcome(result: object, documents: result.insertedCount)
            }

        case "update_many":
            let namespace = try writableNamespace(args)
            let filter = try args.requiredDocument("filter")
            let update = try args.requiredDocument("update")
            guard !update.isEmpty, update.keys.allSatisfy({ $0.hasPrefix("$") }) else {
                throw MCPToolFailure("\"update\" must contain only update operators such as {\"$set\": {…}}; replacement documents are not allowed.")
            }
            try MCPQueryPolicy.checkWrite(filter)
            try MCPQueryPolicy.checkWrite(update)
            let upsert = try args.bool("upsert", default: false)
            let dryRun = try args.bool("dry_run", default: false)
            let maxDocuments = try args.integer("max_documents", default: MongoToolCatalog.defaultMaxDocuments, range: 1...MongoToolCatalog.maxMaxDocuments)
            let summary = "\(namespace) update_many filter=\(Self.shell(filter)) operators=[\(update.keys.joined(separator: ", "))]"
                + (upsert ? " upsert" : "") + (dryRun ? " dry_run" : "") + " max_documents=\(maxDocuments)"
            return Prepared(summary: summary, timeoutMS: timeoutMS) { session, _ in
                let matched = try await Self.count(session, namespace, filter: filter, timeoutMS: timeoutMS)
                if dryRun {
                    return Outcome(result: ["namespace": .string(namespace.fullName), "dry_run": true, "matched": .int(matched)], documents: Int(clamping: matched))
                }
                try Self.checkBound(matched, maxDocuments: maxDocuments, verb: "update_many", change: "changed")
                let result = try await session.client.updateDocuments(namespace, filter: filter, update: update, many: true, upsert: upsert, collation: nil)
                var object: JSONObject = ["namespace": .string(namespace.fullName), "dry_run": false,
                                          "matched": .int(result.matchedCount), "modified": .int(result.modifiedCount)]
                if let upserted = result.upsertedID { object["upserted_id"] = ExtendedJSONRenderer.full.render(upserted).value }
                return Outcome(result: object, documents: result.modifiedCount)
            }

        case "delete_many":
            let namespace = try writableNamespace(args)
            let filter = try args.requiredDocument("filter")
            try MCPQueryPolicy.checkWrite(filter)
            let dryRun = try args.bool("dry_run", default: false)
            let maxDocuments = try args.integer("max_documents", default: MongoToolCatalog.defaultMaxDocuments, range: 1...MongoToolCatalog.maxMaxDocuments)
            let summary = "\(namespace) delete_many filter=\(Self.shell(filter))" + (dryRun ? " dry_run" : "") + " max_documents=\(maxDocuments)"
            return Prepared(summary: summary, timeoutMS: timeoutMS) { session, _ in
                let matched = try await Self.count(session, namespace, filter: filter, timeoutMS: timeoutMS)
                if dryRun {
                    return Outcome(result: ["namespace": .string(namespace.fullName), "dry_run": true, "matched": .int(matched)], documents: Int(clamping: matched))
                }
                try Self.checkBound(matched, maxDocuments: maxDocuments, verb: "delete_many", change: "deleted")
                let deleted = try await session.client.deleteDocuments(namespace, filter: filter, many: true, collation: nil)
                return Outcome(result: ["namespace": .string(namespace.fullName), "dry_run": false, "deleted": .int(deleted)], documents: deleted)
            }

        default:
            throw MCPToolError.unknownTool(spec.name)
        }
    }

    private func prepareExplain(_ args: ToolArguments, timeoutMS: Int) throws -> Prepared {
        let namespace = try readableNamespace(args)
        let includeRaw = try args.bool("include_raw", default: false)
        if args.values["pipeline"] != nil {
            if let conflicting = ["filter", "projection", "sort", "skip", "limit"].first(where: { args.values[$0] != nil }) {
                throw MCPToolError.invalidArguments("explain: pass either \"pipeline\" or find arguments, not both (got \"\(conflicting)\")")
            }
            let pipeline = try args.pipeline("pipeline")
            try MCPQueryPolicy.checkPipeline(pipeline)
            let summary = "\(namespace) explain aggregate [\(pipeline.map { Self.shell($0) }.joined(separator: ", "))]"
            return Prepared(summary: summary, timeoutMS: timeoutMS) { session, _ in
                let raw = try await session.client.explainAggregate(namespace, pipeline: pipeline, options: AggregateOptions(maxTimeMS: timeoutMS))
                return Outcome(result: Self.explain(raw, kind: "aggregate", namespace: namespace, includeRaw: includeRaw), documents: nil)
            }
        }
        let filter = try args.document("filter") ?? [:]
        let projection = try args.document("projection")
        let sort = try args.document("sort")
        try MCPQueryPolicy.checkRead(filter: filter, projection: projection, sort: sort)
        let skip = try args.integer("skip", default: 0, range: 0...MongoToolCatalog.maxSkip)
        let limit = try args.integer("limit", default: 0, range: 0...MongoToolCatalog.maxLimit)
        let summary = "\(namespace) explain find filter=\(Self.shell(filter))" + (sort.map { " sort=\(Self.shell($0))" } ?? "")
        return Prepared(summary: summary, timeoutMS: timeoutMS) { session, _ in
            let raw = try await session.client.explainFind(namespace, options: FindOptions(filter: filter, projection: projection, sort: sort, skip: skip,
                                                                                            limit: limit, maxTimeMS: timeoutMS))
            return Outcome(result: Self.explain(raw, kind: "find", namespace: namespace, includeRaw: includeRaw), documents: nil)
        }
    }

    private static func count(_ session: MongoSession, _ namespace: MongoNamespace, filter: BSONDocument, timeoutMS: Int) async throws -> Int64 {
        guard let count = try await session.client.count(namespace, filter: filter, options: CountOptions(maxTimeMS: timeoutMS)) else {
            throw MCPToolFailure("The count exceeded its time limit of \(timeoutMS) ms. Narrow the filter or raise timeout_ms (max \(MongoToolCatalog.maxTimeoutMS)).")
        }
        return count
    }

    private static func checkBound(_ matched: Int64, maxDocuments: Int, verb: String, change: String) throws {
        guard matched <= Int64(maxDocuments) else {
            throw MCPToolFailure("\(verb) matches \(matched) documents, more than max_documents (\(maxDocuments)); nothing was \(change). "
                + "Narrow the filter or raise max_documents (at most \(MongoToolCatalog.maxMaxDocuments)).")
        }
    }
}

// MARK: - Result rendering

extension MongoToolProvider {
    /// Documents fetched per server round trip; small enough that an abandoned batch costs little.
    static let streamBatchSize = 100
    /// Upper bound on BSON bytes kept in memory while sampling for `collection_schema`.
    static let maxSampleBytes = 32 * 1024 * 1024
    /// Entries returned by list_databases / list_collections.
    static let maxListedItems = 1_000

    /// Runs a streaming read, retrying once on a network or "not primary" error when nothing was delivered
    /// yet (e.g. an idle pooled socket the server closed). Stopping early is not an error.
    static func readingWithRetry(delivered: @Sendable () -> Int, _ read: @Sendable () async throws -> Void) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await read()
                return
            } catch is StreamingDocumentBatch.Stop {
                return
            } catch is SampleCollector.Stop {
                return
            } catch let error as MongoError where (error.isNetworkError || error.isNotPrimary) && delivered() == 0 && attempt < 2 && !Task.isCancelled {
                continue
            }
        }
    }

    static func documentsOutcome(_ batch: StreamingDocumentBatch, namespace: MongoNamespace, maxBytes: Int) -> Outcome {
        let (documents, truncated, hasMore) = batch.result
        var result: JSONObject = [
            "namespace": .string(namespace.fullName),
            "returned": .int(documents.count),
            "has_more": .bool(hasMore),
            "truncated": .bool(truncated),
        ]
        if truncated {
            result["note"] = .string("The result was cut to about \(maxBytes / 1024) KB; use a projection or a smaller limit to see the rest.")
        }
        result["documents"] = .array(documents)
        return Outcome(result: result, documents: documents.count)
    }

    static func serverInfo(_ server: ServerDescription, connection: String) -> JSONObject {
        var topology: JSONObject = ["type": .string(server.serverType)]
        if let setName = server.setName { topology["set_name"] = .string(setName) }
        if !server.members.isEmpty { topology["members"] = .array(server.members.map(JSONValue.string)) }
        var result: JSONObject = [
            "connection": .string(connection),
            "version": .string(server.version),
            "wire_version": .int(server.maxWireVersion),
            "protocol": .string(server.capabilities.protocolName),
            "enterprise": .bool(server.isEnterprise),
            "topology": .object(topology),
            "unavailable_features": .array(AssistantPromptBuilder.versionHints(server.capabilities).map(JSONValue.string)),
        ]
        if let gitVersion = server.gitVersion { result["git_version"] = .string(gitVersion) }
        return result
    }

    static let maxSchemaFields = 500

    static func schema(_ schema: SchemaResult, namespace: MongoNamespace) -> JSONObject {
        var fields: [JSONValue] = []
        var truncated = false
        func round(_ value: Double) -> JSONValue { .double((value * 1000).rounded() / 1000) }
        func walk(_ items: [SchemaField]) {
            for field in items {
                guard fields.count < maxSchemaFields else {
                    truncated = true
                    return
                }
                var object: JSONObject = [
                    "path": .string(field.path),
                    "presence": round(field.presence),
                    "types": .array(field.types.map { ["type": .string(typeAlias($0.type)), "share": round(field.count == 0 ? 0 : Double($0.count) / Double(field.count))] }),
                ]
                if !field.arrayElementTypes.isEmpty {
                    object["array_element_types"] = .array(field.arrayElementTypes.map { .string(typeAlias($0.type)) })
                }
                if !field.sampleValues.isEmpty { object["samples"] = .array(field.sampleValues.map(JSONValue.string)) }
                fields.append(.object(object))
                walk(field.children)
            }
        }
        walk(schema.fields)
        var result: JSONObject = ["namespace": .string(namespace.fullName), "sampled": .int(schema.sampleSize), "fields": .array(fields)]
        if truncated { result["fields_truncated"] = true }
        return result
    }

    /// MongoDB `$type` aliases, so results can be used directly in queries.
    static func typeAlias(_ type: BSONType) -> String {
        switch type {
        case .double: "double"
        case .string: "string"
        case .document: "object"
        case .array: "array"
        case .binary: "binData"
        case .undefined: "undefined"
        case .objectId: "objectId"
        case .bool: "bool"
        case .datetime: "date"
        case .null: "null"
        case .regex: "regex"
        case .dbPointer: "dbPointer"
        case .javascript: "javascript"
        case .symbol: "symbol"
        case .javascriptWithScope: "javascriptWithScope"
        case .int32: "int"
        case .timestamp: "timestamp"
        case .int64: "long"
        case .decimal128: "decimal"
        case .minKey: "minKey"
        case .maxKey: "maxKey"
        }
    }

    static func index(_ index: IndexInfo, usage: IndexUsage?) -> JSONValue {
        var object: JSONObject = [
            "name": .string(index.name),
            "keys": ExtendedJSONRenderer.full.render(index.keys).value,
            "kind": .string(index.kind),
        ]
        if index.isUnique { object["unique"] = true }
        if index.isSparse { object["sparse"] = true }
        if index.isHidden { object["hidden"] = true }
        if let ttl = index.expireAfterSeconds { object["ttl_seconds"] = .int(ttl) }
        if let partial = index.partialFilterExpression { object["partial_filter"] = ExtendedJSONRenderer.full.render(partial).value }
        if let collation = index.collation { object["collation"] = ExtendedJSONRenderer.full.render(collation).value }
        if let usage {
            object["usage_ops"] = .int(usage.operations)
            if let since = usage.since { object["usage_since"] = .string(ISO8601DateFormatter().string(from: since)) }
        }
        return .object(object)
    }

    static func explain(_ raw: BSONDocument, kind: String, namespace: MongoNamespace, includeRaw: Bool) -> JSONObject {
        let plan = ExplainPlan(raw)
        var indexes = plan.indexesUsed.prefix(50).map { JSONValue.string($0.clipped(200)) }
        if plan.indexesUsed.count > 50 { indexes.append(.string("… \(plan.indexesUsed.count - 50) more indexes")) }
        var summary: JSONObject = [
            "indexes_used": .array(indexes),
            "collection_scan": .bool(plan.usesCollectionScan),
            "in_memory_sort": .bool(plan.hasInMemorySort),
        ]
        summary["documents_returned"] = .optional(plan.documentsReturned)
        summary["documents_examined"] = .optional(plan.documentsExamined)
        summary["keys_examined"] = .optional(plan.keysExamined)
        summary["execution_time_ms"] = .optional(plan.executionTimeMillis)
        if let selectivity = plan.selectivity { summary["selectivity"] = .double((selectivity * 1000).rounded() / 1000) }
        var result: JSONObject = [
            "namespace": .string(namespace.fullName),
            "kind": .string(kind),
            "format": .string(plan.format.rawValue),
            "summary": .object(summary),
        ]
        if let root = plan.root {
            var budget = maxPlanNodes
            result["plan"] = planNode(root, depth: 0, budget: &budget)
        }
        if includeRaw {
            let full = ExtendedJSONRenderer.full.render(raw).value
            if JSONWriter.encodedSize(full) <= maxRawExplainBytes {
                result["raw"] = full
            } else {
                let compact = ExtendedJSONRenderer.compact.render(raw).value
                if JSONWriter.encodedSize(compact) <= maxRawExplainBytes {
                    result["raw"] = compact
                } else {
                    result["raw_omitted"] = .string("The raw explain output is larger than \(maxRawExplainBytes / 1024) KB.")
                }
            }
        }
        return result
    }

    static let maxPlanNodes = 200
    static let maxRawExplainBytes = 96 * 1024

    static func planNode(_ node: PlanNode, depth: Int, budget: inout Int) -> JSONValue {
        budget -= 1
        var object: JSONObject = ["stage": .string(node.stage.clipped(200))]
        if let index = node.indexName { object["index"] = .string(index.clipped(200)) }
        if !node.details.isEmpty { object["details"] = .array(node.details.prefix(20).map { .string($0.clipped(500)) }) }
        if let returned = node.documentsReturned { object["returned"] = .int(returned) }
        if let examined = node.documentsExamined { object["docs_examined"] = .int(examined) }
        if let keys = node.keysExamined { object["keys_examined"] = .int(keys) }
        if let millis = node.executionTimeMillis { object["time_ms"] = .int(millis) }
        if !node.children.isEmpty {
            var children: [JSONValue] = []
            for child in node.children {
                guard depth < 32, budget > 0 else {
                    children.append(.string("… \(node.children.count - children.count) more stages"))
                    break
                }
                children.append(planNode(child, depth: depth + 1, budget: &budget))
            }
            object["children"] = .array(children)
        }
        return .object(object)
    }
}

/// Collects sampled documents up to a count and a total BSON size.
final class SampleCollector: @unchecked Sendable {
    struct Stop: Error {}

    private let lock = NSLock()
    private let limit: Int
    private let maxBytes: Int
    private var documents: [BSONDocument] = []
    private var bytes = 0
    private var truncated = false

    init(limit: Int, maxBytes: Int) {
        self.limit = max(1, limit)
        self.maxBytes = maxBytes
    }

    func add(_ batch: [BSONDocument]) throws {
        let done = lock.withLock { () -> Bool in
            for document in batch {
                guard documents.count < limit else { return true }
                let size = document.encodedSize ?? maxBytes
                guard bytes + size <= maxBytes || documents.isEmpty else {
                    truncated = true
                    return true
                }
                documents.append(document)
                bytes += size
            }
            return false
        }
        if done { throw Stop() }
    }

    var count: Int { lock.withLock { documents.count } }
    var result: (documents: [BSONDocument], truncated: Bool) { lock.withLock { (documents, truncated) } }
}

extension String {
    /// At most `length` characters, with an ellipsis when shortened (for echoing client input).
    func clipped(_ length: Int) -> String {
        count > length ? String(prefix(length)) + "…" : self
    }
}

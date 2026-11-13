import BSON
import Foundation
import MongoKit
import Testing

/// A real server to test against, from `GROVE_IT_URIS="2.6=mongodb://...,8.0=mongodb://..."` (see scripts/it-up.sh).
struct ServerTarget: Sendable, CustomTestStringConvertible {
    let version: String
    let uri: String
    var testDescription: String { "MongoDB \(version)" }

    static let all: [ServerTarget] = {
        guard let raw = ProcessInfo.processInfo.environment["GROVE_IT_URIS"], !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return ServerTarget(version: String(parts[0]), uri: String(parts[1]))
        }
    }()

    var majorMinor: (Int, Int) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0)
    }

    func atLeast(_ major: Int, _ minor: Int) -> Bool { majorMinor >= (major, minor) }
}

@Suite("Real server compatibility", .enabled(if: !ServerTarget.all.isEmpty, "set GROVE_IT_URIS (scripts/it-up.sh)"))
struct CompatibilityTests {
    static func everyTypeDocument() -> BSONDocument {
        let oid = ObjectId(hex: "507f1f77bcf86cd799439011")!
        var doc = BSONDocument()
        doc.append("_id", .objectId(ObjectId()))
        doc.append("double", .double(-12.5))
        doc.append("string", .string("grove 🌳 ünïcødé"))
        doc.append("document", .document(["nested": .int32(1), "deeper": .document(["x": .null])]))
        doc.append("array", .array([.int32(1), .string("two"), .document(["three": .int64(3)])]))
        doc.append("binary", .binary(BSONBinary(subtype: .generic, data: Data([0, 1, 2, 255]))))
        doc.append("uuid", .binary(BSONBinary(uuid: UUID())))
        doc.append("objectId", .objectId(oid))
        doc.append("bool", .bool(true))
        doc.append("datetime", .datetime(BSONDateTime(millisecondsSinceEpoch: 1_700_000_000_123)))
        doc.append("null", .null)
        doc.append("regex", .regex(BSONRegex(pattern: "^gro+ve$", options: "im")))
        doc.append("javascript", .javascript("function() { return 1; }"))
        doc.append("int32", .int32(-2_147_483_648))
        doc.append("timestamp", .timestamp(BSONTimestamp(timestamp: 1_700_000_000, increment: 42)))
        doc.append("int64", .int64(Int64.max))
        doc.append("minKey", .minKey)
        doc.append("maxKey", .maxKey)
        return doc
    }

    private func withDatabase(_ target: ServerTarget, _ body: (MongoClient, String) async throws -> Void) async throws {
        let client = try MongoClient(target.uri)
        let database = "grove_it_\(UUID().uuidString.prefix(8).lowercased())"
        do {
            try await body(client, database)
        } catch {
            try? await client.dropDatabase(database)
            await client.close()
            throw error
        }
        try? await client.dropDatabase(database)
        await client.close()
    }

    @Test(arguments: ServerTarget.all)
    func connectsAndIdentifiesServer(target: ServerTarget) async throws {
        let client = try MongoClient(target.uri)
        let info = try await client.connect()
        #expect(info.version.hasPrefix(target.version), "reported \(info.version)")
        #expect(info.capabilities.usesOpMsg == target.atLeast(3, 6))
        await client.close()
    }

    @Test(arguments: ServerTarget.all)
    func everySupportedMechanismAuthenticates(target: ServerTarget) async throws {
        var mechanisms: [AuthMechanism] = []
        if target.atLeast(3, 0) { mechanisms.append(.scramSHA1) }
        if target.atLeast(4, 0) { mechanisms.append(.scramSHA256) }
        if !target.atLeast(3, 0) { mechanisms.append(.mongoCR) }
        for mechanism in mechanisms {
            var uri = try ConnectionString(target.uri)
            uri.setOption("authMechanism", mechanism.rawValue)
            let client = MongoClient(uri)
            let info = try await client.connect()
            #expect(info.version.hasPrefix(target.version), "\(mechanism.rawValue)")
            await client.close()
        }
    }

    @Test(arguments: ServerTarget.all)
    func wrongPasswordIsAnAuthenticationError(target: ServerTarget) async throws {
        var uri = try ConnectionString(target.uri)
        uri.password = "definitely-wrong"
        let client = MongoClient(uri)
        await #expect {
            try await client.connect()
        } throws: { error in
            guard let mongo = error as? MongoError else { return false }
            return mongo.kind == .authentication && !mongo.message.contains("definitely-wrong")
        }
        await client.close()
    }

    @Test(arguments: ServerTarget.all)
    func documentsRoundTripWithTypeFidelity(target: ServerTarget) async throws {
        try await withDatabase(target) { client, database in
            let namespace = MongoNamespace(database: database, collection: "types")
            var document = Self.everyTypeDocument()
            if target.atLeast(3, 4) { document.append("decimal", .decimal128(Decimal128(string: "-1.23E+3000")!)) }
            try await client.insert([document], into: namespace)
            let found = try await client.find(namespace, options: FindOptions(filter: ["_id": document["_id"]!], limit: 1))
            #expect(found.first == document)

            // Edit-and-save path: replace keeps every other field's type.
            var edited = document
            edited["string"] = "changed"
            let result = try await client.replaceOne(namespace, filter: ["_id": document["_id"]!], replacement: edited)
            #expect(result.matchedCount == 1)
            let reread = try await client.find(namespace, options: FindOptions(limit: 1))
            #expect(reread.first == edited)
        }
    }

    @Test(arguments: ServerTarget.all)
    func querying(target: ServerTarget) async throws {
        try await withDatabase(target) { client, database in
            let namespace = MongoNamespace(database: database, collection: "items")
            let documents: [BSONDocument] = (0..<250).map { n in
                ["n": .int32(Int32(n)), "kind": .string(n.isMultiple(of: 2) ? "even" : "odd"), "payload": .string(String(repeating: "x", count: 2_000))]
            }
            let inserted = try await client.insert(documents, into: namespace)
            #expect(inserted.insertedCount == 250)

            let page = try await client.find(namespace, options: FindOptions(filter: ["kind": "even"], projection: ["payload": 0],
                                                                             sort: ["n": -1], skip: 5, limit: 120))
            #expect(page.count == 120)
            #expect(page.first?["n"] == .int32(238))
            #expect(page.first?["payload"] == nil)

            let all = try await client.find(namespace, options: FindOptions(limit: 0))
            #expect(all.count == 250)

            var streamed = 0
            let counter = Counter()
            try await client.forEachBatch(namespace, options: FindOptions(), batchSize: 40) { batch in
                await counter.add(batch.count)
            }
            streamed = await counter.value
            #expect(streamed == 250)

            #expect(try await client.count(namespace, filter: ["kind": "odd"]) == 125)

            let grouped = try await client.aggregate(namespace, pipeline: [
                ["$group": ["_id": "$kind", "total": ["$sum": 1]]],
                ["$sort": ["_id": 1]],
            ])
            #expect(grouped.map { $0["total"]?.int64Value } == [125, 125])

            let sample = try await client.sample(namespace, size: 10)
            #expect(sample.count == 10)

            let plan = try await client.explainFind(namespace, options: FindOptions(filter: ["n": 5], limit: 1))
            #expect(!plan.isEmpty)
            let aggregatePlan = try await client.explainAggregate(namespace, pipeline: [["$match": ["n": 5]]])
            #expect(!aggregatePlan.isEmpty)

            let updated = try await client.updateDocuments(namespace, filter: ["kind": "odd"], update: ["$set": ["flag": true]], many: true)
            #expect(updated.matchedCount == 125)
            let deleted = try await client.deleteDocuments(namespace, filter: ["kind": "even"], many: true)
            #expect(deleted == 125)
            #expect(try await client.count(namespace) == 125)

            let stats = try await client.collectionStats(namespace)
            #expect(stats.documentCount == 125)
        }
    }

    @Test(arguments: ServerTarget.all)
    func adminAndIndexes(target: ServerTarget) async throws {
        try await withDatabase(target) { client, database in
            let namespace = MongoNamespace(database: database, collection: "people")
            try await client.createCollection(namespace)
            try await client.insert([["email": "a@x.io", "age": 30], ["email": "b@x.io", "age": 40]], into: namespace)

            let collections = try await client.listCollections(database: database)
            #expect(collections.map(\.name).contains("people"))
            #expect(!collections.map(\.name).contains { $0.contains("$") })

            let databases = try await client.listDatabases()
            #expect(databases.map(\.name).contains(database))

            let name = try await client.createIndex(namespace, keys: ["email": 1], options: IndexOptions(unique: true))
            #expect(name == "email_1")
            let indexes = try await client.listIndexes(namespace)
            #expect(Set(indexes.map(\.name)) == ["_id_", "email_1"])
            #expect(indexes.first { $0.name == "email_1" }?.isUnique == true)

            await #expect {
                try await client.insert([["email": "a@x.io"]], into: namespace)
            } throws: { error in
                (error as? MongoError)?.code == 11000
            }

            let usage = try await client.indexUsage(namespace)
            #expect((usage != nil) == target.atLeast(3, 2))

            try await client.dropIndex(namespace, name: "email_1")
            #expect(try await client.listIndexes(namespace).map(\.name) == ["_id_"])

            try await client.renameCollection(namespace, to: "humans")
            #expect(try await client.listCollections(database: database).map(\.name).contains("humans"))
            try await client.dropCollection(MongoNamespace(database: database, collection: "humans"))
            #expect(!(try await client.listCollections(database: database).map(\.name).contains("humans")))

            let raw = try await client.runCommandRaw(["definitelyNotACommand": 1], database: "admin")
            #expect(raw["ok"]?.isTruthy == false)
            let status = try await client.serverStatus()
            #expect(status["version"]?.stringValue?.hasPrefix(target.version) == true)
        }
    }
}

actor Counter {
    private(set) var value = 0
    func add(_ amount: Int) { value += amount }
}

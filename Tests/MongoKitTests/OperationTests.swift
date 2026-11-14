import BSON
import Foundation
import Testing
@testable import MongoKit

@Suite("Version-aware operations")
struct OperationTests {
    static let namespace = MongoNamespace(database: "app", collection: "events")

    static func seededDatabase() -> FakeDatabase {
        let database = FakeDatabase(serverBatch: 7)
        database.seed("app.events", (0..<100).map { ["_id": .int32(Int32($0)), "n": .int32(Int32($0)), "kind": .string($0.isMultiple(of: 2) ? "even" : "odd")] })
        database.seed("app.users", [["_id": 1]])
        return database
    }

    static func client(wireVersion: Int, database: FakeDatabase, uri: String = "mongodb://fake:27017/app") throws -> (MongoClient, FakeMongoServer) {
        let server = FakeMongoServer(.init(maxWireVersion: wireVersion)) { database.handle($0) }
        let client = MongoClient(try ConnectionString(uri), options: MongoClientOptions(transportFactory: server.transportFactory))
        return (client, server)
    }

    @Test func findReturnsIdenticalPagesOnLegacyAndModernServers() async throws {
        var pages: [[BSONDocument]] = []
        for wire in [2, 3, 4, 5, 6, 25] {
            let database = Self.seededDatabase()
            let (client, server) = try Self.client(wireVersion: wire, database: database)
            let options = FindOptions(filter: ["kind": "even"], sort: ["n": -1], skip: 5, limit: 20)
            let documents = try await client.find(Self.namespace, options: options)
            pages.append(documents)
            #expect(documents.count == 20, "wire \(wire)")
            #expect(documents.first?["n"] == .int32(88), "wire \(wire)")
            // Legacy servers must have used OP_QUERY + OP_GET_MORE instead of the find command.
            let usedFindCommand = server.commandNames.contains("find")
            #expect(usedFindCommand == (wire >= 4), "wire \(wire)")
            #expect(database.openCursorCount == 0, "wire \(wire) leaked a cursor")
            await client.close()
        }
        #expect(Set(pages.map { $0.map { $0["_id"] } }).count == 1)
    }

    @Test(arguments: [2, 25])
    func cursorStillOpenAtLimitIsKilled(wireVersion: Int) async throws {
        let database = Self.seededDatabase()
        let (client, _) = try Self.client(wireVersion: wireVersion, database: database)
        // Batch size larger than the limit is not honoured by the fake (serverBatch 7), so the
        // server-side cursor remains open after 10 documents and must be killed.
        let documents = try await client.find(Self.namespace, options: FindOptions(limit: 10, batchSize: 100))
        #expect(documents.count == 10)
        #expect(database.openCursorCount == 0)
        await client.close()
    }

    @Test func unlimitedFindDrainsEveryBatch() async throws {
        let database = Self.seededDatabase()
        let (client, _) = try Self.client(wireVersion: 2, database: database)
        let all = try await client.find(Self.namespace, options: FindOptions(limit: 0))
        #expect(all.count == 100)
        await client.close()
    }

    @Test(arguments: [2, 6])
    func listCollectionsAcrossVersions(wireVersion: Int) async throws {
        let database = Self.seededDatabase()
        let (client, server) = try Self.client(wireVersion: wireVersion, database: database)
        let collections = try await client.listCollections(database: "app")
        let names = collections.map(\.name)
        #expect(names.contains("events"))
        #expect(names.contains("users"))
        #expect(!names.contains { $0.contains("$") })
        #expect(server.commandNames.contains("listCollections") == (wireVersion >= 3))
        await client.close()
    }

    @Test(arguments: [2, 6])
    func listIndexesAcrossVersions(wireVersion: Int) async throws {
        let database = Self.seededDatabase()
        let (client, _) = try Self.client(wireVersion: wireVersion, database: database)
        let indexes = try await client.listIndexes(Self.namespace)
        #expect(indexes.map(\.name) == ["_id_"])
        #expect(indexes.first?.keys == ["_id": 1])
        await client.close()
    }

    @Test func listIndexesOfMissingCollectionIsEmpty() async throws {
        let (client, _) = try Self.client(wireVersion: 25, database: Self.seededDatabase())
        #expect(try await client.listIndexes(MongoNamespace(database: "app", collection: "missing")).isEmpty)
        await client.close()
    }

    @Test func countTimeoutReportsUnavailable() async throws {
        let database = Self.seededDatabase()
        database.countTimesOut = true
        let (client, _) = try Self.client(wireVersion: 25, database: database)
        let count = try await client.count(Self.namespace, filter: ["kind": "odd"])
        #expect(count == nil)
        await client.close()
    }

    @Test func countMatchesFilter() async throws {
        let (client, _) = try Self.client(wireVersion: 5, database: Self.seededDatabase())
        #expect(try await client.count(Self.namespace, filter: ["kind": "odd"]) == 50)
        await client.close()
    }

    @Test func duplicateKeyInsertIsAWriteError() async throws {
        let (client, _) = try Self.client(wireVersion: 25, database: Self.seededDatabase())
        await #expect {
            try await client.insert([["_id": 1], ["_id": 1000]], into: Self.namespace)
        } throws: { error in
            let mongo = error as? MongoError
            return mongo?.kind == .write && mongo?.code == 11000
        }
        await client.close()
    }

    @Test func insertAssignsObjectIds() async throws {
        let database = Self.seededDatabase()
        let (client, _) = try Self.client(wireVersion: 2, database: database)
        let result = try await client.insert([["name": "a"], ["name": "b"]], into: MongoNamespace(database: "app", collection: "fresh"))
        #expect(result.insertedCount == 2)
        #expect(result.insertedIDs.allSatisfy { $0.objectIdValue != nil })
        await client.close()
    }

    @Test func restrictedUserFallsBackToURIDatabase() async throws {
        let database = Self.seededDatabase()
        database.unauthorizedListDatabases = true
        let (client, _) = try Self.client(wireVersion: 5, database: database, uri: "mongodb://fake:27017/reports")
        let databases = try await client.listDatabases()
        #expect(databases.map(\.name) == ["reports"])
        await client.close()
    }

    @Test(arguments: [2, 25])
    func explainUsesTheRightMechanism(wireVersion: Int) async throws {
        let (client, server) = try Self.client(wireVersion: wireVersion, database: Self.seededDatabase())
        let plan = try await client.explainFind(Self.namespace, options: FindOptions(filter: ["kind": "odd"], limit: 5))
        if wireVersion >= 4 {
            #expect(server.commandNames.contains("explain"))
            #expect(plan["queryPlanner"] != nil)
        } else {
            #expect(plan["cursor"] == .string("BasicCursor"))
        }
        await client.close()
    }

    @Test func collationIsRejectedBeforeMongo34() async throws {
        let (client, _) = try Self.client(wireVersion: 4, database: Self.seededDatabase())
        await #expect {
            _ = try await client.find(Self.namespace, options: FindOptions(limit: 1, collation: ["locale": "en"]))
        } throws: { error in
            (error as? MongoError)?.kind == .unsupportedServer
        }
        await client.close()
    }

    @Test func defaultIndexNames() {
        #expect(MongoClient.defaultIndexName(["a": 1, "b": -1]) == "a_1_b_-1")
        #expect(MongoClient.defaultIndexName(["loc": "2dsphere"]) == "loc_2dsphere")
        #expect(MongoClient.defaultIndexName(["x": 1.0]) == "x_1")
    }

    @Test func connectReportsServerInfo() async throws {
        let (client, _) = try Self.client(wireVersion: 5, database: Self.seededDatabase())
        let info = try await client.connect()
        #expect(info.version == "9.9.9")
        #expect(info.protocolName.contains("OP_QUERY"))
        #expect(info.serverType == .standalone)
        await client.close()
    }
}

@Suite("Explain time limits")
struct ExplainTimeLimitTests {
    /// The server applies maxTimeMS from the top level of a command, so explain must carry it there too.
    @Test func explainCommandCarriesMaxTimeMSAtTheTopLevel() async throws {
        let database = OperationTests.seededDatabase()
        let (client, server) = try OperationTests.client(wireVersion: 25, database: database)
        _ = try await client.explainFind(OperationTests.namespace, options: FindOptions(filter: ["kind": "odd"], maxTimeMS: 1234))
        _ = try? await client.explainAggregate(OperationTests.namespace, pipeline: [["$match": [:]]], options: AggregateOptions(maxTimeMS: 4321))
        let explains = server.requests.compactMap { request -> BSONDocument? in
            guard case let .command(_, body, _, _) = request, body.elements.first?.key == "explain" else { return nil }
            return body
        }
        #expect(explains.count == 2)
        #expect(explains.first?["maxTimeMS"] == .int32(1234))
        #expect(explains.last?["maxTimeMS"] == .int32(4321))
        await client.close()
    }
}

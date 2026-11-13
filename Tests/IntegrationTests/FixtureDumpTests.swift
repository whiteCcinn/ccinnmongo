import BSON
import Foundation
import MongoKit
import Testing

/// Records real explain outputs as fixtures for GroveKit's parser tests.
/// Run with `GROVE_DUMP_FIXTURES=1` and `GROVE_IT_URIS` set.
@Suite("Fixture recording", .enabled(if: ProcessInfo.processInfo.environment["GROVE_DUMP_FIXTURES"] == "1" && !ServerTarget.all.isEmpty))
struct FixtureDumpTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GroveKitTests/Fixtures", isDirectory: true)

    @Test(arguments: ServerTarget.all.filter { ["2.6", "3.4", "4.0", "8.0"].contains($0.version) })
    func recordExplainOutputs(target: ServerTarget) async throws {
        let client = try MongoClient(target.uri)
        let database = "grove_fixture"
        let namespace = MongoNamespace(database: database, collection: "orders")
        try? await client.dropDatabase(database)
        try await client.insert((0..<500).map { ["n": .int32(Int32($0)), "status": .string($0 % 3 == 0 ? "A" : "B")] }, into: namespace)
        try await client.createIndex(namespace, keys: ["n": 1])

        let formatter = BSONFormatter(style: .canonicalExtendedJSON, indent: 1)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let version = target.version.replacingOccurrences(of: ".", with: "")

        let collscan = try await client.explainFind(namespace, options: FindOptions(filter: ["status": "A"], limit: 0))
        try formatter.format(collscan).write(to: Self.directory.appendingPathComponent("explain-\(version)-collscan.json"), atomically: true, encoding: .utf8)

        let ixscan = try await client.explainFind(namespace, options: FindOptions(filter: ["n": ["$gt": 100]], sort: ["status": 1], limit: 10))
        try formatter.format(ixscan).write(to: Self.directory.appendingPathComponent("explain-\(version)-ixscan-sort.json"), atomically: true, encoding: .utf8)

        let aggregate = try await client.explainAggregate(namespace, pipeline: [["$match": ["n": ["$lt": 50]]], ["$group": ["_id": "$status", "c": ["$sum": 1]]]])
        try formatter.format(aggregate).write(to: Self.directory.appendingPathComponent("explain-\(version)-aggregate.json"), atomically: true, encoding: .utf8)

        try await client.dropDatabase(database)
        await client.close()
    }
}

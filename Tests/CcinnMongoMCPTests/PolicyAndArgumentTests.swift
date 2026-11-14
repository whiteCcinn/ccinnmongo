import BSON
import CcinnMongoKit
import Foundation
import Testing
@testable import CcinnMongoMCP

@Suite("MCP read-only policy")
struct MCPQueryPolicyTests {
    private func pipeline(_ text: String) throws -> [BSONDocument] {
        try ShellSyntax.parseArray(text).compactMap(\.documentValue)
    }

    @Test func acceptsOrdinaryReads() throws {
        try MCPQueryPolicy.checkRead(filter: ["status": "paid", "total": ["$gt": 100]], projection: ["_id": 0], sort: ["total": -1])
        try MCPQueryPolicy.checkPipeline(try pipeline("""
        [{ $match: { a: 1 } }, { $group: { _id: "$k", n: { $sum: 1 } } },
         { $lookup: { from: "customers", localField: "c", foreignField: "_id", as: "cust" } },
         { $facet: { byStatus: [{ $sortByCount: "$status" }] } }, { $sort: { n: -1 } }]
        """))
        // A field literally named "out" is fine.
        try MCPQueryPolicy.checkRead(filter: ["out": 1, "merge": "x"], projection: nil, sort: nil)
    }

    @Test(arguments: [
        "[{ $out: \"x\" }]",
        "[{ $merge: { into: \"x\" } }]",
        "[{ $match: {} }, { $facet: { a: [{ $merge: \"x\" }] } }]",
        "[{ $lookup: { from: \"c\", pipeline: [{ $out: \"x\" }], as: \"j\" } }]",
        "[{ $unionWith: { coll: \"c\", pipeline: [{ $merge: \"x\" }] } }]",
        "[{ $match: { $where: \"sleep(100)\" } }]",
        "[{ $match: { $expr: { $function: { body: \"function(){}\", args: [], lang: \"js\" } } } }]",
        "[{ $group: { _id: 1, x: { $accumulator: { init: \"function(){}\" } } } }]",
        "[{ $changeStream: {} }]",
        "[{ $addFields: { f: Code(\"function(){}\") } }]",
        "[{ $lookup: { from: \"system.users\", localField: \"a\", foreignField: \"b\", as: \"u\" } }]",
        "[{ $graphLookup: { from: \"system.keys\", startWith: \"$a\", connectFromField: \"a\", connectToField: \"b\", as: \"k\" } }]",
        "[{ $unionWith: \"system.users\" }]",
        "[{ $unionWith: { coll: \"oplog.rs\" } }]",
        "[{ $lookup: { from: { db: \"admin\", coll: \"system.users\" }, pipeline: [], as: \"u\" } }]",
        "[{ $lookup: { from: \"system.backup_users\", localField: \"a\", foreignField: \"b\", as: \"u\" } }]",
        "[{ $unionWith: { coll: \"external_validation_keys\" } }]",
    ])
    func rejectsUnsafePipelines(text: String) throws {
        let stages = try pipeline(text)
        #expect(throws: MCPToolFailure.self) { try MCPQueryPolicy.checkPipeline(stages) }
    }

    @Test func rejectsServerSideJavaScriptInFilters() throws {
        #expect(throws: MCPToolFailure.self) { try MCPQueryPolicy.checkRead(filter: ["$where": "true"], projection: nil, sort: nil) }
        #expect(throws: MCPToolFailure.self) {
            try MCPQueryPolicy.checkRead(filter: ["$and": [["a": 1], ["$where": "true"]]], projection: nil, sort: nil)
        }
        #expect(throws: MCPToolFailure.self) {
            try MCPQueryPolicy.checkRead(filter: ["a": .javascript("x")], projection: nil, sort: nil)
        }
        #expect(throws: MCPToolFailure.self) {
            try MCPQueryPolicy.checkRead(filter: [:], projection: ["x": ["$function": [:]]], sort: nil)
        }
        do {
            try MCPQueryPolicy.checkRead(filter: ["$where": "1"], projection: nil, sort: nil)
            Issue.record("expected a failure")
        } catch let failure as MCPToolFailure {
            #expect(failure.message.contains("JavaScript"))
        }
    }

    @Test func rejectsCredentialCollections() {
        for collection in ["system.users", "system.keys", "oplog.rs", "oplog.$main", "system.backup_users", "system.new_users",
                           "external_validation_keys"] {
            #expect(throws: MCPToolFailure.self, "\(collection)") {
                try MCPQueryPolicy.checkReadableNamespace(database: collection.hasPrefix("oplog") ? "local" : "admin", collection: collection)
            }
        }
        #expect(throws: Never.self) { try MCPQueryPolicy.checkReadableNamespace(database: "admin", collection: "system.version") }
        #expect(throws: Never.self) { try MCPQueryPolicy.checkReadableNamespace(database: "shop", collection: "users") }
    }

    @Test func writeDocumentsMustNotContainJavaScript() {
        #expect(throws: MCPToolFailure.self) { try MCPQueryPolicy.checkWrite(["$set": ["f": .javascript("x")]]) }
        #expect(throws: MCPToolFailure.self) { try MCPQueryPolicy.checkWrite(["$where": "x"]) }
        #expect(throws: Never.self) { try MCPQueryPolicy.checkWrite(["$set": ["status": "shipped"]]) }
    }
}

@Suite("Tool argument decoding")
struct ToolArgumentTests {
    private func arguments(_ text: String) throws -> ToolArguments {
        ToolArguments(tool: "find", values: try #require(JSONParser.parse(text).objectValue))
    }

    @Test func rejectsUnexpectedArguments() throws {
        let args = try arguments(#"{"database":"shop","writeConcern":{"w":0}}"#)
        #expect(throws: MCPToolError.invalidArguments("Unexpected argument \"writeConcern\" for find. Allowed: connection, database")) {
            try args.requireOnly(["connection", "database"])
        }
    }

    @Test func requiredStrings() throws {
        let args = try arguments(#"{"database":"shop","collection":7}"#)
        #expect(try args.requiredString("database") == "shop")
        #expect(throws: MCPToolError.self) { try args.requiredString("collection") }
        #expect(throws: MCPToolError.self) { try args.requiredString("missing") }
        #expect(throws: MCPToolError.self) { try arguments(#"{"database":""}"#).requiredString("database") }
    }

    @Test func databaseAndCollectionNamesAreValidated() throws {
        #expect(try arguments(#"{"database":"shop","collection":"orders.2024"}"#).namespace()
            == MongoNamespaceName(database: "shop", collection: "orders.2024"))
        for bad in [#"{"database":"admin.system","collection":"users"}"#, #"{"database":"a b","collection":"c"}"#,
                    #"{"database":"a$","collection":"c"}"#, #"{"database":"a/b","collection":"c"}"#,
                    #"{"database":"a\u0000","collection":"c"}"#, #"{"database":"a","collection":"c\u0000d"}"#,
                    #"{"database":"a","collection":"c$d"}"#] {
            #expect(throws: MCPToolError.self, "\(bad)") { try arguments(bad).namespace() }
        }
        // The legacy oplog name contains '$' and must stay addressable (and is then blocked by the policy).
        #expect(try arguments(#"{"database":"local","collection":"oplog.$main"}"#).namespace().collection == "oplog.$main")
    }

    @Test func integersWithBounds() throws {
        let args = try arguments(#"{"limit":10,"skip":2.0,"bad":1.5,"huge":5000,"neg":-1}"#)
        #expect(try args.integer("limit", default: 200, range: 1...1000) == 10)
        #expect(try args.integer("skip", default: 0, range: 0...Int(Int32.max)) == 2)
        #expect(try args.integer("missing", default: 200, range: 1...1000) == 200)
        #expect(throws: MCPToolError.self) { try args.integer("bad", default: 1, range: 1...1000) }
        #expect(throws: MCPToolError.self) { try args.integer("huge", default: 1, range: 1...1000) }
        #expect(throws: MCPToolError.self) { try args.integer("neg", default: 1, range: 0...10) }
    }

    @Test func documentsFromJSONPreserveKeyOrderAndExtendedJSON() throws {
        let args = try arguments(#"{"sort":{"b":1,"a":-1},"filter":{"_id":{"$oid":"507f1f77bcf86cd799439011"},"n":{"$numberLong":"5"},"d":{"$date":"2024-01-02T03:04:05Z"}}}"#)
        #expect(try args.document("sort")?.keys == ["b", "a"])
        let filter = try #require(try args.document("filter"))
        #expect(filter["_id"] == .objectId(ObjectId(hex: "507f1f77bcf86cd799439011")!))
        #expect(filter["n"] == .int64(5))
        #expect(filter["d"]?.datetimeValue != nil)
    }

    @Test func documentsFromShellSyntax() throws {
        let args = try arguments(#"{"filter":"{ _id: ObjectId('507f1f77bcf86cd799439011'), total: { $gt: NumberDecimal('9.99') } }"}"#)
        let filter = try #require(try args.document("filter"))
        #expect(filter["_id"] == .objectId(ObjectId(hex: "507f1f77bcf86cd799439011")!))
        #expect(filter["total"]?.documentValue?["$gt"]?.type == .decimal128)
        #expect(try arguments(#"{"filter":"  "}"#).document("filter") == nil)
    }

    @Test func invalidDocumentSyntaxIsAToolFailure() throws {
        #expect(throws: MCPToolFailure.self) { try arguments(#"{"filter":"{ a: "}"#).document("filter") }
        // Wrong JSON type is a schema violation.
        #expect(throws: MCPToolError.self) { try arguments(#"{"filter":[1]}"#).document("filter") }
        #expect(throws: MCPToolError.self) { try arguments(#"{"filter":3}"#).document("filter") }
    }

    @Test func pipelines() throws {
        let fromJSON = try arguments(#"{"pipeline":[{"$match":{"a":1}},{"$limit":5}]}"#).pipeline("pipeline")
        #expect(fromJSON.count == 2)
        let fromShell = try arguments(#"{"pipeline":"[{ $match: { a: 1 } }, { $sort: { b: -1 } }]"}"#).pipeline("pipeline")
        #expect(fromShell.map(\.keys) == [["$match"], ["$sort"]])
        #expect(throws: MCPToolError.self) { try arguments(#"{"pipeline":{"$match":{}}}"#).pipeline("pipeline") }
        #expect(throws: MCPToolFailure.self) { try arguments(#"{"pipeline":[1]}"#).pipeline("pipeline") }
        #expect(throws: MCPToolFailure.self) { try arguments(#"{"pipeline":[]}"#).pipeline("pipeline") }
        #expect(throws: MCPToolFailure.self) { try arguments(#"{"pipeline":[{"$match":{},"$limit":1}]}"#).pipeline("pipeline") }
    }

    @Test func booleans() throws {
        let args = try arguments(#"{"dry_run":true,"upsert":"yes"}"#)
        #expect(try args.bool("dry_run", default: false))
        #expect(try args.bool("missing", default: true))
        #expect(throws: MCPToolError.self) { try args.bool("upsert", default: false) }
    }
}

@Suite("Connection selection")
struct ProfileSelectionTests {
    let prod = ConnectionProfile(name: "Prod", uri: "mongodb://prod/", mcpAccess: .readOnly)
    let staging = ConnectionProfile(name: "Staging", uri: "mongodb://staging/", mcpAccess: .readWrite)
    let secret = ConnectionProfile(name: "Secret", uri: "mongodb://secret/")
    let unnamed = ConnectionProfile(name: "", uri: "mongodb://h1:27017/", mcpAccess: .readOnly)

    private func select(_ requested: String?, default defaultProfile: String? = nil, profiles: [ConnectionProfile],
                        cap: MCPAccessLevel = .readWrite) -> Result<SelectedProfile, MCPToolFailure> {
        MCPProfileSelector.select(requested: requested, defaultProfile: defaultProfile, profiles: profiles, cap: cap)
    }

    @Test func singleEnabledProfileIsTheDefault() throws {
        let selected = try select(nil, profiles: [prod, secret]).get()
        #expect(selected.profile.id == prod.id)
        #expect(selected.access == .readOnly)
    }

    @Test func ambiguousDefaultListsEnabledNames() {
        guard case let .failure(error) = select(nil, profiles: [prod, staging, secret]) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.message.contains("Prod"))
        #expect(error.message.contains("Staging"))
        #expect(!error.message.contains("Secret"))
    }

    @Test func noEnabledProfiles() {
        guard case let .failure(error) = select(nil, profiles: [secret]) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.message.contains("No connections are enabled"))
    }

    @Test func matchesByIdNameAndCaseInsensitiveName() throws {
        #expect(try select(staging.id.uuidString, profiles: [prod, staging]).get().profile.id == staging.id)
        #expect(try select(staging.id.uuidString.lowercased(), profiles: [prod, staging]).get().profile.id == staging.id)
        #expect(try select("Staging", profiles: [prod, staging]).get().profile.id == staging.id)
        #expect(try select("  staging ", profiles: [prod, staging]).get().profile.id == staging.id)
        // Unnamed profiles are addressed by their host summary.
        #expect(try select("h1:27017", profiles: [prod, unnamed]).get().profile.id == unnamed.id)
    }

    @Test func commandLineDefaultApplies() throws {
        #expect(try select(nil, default: "Staging", profiles: [prod, staging]).get().profile.id == staging.id)
        // An explicit argument wins over the default.
        #expect(try select("Prod", default: "Staging", profiles: [prod, staging]).get().profile.id == prod.id)
    }

    @Test func disabledProfileIsRefusedWithGuidance() {
        guard case let .failure(error) = select("Secret", profiles: [prod, secret]) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.message.contains("not enabled for AI access"))
    }

    @Test func unknownNameListsEnabledConnections() {
        guard case let .failure(error) = select("Nope", profiles: [prod, staging, secret]) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.message.contains("Prod, Staging"))
        #expect(!error.message.contains("Secret"))
    }

    @Test func duplicateNamesAreAmbiguous() {
        let twin = ConnectionProfile(name: "Prod", uri: "mongodb://prod2/", mcpAccess: .readOnly)
        guard case let .failure(error) = select("Prod", profiles: [prod, twin]) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.message.contains(prod.id.uuidString))
        #expect(error.message.contains(twin.id.uuidString))
    }

    @Test func readOnlyCapApplies() throws {
        #expect(try select("Staging", profiles: [staging], cap: .readOnly).get().access == .readOnly)
    }
}

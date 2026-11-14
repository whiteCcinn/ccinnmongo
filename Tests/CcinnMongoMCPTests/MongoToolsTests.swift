import BSON
import CcinnMongoKit
import Foundation
import MongoKit
import Testing
@testable import CcinnMongoMCP

@Suite("MongoDB tools")
struct MongoToolsTests {
    static let readOnly = ConnectionProfile(name: "Shop", uri: "mongodb://app@db1:27017,db2:27017/shop?replicaSet=rs0&tls=true",
                                            mcpAccess: .readOnly)
    static let readWrite = ConnectionProfile(name: "Scratch", uri: "mongodb://localhost:27017/", mcpAccess: .readWrite)
    static let disabled = ConnectionProfile(name: "Private", uri: "mongodb://private:27017/")
    static let context = MCPCallContext(protocolVersion: MCPProtocolVersion.latest)

    struct Harness {
        let provider: MongoToolProvider
        let sessions: FakeSessions
        let client: FakeMongoClient
        let audit: RecordingAudit
    }

    static func harness(profiles: [ConnectionProfile] = [readOnly], defaultProfile: String? = nil, readOnlyCap: Bool = false,
                        client: FakeMongoClient = FakeMongoClient()) -> Harness {
        let sessions = FakeSessions(client: client)
        let audit = RecordingAudit()
        let provider = MongoToolProvider(configuration: MongoToolProvider.Configuration(defaultProfile: defaultProfile, readOnly: readOnlyCap),
                                         profiles: StaticProfiles(profiles: profiles), sessions: sessions, audit: audit)
        return Harness(provider: provider, sessions: sessions, client: client, audit: audit)
    }

    private func call(_ harness: Harness, _ tool: String, _ arguments: String = "{}") async throws -> MCPToolResult {
        let object = try #require(JSONParser.parse(arguments).objectValue)
        return try await harness.provider.callTool(name: tool, arguments: object, context: Self.context)
    }

    private func structured(_ result: MCPToolResult) -> JSONObject? {
        if case let .structured(object) = result.payload { return object }
        return nil
    }

    private func errorMessage(_ result: MCPToolResult) -> String? {
        if case let .error(message) = result.payload { return message }
        return nil
    }

    // MARK: Catalogue

    @Test func readOnlyCatalogue() async {
        let harness = Self.harness(profiles: [Self.readOnly, Self.disabled])
        let tools = await harness.provider.listTools(context: Self.context)
        #expect(tools.map(\.name) == ["list_connections", "server_info", "list_databases", "list_collections", "collection_schema",
                                      "list_indexes", "find", "aggregate", "count_documents", "explain"])
        for tool in tools {
            #expect(tool.readOnly)
            #expect(!tool.destructive)
            let schema = tool.inputSchema.objectValue
            #expect(schema?["type"] == "object")
            #expect(schema?["additionalProperties"] == false)
            #expect(schema?["properties"]?.objectValue != nil)
            #expect(schema?["required"]?.arrayValue != nil)
            // Every property is described.
            for member in schema?["properties"]?.objectValue ?? [:] {
                #expect(member.value.objectValue?["description"]?.stringValue?.isEmpty == false, "\(tool.name).\(member.key)")
            }
            #expect(!tool.description.isEmpty)
        }
    }

    @Test func writeToolsAppearOnlyWithAReadWriteConnection() async {
        let names = await Self.harness(profiles: [Self.readOnly, Self.readWrite]).provider.listTools(context: Self.context).map(\.name)
        #expect(names.suffix(3) == ["insert_one", "update_many", "delete_many"])
        let capped = await Self.harness(profiles: [Self.readWrite], readOnlyCap: true).provider.listTools(context: Self.context).map(\.name)
        #expect(!capped.contains("insert_one"))
        let writeTools = await Self.harness(profiles: [Self.readWrite]).provider.listTools(context: Self.context).filter { !$0.readOnly }
        #expect(writeTools.count == 3)
        let allDestructive = writeTools.allSatisfy { $0.destructive }
        #expect(allDestructive)
    }

    // MARK: Connections

    @Test func listConnectionsShowsOnlyEnabledProfilesWithoutSecrets() async throws {
        let harness = Self.harness(profiles: [Self.readOnly, Self.readWrite, Self.disabled], readOnlyCap: true)
        let result = try await call(harness, "list_connections")
        let object = try #require(structured(result))
        let connections = try #require(object["connections"]?.arrayValue)
        #expect(connections.count == 2)
        let shop = try #require(connections.first?.objectValue)
        #expect(shop["name"] == "Shop")
        #expect(shop["id"] == .string(Self.readOnly.id.uuidString))
        #expect(shop["hosts"] == "db1:27017, db2:27017")
        #expect(shop["access"] == "read-only")
        #expect(shop["replica_set"] == "rs0")
        #expect(shop["tls"] == true)
        #expect(shop["default_database"] == "shop")
        #expect(connections.last?.objectValue?["access"] == "read-only") // capped by --read-only
        #expect(object["read_only_mode"] == true)
        let text = JSONWriter.string(.object(object))
        #expect(!text.contains("app@"))
        #expect(!text.contains("Private"))
        #expect(harness.sessions.opened.isEmpty)
    }

    @Test func callsWithoutAConnectionUseTheOnlyEnabledProfile() async throws {
        let harness = Self.harness(profiles: [Self.readOnly, Self.disabled])
        _ = try await call(harness, "list_databases")
        #expect(harness.sessions.opened == [Self.readOnly.id])
    }

    @Test func ambiguousConnectionIsAToolError() async throws {
        let harness = Self.harness(profiles: [Self.readOnly, Self.readWrite])
        let result = try await call(harness, "list_databases")
        #expect(result.isError)
        #expect(errorMessage(result)?.contains("Shop, Scratch") == true)
        #expect(harness.sessions.opened.isEmpty)
    }

    @Test func disabledProfileIsRefused() async throws {
        let harness = Self.harness(profiles: [Self.readOnly, Self.disabled])
        let result = try await call(harness, "list_databases", #"{"connection":"Private"}"#)
        #expect(errorMessage(result)?.contains("not enabled for AI access") == true)
        #expect(harness.sessions.opened.isEmpty)
    }

    // MARK: Read tools

    @Test func serverInfoReportsVersionAndFeatureGaps() async throws {
        let harness = Self.harness()
        harness.sessions.server = ServerDescription(version: "3.4.24", maxWireVersion: 5, serverType: "Standalone", setName: nil, members: [],
                                                    gitVersion: nil, isEnterprise: false)
        let object = try #require(structured(try await call(harness, "server_info")))
        #expect(object["version"] == "3.4.24")
        #expect(object["wire_version"] == 5)
        #expect(object["protocol"] == "OP_QUERY (legacy)")
        let gaps = object["unavailable_features"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(gaps.contains { $0.contains("$expr") })
    }

    @Test func listCollectionsHidesSystemCollectionsByDefault() async throws {
        let harness = Self.harness()
        let object = try #require(structured(try await call(harness, "list_collections", #"{"database":"shop"}"#)))
        let names = object["collections"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names == ["orders", "recent"])
        #expect(object["collections"]?.arrayValue?.last?.objectValue?["view_on"] == "orders")
        let all = try #require(structured(try await call(harness, "list_collections", #"{"database":"shop","include_system":true}"#)))
        #expect(all["collections"]?.arrayValue?.count == 3)
    }

    @Test func findAppliesLimitsAndReportsMore() async throws {
        let client = FakeMongoClient()
        client.documents = (0..<10).map { ["_id": .int32(Int32($0))] }
        let harness = Self.harness(client: client)
        let result = try await call(harness, "find", #"{"database":"shop","collection":"orders","filter":{"status":"paid"},"sort":{"b":1,"a":-1},"skip":2,"limit":3}"#)
        let object = try #require(structured(result))
        #expect(object["returned"] == 3)
        #expect(object["has_more"] == true)
        #expect(object["truncated"] == false)
        #expect(object["documents"] == [["_id": 0], ["_id": 1], ["_id": 2]])
        let options = try #require(client.lastFindOptions)
        #expect(options.limit == 4)
        #expect(options.skip == 2)
        #expect(options.sort?.keys == ["b", "a"])
        #expect(options.filter == ["status": "paid"])
        #expect(options.maxTimeMS == 30_000)
    }

    @Test func findDefaultsTo200Documents() async throws {
        let client = FakeMongoClient()
        client.documents = (0..<500).map { ["_id": .int32(Int32($0))] }
        let harness = Self.harness(client: client)
        let object = try #require(structured(try await call(harness, "find", #"{"database":"shop","collection":"orders"}"#)))
        #expect(object["returned"] == 200)
        #expect(object["has_more"] == true)
        #expect(client.lastFindOptions?.limit == 201)
    }

    @Test func findResultsRespectTheByteBudget() async throws {
        let client = FakeMongoClient()
        client.documents = (0..<1000).map { ["_id": .int32(Int32($0)), "pad": .string(String(repeating: "x", count: 1024))] }
        let harness = Self.harness(client: client)
        let result = try await call(harness, "find", #"{"database":"shop","collection":"orders","limit":1000}"#)
        let object = try #require(structured(result))
        #expect(object["truncated"] == true)
        let returned = try #require(object["returned"]?.int64Value)
        #expect(returned < 1000)
        #expect(JSONWriter.encodedSize(.object(object)) < 300 * 1024)
    }

    @Test func findStreamsAndStopsReadingOnceTheBudgetIsFull() async throws {
        let client = FakeMongoClient()
        client.documents = (0..<1000).map { ["_id": .int32(Int32($0)), "pad": .string(String(repeating: "x", count: 100_000))] }
        let harness = Self.harness(client: client)
        let object = try #require(structured(try await call(harness, "find", #"{"database":"shop","collection":"orders","limit":1000}"#)))
        #expect(object["truncated"] == true)
        #expect(object["has_more"] == true)
        // About 256 KB of 100 KB documents: the cursor is abandoned after a few batches instead of reading 1001 documents.
        #expect((client.lastBatchSize ?? 0) <= 100)
        #expect(client.batchesDelivered <= 2)
        // Two documents fit whole; later ones are shortened (marked truncated) until the budget is full.
        let returned = try #require(object["returned"]?.int64Value)
        #expect(returned >= 2 && returned < 1000)
        #expect(JSONWriter.encodedSize(.object(object)) <= 300 * 1024)
    }

    @Test func aggregateStreamsToo() async throws {
        let client = FakeMongoClient()
        client.documents = (0..<1000).map { ["n": .int32(Int32($0)), "pad": .string(String(repeating: "y", count: 100_000))] }
        let harness = Self.harness(client: client)
        let object = try #require(structured(try await call(harness, "aggregate", #"{"database":"shop","collection":"orders","pipeline":[{"$match":{}}],"limit":1000}"#)))
        #expect(object["truncated"] == true)
        #expect(client.batchesDelivered <= 2)
    }

    @Test func schemaSamplingIsByteBounded() async throws {
        let client = FakeMongoClient()
        client.documents = (0..<1000).map { ["n": .int32(Int32($0)), "pad": .string(String(repeating: "z", count: 1_000_000))] }
        let harness = Self.harness(client: client)
        let object = try #require(structured(try await call(harness, "collection_schema", #"{"database":"shop","collection":"orders","sample_size":1000}"#)))
        let sampled = try #require(object["sampled"]?.int64Value)
        #expect(sampled < 1000)
        #expect(object["sample_truncated"] == true)
    }

    @Test func listingsAreCapped() async throws {
        let client = FakeMongoClient()
        client.collections = (0..<5000).map { CollectionInfo(name: "c\($0)") }
        client.databases = (0..<3000).map { DatabaseInfo(name: "db\($0)") }
        let harness = Self.harness(client: client)
        let collections = try #require(structured(try await call(harness, "list_collections", #"{"database":"shop"}"#)))
        #expect(collections["collections"]?.arrayValue?.count == 1000)
        #expect(collections["total"] == 5000)
        #expect(collections["truncated"] == true)
        let databases = try #require(structured(try await call(harness, "list_databases")))
        #expect(databases["databases"]?.arrayValue?.count == 1000)
        #expect(databases["truncated"] == true)
    }

    @Test func explainOutputIsBounded() async throws {
        let client = FakeMongoClient()
        let branches: [BSONValue] = (0..<5000).map { index in
            ["stage": "IXSCAN", "indexName": .string("idx_\(index)_" + String(repeating: "k", count: 200)), "keyPattern": ["a": 1]]
        }
        client.explainResult = ["queryPlanner": ["winningPlan": ["stage": "OR", "inputStages": .array(branches)]],
                                "executionStats": ["nReturned": 1, "totalDocsExamined": 1, "totalKeysExamined": 1, "executionTimeMillis": 1]]
        let harness = Self.harness(client: client)
        let result = try await call(harness, "explain", #"{"database":"shop","collection":"orders","include_raw":true}"#)
        let object = try #require(structured(result), "\(errorMessage(result) ?? "")")
        #expect(JSONWriter.encodedSize(.object(object)) <= 300 * 1024)
    }

    @Test func echoedNamesAreBounded() async throws {
        let harness = Self.harness()
        let longName = String(repeating: "n", count: 10_000)
        do {
            _ = try await call(harness, "find", "{\"database\":\"shop\",\"collection\":\"o\",\"\(longName)\":1}")
            Issue.record("expected an argument error")
        } catch let error as MCPToolError {
            #expect(error.message.count < 600)
        }
        let result = try await call(harness, "find", "{\"connection\":\"\(longName)\",\"database\":\"shop\",\"collection\":\"o\"}")
        #expect((errorMessage(result)?.count ?? 0) < 600)
    }

    @Test func unnamedProfileWithUnparsableURINeverExposesTheURI() async throws {
        let broken = ConnectionProfile(name: "", uri: "mongodb://user:hunter22@bad host:99999/", mcpAccess: .readOnly)
        let harness = Self.harness(profiles: [broken])
        let result = try await call(harness, "list_connections")
        let text = JSONWriter.string(.object(try #require(structured(result))))
        #expect(!text.contains("hunter22"))
        let audit = await harness.audit.records
        #expect(!audit.contains { ($0.connection ?? "").contains("hunter22") })
    }

    @Test func authenticationErrorsDoNotRevealPasswordCharacters() {
        let message = MongoToolProvider.describe(MongoError(.authentication, "The password contains a character (U+00E9) that is not allowed by SASLprep"),
                                                 connection: "Shop", timeoutMS: 1000, isWrite: false)
        #expect(!message.contains("00E9"))
        #expect(message.contains("Shop"))
    }

    @Test func timedOutWritesSayTheyMayHaveApplied() {
        let message = MongoToolProvider.describe(MCPDeadline.Expired(), connection: "Shop", timeoutMS: 100, isWrite: true)
        #expect(message.contains("may still"))
    }

    @Test func sessionsOfDisabledOrDeletedProfilesArePruned() async throws {
        let harness = Self.harness(profiles: [Self.readOnly, Self.disabled])
        _ = try await call(harness, "list_databases")
        #expect(harness.sessions.kept == [Self.readOnly.id])
    }

    @Test func oversizedResultsBecomeErrors() {
        var big = JSONObject()
        big["blob"] = .string(String(repeating: "q", count: 2_000_000))
        let guarded = MongoToolProvider.guardSize(.success(big), maxBytes: 256 * 1024)
        #expect(guarded.isError)
    }

    @Test func findRejectsUnsafeFiltersBeforeContactingTheServer() async throws {
        let harness = Self.harness()
        let result = try await call(harness, "find", #"{"database":"shop","collection":"orders","filter":{"$where":"sleep(1000) || true"}}"#)
        #expect(errorMessage(result)?.contains("JavaScript") == true)
        #expect(harness.sessions.opened.isEmpty)
        #expect(harness.client.calls.isEmpty)
    }

    @Test func credentialCollectionsAreRefused() async throws {
        let harness = Self.harness()
        let result = try await call(harness, "find", #"{"database":"admin","collection":"system.users"}"#)
        #expect(result.isError)
        #expect(harness.client.calls.isEmpty)
        let schema = try await call(harness, "collection_schema", #"{"database":"admin","collection":"system.users"}"#)
        #expect(schema.isError)
    }

    @Test func shellSyntaxFilters() async throws {
        let harness = Self.harness()
        _ = try await call(harness, "find", #"{"database":"shop","collection":"orders","filter":"{ _id: ObjectId('507f1f77bcf86cd799439011') }"}"#)
        #expect(harness.client.lastFindOptions?.filter["_id"] == .objectId(ObjectId(hex: "507f1f77bcf86cd799439011")!))
    }

    @Test func invalidSyntaxIsAToolErrorAndWrongTypesAreProtocolErrors() async throws {
        let harness = Self.harness()
        let syntax = try await call(harness, "find", #"{"database":"shop","collection":"orders","filter":"{ a: "}"#)
        #expect(errorMessage(syntax)?.contains("not valid MongoDB syntax") == true)
        await #expect(throws: MCPToolError.self) {
            try await call(harness, "find", #"{"database":"shop","collection":"orders","writeConcern":{"w":0}}"#)
        }
        await #expect(throws: MCPToolError.self) { try await call(harness, "find", #"{"database":"shop"}"#) }
        await #expect(throws: MCPToolError.self) { try await call(harness, "find", #"{"database":"shop","collection":"o","limit":5000}"#) }
        await #expect(throws: MCPToolError.self) { try await call(harness, "find", #"{"database":"shop","collection":"o","timeout_ms":999999}"#) }
        await #expect(throws: MCPToolError.unknownTool("drop_database")) { try await call(harness, "drop_database") }
    }

    @Test func aggregateIsBoundedAndChecked() async throws {
        let client = FakeMongoClient()
        client.documents = (0..<5).map { ["n": .int32(Int32($0))] }
        let harness = Self.harness(client: client)
        let result = try await call(harness, "aggregate", #"{"database":"shop","collection":"orders","pipeline":[{"$group":{"_id":"$status","n":{"$sum":1}}}],"limit":2}"#)
        let object = try #require(structured(result))
        #expect(object["returned"] == 2)
        #expect(object["has_more"] == true)
        #expect(client.lastPipeline?.last == ["$limit": .int32(3)])
        #expect(client.lastAggregateOptions?.maxResults == 3)
        #expect(client.lastAggregateOptions?.maxTimeMS == 30_000)

        let merge = try await call(harness, "aggregate", #"{"database":"shop","collection":"orders","pipeline":[{"$facet":{"a":[{"$merge":"x"}]}}]}"#)
        #expect(merge.isError)
        #expect(client.calls.count == 1)
    }

    @Test func countDocumentsAndTimeLimit() async throws {
        let client = FakeMongoClient()
        client.countResult = 42
        let harness = Self.harness(client: client)
        let object = try #require(structured(try await call(harness, "count_documents", #"{"database":"shop","collection":"orders","filter":{"status":"paid"},"timeout_ms":5000}"#)))
        #expect(object["count"] == 42)
        #expect(client.lastCountOptions?.maxTimeMS == 5000)
        client.countResult = nil
        let expired = try await call(harness, "count_documents", #"{"database":"shop","collection":"orders"}"#)
        #expect(errorMessage(expired)?.contains("time limit") == true)
    }

    @Test func schemaSamplesAndSummarises() async throws {
        let client = FakeMongoClient()
        client.documents = [["a": 1, "b": "x"], ["a": "two"], ["a": 3, "c": ["d": true]]]
        let harness = Self.harness(client: client)
        let object = try #require(structured(try await call(harness, "collection_schema", #"{"database":"shop","collection":"orders","sample_size":50}"#)))
        #expect(object["sampled"] == 3)
        let fields = object["fields"]?.arrayValue?.compactMap(\.objectValue) ?? []
        #expect(fields.map { $0["path"]?.stringValue } == ["a", "b", "c", "c.d"])
        let a = try #require(fields.first)
        #expect(a["presence"] == 1.0)
        #expect(a["types"]?.arrayValue?.first?.objectValue?["type"] == "int")
        // $sample on 3.2+ servers.
        #expect(client.lastPipeline == [["$sample": ["size": .int32(50)]]])
    }

    @Test func schemaFallsBackToFindOnLegacyServers() async throws {
        let client = FakeMongoClient()
        client.documents = [["a": 1]]
        let harness = Self.harness(client: client)
        harness.sessions.server = ServerDescription(version: "2.6.12", maxWireVersion: 2, serverType: "Standalone", setName: nil, members: [],
                                                    gitVersion: nil, isEnterprise: false)
        _ = try await call(harness, "collection_schema", #"{"database":"shop","collection":"orders"}"#)
        #expect(client.calls.first?.operation == "find")
        #expect(client.lastFindOptions?.limit == 100)
    }

    @Test func listIndexes() async throws {
        let harness = Self.harness()
        let object = try #require(structured(try await call(harness, "list_indexes", #"{"database":"shop","collection":"orders"}"#)))
        let indexes = object["indexes"]?.arrayValue?.compactMap(\.objectValue) ?? []
        #expect(indexes.map { $0["name"]?.stringValue } == ["_id_", "status_1_total_-1"])
        #expect(indexes[1]["keys"] == ["status": 1, "total": -1])
        #expect(indexes[1]["unique"] == true)
        #expect(indexes[0]["usage_ops"] == 7)
    }

    @Test func explainFindAndAggregate() async throws {
        let harness = Self.harness()
        let find = try #require(structured(try await call(harness, "explain", #"{"database":"shop","collection":"orders","filter":{"a":1}}"#)))
        #expect(find["kind"] == "find")
        #expect(find["summary"]?.objectValue?["collection_scan"] == true)
        #expect(find["raw"] == nil)
        let aggregate = try #require(structured(try await call(harness, "explain", #"{"database":"shop","collection":"orders","pipeline":[{"$match":{"a":1}}],"include_raw":true}"#)))
        #expect(aggregate["kind"] == "aggregate")
        #expect(aggregate["raw"]?.objectValue != nil)
        #expect(harness.client.calls.map(\.operation) == ["explainFind", "explainAggregate"])
        await #expect(throws: MCPToolError.self) {
            try await call(harness, "explain", #"{"database":"shop","collection":"orders","pipeline":[{"$match":{}}],"filter":{"a":1}}"#)
        }
    }

    // MARK: Errors, cancellation, timeouts

    @Test func serverErrorsBecomeToolErrorsAndConnectionErrorsEvict() async throws {
        let client = FakeMongoClient()
        client.error = MongoError(.command, "unknown operator: $foo", code: 2, codeName: "BadValue")
        let harness = Self.harness(client: client)
        let result = try await call(harness, "find", #"{"database":"shop","collection":"orders","filter":{"a":{"$foo":1}}}"#)
        #expect(errorMessage(result)?.contains("unknown operator: $foo") == true)
        #expect(harness.sessions.evicted.isEmpty)

        client.error = MongoError(.network, "Connection to db1:27017 failed: reset")
        let network = try await call(harness, "find", #"{"database":"shop","collection":"orders"}"#)
        #expect(network.isError)
        #expect(harness.sessions.evicted == [Self.readOnly.id])
    }

    @Test func connectionFailuresAreToolErrors() async throws {
        let harness = Self.harness()
        harness.sessions.openError = MongoError(.authentication, "Authentication failed.")
        let result = try await call(harness, "list_databases")
        #expect(errorMessage(result)?.contains("Shop") == true)
        #expect(errorMessage(result)?.contains("Authentication failed") == true)
    }

    @Test func deadlineAbandonsHungOperations() async throws {
        let client = FakeMongoClient()
        client.hangs = true
        let harness = Self.harness(client: client)
        let started = ContinuousClock.now
        let result = try await call(harness, "find", #"{"database":"shop","collection":"orders","timeout_ms":100}"#)
        #expect(errorMessage(result)?.contains("100 ms") == true)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func cancellationPropagates() async throws {
        let client = FakeMongoClient()
        client.hangs = true
        let harness = Self.harness(client: client)
        let object = try #require(JSONParser.parse(#"{"database":"shop","collection":"orders"}"#).objectValue)
        let task = Task { try await harness.provider.callTool(name: "find", arguments: object, context: Self.context) }
        try await waitUntil { !client.calls.isEmpty }
        task.cancel()
        let outcome = await task.result
        switch outcome {
        case .failure: break // cancelled calls throw so the server sends no response
        case .success: Issue.record("a cancelled call must not produce a result")
        }
    }

    // MARK: Writes

    @Test func writeToolsRequireReadWriteAccess() async throws {
        let harness = Self.harness(profiles: [Self.readOnly, Self.readWrite])
        let result = try await call(harness, "insert_one", #"{"connection":"Shop","database":"shop","collection":"orders","document":{"a":1}}"#)
        #expect(errorMessage(result)?.contains("read-only") == true)
        #expect(harness.client.calls.isEmpty)
        let capped = Self.harness(profiles: [Self.readWrite], readOnlyCap: true)
        let refused = try await call(capped, "delete_many", #"{"database":"shop","collection":"orders","filter":{"a":1}}"#)
        #expect(refused.isError)
        #expect(capped.client.calls.isEmpty)
    }

    @Test func insertOne() async throws {
        let harness = Self.harness(profiles: [Self.readWrite])
        let object = try #require(structured(try await call(harness, "insert_one", #"{"database":"shop","collection":"orders","document":{"_id":5,"a":1}}"#)))
        #expect(object["inserted_id"] == 5)
        #expect(harness.client.calls.map(\.operation) == ["insert"])
    }

    @Test func boundedDeleteRefusesLargeMatches() async throws {
        let client = FakeMongoClient()
        client.countResult = 250
        let harness = Self.harness(profiles: [Self.readWrite], client: client)
        let result = try await call(harness, "delete_many", #"{"database":"shop","collection":"orders","filter":{"status":"old"}}"#)
        let message = errorMessage(result) ?? ""
        #expect(message.contains("250"))
        #expect(message.contains("100"))
        #expect(client.calls.map(\.operation) == ["count"])

        let allowed = try #require(structured(try await call(harness, "delete_many", #"{"database":"shop","collection":"orders","filter":{"status":"old"},"max_documents":300}"#)))
        #expect(allowed["deleted"] == 250)
        #expect(client.calls.map(\.operation) == ["count", "count", "delete"])
    }

    @Test func dryRunsOnlyCount() async throws {
        let client = FakeMongoClient()
        client.countResult = 3
        let harness = Self.harness(profiles: [Self.readWrite], client: client)
        let update = try #require(structured(try await call(harness, "update_many", #"{"database":"shop","collection":"orders","filter":{"a":1},"update":{"$set":{"b":2}},"dry_run":true}"#)))
        #expect(update["dry_run"] == true)
        #expect(update["matched"] == 3)
        let delete = try #require(structured(try await call(harness, "delete_many", #"{"database":"shop","collection":"orders","filter":{"a":1},"dry_run":true}"#)))
        #expect(delete["matched"] == 3)
        #expect(client.calls.map(\.operation) == ["count", "count"])
    }

    @Test func updateRequiresOperatorsAndNoJavaScript() async throws {
        let harness = Self.harness(profiles: [Self.readWrite])
        let replacement = try await call(harness, "update_many", #"{"database":"shop","collection":"orders","filter":{"a":1},"update":{"b":2}}"#)
        #expect(errorMessage(replacement)?.contains("update operators") == true)
        let javascript = try await call(harness, "update_many", #"{"database":"shop","collection":"orders","filter":{"$where":"1"},"update":{"$set":{"b":2}}}"#)
        #expect(javascript.isError)
        let system = try await call(harness, "insert_one", #"{"database":"admin","collection":"system.users","document":{"a":1}}"#)
        #expect(system.isError)
        let local = try await call(harness, "delete_many", #"{"database":"local","collection":"startup_log","filter":{"a":1}}"#)
        #expect(local.isError)
        #expect(harness.client.calls.isEmpty)
    }

    // MARK: Audit

    @Test func everyCallIsAudited() async throws {
        let client = FakeMongoClient()
        client.countResult = 9
        let harness = Self.harness(client: client)
        _ = try await call(harness, "count_documents", #"{"database":"shop","collection":"orders","filter":{"status":"paid"}}"#)
        _ = try await call(harness, "find", #"{"database":"shop","collection":"orders","filter":{"$where":"1"}}"#)
        let records = await harness.audit.records
        #expect(records.count == 2)
        #expect(records[0].tool == "count_documents")
        #expect(records[0].connection == "Shop")
        #expect(records[0].operation.contains("shop.orders"))
        #expect(records[0].operation.contains("paid"))
        #expect(records[0].documents == 9)
        #expect(records[0].error == nil)
        #expect(records[1].error?.contains("JavaScript") == true)
        let line = String(decoding: records[0].jsonLine(), as: UTF8.self)
        #expect(line.contains("\"source\":\"mcp\""))
        #expect(!line.contains("\n"))
    }
}

import BSON
import CcinnMongoKit
import CcinnMongoMCP
import Foundation
import MongoKit
import Testing

/// Drives the real `CcinnMongo mcp` executable over stdio.
final class MCPProcessClient: @unchecked Sendable {
    /// The executable under test: `CCINNMONGO_BINARY`, else `.build/debug/CcinnMongo` of this package.
    static let binary: URL? = {
        if let explicit = ProcessInfo.processInfo.environment["CCINNMONGO_BINARY"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = root.appendingPathComponent(".build/debug/CcinnMongo")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }()

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var stderrText = ""
    private var nextID = 100

    init(binary: URL, arguments: [String], profileDirectory: URL) throws {
        process.executableURL = binary
        process.arguments = ["mcp"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CCINNMONGO_PROFILE_DIR"] = profileDirectory.path
        environment["CCINNMONGO_TEST_DISABLE_KEYCHAIN"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    self.lines.append(String(decoding: self.buffer[self.buffer.startIndex..<newline], as: UTF8.self))
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock { self.stderrText += String(decoding: data, as: UTF8.self) }
        }
        try process.run()
    }

    var allLines: [String] { lock.withLock { lines } }
    var standardError: String { lock.withLock { stderrText } }

    func sendLine(_ text: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
    }

    func notify(_ method: String, params: JSONValue = [:]) throws {
        try sendLine(JSONWriter.string(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    /// Sends a request and waits (up to 90 s) for the response with the same id.
    func request(_ method: String, params: JSONValue = [:]) async throws -> JSONObject {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try sendLine(JSONWriter.string(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]))
        return try await response(id: .int(Int64(id)))
    }

    func response(id: JSONValue) async throws -> JSONObject {
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            let match = allLines.lazy.compactMap { try? JSONParser.parse($0).objectValue }.first { $0["id"] == id }
            if let match { return match }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MongoError(.timeout, "No response for request \(id); stderr: \(standardError)")
    }

    /// Calls a tool and returns (structured result, isError, text).
    func callTool(_ name: String, _ arguments: JSONValue = [:]) async throws -> (object: JSONObject?, isError: Bool, text: String) {
        let response = try await request("tools/call", params: ["name": .string(name), "arguments": arguments])
        let result = response["result"]?.objectValue
        let text = result?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? JSONWriter.string(.object(response))
        return (result?["structuredContent"]?.objectValue, result?["isError"] == true, text)
    }

    func closeInputAndWait(timeout: Duration = .seconds(30)) async -> Int32? {
        try? input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}

@Suite("MCP server process", .serialized,
       .enabled(if: !ServerTarget.all.isEmpty, "set CCINNMONGO_IT_URIS (scripts/it-up.sh)"),
       .enabled(if: MCPProcessClient.binary != nil, "build the CcinnMongo executable first (swift build)"))
struct MCPServerProcessTests {
    struct Fixture {
        let directory: URL
        let database: String
        let readWrite: ConnectionProfile
        let disabled: ConnectionProfile
    }

    private func withFixture(_ target: ServerTarget, _ body: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-mcp-it-\(UUID().uuidString)")
        let database = "ccinnmongo_mcp_it_\(UUID().uuidString.prefix(8).lowercased())"
        // Test-only: the password stays inline in the URI because the Keychain is disabled for the child process.
        let readWrite = ConnectionProfile(name: "IT \(target.version)", uri: target.uri, mcpAccess: .readWrite)
        let disabled = ConnectionProfile(name: "Disabled", uri: target.uri)
        try ProfileRepository(directory: directory, secrets: InMemorySecretStore()).save([readWrite, disabled])

        let client = try MongoClient(target.uri)
        let namespace = MongoNamespace(database: database, collection: "orders")
        let statuses = ["paid", "pending", "shipped"]
        let documents: [BSONDocument] = (0..<30).map { index in
            ["_id": .int32(Int32(index)), "status": .string(statuses[index % 3]), "total": .double(Double(index) * 10.5),
             "customer": ["name": .string("c\(index % 7)"), "vip": .bool(index % 5 == 0)]]
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await client.insert(documents, into: namespace)
            try await client.createIndex(namespace, keys: ["status": 1, "total": -1])
            try await body(Fixture(directory: directory, database: database, readWrite: readWrite, disabled: disabled))
        } catch {
            try? await client.dropDatabase(database)
            await client.close()
            throw error
        }
        try? await client.dropDatabase(database)
        await client.close()
    }

    @Test(arguments: ServerTarget.all)
    func fullStdioSession(target: ServerTarget) async throws {
        let binary = try #require(MCPProcessClient.binary)
        try await withFixture(target) { fixture in
            let mcp = try MCPProcessClient(binary: binary, arguments: [], profileDirectory: fixture.directory)
            let db = JSONValue.string(fixture.database)

            // Lifecycle.
            let initialize = try await mcp.request("initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                          "clientInfo": ["name": "it", "version": "1"]])
            let initResult = try #require(initialize["result"]?.objectValue)
            #expect(initResult["protocolVersion"] == "2025-06-18")
            #expect(initResult["serverInfo"]?.objectValue?["name"] == "ccinnmongo")
            try mcp.notify("notifications/initialized")
            #expect(try await mcp.request("ping")["result"] == [:])

            // Malformed input does not end the session.
            try mcp.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,")
            let parseError = try await mcp.response(id: .null)
            #expect(parseError["error"]?.objectValue?["code"] == .int(-32700))

            let tools = try await mcp.request("tools/list")["result"]?.objectValue?["tools"]?.arrayValue ?? []
            #expect(tools.count == 13)

            // Connections: the disabled profile is invisible; no secrets.
            let connections = try await mcp.callTool("list_connections")
            let listed = connections.object?["connections"]?.arrayValue ?? []
            #expect(listed.count == 1)
            #expect(listed.first?.objectValue?["name"] == .string(fixture.readWrite.name))
            #expect(!connections.text.contains("ccinn-secret"))
            let refused = try await mcp.callTool("list_databases", ["connection": "Disabled"])
            #expect(refused.isError)

            // Server metadata.
            let info = try await mcp.callTool("server_info")
            #expect(info.object?["version"]?.stringValue?.hasPrefix(target.version) == true, "\(info.text)")
            #expect((info.object?["protocol"]?.stringValue == "OP_MSG") == target.atLeast(3, 6))
            let databases = try await mcp.callTool("list_databases")
            #expect(databases.object?["databases"]?.arrayValue?.contains { $0.objectValue?["name"] == db } == true, "\(databases.text)")
            let collections = try await mcp.callTool("list_collections", ["database": db])
            #expect(collections.object?["collections"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } == ["orders"])
            let schema = try await mcp.callTool("collection_schema", ["database": db, "collection": "orders", "sample_size": 30])
            let paths = schema.object?["fields"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue } ?? []
            #expect(paths.contains("customer.vip"), "\(schema.text)")
            let indexes = try await mcp.callTool("list_indexes", ["database": db, "collection": "orders"])
            #expect(indexes.object?["indexes"]?.arrayValue?.count == 2, "\(indexes.text)")

            // Queries.
            let found = try await mcp.callTool("find", ["database": db, "collection": "orders", "filter": ["status": "paid"],
                                                        "sort": ["total": -1], "projection": ["total": 1], "limit": 3])
            let totals = found.object?["documents"]?.arrayValue?.compactMap { $0.objectValue?["total"]?.doubleValue } ?? []
            #expect(totals == [283.5, 252.0, 220.5], "\(found.text)")
            #expect(found.object?["has_more"] == true)
            let shell = try await mcp.callTool("find", ["database": db, "collection": "orders", "filter": "{ 'customer.vip': true, total: { $gte: 100 } }"])
            #expect(shell.object?["returned"] == 4, "\(shell.text)")
            let count = try await mcp.callTool("count_documents", ["database": db, "collection": "orders", "filter": ["status": "pending"]])
            #expect(count.object?["count"] == 10, "\(count.text)")
            let grouped = try await mcp.callTool("aggregate", ["database": db, "collection": "orders",
                                                               "pipeline": [["$group": ["_id": "$status", "n": ["$sum": 1]]], ["$sort": ["_id": 1]]]])
            let groups = grouped.object?["documents"]?.arrayValue?.compactMap { $0.objectValue?["_id"]?.stringValue } ?? []
            #expect(groups == ["paid", "pending", "shipped"], "\(grouped.text)")
            let explained = try await mcp.callTool("explain", ["database": db, "collection": "orders", "filter": ["status": "paid"], "sort": ["total": -1]])
            #expect(explained.object?["summary"]?.objectValue?["indexes_used"]?.arrayValue?.isEmpty == false, "\(explained.text)")
            let explainedPipeline = try await mcp.callTool("explain", ["database": db, "collection": "orders", "pipeline": [["$match": ["status": "paid"]]]])
            #expect(!explainedPipeline.isError, "\(explainedPipeline.text)")

            // Read-only enforcement happens before the server is contacted.
            let out = try await mcp.callTool("aggregate", ["database": db, "collection": "orders", "pipeline": [["$match": [:]], ["$out": "stolen"]]])
            #expect(out.isError)
            let javascript = try await mcp.callTool("find", ["database": db, "collection": "orders", "filter": ["$where": "true"]])
            #expect(javascript.isError)
            let credentials = try await mcp.callTool("find", ["database": "admin", "collection": "system.users"])
            #expect(credentials.isError)
            let after = try await mcp.callTool("list_collections", ["database": db])
            #expect(after.object?["collections"]?.arrayValue?.count == 1, "\(after.text)")
            let serverError = try await mcp.callTool("find", ["database": db, "collection": "orders", "filter": ["a": ["$bogusOperator": 1]]])
            #expect(serverError.isError, "\(serverError.text)")

            // Bounded writes (the profile is read & write).
            let dryRun = try await mcp.callTool("delete_many", ["database": db, "collection": "orders", "filter": ["status": "paid"], "dry_run": true])
            #expect(dryRun.object?["matched"] == 10, "\(dryRun.text)")
            let bounded = try await mcp.callTool("delete_many", ["database": db, "collection": "orders", "filter": [:], "max_documents": 5])
            #expect(bounded.isError)
            #expect(bounded.text.contains("30"), "\(bounded.text)")
            let inserted = try await mcp.callTool("insert_one", ["database": db, "collection": "orders", "document": ["_id": 100, "status": "new"]])
            #expect(inserted.object?["inserted_id"] == 100, "\(inserted.text)")
            let updated = try await mcp.callTool("update_many", ["database": db, "collection": "orders", "filter": ["_id": 100],
                                                                 "update": ["$set": ["status": "done"]], "max_documents": 1])
            #expect(updated.object?["modified"] == 1, "\(updated.text)")
            let deleted = try await mcp.callTool("delete_many", ["database": db, "collection": "orders", "filter": ["status": "done"], "max_documents": 1])
            #expect(deleted.object?["deleted"] == 1, "\(deleted.text)")
            let total = try await mcp.callTool("count_documents", ["database": db, "collection": "orders"])
            #expect(total.object?["count"] == 30)

            // Shutdown on end of input, and nothing but JSON-RPC on stdout.
            let status = await mcp.closeInputAndWait()
            #expect(status == 0, "stderr: \(mcp.standardError)")
            for line in mcp.allLines {
                let message = try JSONParser.parse(line).objectValue
                #expect(message?["jsonrpc"] == "2.0", "unexpected stdout line: \(line)")
            }
            let audit = try String(contentsOf: fixture.directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
            #expect(audit.split(separator: "\n").count >= 20)
            #expect(!audit.contains("ccinn-secret"))
        }
    }

    @Test(arguments: ServerTarget.all.prefix(1))
    func readOnlyFlagAndDefaultProfile(target: ServerTarget) async throws {
        let binary = try #require(MCPProcessClient.binary)
        try await withFixture(target) { fixture in
            let mcp = try MCPProcessClient(binary: binary, arguments: ["--read-only", "--profile", fixture.readWrite.name],
                                           profileDirectory: fixture.directory)
            _ = try await mcp.request("initialize", params: ["protocolVersion": "2024-11-05", "capabilities": [:]])
            let tools = try await mcp.request("tools/list")["result"]?.objectValue?["tools"]?.arrayValue ?? []
            #expect(tools.count == 10)
            // Older protocol versions get text content only.
            let response = try await mcp.request("tools/call", params: ["name": "count_documents",
                                                                        "arguments": ["database": .string(fixture.database), "collection": "orders"]])
            let result = response["result"]?.objectValue
            #expect(result?["structuredContent"] == nil)
            #expect(result?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?.contains("\"count\":30") == true)
            let insert = try await mcp.callTool("insert_one", ["database": .string(fixture.database), "collection": "orders", "document": ["a": 1]])
            #expect(insert.isError)
            #expect(await mcp.closeInputAndWait() == 0)
        }
    }
}

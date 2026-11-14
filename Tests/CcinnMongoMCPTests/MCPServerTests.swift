import Foundation
import Testing
@testable import CcinnMongoMCP

/// Collects every line the server writes.
actor RecordingOutput: MCPOutput {
    private(set) var lines: [String] = []
    private var waiters: [(id: Int, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextWaiterID = 0
    var failWrites = false

    func send(_ line: [UInt8]) async throws {
        if failWrites { throw MCPOutputError.closed }
        lines.append(String(decoding: line, as: UTF8.self))
        let ready = waiters.filter { $0.count <= lines.count }
        waiters.removeAll { $0.count <= lines.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func setFailWrites(_ value: Bool) { failWrites = value }

    /// Waits until at least `count` lines were written, or records an issue after 5 seconds.
    func waitFor(_ count: Int) async {
        if lines.count >= count { return }
        let id = nextWaiterID
        nextWaiterID += 1
        Task {
            try? await Task.sleep(for: .seconds(5))
            self.expire(id)
        }
        await withCheckedContinuation { continuation in
            waiters.append((id, count, continuation))
        }
    }

    private func expire(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        Issue.record("expected \(waiter.count) output lines, got \(lines.count)")
        waiter.continuation.resume()
    }

    var messages: [JSONValue] { lines.compactMap { try? JSONParser.parse($0) } }
}

/// Tool provider double: `echo` returns its arguments, `slow` waits until cancelled or released,
/// `fail` returns an error result, `strict` rejects arguments with -32602.
final class FakeTools: MCPToolProvider, @unchecked Sendable {
    let lock = NSLock()
    private var _slowStarted = 0
    private var _slowCancelled = 0
    private var _calls: [String] = []
    private var release: [CheckedContinuation<Void, Never>] = []

    var slowStarted: Int { lock.withLock { _slowStarted } }
    var slowCancelled: Int { lock.withLock { _slowCancelled } }
    var calls: [String] { lock.withLock { _calls } }

    func releaseSlowCalls() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { release.removeAll() }
            return release
        }
        for continuation in pending { continuation.resume() }
    }

    func listTools(context: MCPCallContext) async -> [MCPToolDefinition] {
        [MCPToolDefinition(name: "echo", title: "Echo", description: "Echoes", inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                           readOnly: true, destructive: false, idempotent: true)]
    }

    func callTool(name: String, arguments: JSONObject, context: MCPCallContext) async throws -> MCPToolResult {
        lock.withLock { _calls.append(name) }
        switch name {
        case "echo":
            return .success(["arguments": .object(arguments), "protocol": .string(context.protocolVersion)])
        case "fail":
            return .failure("Something went wrong")
        case "strict":
            throw MCPToolError.invalidArguments("Unexpected argument \"x\"")
        case "slow":
            lock.withLock { _slowStarted += 1 }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.withLock { release.append(continuation) }
                }
            } onCancel: {
                lock.withLock { _slowCancelled += 1 }
                self.releaseSlowCalls()
            }
            if Task.isCancelled { throw CancellationError() }
            return .success(["slow": true])
        default:
            throw MCPToolError.unknownTool(name)
        }
    }
}

@Suite("MCP server")
struct MCPServerTests {
    static let configuration = MCPServer.Configuration(name: "ccinnmongo", title: "CcinnMongo", version: "1.1.0",
                                                       instructions: "Test instructions", maxConcurrentCalls: 2)

    private func makeServer(tools: FakeTools = FakeTools()) -> (MCPServer, RecordingOutput, FakeTools) {
        let output = RecordingOutput()
        return (MCPServer(configuration: Self.configuration, tools: tools, output: output), output, tools)
    }

    private func send(_ server: MCPServer, _ text: String) async {
        await server.receive(Array((text + "\n").utf8))
    }

    @Test func initializeNegotiatesTheProtocolVersion() async throws {
        for (requested, expected) in [("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"), ("2024-11-05", "2024-11-05"),
                                      ("1999-01-01", "2025-06-18"), ("", "2025-06-18")] {
            let (server, output, _) = makeServer()
            await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(requested)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
            await output.waitFor(1)
            let result = await output.messages.first?.objectValue?["result"]?.objectValue
            #expect(result?["protocolVersion"]?.stringValue == expected)
            #expect(result?["serverInfo"] == ["name": "ccinnmongo", "title": "CcinnMongo", "version": "1.1.0"])
            #expect(result?["capabilities"] == ["tools": ["listChanged": false]])
            #expect(result?["instructions"]?.stringValue == "Test instructions")
        }
    }

    @Test func initializeWithoutParamsIsInvalid() async {
        let (server, output, _) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        await output.waitFor(1)
        let error = await output.messages.first?.objectValue?["error"]?.objectValue
        #expect(error?["code"] == .int(-32602))
    }

    @Test func pingAndEmptyListings() async {
        let (server, output, _) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        await send(server, #"{"jsonrpc":"2.0","id":3,"method":"resources/templates/list"}"#)
        await send(server, #"{"jsonrpc":"2.0","id":4,"method":"prompts/list"}"#)
        await output.waitFor(4)
        let lines = await output.lines
        #expect(lines == [
            #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"resources":[]}}"#,
            #"{"jsonrpc":"2.0","id":3,"result":{"resourceTemplates":[]}}"#,
            #"{"jsonrpc":"2.0","id":4,"result":{"prompts":[]}}"#,
        ])
    }

    @Test func unknownMethodsAndNotifications() async {
        let (server, output, _) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await send(server, #"{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":"q","method":"sampling/createMessage","params":{}}"#)
        await output.waitFor(1)
        let lines = await output.lines
        #expect(lines == [#"{"jsonrpc":"2.0","id":"q","error":{"code":-32601,"message":"Method not found: sampling/createMessage"}}"#])
    }

    @Test func parseErrorsAndInvalidRequests() async {
        let (server, output, _) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"#)
        await send(server, #"[]"#)
        await send(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":[1]}"#)
        await output.waitFor(3)
        let messages = await output.messages
        #expect(messages[0].objectValue?["error"]?.objectValue?["code"] == .int(-32700))
        #expect(messages[0].objectValue?["id"] == .null)
        #expect(messages[1].objectValue?["error"]?.objectValue?["code"] == .int(-32600))
        #expect(messages[2].objectValue?["error"]?.objectValue?["code"] == .int(-32602))
        #expect(messages[2].objectValue?["id"] == .int(7))
    }

    @Test func oversizedMessagesAreRejectedAndTheSessionContinues() async {
        let output = RecordingOutput()
        var configuration = Self.configuration
        configuration.maxMessageBytes = 64
        let server = MCPServer(configuration: configuration, tools: FakeTools(), output: output)
        let huge = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":""# + String(repeating: "x", count: 500) + "\"}}\n"
        await server.receive(Array(huge.utf8))
        await server.receive(Array("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n".utf8))
        await output.waitFor(2)
        let messages = await output.messages
        #expect(messages[0].objectValue?["error"]?.objectValue?["code"] == .int(-32600))
        #expect(messages[0].objectValue?["error"]?.objectValue?["message"]?.stringValue?.contains("larger than") == true)
        #expect(messages[1] == ["jsonrpc": "2.0", "id": 2, "result": [:]])
    }

    @Test func toolsListAndCallRouting() async {
        let (server, output, _) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"b":1,"a":[true]}}}"#)
        await output.waitFor(3)
        let messages = await output.messages
        let tools = messages[1].objectValue?["result"]?.objectValue?["tools"]?.arrayValue
        #expect(tools?.count == 1)
        let tool = tools?.first?.objectValue
        #expect(tool?["name"] == "echo")
        #expect(tool?["title"] == "Echo")
        #expect(tool?["annotations"] == ["title": "Echo", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false])
        let result = messages[2].objectValue?["result"]?.objectValue
        let expected: JSONValue = ["arguments": ["b": 1, "a": [true]], "protocol": "2025-06-18"]
        #expect(result?["structuredContent"] == expected)
        #expect(result?["content"] == [["type": "text", "text": .string(JSONWriter.string(expected))]])
        #expect(result?["isError"] == nil)
    }

    @Test func olderProtocolVersionsGetNoStructuredContent() async {
        let (server, output, _) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo"}}"#)
        await output.waitFor(2)
        let result = await output.messages[1].objectValue?["result"]?.objectValue
        #expect(result?["structuredContent"] == nil)
        #expect(result?["content"]?.arrayValue?.count == 1)
    }

    @Test func toolFailuresAreResultsAndArgumentErrorsAreProtocolErrors() async {
        let (server, output, _) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fail","arguments":{}}}"#)
        await output.waitFor(1)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"strict","arguments":{}}}"#)
        await output.waitFor(2)
        await send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
        await output.waitFor(3)
        await send(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"arguments":{}}}"#)
        await output.waitFor(4)
        await send(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#)
        await output.waitFor(5)
        let messages = await output.messages
        #expect(messages[0].objectValue?["result"] == ["content": [["type": "text", "text": "Something went wrong"]], "isError": true])
        #expect(messages[1].objectValue?["error"] == ["code": -32602, "message": "Unexpected argument \"x\""])
        #expect(messages[2].objectValue?["error"] == ["code": -32602, "message": "Unknown tool: nope"])
        #expect(messages[3].objectValue?["error"]?.objectValue?["code"] == .int(-32602))
        #expect(messages[4].objectValue?["error"]?.objectValue?["code"] == .int(-32602))
    }

    @Test func callsRunConcurrentlyAndCancellationSuppressesTheResponse() async throws {
        let (server, output, tools) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":"slow-1","method":"tools/call","params":{"name":"slow","arguments":{}}}"#)
        try await waitUntil { tools.slowStarted == 1 }
        // Another call completes while the slow one is in flight.
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        await output.waitFor(1)
        #expect(await output.messages.first?.objectValue?["id"] == .int(2))

        await send(server, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow-1","reason":"user"}}"#)
        try await waitUntil { tools.slowCancelled == 1 }
        await server.drain()
        await send(server, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        await output.waitFor(2)
        let ids = await output.messages.compactMap { $0.objectValue?["id"] }
        #expect(ids == [.int(2), .int(3)])
        #expect(await server.inFlightCount == 0)
    }

    @Test func concurrencyIsBounded() async throws {
        let (server, output, tools) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#)
        try await waitUntil { tools.slowStarted == 2 }
        await send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#)
        await output.waitFor(1)
        let busy = await output.messages.first?.objectValue
        #expect(busy?["id"] == .int(3))
        #expect(busy?["error"]?.objectValue?["code"] == .int(-32000))
        tools.releaseSlowCalls()
        await server.drain()
        await output.waitFor(3)
        #expect(await output.messages.count == 3)
    }

    @Test func duplicateInFlightIDsAreRejected() async throws {
        let (server, output, tools) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#)
        try await waitUntil { tools.slowStarted == 1 }
        await send(server, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        await output.waitFor(1)
        #expect(await output.messages.first?.objectValue?["error"]?.objectValue?["code"] == .int(-32600))
        tools.releaseSlowCalls()
        await server.drain()
    }

    @Test func runDrainsInFlightCallsAtEndOfInput() async throws {
        let (server, output, tools) = makeServer()
        let input = AsyncStream<[UInt8]> { continuation in
            continuation.yield(Array("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"slow\",\"arguments\":{}}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}".utf8))
            continuation.finish()
        }
        let running = Task { await server.run(input: input) }
        try await waitUntil { tools.slowStarted == 1 }
        tools.releaseSlowCalls()
        await running.value
        // The unterminated final line was processed too.
        let ids = await output.messages.compactMap { $0.objectValue?["id"] }
        #expect(Set(ids) == [.int(1), .int(2)])
    }

    @Test func outputFailureCancelsInFlightCalls() async throws {
        let (server, output, tools) = makeServer()
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#)
        try await waitUntil { tools.slowStarted == 1 }
        await output.setFailWrites(true)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        try await waitUntil { tools.slowCancelled == 1 }
        #expect(await server.isOutputClosed)
        await server.drain()
    }
}

/// Polls `condition` every 5 ms for up to 5 seconds.
func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within 5 seconds")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

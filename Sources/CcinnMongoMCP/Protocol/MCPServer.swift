/// Model Context Protocol server core: framing, JSON-RPC dispatch, lifecycle, concurrency and cancellation.
///
/// The actor owns only small bookkeeping state. Each `tools/call` runs in its own task (the tool provider
/// executes off the actor) and its response goes through the single `MCPOutput`, which serialises writes.
public actor MCPServer {
    public struct Configuration: Sendable {
        public var name: String
        public var title: String
        public var version: String
        public var instructions: String
        /// Calls beyond this many in flight are refused with `-32000`.
        public var maxConcurrentCalls: Int
        /// Longest accepted message line in bytes.
        public var maxMessageBytes: Int

        public init(name: String, title: String, version: String, instructions: String,
                    maxConcurrentCalls: Int = 16, maxMessageBytes: Int = 4 * 1024 * 1024) {
            self.name = name
            self.title = title
            self.version = version
            self.instructions = instructions
            self.maxConcurrentCalls = max(1, maxConcurrentCalls)
            self.maxMessageBytes = max(1024, maxMessageBytes)
        }
    }

    private struct InFlightCall {
        let task: Task<Void, Never>
        var isCancelled = false
    }

    private let configuration: Configuration
    private let tools: any MCPToolProvider
    private let output: any MCPOutput
    private var framer: LineFramer
    private var protocolVersion = MCPProtocolVersion.latest
    private var inFlight: [JSONRPCID: InFlightCall] = [:]
    public private(set) var isOutputClosed = false

    public init(configuration: Configuration, tools: any MCPToolProvider, output: any MCPOutput) {
        self.configuration = configuration
        self.tools = tools
        self.output = output
        framer = LineFramer(maxLineBytes: configuration.maxMessageBytes)
    }

    public var inFlightCount: Int { inFlight.count }

    /// Processes `input` until it ends (or output breaks), then waits for in-flight calls to finish.
    public func run(input: AsyncStream<[UInt8]>) async {
        for await chunk in input {
            await receive(chunk)
            if isOutputClosed { break }
        }
        for event in framer.finish() { await handle(event) }
        await drain()
    }

    /// Feeds raw bytes from the transport.
    public func receive(_ chunk: [UInt8]) async {
        for event in framer.append(chunk) {
            await handle(event)
        }
    }

    /// Waits until every in-flight call has completed.
    public func drain() async {
        while !inFlight.isEmpty {
            let tasks = inFlight.values.map(\.task)
            for task in tasks { await task.value }
        }
    }

    // MARK: Dispatch

    private func handle(_ event: LineFramer.Event) async {
        switch event {
        case let .oversized(size):
            await send(JSONRPC.errorResponse(id: nil, code: .invalidRequest,
                                             message: "Message of \(size) bytes is larger than the \(configuration.maxMessageBytes / (1024 * 1024)) MB limit"))
        case let .line(bytes):
            let message: JSONValue
            do {
                message = try JSONParser.parse(bytes: bytes)
            } catch let error as JSONParseError {
                await send(JSONRPC.errorResponse(id: nil, code: .parseError, message: "Parse error: \(error.description)"))
                return
            } catch {
                await send(JSONRPC.errorResponse(id: nil, code: .parseError, message: "Parse error"))
                return
            }
            await dispatch(JSONRPC.classify(message))
        }
    }

    private func dispatch(_ incoming: JSONRPCIncoming) async {
        switch incoming {
        case let .request(id, method, params):
            await handleRequest(id: id, method: method, params: params)
        case let .notification(method, params):
            handleNotification(method: method, params: params)
        case .response:
            break
        case let .invalid(id, message):
            await send(JSONRPC.errorResponse(id: id, code: .invalidRequest, message: message))
        }
    }

    private func handleRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        switch method {
        case "initialize":
            guard let object = params?.objectValue, let requested = object["protocolVersion"]?.stringValue else {
                await send(JSONRPC.errorResponse(id: id, code: .invalidParams, message: "initialize requires params.protocolVersion"))
                return
            }
            protocolVersion = MCPProtocolVersion.negotiate(requested)
            let result: JSONValue = [
                "protocolVersion": .string(protocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(configuration.name), "title": .string(configuration.title), "version": .string(configuration.version)],
                "instructions": .string(configuration.instructions),
            ]
            await send(JSONRPC.response(id: id, result: result))
        case "ping":
            await send(JSONRPC.response(id: id, result: [:]))
        case "tools/list":
            let definitions = await tools.listTools(context: MCPCallContext(protocolVersion: protocolVersion))
            await send(JSONRPC.response(id: id, result: ["tools": .array(definitions.map(\.json))]))
        case "tools/call":
            await startCall(id: id, params: params)
        case "resources/list":
            await send(JSONRPC.response(id: id, result: ["resources": []]))
        case "resources/templates/list":
            await send(JSONRPC.response(id: id, result: ["resourceTemplates": []]))
        case "prompts/list":
            await send(JSONRPC.response(id: id, result: ["prompts": []]))
        default:
            await send(JSONRPC.errorResponse(id: id, code: .methodNotFound, message: "Method not found: \(method)"))
        }
    }

    private func handleNotification(method: String, params: JSONValue?) {
        guard method == "notifications/cancelled",
              let requestID = params?.objectValue?["requestId"].flatMap(JSONRPCID.init),
              let call = inFlight[requestID] else { return }
        inFlight[requestID]?.isCancelled = true
        call.task.cancel()
    }

    // MARK: Tool calls

    private func startCall(id: JSONRPCID, params: JSONValue?) async {
        guard let object = params?.objectValue, let name = object["name"]?.stringValue, !name.isEmpty else {
            await send(JSONRPC.errorResponse(id: id, code: .invalidParams, message: "tools/call requires params.name"))
            return
        }
        let arguments: JSONObject
        switch object["arguments"] {
        case nil, .null?: arguments = JSONObject()
        case let .object(value)?: arguments = value
        default:
            await send(JSONRPC.errorResponse(id: id, code: .invalidParams, message: "tools/call params.arguments must be an object"))
            return
        }
        guard inFlight[id] == nil else {
            await send(JSONRPC.errorResponse(id: id, code: .invalidRequest, message: "Request id \(id) is already in use"))
            return
        }
        guard inFlight.count < configuration.maxConcurrentCalls else {
            await send(JSONRPC.errorResponse(id: id, code: .serverBusy,
                                             message: "Too many concurrent tool calls (limit \(configuration.maxConcurrentCalls)); retry when earlier calls finish"))
            return
        }
        let context = MCPCallContext(protocolVersion: protocolVersion)
        let tools = self.tools
        let task = Task {
            let response: JSONValue?
            do {
                let result = try await tools.callTool(name: name, arguments: arguments, context: context)
                response = JSONRPC.response(id: id, result: result.json(protocolVersion: context.protocolVersion))
            } catch let error as MCPToolError {
                response = JSONRPC.errorResponse(id: id, code: .invalidParams, message: error.message)
            } catch {
                response = Task.isCancelled ? nil : JSONRPC.errorResponse(id: id, code: .internalError, message: "Internal error")
            }
            await self.finishCall(id: id, response: response)
        }
        // Registered before the task can reach `finishCall`, which needs this actor.
        inFlight[id] = InFlightCall(task: task)
    }

    private func finishCall(id: JSONRPCID, response: JSONValue?) async {
        guard let call = inFlight.removeValue(forKey: id), !call.isCancelled, let response else { return }
        await send(response)
    }

    // MARK: Output

    private func send(_ message: JSONValue) async {
        guard !isOutputClosed else { return }
        do {
            try await output.send(JSONWriter.encode(message))
        } catch {
            // The client is gone: stop all work.
            isOutputClosed = true
            for (id, call) in inFlight {
                inFlight[id]?.isCancelled = true
                call.task.cancel()
            }
        }
    }
}

import BSON
import Foundation
import MongoKit
import os
import Testing
@testable import CcinnMongoKit

@Suite("AI assistant engine")
struct AssistantTests {
    // MARK: Invocation & discovery

    @Test func claudeInvocationIsIsolated() {
        let invocation = AgentProvider.claudeCode.invocation(executable: URL(fileURLWithPath: "/bin/claude"), systemPrompt: "SYS",
                                                             prompt: "PROMPT", model: "sonnet",
                                                             workingDirectory: URL(fileURLWithPath: "/tmp/x"),
                                                             outputFile: URL(fileURLWithPath: "/tmp/x/out.txt"))
        let args = invocation.arguments
        #expect(args.first == "-p")
        #expect(args.contains("--tools") && args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        #expect(args[args.firstIndex(of: "--output-format")! + 1] == "json")
        #expect(args[args.firstIndex(of: "--system-prompt")! + 1] == "SYS")
        #expect(args[args.firstIndex(of: "--model")! + 1] == "sonnet")
        #expect(args.contains("PROMPT"))
    }

    @Test func codexInvocationIsReadOnlyAndEphemeral() {
        let invocation = AgentProvider.codex.invocation(executable: URL(fileURLWithPath: "/bin/codex"), systemPrompt: "SYS",
                                                        prompt: "PROMPT", model: nil,
                                                        workingDirectory: URL(fileURLWithPath: "/tmp/x"),
                                                        outputFile: URL(fileURLWithPath: "/tmp/x/out.txt"))
        let args = invocation.arguments
        #expect(args.first == "exec")
        #expect(args[args.firstIndex(of: "--sandbox")! + 1] == "read-only")
        #expect(args.contains("--ephemeral"))
        #expect(args.contains("--skip-git-repo-check"))
        #expect(args[args.firstIndex(of: "-o")! + 1] == "/tmp/x/out.txt")
        #expect(args[args.firstIndex(of: "-C")! + 1] == "/tmp/x")
        #expect(!args.contains("-m"))
        #expect(args.last?.contains("SYS") == true && args.last?.contains("PROMPT") == true)
    }

    @Test func parsesClaudeJSONOutput() throws {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"type\":\"answer\",\"text\":\"hi\"}","session_id":"x"}"#
        #expect(try AgentProvider.claudeCode.extractReply(stdout: ok, outputFile: nil) == #"{"type":"answer","text":"hi"}"#)
        let failed = #"{"type":"result","is_error":true,"result":"Invalid API key"}"#
        #expect(throws: AgentError.self) { try AgentProvider.claudeCode.extractReply(stdout: failed, outputFile: nil) }
        #expect(try AgentProvider.codex.extractReply(stdout: "noise", outputFile: "final answer\n") == "final answer")
    }

    @Test func locatesExecutablesOnASearchPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        #expect(AgentLocator.locate(.codex, override: nil, searchPath: "/nonexistent:\(directory.path)") == fake)
        #expect(AgentLocator.locate(.claudeCode, override: nil, searchPath: directory.path, extraDirectories: []) == nil)
        #expect(AgentLocator.locate(.claudeCode, override: fake.path, searchPath: "") == fake)
    }

    // MARK: Process runner

    @Test func processRunnerCapturesOutput() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"],
                                                 environment: [:], currentDirectory: nil, timeout: .seconds(10))
        #expect(result.status == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    @Test func processRunnerTimesOut() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: AgentError.self) {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:],
                                            currentDirectory: nil, timeout: .milliseconds(300))
        }
        #expect(clock.now - start < .seconds(3))
    }

    @Test func processRunnerHonoursCancellation() async {
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:],
                                        currentDirectory: nil, timeout: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let result = await task.result
        #expect(clock.now - start < .seconds(2))
        if case .success = result { Issue.record("expected cancellation") }
    }

    // MARK: Reply parsing

    @Test func parsesQueryWithShellSyntaxFields() throws {
        let text = #"{"type": "query", "reason": "count VIPs", "query": {"kind": "count", "filter": "{city: 'Penang', vip: true, joined: {$gte: ISODate('2021-06-01')}}"}}"#
        guard case let .query(query, reason) = try AssistantReplyParser.parse(text) else {
            Issue.record("expected query")
            return
        }
        #expect(reason == "count VIPs")
        #expect(query.kind == .count)
        #expect(query.filter["city"] == "Penang")
        #expect(query.filter["vip"] == true)
        #expect(query.filter["joined"]?.documentValue?["$gte"]?.datetimeValue != nil)
    }

    @Test func parsesFencedAndEmbeddedJSON() throws {
        let fenced = "Here you go:\n```json\n{\"type\":\"answer\",\"text\":\"There are **3**.\"}\n```\nThanks"
        #expect(try AssistantReplyParser.parse(fenced) == .answer(text: "There are **3**.", suggestion: nil))
        let embedded = "Sure! {\"type\": \"answer\", \"text\": \"a {brace} inside\"} done"
        #expect(try AssistantReplyParser.parse(embedded) == .answer(text: "a {brace} inside", suggestion: nil))
    }

    @Test func parsesPipelineAndObjectFilters() throws {
        let text = #"{"type":"query","query":{"kind":"aggregate","pipeline":"[{$match: {status: 'paid'}}, {$group: {_id: '$city', n: {$sum: 1}}}]"}}"#
        guard case let .query(query, _) = try AssistantReplyParser.parse(text) else {
            Issue.record("expected query")
            return
        }
        #expect(query.pipeline.count == 2)
        let objectFilter = #"{"type":"answer","text":"Use this","query":{"kind":"find","filter":{"total":{"$gt":100}},"sort":{"total":-1},"limit":5}}"#
        guard case let .answer(_, suggestion?) = try AssistantReplyParser.parse(objectFilter) else {
            Issue.record("expected answer with suggestion")
            return
        }
        #expect(suggestion.filter == ["total": ["$gt": 100]])
        #expect(suggestion.sort == ["total": -1])
        #expect(suggestion.limit == 5)
    }

    @Test(arguments: ["", "no json here", #"{"type":"dance"}"#, #"{"type":"query"}"#, #"{"type":"query","query":{"kind":"find","filter":"{a: "}}"#])
    func rejectsInvalidReplies(_ text: String) {
        #expect(throws: AssistantProtocolError.self) { try AssistantReplyParser.parse(text) }
    }

    // MARK: Safety

    @Test func safetyRejectsWritesAndJavaScript() {
        let out = AssistantQuery(kind: .aggregate, pipeline: [["$match": [:]], ["$out": "x"]])
        #expect(throws: AssistantProtocolError.self) { try QuerySafetyPolicy.validate(out) }
        let merge = AssistantQuery(kind: .aggregate, pipeline: [["$facet": ["a": [["$merge": "x"]]]]])
        #expect(throws: AssistantProtocolError.self) { try QuerySafetyPolicy.validate(merge) }
        let whereFilter = AssistantQuery(kind: .find, filter: ["$or": [["$where": "this.a > 1"]]])
        #expect(throws: AssistantProtocolError.self) { try QuerySafetyPolicy.validate(whereFilter) }
        let function = AssistantQuery(kind: .aggregate, pipeline: [["$addFields": ["x": ["$function": ["body": "f", "args": [], "lang": "js"]]]]])
        #expect(throws: AssistantProtocolError.self) { try QuerySafetyPolicy.validate(function) }
    }

    @Test func safetyClampsResults() throws {
        let find = try QuerySafetyPolicy.validate(AssistantQuery(kind: .find, limit: 10_000))
        #expect(find.limit == QuerySafetyPolicy.maxDocuments)
        let unlimited = try QuerySafetyPolicy.validate(AssistantQuery(kind: .find))
        #expect(unlimited.limit == QuerySafetyPolicy.maxDocuments)
        let pipeline = try QuerySafetyPolicy.validate(AssistantQuery(kind: .aggregate, pipeline: [["$match": ["a": 1]]]))
        #expect(pipeline.pipeline.last == ["$limit": .int32(Int32(QuerySafetyPolicy.maxDocuments))])
    }

    // MARK: Prompts

    static func context(samples: [BSONDocument] = [], wire: Int = 5, version: String = "3.4.24") -> AssistantContext {
        let schema = SchemaAnalyzer.analyze([["_id": 1, "city": "Penang", "vip": true], ["_id": 2, "city": "Ipoh", "vip": false, "age": 30]])
        return AssistantContext(namespace: MongoNamespace(database: "shop", collection: "customers"), serverVersion: version,
                                capabilities: ServerCapabilities(maxWireVersion: wire), documentCount: 120, schema: schema,
                                samples: samples, indexes: ["_id_", "email_1"], currentQuery: nil)
    }

    @Test func promptCarriesVersionHintsAndSchema() {
        let prompt = AssistantPromptBuilder.prompt(mode: .conversation(allowQueries: true), context: Self.context(), history: [], request: "how many VIPs?")
        #expect(prompt.contains("MongoDB 3.4.24"))
        #expect(prompt.contains("$expr"))
        #expect(prompt.contains("city"))
        #expect(prompt.contains("shop.customers"))
        #expect(prompt.contains("how many VIPs?"))
        let modern = AssistantPromptBuilder.prompt(mode: .generateFind, context: Self.context(wire: 25, version: "8.0.1"), history: [], request: "x")
        #expect(!modern.contains("not available on this server"))
    }

    @Test func samplesAreOptIn() {
        let secretValue = "Sup3rSecretCustomerName"
        let without = AssistantPromptBuilder.prompt(mode: .generateFind, context: Self.context(), history: [], request: "q")
        #expect(!without.contains(secretValue))
        let with = AssistantPromptBuilder.prompt(mode: .generateFind, context: Self.context(samples: [["name": .string(secretValue)]]), history: [], request: "q")
        #expect(with.contains(secretValue))
    }

    @Test func resultSummariesAreBounded() {
        let big = (0..<500).map { ["i": .int32(Int32($0)), "blob": .string(String(repeating: "x", count: 5_000))] as BSONDocument }
        let summary = AssistantResultFormatter.summary(AssistantQueryResult(documents: big, count: nil))
        #expect(summary.utf8.count <= AssistantResultFormatter.maxBytes + 200)
        #expect(summary.contains("truncated"))
    }

    // MARK: Agent loop

    final class ScriptedAgent: AgentRunning, @unchecked Sendable {
        private let replies: OSAllocatedUnfairLock<[String]>
        private let prompts = OSAllocatedUnfairLock<[String]>(initialState: [])
        init(_ replies: [String]) { self.replies = OSAllocatedUnfairLock(initialState: replies) }
        var receivedPrompts: [String] { prompts.withLock { $0 } }
        func complete(system: String, prompt: String) async throws -> String {
            prompts.withLock { $0.append(prompt) }
            return try replies.withLock { replies in
                guard !replies.isEmpty else { throw AgentError.failed("no more scripted replies") }
                return replies.removeFirst()
            }
        }
    }

    final class RecordingExecutor: AssistantQueryExecuting, @unchecked Sendable {
        private let executed = OSAllocatedUnfairLock<[AssistantQuery]>(initialState: [])
        var queries: [AssistantQuery] { executed.withLock { $0 } }
        func execute(_ query: AssistantQuery) async throws -> AssistantQueryResult {
            executed.withLock { $0.append(query) }
            return query.kind == .count ? AssistantQueryResult(documents: [], count: 3) : AssistantQueryResult(documents: [["n": 1]], count: nil)
        }
    }

    @Test func conversationRunsQueriesThenAnswers() async throws {
        let agent = ScriptedAgent([
            #"{"type":"query","reason":"count","query":{"kind":"count","filter":"{city: 'Penang', vip: true}"}}"#,
            #"{"type":"answer","text":"There are 3 VIP customers in Penang.","query":{"kind":"count","filter":"{city: 'Penang', vip: true}"}}"#,
        ])
        let executor = RecordingExecutor()
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let outcome = try await AssistantEngine(agent: agent, executor: executor).run(
            mode: .conversation(allowQueries: true), context: Self.context(), history: [], request: "How many VIPs in Penang?"
        ) { event in events.withLock { $0.append(event.label) } }
        #expect(outcome.answer == "There are 3 VIP customers in Penang.")
        #expect(executor.queries.count == 1)
        #expect(executor.queries.first?.filter == ["city": "Penang", "vip": true])
        #expect(events.withLock { $0 }.contains("ran"))
        #expect(agent.receivedPrompts.last?.contains("\"count\": 3") == true || agent.receivedPrompts.last?.contains("count: 3") == true)
    }

    @Test func rejectedQueryIsReportedToTheAgentAndNotExecuted() async throws {
        let agent = ScriptedAgent([
            #"{"type":"query","query":{"kind":"aggregate","pipeline":"[{$out: 'x'}]"}}"#,
            #"{"type":"answer","text":"I cannot write data."}"#,
        ])
        let executor = RecordingExecutor()
        let outcome = try await AssistantEngine(agent: agent, executor: executor).run(
            mode: .conversation(allowQueries: true), context: Self.context(), history: [], request: "copy the collection") { _ in }
        #expect(executor.queries.isEmpty)
        #expect(outcome.answer == "I cannot write data.")
        #expect(agent.receivedPrompts.last?.contains("rejected") == true)
    }

    @Test func invalidOutputIsRetriedOnce() async throws {
        let agent = ScriptedAgent(["Sorry, here is prose.", #"{"type":"answer","text":"ok"}"#])
        let outcome = try await AssistantEngine(agent: agent, executor: RecordingExecutor()).run(
            mode: .conversation(allowQueries: true), context: Self.context(), history: [], request: "hi") { _ in }
        #expect(outcome.answer == "ok")
        let failing = ScriptedAgent(["nope", "still nope"])
        await #expect(throws: AssistantProtocolError.self) {
            _ = try await AssistantEngine(agent: failing, executor: RecordingExecutor()).run(
                mode: .conversation(allowQueries: true), context: Self.context(), history: [], request: "hi") { _ in }
        }
    }

    @Test func queriesAreNotExecutedWhenDisabled() async throws {
        let agent = ScriptedAgent([#"{"type":"query","query":{"kind":"find","filter":"{a: 1}"}}"#])
        let executor = RecordingExecutor()
        let outcome = try await AssistantEngine(agent: agent, executor: executor).run(
            mode: .conversation(allowQueries: false), context: Self.context(), history: [], request: "find a") { _ in }
        #expect(executor.queries.isEmpty)
        #expect(outcome.suggestion?.filter == ["a": 1])
    }

    @Test func generateFindReturnsSuggestion() async throws {
        let agent = ScriptedAgent([#"{"type":"query","query":{"kind":"find","filter":"{status: 'paid', total: {$gt: 100}}","sort":"{total: -1}"}}"#])
        let executor = RecordingExecutor()
        let outcome = try await AssistantEngine(agent: agent, executor: executor).run(
            mode: .generateFind, context: Self.context(), history: [], request: "paid orders over 100") { _ in }
        #expect(executor.queries.isEmpty)
        #expect(outcome.suggestion?.sort == ["total": -1])
    }

    @Test func stepLimitStopsRunawayLoops() async throws {
        let loop = #"{"type":"query","query":{"kind":"count","filter":"{}"}}"#
        let agent = ScriptedAgent(Array(repeating: loop, count: 20))
        let executor = RecordingExecutor()
        let outcome = try await AssistantEngine(agent: agent, executor: executor, maxSteps: 3).run(
            mode: .conversation(allowQueries: true), context: Self.context(), history: [], request: "loop") { _ in }
        #expect(executor.queries.count == 3)
        #expect(outcome.answer?.contains("step limit") == true)
    }
}

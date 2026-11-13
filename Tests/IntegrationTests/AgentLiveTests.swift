import BSON
import CcinnMongoKit
import Foundation
import MongoKit
import os
import Testing

/// End-to-end checks with the real Claude Code / Codex CLIs against a seeded MongoDB (scripts/seed-demo.js).
/// Opt-in because they call paid models:
///   CCINNMONGO_AI_IT=claude,codex CCINNMONGO_AI_URI="mongodb://…:27134/?authSource=admin" swift test --filter AgentLiveTests
@Suite("Live agent CLIs", .enabled(if: ProcessInfo.processInfo.environment["CCINNMONGO_AI_IT"] != nil && ProcessInfo.processInfo.environment["CCINNMONGO_AI_URI"] != nil))
struct AgentLiveTests {
    static var providers: [AgentProvider] {
        (ProcessInfo.processInfo.environment["CCINNMONGO_AI_IT"] ?? "").split(separator: ",").compactMap { name in
            AgentProvider.allCases.first { $0.executableName == name.trimmingCharacters(in: .whitespaces) }
        }
    }

    @Test(arguments: AgentLiveTests.providers)
    func answersADataQuestionWithReadOnlyQueries(provider: AgentProvider) async throws {
        let path = AgentLocator.loginShellPath()
        let executable = try #require(AgentLocator.locate(provider, override: nil, searchPath: path), "\(provider.displayName) not installed")
        let client = try MongoClient(try #require(ProcessInfo.processInfo.environment["CCINNMONGO_AI_URI"]))
        let info = try await client.connect()
        let namespace = MongoNamespace(database: "shop", collection: "customers")
        let context = await AssistantContext.load(client: client, namespace: namespace, serverInfo: info, includeSamples: false, currentQuery: nil)
        let engine = AssistantEngine(agent: CLIAgent(provider: provider, executable: executable, model: nil, searchPath: path),
                                     executor: MongoAssistantExecutor(client: client, namespace: namespace))
        let ran = OSAllocatedUnfairLock<[AssistantQuery]>(initialState: [])
        let outcome = try await engine.run(mode: .conversation(allowQueries: true), context: context, history: [],
                                           request: "How many VIP customers live in Kuala Lumpur? Reply with the number.") { event in
            if case let .ran(query, _) = event { ran.withLock { $0.append(query) } }
        }
        print("[\(provider.displayName)] queries: \(ran.withLock { $0 }.map { $0.shellText(collection: "customers") })")
        print("[\(provider.displayName)] answer: \(outcome.answer ?? "-")")
        #expect(!ran.withLock { $0 }.isEmpty)
        #expect(outcome.answer?.contains("7") == true)
        await client.close()
    }

    @Test(arguments: AgentLiveTests.providers)
    func generatesAVersionCompatibleFind(provider: AgentProvider) async throws {
        let path = AgentLocator.loginShellPath()
        let executable = try #require(AgentLocator.locate(provider, override: nil, searchPath: path))
        let client = try MongoClient(try #require(ProcessInfo.processInfo.environment["CCINNMONGO_AI_URI"]))
        let info = try await client.connect()
        let namespace = MongoNamespace(database: "shop", collection: "orders")
        let context = await AssistantContext.load(client: client, namespace: namespace, serverInfo: info, includeSamples: false, currentQuery: nil)
        let engine = AssistantEngine(agent: CLIAgent(provider: provider, executable: executable, model: nil, searchPath: path), executor: nil)
        let outcome = try await engine.run(mode: .generateFind, context: context, history: [],
                                           request: "paid orders with total over 100, highest total first") { _ in }
        let query = try #require(outcome.suggestion)
        print("[\(provider.displayName)] generated: \(query.shellText(collection: "orders"))")
        #expect(query.kind == .find)
        #expect(BSONFormatter(style: .shell).format(query.filter).contains("paid"))
        #expect(query.sort?["total"]?.int64Value == -1)
        let documents = try await client.find(namespace, options: FindOptions(filter: query.filter, sort: query.sort, limit: 5))
        #expect(!documents.isEmpty)
        #expect(documents.allSatisfy { $0["status"] == "paid" && ($0["total"]?.doubleValue ?? 0) > 100 })
        await client.close()
    }
}

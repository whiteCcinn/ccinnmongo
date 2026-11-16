import BSON
import Foundation
import MongoKit
import os
import Testing
@testable import CcinnMongoKit

/// Regression tests for issues found in the adversarial review.
@Suite("Review regressions (CcinnMongoKit)")
struct KitReviewRegressionTests {
    @Test func tlsCertificatePasswordGoesToTheKeychain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmongo-tests-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let repository = ProfileRepository(directory: directory, secrets: secrets)
        var profile = ConnectionProfile(name: "TLS", uri: "")
        try repository.update(&profile, uri: "mongodb://u:pw@h/?tls=true&tlsCertificateKeyFile=%2Fk.p12&tlsCertificateKeyFilePassword=p12-secret", sshSecret: nil)
        try repository.save([profile])
        let file = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!file.contains("p12-secret"))
        #expect(!profile.uri.contains("p12-secret"))
        let restored = try repository.connectionString(for: profile)
        #expect(restored.tlsCertificateKeyFilePassword == "p12-secret")
        #expect(restored.password == "pw")
    }

    @Test func csvNeutralisesFormulas() {
        let document: BSONDocument = ["a": "=HYPERLINK(\"http://x\")", "b": "+1", "c": "@cmd", "d": .int32(-5), "e": "-2"]
        let row = CSVExporter.row(document, paths: ["a", "b", "c", "d", "e"])
        #expect(row == "\"'=HYPERLINK(\"\"http://x\"\")\",'+1,'@cmd,-5,'-2\n")
    }

    @Test func safetyCheckRejectsJavaScriptInSuggestions() {
        #expect(throws: AssistantProtocolError.self) {
            try QuerySafetyPolicy.check(AssistantQuery(kind: .find, filter: ["$where": "sleep(100000)"]))
        }
        #expect(throws: Never.self) { try QuerySafetyPolicy.check(AssistantQuery(kind: .find, filter: ["a": 1])) }
    }

    @Test func codexIgnoresUserConfiguration() {
        let invocation = AgentProvider.codex.invocation(executable: URL(fileURLWithPath: "/bin/codex"), systemPrompt: "S", prompt: "P",
                                                        model: nil, workingDirectory: URL(fileURLWithPath: "/tmp/w"),
                                                        outputFile: URL(fileURLWithPath: "/tmp/w/o"))
        #expect(invocation.arguments.contains("--ignore-user-config"))
        #expect(!AgentProvider.codex.isToolFree)
        #expect(AgentProvider.claudeCode.isToolFree)
    }

    @Test func agentEnvironmentDropsAppSecretsAndNestingMarkers() {
        let environment = CLIAgent.agentEnvironment(from: ["PATH": "/bin", "HOME": "/Users/x", "CCINNMONGO_ASKPASS_SECRET": "s",
                                                           "CLAUDECODE": "1", "ANTHROPIC_API_KEY": "k"], searchPath: "/usr/bin")
        #expect(environment["CCINNMONGO_ASKPASS_SECRET"] == nil)
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == "k")
        #expect(environment["PATH"] == "/usr/bin")
    }

    @Test func declinedQueriesAreNotExecuted() async throws {
        let agent = AssistantTests.ScriptedAgent([
            #"{"type":"query","query":{"kind":"count","filter":"{a: 1}"}}"#,
            #"{"type":"answer","text":"ok"}"#,
        ])
        let executor = AssistantTests.RecordingExecutor()
        let outcome = try await AssistantEngine(agent: agent, executor: executor).run(
            mode: .conversation(allowQueries: true), context: AssistantTests.context(), history: [], request: "q",
            approve: { _ in false }) { _ in }
        #expect(executor.queries.isEmpty)
        #expect(outcome.answer == "ok")
        #expect(agent.receivedPrompts.last?.contains("declined") == true)
    }

    @Test func cancellingBeforeLaunchStopsTheProcess() async {
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], environment: [:],
                                        currentDirectory: nil, timeout: .seconds(90))
        }
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        _ = await task.result
        // Well under the 60 s the process would run. Generous bound: CI scheduling adds seconds of delay.
        #expect(clock.now - start < .seconds(15))
    }
}

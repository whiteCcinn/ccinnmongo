import BSON
import Foundation
import MongoKit

public enum AssistantMode: Sendable, Equatable {
    /// Natural language → find query (applied to the query bar).
    case generateFind
    /// Natural language → aggregation pipeline (applied to the workbench).
    case generatePipeline
    /// Multi-turn Q&A; with `allowQueries` the agent may ask CcinnMongo to run read-only queries.
    case conversation(allowQueries: Bool)
}

/// What the agent knows about the collection. Deliberately contains no connection details.
public struct AssistantContext: Sendable {
    public var namespace: MongoNamespace
    public var serverVersion: String
    public var capabilities: ServerCapabilities
    public var documentCount: Int64?
    public var schema: SchemaResult?
    public var samples: [BSONDocument]
    public var indexes: [String]
    public var currentQuery: QueryInput?

    public init(namespace: MongoNamespace, serverVersion: String, capabilities: ServerCapabilities, documentCount: Int64?,
                schema: SchemaResult?, samples: [BSONDocument], indexes: [String], currentQuery: QueryInput?) {
        self.namespace = namespace
        self.serverVersion = serverVersion
        self.capabilities = capabilities
        self.documentCount = documentCount
        self.schema = schema
        self.samples = samples
        self.indexes = indexes
        self.currentQuery = currentQuery
    }
}

public enum AssistantTurn: Sendable, Equatable {
    case user(String)
    case agentQuery(AssistantQuery, reason: String?)
    case queryResult(String)
    case queryRejected(String)
    case agentAnswer(String)
    case protocolCorrection(String)
}

public enum AssistantEvent: Sendable {
    case thinking(step: Int)
    case running(AssistantQuery)
    case ran(AssistantQuery, AssistantQueryResult)
    case rejected(AssistantQuery, String)
    case failed(AssistantQuery, String)

    public var label: String {
        switch self {
        case .thinking: "thinking"
        case .running: "running"
        case .ran: "ran"
        case .rejected: "rejected"
        case .failed: "failed"
        }
    }
}

public struct AssistantOutcome: Sendable {
    public let answer: String?
    public let suggestion: AssistantQuery?
    /// Full transcript including this exchange, to pass as `history` next time.
    public let transcript: [AssistantTurn]
}

public protocol AssistantQueryExecuting: Sendable {
    func execute(_ query: AssistantQuery) async throws -> AssistantQueryResult
}

/// Provider-neutral agent loop: prompt → reply → (run read-only query → feed result back)* → answer.
public struct AssistantEngine: Sendable {
    public let agent: any AgentRunning
    public let executor: (any AssistantQueryExecuting)?
    public let maxSteps: Int

    public init(agent: any AgentRunning, executor: (any AssistantQueryExecuting)?, maxSteps: Int = 6) {
        self.agent = agent
        self.executor = executor
        self.maxSteps = maxSteps
    }

    public func run(mode: AssistantMode, context: AssistantContext, history: [AssistantTurn], request: String,
                    onEvent: @Sendable (AssistantEvent) -> Void) async throws -> AssistantOutcome {
        var transcript = history + [.user(request)]
        let system = AssistantPromptBuilder.systemPrompt(for: mode)
        var steps = 0
        var corrected = false

        while true {
            try Task.checkCancellation()
            onEvent(.thinking(step: steps + 1))
            let prompt = AssistantPromptBuilder.prompt(mode: mode, context: context, transcript: transcript)
            let raw = try await agent.complete(system: system, prompt: prompt)
            try Task.checkCancellation()

            let reply: AssistantReply
            do {
                reply = try AssistantReplyParser.parse(raw)
                corrected = false
            } catch let error as AssistantProtocolError {
                guard !corrected else { throw error }
                corrected = true
                transcript.append(.protocolCorrection("Your previous reply was invalid (\(error.message)). Reply again with exactly one JSON object in the required format and nothing else."))
                continue
            }

            switch reply {
            case let .answer(text, suggestion):
                transcript.append(.agentAnswer(text))
                return AssistantOutcome(answer: text, suggestion: suggestion, transcript: transcript)

            case let .query(query, reason):
                guard case .conversation(allowQueries: true) = mode, let executor else {
                    // Generate modes (or queries disabled): the query is a proposal for the user.
                    transcript.append(.agentAnswer(reason ?? "Proposed query"))
                    return AssistantOutcome(answer: reason, suggestion: query, transcript: transcript)
                }
                guard steps < maxSteps else {
                    let message = "Stopped after reaching the step limit of \(maxSteps) queries."
                    transcript.append(.agentAnswer(message))
                    return AssistantOutcome(answer: message, suggestion: query, transcript: transcript)
                }
                steps += 1
                transcript.append(.agentQuery(query, reason: reason))
                let bounded: AssistantQuery
                do {
                    bounded = try QuerySafetyPolicy.validate(query)
                } catch let error as AssistantProtocolError {
                    onEvent(.rejected(query, error.message))
                    transcript.append(.queryRejected("CcinnMongo rejected that query: \(error.message) Only read-only find, count and aggregate operations are allowed."))
                    continue
                }
                onEvent(.running(bounded))
                do {
                    let result = try await executor.execute(bounded)
                    onEvent(.ran(bounded, result))
                    transcript.append(.queryResult(AssistantResultFormatter.summary(result)))
                } catch is CancellationError {
                    throw AgentError.cancelled
                } catch {
                    let message = (error as? MongoError)?.message ?? error.localizedDescription
                    onEvent(.failed(bounded, message))
                    transcript.append(.queryResult("The query failed on the server: \(message)"))
                }
            }
        }
    }
}

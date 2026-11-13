import BSON
import CcinnMongoKit
import Foundation
import MongoKit
import Observation

/// Conversation state for the Assistant tab of one collection.
@MainActor
@Observable
final class AssistantModel {
    struct Message: Identifiable {
        enum Kind {
            case user(String)
            case query(AssistantQuery, status: QueryStatus)
            case answer(String, suggestion: AssistantQuery?)
            case error(String)
        }

        enum QueryStatus {
            case running
            case finished(AssistantQueryResult)
            case rejected(String)
            case failed(String)
        }

        let id = UUID()
        var kind: Kind
    }

    let namespace: MongoNamespace
    unowned let tab: CollectionTabModel
    var messages: [Message] = []
    var input = ""
    var isRunning = false
    var status = ""
    var allowQueries = UserDefaults.standard.object(forKey: AISettings.allowQueries) as? Bool ?? true
    var includeSamples = UserDefaults.standard.bool(forKey: AISettings.includeSamples)
    var provider: AgentProvider?

    @ObservationIgnored private var transcript: [AssistantTurn] = []
    @ObservationIgnored private var context: AssistantContext?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(namespace: MongoNamespace, tab: CollectionTabModel) {
        self.namespace = namespace
        self.tab = tab
        provider = AgentService.shared.activeProvider
    }

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        input = ""
        messages.append(Message(kind: .user(question)))
        isRunning = true
        status = "Reading the collection…"
        let agentProvider = provider ?? AgentService.shared.activeProvider
        let agent: CLIAgent
        do {
            agent = try AgentService.shared.agent(for: agentProvider)
        } catch {
            messages.append(Message(kind: .error(describe(error))))
            isRunning = false
            return
        }
        let workspace = tab.workspace
        let client = workspace.client
        let namespace = self.namespace
        let allowQueries = self.allowQueries
        let includeSamples = self.includeSamples
        let history = transcript
        let cachedContext = context
        let currentQuery = tab.documents.query
        task = Task {
            var context = cachedContext
            if context == nil || context?.samples.isEmpty == includeSamples {
                context = await AssistantContext.load(client: client, namespace: namespace, serverInfo: workspace.serverInfo,
                                                      includeSamples: includeSamples, currentQuery: currentQuery)
            }
            guard let context, !Task.isCancelled else { return }
            self.context = context
            self.status = "\(agent.provider.displayName) is thinking…"
            let engine = AssistantEngine(agent: agent, executor: MongoAssistantExecutor(client: client, namespace: namespace))
            do {
                let outcome = try await engine.run(mode: .conversation(allowQueries: allowQueries), context: context,
                                                   history: history, request: question) { event in
                    Task { @MainActor in self.handle(event) }
                }
                guard !Task.isCancelled else { return }
                // Let queued event updates land before the answer.
                await Task.yield()
                self.transcript = outcome.transcript
                self.messages.append(Message(kind: .answer(outcome.answer ?? "Here is a query you can use.", suggestion: outcome.suggestion)))
            } catch {
                guard !Task.isCancelled else { return }
                self.messages.append(Message(kind: .error(describe(error))))
            }
            self.isRunning = false
            self.status = ""
        }
    }

    private func handle(_ event: AssistantEvent) {
        switch event {
        case let .thinking(step):
            status = step == 1 ? "\(provider?.displayName ?? "Assistant") is thinking…" : "Analysing results (step \(step))…"
        case let .running(query):
            status = "Running \(query.kind.rawValue)…"
            messages.append(Message(kind: .query(query, status: .running)))
        case let .ran(query, result):
            update(query, .finished(result))
        case let .rejected(query, reason):
            messages.append(Message(kind: .query(query, status: .rejected(reason))))
        case let .failed(query, reason):
            update(query, .failed(reason))
        }
    }

    private func update(_ query: AssistantQuery, _ status: Message.QueryStatus) {
        if let index = messages.lastIndex(where: {
            if case let .query(existing, .running) = $0.kind { return existing == query }
            return false
        }) {
            messages[index].kind = .query(query, status: status)
        } else {
            messages.append(Message(kind: .query(query, status: status)))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        status = ""
        messages.append(Message(kind: .error("Cancelled.")))
    }

    func clear() {
        cancel()
        messages = []
        transcript = []
        context = nil
    }

    /// Opens a query in the Documents or Aggregations tab.
    func open(_ query: AssistantQuery) {
        tab.apply(query)
    }
}

extension CollectionTabModel {
    /// Applies an assistant query to the matching editor and runs it.
    func apply(_ query: AssistantQuery) {
        let formatter = BSONFormatter(style: .shell)
        switch query.kind {
        case .find, .count:
            var input = QueryInput()
            input.filter = query.filter.isEmpty ? "" : formatter.format(query.filter)
            input.projection = query.projection.map(formatter.format) ?? ""
            input.sort = query.sort.map(formatter.format) ?? ""
            input.limit = query.kind == .find ? (query.limit ?? 0) : 0
            documents.query = input
            section = .documents
            documents.run()
        case .aggregate:
            let stages = query.pipeline.filter { !($0.keys.first == "$limit" && $0 == query.pipeline.last && query.pipeline.count > 1 && $0["$limit"] == .int(QuerySafetyPolicy.maxDocuments)) }
            let shellFormatter = BSONFormatter(style: .shell, indent: 2)
            aggregation.pipeline.stages = stages.compactMap { stage in
                guard let element = stage.elements.first else { return nil }
                return PipelineStage(operatorName: element.key, body: shellFormatter.format(element.value))
            }
            aggregation.isTextMode = false
            aggregation.showResults = false
            section = .aggregations
            aggregation.schedulePreviews(from: nil)
        }
    }
}

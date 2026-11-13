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
            case awaitingApproval
            case running
            case finished(AssistantQueryResult)
            case rejected(String)
            case declined
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
    /// Message waiting for the user to approve or skip an agent-requested query.
    private(set) var pendingApprovalID: UUID?

    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
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
        task = Task { await converse(question: question, agent: agent) }
    }

    private func loadContext() async -> AssistantContext {
        if let context, context.samples.isEmpty != includeSamples { return context }
        let workspace = tab.workspace
        let loaded = await AssistantContext.load(client: workspace.client, namespace: namespace, serverInfo: workspace.serverInfo,
                                                 includeSamples: includeSamples, currentQuery: tab.documents.query)
        context = loaded
        return loaded
    }

    /// Agents that can use tools (Codex) never run queries without the user's approval.
    private func approvalHandler(for agent: CLIAgent) -> (@Sendable (AssistantQuery) async -> Bool)? {
        guard !agent.provider.isToolFree || UserDefaults.standard.bool(forKey: AISettings.approveQueries) else { return nil }
        return { query in await self.requestApproval(for: query) }
    }

    private func converse(question: String, agent: CLIAgent) async {
        defer {
            isRunning = false
            status = ""
        }
        let context = await loadContext()
        guard !Task.isCancelled else { return }
        status = "\(agent.provider.displayName) is thinking…"
        let client = tab.workspace.client
        let engine = AssistantEngine(agent: agent, executor: MongoAssistantExecutor(client: client, namespace: namespace))
        let mode = AssistantMode.conversation(allowQueries: allowQueries)
        do {
            let outcome = try await engine.run(mode: mode, context: context, history: transcript, request: question,
                                               approve: approvalHandler(for: agent)) { event in
                Task { @MainActor in self.handle(event) }
            }
            guard !Task.isCancelled else { return }
            // Let queued event updates land before the answer.
            await Task.yield()
            transcript = outcome.transcript
            messages.append(Message(kind: .answer(outcome.answer ?? "Here is a query you can use.", suggestion: outcome.suggestion)))
        } catch {
            guard !Task.isCancelled else { return }
            messages.append(Message(kind: .error(describe(error))))
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
        case .declined:
            break // the approval card already shows the decision
        case let .failed(query, reason):
            update(query, .failed(reason))
        }
    }

    /// Shows the query and waits until the user runs or skips it.
    private func requestApproval(for query: AssistantQuery) async -> Bool {
        let message = Message(kind: .query(query, status: .awaitingApproval))
        messages.append(message)
        pendingApprovalID = message.id
        status = "Waiting for your approval…"
        let approved = await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            if approved {
                // The .running/.finished events add the live card.
                messages.remove(at: index)
            } else {
                messages[index].kind = .query(query, status: .declined)
            }
        }
        pendingApprovalID = nil
        return approved
    }

    func decide(_ approved: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        continuation.resume(returning: approved)
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
        decide(false)
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
        if let problem = tab.apply(query) { messages.append(Message(kind: .error(problem))) }
    }
}

extension CollectionTabModel {
    /// Applies an assistant query to the matching editor and runs it. Returns an error message when the
    /// query is refused by the safety policy (e.g. server-side JavaScript from a prompt injection).
    @discardableResult
    func apply(_ query: AssistantQuery) -> String? {
        do {
            try QuerySafetyPolicy.check(query)
        } catch {
            return "Not applied: \(describe(error))"
        }
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
        return nil
    }
}

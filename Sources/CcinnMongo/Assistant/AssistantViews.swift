import BSON
import CcinnMongoKit
import MongoKit
import SwiftUI

/// Chat-style assistant for one collection.
struct AssistantView: View {
    @Bindable var model: AssistantModel
    private let service = AgentService.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if service.hasScanned, service.availableProviders.isEmpty {
                AgentUnavailableView()
            } else {
                conversation
                Divider()
                composer
            }
        }
        .onAppear {
            service.scanIfNeeded()
            if model.provider == nil { model.provider = service.activeProvider }
        }
        .onChange(of: service.hasScanned) { _, _ in
            if model.provider == nil { model.provider = service.activeProvider }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text("Ask about \(model.namespace.collection)").font(.headline)
            Spacer()
            Toggle("Run read-only queries", isOn: $model.allowQueries)
                .toggleStyle(.switch).controlSize(.small)
                .help("Let the assistant ask CcinnMongo to run find/count/aggregate (read-only, max 50 documents, 15 s)")
            Toggle("Share sample documents", isOn: $model.includeSamples)
                .toggleStyle(.switch).controlSize(.small)
                .help("Send three sample documents for better context")
            Picker("", selection: $model.provider) {
                ForEach(service.availableProviders) { provider in
                    Text(provider.displayName).tag(Optional(provider))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(service.availableProviders.count < 2)
            Button {
                model.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear conversation")
            .disabled(model.messages.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageView(message: message, collection: model.namespace.collection, open: model.open)
                            .id(message.id)
                    }
                    if model.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.status).foregroundStyle(.secondary)
                            Button("Stop") { model.cancel() }.buttonStyle(.borderless)
                        }
                        .id("status")
                    }
                }
                .padding(16)
            }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask questions in plain language — in any language.").font(.title3.weight(.semibold))
            Text("The assistant reads the collection's field structure, asks CcinnMongo to run read-only queries when it needs data, and answers with the queries it used.")
                .foregroundStyle(.secondary)
            FlowSuggestions(suggestions: [
                "How many documents are there per status?",
                "Show the 5 most recent documents",
                "Which fields are missing in some documents?",
                "What is the average total per month?",
            ]) { suggestion in
                model.input = suggestion
                model.send()
            }
            AIPrivacyNote(provider: model.provider)
        }
        .padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a question about \(model.namespace.collection)…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
                .onSubmit(model.send)
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isRunning)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }
}

private struct MessageView: View {
    let message: AssistantModel.Message
    let collection: String
    let open: (AssistantQuery) -> Void

    var body: some View {
        switch message.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            }
        case let .query(query, status):
            QueryCard(query: query, status: status, collection: collection, open: open)
        case let .answer(text, suggestion):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent).padding(.top, 2)
                    Text(markdown(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let suggestion {
                    QueryCard(query: suggestion, status: nil, collection: collection, open: open)
                }
            }
        case let .error(text):
            ErrorBanner(message: text)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct QueryCard: View {
    let query: AssistantQuery
    let status: AssistantModel.Message.QueryStatus?
    let collection: String
    let open: (AssistantQuery) -> Void
    @State private var showResults = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(text: query.kind.rawValue.uppercased(), color: Theme.accent)
                statusLabel
                Spacer()
                Button {
                    Pasteboard.copy(query.shellText(collection: collection))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy as mongo shell")
                Button(query.kind == .aggregate ? "Open in Aggregations" : "Open in Documents") { open(query) }
                    .controlSize(.small)
            }
            Text(HighlightedText.make(query.shellText(collection: collection)))
                .font(Theme.monospacedSmall)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case let .finished(result)? = status, result.count == nil, !result.documents.isEmpty {
                DisclosureGroup(isExpanded: $showResults) {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(Array(result.documents.prefix(10).enumerated()), id: \.offset) { _, document in
                                MiniDocumentView(document: document)
                            }
                        }
                    }
                } label: {
                    Text("Show results").font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case nil:
            Text("suggested").font(.caption).foregroundStyle(.secondary)
        case .running?:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("running").font(.caption) }
        case let .finished(result)?:
            Text(result.count.map { "count = \(Format.count($0))" } ?? "\(result.documents.count) documents")
                .font(.caption.weight(.medium)).foregroundStyle(.green)
        case let .rejected(reason)?:
            Text("blocked: \(reason)").font(.caption).foregroundStyle(.orange).lineLimit(2)
        case let .failed(reason)?:
            Text("failed: \(reason)").font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

private struct FlowSuggestions: View {
    let suggestions: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    action(suggestion)
                } label: {
                    Label(suggestion, systemImage: "text.bubble")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AgentUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No AI assistant found", systemImage: "sparkles")
        } description: {
            VStack(spacing: 6) {
                Text("CcinnMongo uses your locally installed Claude Code or Codex CLI.")
                ForEach(AgentProvider.allCases) { provider in
                    Text("**\(provider.displayName)**: \(provider.installHint)").font(.caption)
                }
                Text("You can also set the executable path in Settings → AI.").font(.caption)
            }
        } actions: {
            Button("Search Again") { AgentService.shared.refresh() }
        }
    }
}

/// Popover used by the query bar and the aggregation workbench to generate a query from a description.
struct AIGeneratePopover: View {
    enum Target {
        case find
        case pipeline

        var mode: AssistantMode { self == .find ? .generateFind : .generatePipeline }
    }

    let target: Target
    let tab: CollectionTabModel
    @Binding var isPresented: Bool
    @State private var request = ""
    @State private var isRunning = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private let service = AgentService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(target == .find ? "Generate a query" : "Generate a pipeline", systemImage: "sparkles")
                .font(.headline)
            if service.hasScanned, service.availableProviders.isEmpty {
                Text("Install Claude Code or the Codex CLI to use this feature.").foregroundStyle(.secondary)
            } else {
                TextField(target == .find ? "e.g. paid orders over 100 from last month, newest first" : "e.g. revenue per city for shipped orders, top 10",
                          text: $request, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(generate)
                    .disabled(isRunning)
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Text(service.activeProvider?.displayName ?? "…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                        Button("Stop") {
                            task?.cancel()
                            isRunning = false
                        }
                    } else {
                        Button("Generate", action: generate)
                            .buttonStyle(.borderedProminent)
                            .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                AIPrivacyNote(provider: service.activeProvider)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { service.scanIfNeeded() }
    }

    private func generate() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        let agent: CLIAgent
        do {
            agent = try service.agent()
        } catch {
            self.error = describe(error)
            return
        }
        isRunning = true
        error = nil
        let workspace = tab.workspace
        let namespace = tab.namespace
        let includeSamples = UserDefaults.standard.bool(forKey: AISettings.includeSamples)
        let current = tab.documents.query
        let mode = target.mode
        task = Task {
            let context = await AssistantContext.load(client: workspace.client, namespace: namespace, serverInfo: workspace.serverInfo,
                                                      includeSamples: includeSamples, currentQuery: current)
            do {
                let outcome = try await AssistantEngine(agent: agent, executor: nil).run(mode: mode, context: context, history: [], request: text) { _ in }
                guard !Task.isCancelled else { return }
                guard let query = outcome.suggestion else {
                    error = outcome.answer ?? "The assistant did not return a query."
                    isRunning = false
                    return
                }
                if target == .pipeline, query.kind != .aggregate {
                    var pipeline: [BSONDocument] = []
                    if !query.filter.isEmpty { pipeline.append(["$match": .document(query.filter)]) }
                    if let sort = query.sort { pipeline.append(["$sort": .document(sort)]) }
                    if let limit = query.limit { pipeline.append(["$limit": .int(limit)]) }
                    tab.apply(AssistantQuery(kind: .aggregate, pipeline: pipeline))
                } else {
                    tab.apply(query)
                }
                isRunning = false
                isPresented = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = describe(error)
                isRunning = false
            }
        }
    }
}

/// Settings → AI.
struct AISettingsView: View {
    @AppStorage(AISettings.provider) private var provider = AgentProvider.claudeCode.rawValue
    @AppStorage(AISettings.claudeModel) private var claudeModel = ""
    @AppStorage(AISettings.codexModel) private var codexModel = ""
    @AppStorage(AISettings.claudePath) private var claudePath = ""
    @AppStorage(AISettings.codexPath) private var codexPath = ""
    @AppStorage(AISettings.includeSamples) private var includeSamples = false
    @AppStorage(AISettings.allowQueries) private var allowQueries = true
    private let service = AgentService.shared

    var body: some View {
        Form {
            Picker("Assistant", selection: $provider) {
                ForEach(AgentProvider.allCases) { provider in
                    Text(provider.displayName + (service.executables[provider] == nil ? " (not found)" : "")).tag(provider.rawValue)
                }
            }
            Section("Claude Code") {
                LabeledContent("Executable", value: service.executables[.claudeCode]?.path ?? "not found")
                TextField("Custom path", text: $claudePath, prompt: Text("auto-detect"))
                TextField("Model", text: $claudeModel, prompt: Text("default (e.g. sonnet, opus)"))
            }
            Section("Codex CLI") {
                LabeledContent("Executable", value: service.executables[.codex]?.path ?? "not found")
                TextField("Custom path", text: $codexPath, prompt: Text("auto-detect"))
                TextField("Model", text: $codexModel, prompt: Text("default from ~/.codex/config.toml"))
            }
            Section("Privacy") {
                Toggle("Let the assistant run read-only queries", isOn: $allowQueries)
                Toggle("Share sample documents with the assistant", isOn: $includeSamples)
                Text("Connection strings, hosts and passwords are never sent. Queries the assistant requests are read-only, limited to 50 documents and 15 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Detect Again") { service.refresh() }
        }
        .formStyle(.grouped)
        .onAppear { service.scanIfNeeded() }
        .onChange(of: claudePath) { _, _ in service.refresh() }
        .onChange(of: codexPath) { _, _ in service.refresh() }
    }
}

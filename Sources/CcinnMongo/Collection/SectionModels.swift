import BSON
import Foundation
import CcinnMongoKit
import MongoKit
import Observation

// MARK: - Aggregations

@MainActor
@Observable
final class AggregationModel {
    struct StagePreview: Equatable {
        var documents: [BSONDocument] = []
        var isLoading = false
        var error: String?
    }

    let namespace: MongoNamespace
    unowned let workspace: WorkspaceModel

    var pipeline = PipelineModel()
    var isTextMode = false
    var pipelineText = "[]"
    var textError: String?
    var autoPreview = true
    var previewLimit = 10
    var previews: [UUID: StagePreview] = [:]

    var results: [DocumentItem] = []
    var isRunning = false
    var runError: String?
    var lastDuration: Duration?
    var showResults = false

    @ObservationIgnored private var previewTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init(namespace: MongoNamespace, workspace: WorkspaceModel) {
        self.namespace = namespace
        self.workspace = workspace
        pipeline.stages = [PipelineStage(operatorName: "$match", body: "{}")]
    }

    var client: MongoClient { workspace.client }

    func addStage(after index: Int? = nil, template: StageTemplate? = nil) {
        let stage = PipelineStage(operatorName: template?.name ?? "$match", body: template?.template ?? "{}")
        if let index, index < pipeline.stages.count {
            pipeline.stages.insert(stage, at: index + 1)
        } else {
            pipeline.stages.append(stage)
        }
        schedulePreviews(from: stage.id)
    }

    func remove(_ stage: PipelineStage) {
        pipeline.stages.removeAll { $0.id == stage.id }
        previews[stage.id] = nil
        schedulePreviews(from: nil)
    }

    func move(_ stage: PipelineStage, by offset: Int) {
        guard let index = pipeline.stages.firstIndex(where: { $0.id == stage.id }) else { return }
        let destination = index + offset
        guard pipeline.stages.indices.contains(destination) else { return }
        pipeline.stages.swapAt(index, destination)
        schedulePreviews(from: nil)
    }

    func changeOperator(_ stage: PipelineStage, to template: StageTemplate) {
        guard let index = pipeline.stages.firstIndex(where: { $0.id == stage.id }) else { return }
        let trimmed = pipeline.stages[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
        pipeline.stages[index].operatorName = template.name
        if trimmed.isEmpty || trimmed == "{}" { pipeline.stages[index].body = template.template }
        schedulePreviews(from: stage.id)
    }

    func stageEdited(_ stage: PipelineStage) {
        schedulePreviews(from: stage.id)
    }

    func setTextMode(_ enabled: Bool) {
        if enabled {
            pipelineText = pipeline.text
            textError = nil
            isTextMode = true
        } else {
            do {
                pipeline = try PipelineModel(text: pipelineText)
                textError = nil
                isTextMode = false
                schedulePreviews(from: nil)
            } catch {
                textError = describe(error)
            }
        }
    }

    /// Recomputes previews for `stageID` and every later stage (all stages when nil), debounced.
    func schedulePreviews(from stageID: UUID?) {
        guard autoPreview else { return }
        let startIndex = stageID.flatMap { id in pipeline.stages.firstIndex { $0.id == id } } ?? 0
        for (index, stage) in pipeline.stages.enumerated() where index >= startIndex {
            previewTasks[stage.id]?.cancel()
            previews[stage.id, default: StagePreview()].isLoading = stage.isEnabled
            let delay = 0.45 + Double(index - startIndex) * 0.05
            previewTasks[stage.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.preview(stageID: stage.id)
            }
        }
    }

    private func preview(stageID: UUID) async {
        guard let index = pipeline.stages.firstIndex(where: { $0.id == stageID }) else { return }
        let stage = pipeline.stages[index]
        guard stage.isEnabled else {
            previews[stageID] = StagePreview()
            return
        }
        do {
            var documents = try pipeline.documents(through: index)
            if let last = documents.last?.keys.first, ["$out", "$merge"].contains(last) {
                previews[stageID] = StagePreview(documents: [], isLoading: false, error: "\(last) is not previewed; run the pipeline to write output.")
                return
            }
            documents.append(["$limit": .int(previewLimit)])
            let results = try await client.aggregate(namespace, pipeline: documents, options: AggregateOptions(maxTimeMS: 10_000, maxResults: previewLimit))
            guard !Task.isCancelled else { return }
            previews[stageID] = StagePreview(documents: results)
        } catch {
            guard !Task.isCancelled else { return }
            previews[stageID] = StagePreview(documents: [], isLoading: false, error: describe(error))
        }
    }

    func run() {
        runTask?.cancel()
        let stages: [BSONDocument]
        do {
            if isTextMode { pipeline = try PipelineModel(text: pipelineText) }
            stages = try pipeline.documents()
        } catch {
            runError = describe(error)
            showResults = true
            return
        }
        isRunning = true
        runError = nil
        showResults = true
        let clock = ContinuousClock()
        let start = clock.now
        let client = self.client
        let namespace = self.namespace
        runTask = Task {
            do {
                let documents = try await client.aggregate(namespace, pipeline: stages, options: AggregateOptions(allowDiskUse: true, maxTimeMS: 120_000, maxResults: 1000))
                let prepared = await DocumentsModel.prepare(documents, offset: 0)
                guard !Task.isCancelled else { return }
                self.results = prepared
                self.lastDuration = clock.now - start
                self.isRunning = false
            } catch {
                guard !Task.isCancelled else { return }
                self.runError = describe(error)
                self.isRunning = false
            }
        }
    }

    func explain() async -> Result<BSONDocument, any Error> {
        do {
            let stages = try pipeline.documents()
            return .success(try await client.explainAggregate(namespace, pipeline: stages))
        } catch {
            return .failure(error)
        }
    }

    func cancel() {
        runTask?.cancel()
        isRunning = false
        for task in previewTasks.values { task.cancel() }
        previewTasks.removeAll()
    }
}

// MARK: - Schema

@MainActor
@Observable
final class SchemaModel {
    let namespace: MongoNamespace
    let client: MongoClient
    var sampleSize = 1000
    var result: SchemaResult?
    var isLoading = false
    var error: String?
    var lastDuration: Duration?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(namespace: MongoNamespace, client: MongoClient) {
        self.namespace = namespace
        self.client = client
    }

    func analyze() {
        task?.cancel()
        isLoading = true
        error = nil
        let client = self.client
        let namespace = self.namespace
        let size = sampleSize
        let clock = ContinuousClock()
        let start = clock.now
        task = Task {
            do {
                let documents = try await client.sample(namespace, size: size)
                let schema = await Self.analyze(documents)
                guard !Task.isCancelled else { return }
                self.result = schema
                self.lastDuration = clock.now - start
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = describe(error)
                self.isLoading = false
            }
        }
    }

    nonisolated static func analyze(_ documents: [BSONDocument]) async -> SchemaResult {
        SchemaAnalyzer.analyze(documents)
    }

    func cancel() {
        task?.cancel()
        isLoading = false
    }
}

// MARK: - Indexes

@MainActor
@Observable
final class IndexesModel {
    let namespace: MongoNamespace
    unowned let workspace: WorkspaceModel
    var indexes: [IndexInfo] = []
    var usage: [String: IndexUsage]?
    var sizes: [String: Double] = [:]
    var isLoading = false
    var error: String?
    var hasLoaded = false

    init(namespace: MongoNamespace, workspace: WorkspaceModel) {
        self.namespace = namespace
        self.workspace = workspace
    }

    var client: MongoClient { workspace.client }
    var supportsUsage: Bool { workspace.capabilities.hasIndexStats }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            async let indexes = client.listIndexes(namespace)
            async let usage = client.indexUsage(namespace)
            async let stats = try? client.collectionStats(namespace)
            self.indexes = try await indexes
            self.usage = (try? await usage) ?? nil
            sizes = await stats?.indexSizes ?? [:]
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    func create(keys: BSONDocument, options: IndexOptions) async throws {
        let name = try await client.createIndex(namespace, keys: keys, options: options)
        await load()
        workspace.show("Created index \(name)")
    }

    func drop(_ index: IndexInfo) async throws {
        try await client.dropIndex(namespace, name: index.name)
        await load()
        workspace.show("Dropped index \(index.name)")
    }
}

// MARK: - Explain

@MainActor
@Observable
final class ExplainModel {
    let namespace: MongoNamespace
    let client: MongoClient
    var query = QueryInput()
    var plan: ExplainPlan?
    var isLoading = false
    var error: String?
    var showRaw = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(namespace: MongoNamespace, client: MongoClient) {
        self.namespace = namespace
        self.client = client
    }

    func run() {
        task?.cancel()
        isLoading = true
        error = nil
        let client = self.client
        let namespace = self.namespace
        let query = self.query
        task = Task {
            do {
                var options = try query.allResultsOptions()
                options.maxTimeMS = 60_000
                let raw = try await client.explainFind(namespace, options: options)
                guard !Task.isCancelled else { return }
                self.plan = ExplainPlan(raw)
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = describe(error)
                self.isLoading = false
            }
        }
    }

    func show(_ raw: BSONDocument) {
        plan = ExplainPlan(raw)
        error = nil
    }

    func cancel() {
        task?.cancel()
        isLoading = false
    }
}

// MARK: - Database overview

@MainActor
@Observable
final class DatabaseOverviewModel {
    struct Row: Identifiable, Hashable {
        let info: CollectionInfo
        var stats: CollectionStats?
        var id: String { info.name }

        static func == (lhs: Row, rhs: Row) -> Bool { lhs.info == rhs.info && lhs.stats?.raw == rhs.stats?.raw }
        func hash(into hasher: inout Hasher) { hasher.combine(info) }
    }

    let database: String
    unowned let workspace: WorkspaceModel
    var rows: [Row] = []
    var databaseStats: BSONDocument?
    var isLoading = false
    var error: String?

    init(database: String, workspace: WorkspaceModel) {
        self.database = database
        self.workspace = workspace
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let client = workspace.client
        do {
            let collections = try await client.listCollections(database: database)
            rows = collections.map { Row(info: $0) }
            error = nil
            databaseStats = try? await client.databaseStats(database)
            // Load stats with bounded concurrency so large databases do not flood the server.
            let names = collections.filter { $0.kind == .collection }.map(\.name)
            let database = self.database
            await withTaskGroup(of: (String, CollectionStats?).self) { group in
                var iterator = names.makeIterator()
                for _ in 0..<4 {
                    guard let name = iterator.next() else { break }
                    group.addTask { (name, try? await client.collectionStats(MongoNamespace(database: database, collection: name))) }
                }
                for await (name, stats) in group {
                    if let index = rows.firstIndex(where: { $0.info.name == name }) { rows[index].stats = stats }
                    if let next = iterator.next() {
                        group.addTask { (next, try? await client.collectionStats(MongoNamespace(database: database, collection: next))) }
                    }
                }
            }
        } catch {
            self.error = describe(error)
        }
    }
}

// MARK: - Performance

@MainActor
@Observable
final class PerformanceModel {
    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let opsPerSecond: [String: Double]
        let networkInPerSecond: Double
        let networkOutPerSecond: Double
        let connections: Double
        let residentMB: Double
        let virtualMB: Double
    }

    static let operationKinds = ["insert", "query", "update", "delete", "getmore", "command"]
    static let window = 90

    let client: MongoClient
    var samples: [Sample] = []
    var error: String?
    var isRunning = false
    var host = ""
    var uptime: Double?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previous: (time: Date, opcounters: [String: Double], bytesIn: Double, bytesOut: Double)?

    init(client: MongoClient) {
        self.client = client
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        let client = self.client
        task = Task {
            while !Task.isCancelled {
                do {
                    let status = try await client.serverStatus()
                    self.ingest(status)
                    self.error = nil
                } catch {
                    if Task.isCancelled { break }
                    self.error = describe(error)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func ingest(_ status: BSONDocument) {
        let now = Date()
        host = status["host"]?.stringValue ?? host
        uptime = status["uptime"]?.doubleValue
        var counters: [String: Double] = [:]
        if let opcounters = status["opcounters"]?.documentValue {
            for kind in Self.operationKinds { counters[kind] = opcounters[kind]?.doubleValue ?? 0 }
        }
        let network = status["network"]?.documentValue
        let bytesIn = network?["bytesIn"]?.doubleValue ?? 0
        let bytesOut = network?["bytesOut"]?.doubleValue ?? 0
        let connections = status["connections"]?.documentValue?["current"]?.doubleValue ?? 0
        let memory = status["mem"]?.documentValue
        defer { previous = (now, counters, bytesIn, bytesOut) }
        guard let previous else { return }
        let elapsed = max(0.001, now.timeIntervalSince(previous.time))
        var rates: [String: Double] = [:]
        for kind in Self.operationKinds {
            rates[kind] = max(0, ((counters[kind] ?? 0) - (previous.opcounters[kind] ?? 0)) / elapsed)
        }
        samples.append(Sample(time: now, opsPerSecond: rates,
                              networkInPerSecond: max(0, (bytesIn - previous.bytesIn) / elapsed),
                              networkOutPerSecond: max(0, (bytesOut - previous.bytesOut) / elapsed),
                              connections: connections,
                              residentMB: memory?["resident"]?.doubleValue ?? 0,
                              virtualMB: memory?["virtual"]?.doubleValue ?? 0))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }
}

// MARK: - Console

@MainActor
@Observable
final class ConsoleModel {
    struct Entry: Identifiable {
        let id = UUID()
        let database: String
        let command: String
        let output: String
        let succeeded: Bool
        let duration: Duration
        let date = Date()
    }

    let client: MongoClient
    var database: String
    var input = "{ buildInfo: 1 }"
    var entries: [Entry] = []
    var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(client: MongoClient, database: String) {
        self.client = client
        self.database = database
    }

    var inputError: SyntaxError? {
        do {
            _ = try ShellSyntax.parseDocument(input)
            return nil
        } catch let error as SyntaxError {
            return error
        } catch {
            return nil
        }
    }

    func run() {
        guard !isRunning else { return }
        let command: BSONDocument
        do {
            command = try ShellSyntax.parseDocument(input)
        } catch {
            entries.insert(Entry(database: database, command: input, output: describe(error), succeeded: false, duration: .zero), at: 0)
            return
        }
        isRunning = true
        let client = self.client
        let database = self.database
        let text = input
        let clock = ContinuousClock()
        let start = clock.now
        task = Task {
            let entry: Entry
            do {
                let reply = try await client.runCommandRaw(command, database: database)
                let output = BSONFormatter(style: .shell, indent: 2).format(reply)
                entry = Entry(database: database, command: text, output: output, succeeded: reply["ok"]?.isTruthy ?? false, duration: clock.now - start)
            } catch {
                entry = Entry(database: database, command: text, output: describe(error), succeeded: false, duration: clock.now - start)
            }
            self.entries.insert(entry, at: 0)
            if self.entries.count > 100 { self.entries.removeLast(self.entries.count - 100) }
            self.isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }
}

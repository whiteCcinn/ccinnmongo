import BSON
import Foundation
import GroveKit
import MongoKit
import Observation

/// State of one open collection: its sub-views are created lazily on first use.
@MainActor
@Observable
final class CollectionTabModel {
    enum Section: String, CaseIterable, Identifiable {
        case documents = "Documents"
        case aggregations = "Aggregations"
        case schema = "Schema"
        case indexes = "Indexes"
        case explain = "Explain Plan"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .documents: "doc.text"
            case .aggregations: "line.3.horizontal.decrease"
            case .schema: "chart.bar.doc.horizontal"
            case .indexes: "list.bullet.indent"
            case .explain: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    let namespace: MongoNamespace
    let info: CollectionInfo?
    unowned let workspace: WorkspaceModel
    var section: Section = .documents
    var stats: CollectionStats?

    let documents: DocumentsModel
    @ObservationIgnored private var aggregationModel: AggregationModel?
    @ObservationIgnored private var schemaModel: SchemaModel?
    @ObservationIgnored private var indexesModel: IndexesModel?
    @ObservationIgnored private var explainModel: ExplainModel?

    init(namespace: MongoNamespace, info: CollectionInfo?, workspace: WorkspaceModel) {
        self.namespace = namespace
        self.info = info
        self.workspace = workspace
        documents = DocumentsModel(namespace: namespace, workspace: workspace)
        Task { await loadStats() }
    }

    var client: MongoClient { workspace.client }
    var isReadOnly: Bool { info?.kind == .view || info?.isReadOnly == true }

    var aggregation: AggregationModel {
        if let aggregationModel { return aggregationModel }
        let model = AggregationModel(namespace: namespace, workspace: workspace)
        aggregationModel = model
        return model
    }

    var schema: SchemaModel {
        if let schemaModel { return schemaModel }
        let model = SchemaModel(namespace: namespace, client: client)
        schemaModel = model
        return model
    }

    var indexes: IndexesModel {
        if let indexesModel { return indexesModel }
        let model = IndexesModel(namespace: namespace, workspace: workspace)
        indexesModel = model
        return model
    }

    var explain: ExplainModel {
        if let explainModel { return explainModel }
        let model = ExplainModel(namespace: namespace, client: client)
        explainModel = model
        return model
    }

    /// Field paths known for this collection (for completion).
    var knownFieldPaths: [String] {
        var paths = documents.fieldPaths
        if let schema = schemaModel?.result { paths += schema.allFieldPaths }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    func loadStats() async {
        guard info?.kind != .view else { return }
        stats = try? await client.collectionStats(namespace)
    }

    /// Explain the query currently in the Documents tab.
    func explainCurrentQuery() {
        section = .explain
        explain.query = documents.query
        explain.run()
    }

    func cancelAll() {
        documents.cancel()
        aggregationModel?.cancel()
        schemaModel?.cancel()
        explainModel?.cancel()
    }
}

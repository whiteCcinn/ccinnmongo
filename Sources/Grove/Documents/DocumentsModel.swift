import BSON
import Foundation
import GroveKit
import MongoKit
import Observation

/// One document on the current page, with pre-rendered representations (built off the main actor).
struct DocumentItem: Identifiable, Sendable {
    let id: Int
    let document: BSONDocument
    /// `{_id: …}` used to address the document for edits and deletes.
    let identity: BSONDocument?
    let shellText: String

    var idSummary: String {
        document["_id"].map { BSONFormatter.summary(of: $0, maxLength: 60) } ?? "(no _id)"
    }
}

enum DocumentViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case json = "JSON"
    case table = "Table"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .list: "list.bullet.rectangle"
        case .json: "curlybraces"
        case .table: "tablecells"
        }
    }
}

@MainActor
@Observable
final class DocumentsModel {
    enum CountState: Equatable {
        case idle
        case loading
        case known(Int64)
        case unavailable
    }

    let namespace: MongoNamespace
    unowned let workspace: WorkspaceModel

    var query = QueryInput()
    private(set) var appliedQuery = QueryInput()
    var viewMode: DocumentViewMode = .list
    var pageSize = UserDefaults.standard.integer(forKey: "defaultPageSize").nonZero ?? 20
    private(set) var page = 0
    private(set) var items: [DocumentItem] = []
    private(set) var count: CountState = .idle
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var error: String?
    private(set) var lastDuration: Duration?
    /// Expanded tree paths per document id (list view).
    var expanded: [Int: Set<String>] = [:]

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(namespace: MongoNamespace, workspace: WorkspaceModel) {
        self.namespace = namespace
        self.workspace = workspace
    }

    var client: MongoClient { workspace.client }
    var validationErrors: [QueryInput.Field: SyntaxError] { query.validationErrors }
    var canRun: Bool { validationErrors.isEmpty }

    var pageCount: Int? {
        guard case let .known(total) = count else { return nil }
        return max(1, appliedQuery.pageCount(total: max(0, total), pageSize: pageSize))
    }

    var rangeDescription: String {
        guard !items.isEmpty else { return hasLoaded ? "0 documents" : "" }
        let start = page * pageSize + 1
        let end = page * pageSize + items.count
        switch count {
        case let .known(total): return "\(Format.count(start)) – \(Format.count(end)) of \(Format.count(total))"
        case .loading: return "\(Format.count(start)) – \(Format.count(end)) of …"
        default: return "\(Format.count(start)) – \(Format.count(end)) of N/A"
        }
    }

    var canGoBack: Bool { page > 0 && !isLoading }

    var canGoForward: Bool {
        guard !isLoading else { return false }
        if let pageCount { return page + 1 < pageCount }
        return items.count == pageSize
    }

    /// Top-level and nested field paths of the loaded page (for completion).
    var fieldPaths: [String] {
        var seen = Set<String>()
        var paths: [String] = []
        func walk(_ document: BSONDocument, prefix: String, depth: Int) {
            for element in document.elements {
                let path = prefix.isEmpty ? element.key : "\(prefix).\(element.key)"
                if seen.insert(path).inserted { paths.append(path) }
                if depth < 3, case let .document(nested) = element.value { walk(nested, prefix: path, depth: depth + 1) }
            }
        }
        for item in items.prefix(50) { walk(item.document, prefix: "", depth: 0) }
        return paths
    }

    // MARK: Loading

    /// Applies the query bar and loads the first page (and the count).
    func run() {
        guard canRun else { return }
        appliedQuery = query
        page = 0
        expanded = [:]
        AppServices.shared.history.record(query, namespace: namespace.fullName)
        load(recount: true)
    }

    func reset() {
        query = QueryInput()
        run()
    }

    func refresh() { load(recount: true) }

    func loadIfNeeded() {
        if !hasLoaded, loadTask == nil { load(recount: true) }
    }

    func nextPage() {
        guard canGoForward else { return }
        page += 1
        load(recount: false)
    }

    func previousPage() {
        guard canGoBack else { return }
        page -= 1
        load(recount: false)
    }

    func setPageSize(_ size: Int) {
        pageSize = size
        page = 0
        load(recount: false)
    }

    func cancel() {
        loadTask?.cancel()
        countTask?.cancel()
        loadTask = nil
        if isLoading { isLoading = false }
        if count == .loading { count = .unavailable }
    }

    private func load(recount: Bool) {
        loadTask?.cancel()
        generation += 1
        let generation = self.generation
        let options: FindOptions?
        do {
            options = try appliedQuery.findOptions(page: page, pageSize: pageSize)
        } catch {
            self.error = describe(error)
            return
        }
        guard let options else {
            items = []
            hasLoaded = true
            return
        }
        isLoading = true
        error = nil
        let client = self.client
        let namespace = self.namespace
        let offset = page * pageSize
        let clock = ContinuousClock()
        let start = clock.now
        loadTask = Task {
            do {
                let documents = try await client.find(namespace, options: options)
                let prepared = await Self.prepare(documents, offset: offset)
                guard generation == self.generation, !Task.isCancelled else { return }
                self.items = prepared
                self.lastDuration = clock.now - start
                self.isLoading = false
                self.hasLoaded = true
                self.loadTask = nil
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                self.error = describe(error)
                self.isLoading = false
                self.hasLoaded = true
                self.loadTask = nil
            }
        }
        if recount { loadCount() }
    }

    private func loadCount() {
        countTask?.cancel()
        count = .loading
        let client = self.client
        let namespace = self.namespace
        let query = appliedQuery
        countTask = Task {
            do {
                let filter = try query.filterDocument()
                let total = try await client.count(namespace, filter: filter, options: try query.countOptions())
                guard !Task.isCancelled else { return }
                self.count = total.map(CountState.known) ?? .unavailable
            } catch {
                guard !Task.isCancelled else { return }
                self.count = .unavailable
            }
        }
    }

    /// Formats documents away from the main actor so large pages never stall the UI.
    nonisolated static func prepare(_ documents: [BSONDocument], offset: Int) async -> [DocumentItem] {
        let formatter = BSONFormatter(style: .shell, indent: 2)
        return documents.enumerated().map { index, document in
            DocumentItem(id: offset + index,
                         document: document,
                         identity: document["_id"].map { ["_id": $0] },
                         shellText: formatter.format(document))
        }
    }

    // MARK: Editing

    func insert(_ documents: [BSONDocument]) async throws -> Int {
        let result = try await client.insert(documents, into: namespace)
        refresh()
        return result.insertedCount
    }

    func replace(_ item: DocumentItem, with document: BSONDocument) async throws {
        guard let identity = item.identity else {
            throw MongoError(.invalidArgument, "This document has no _id, so it cannot be updated safely")
        }
        if let newID = document["_id"], newID != identity["_id"] {
            throw MongoError(.invalidArgument, "The _id field cannot be changed. Clone the document instead.")
        }
        let result = try await client.replaceOne(namespace, filter: identity, replacement: document)
        guard result.matchedCount == 1 else {
            throw MongoError(.write, "The document no longer exists (it may have been deleted by someone else)")
        }
        refresh()
    }

    func delete(_ item: DocumentItem) async throws {
        guard let identity = item.identity else {
            throw MongoError(.invalidArgument, "This document has no _id, so it cannot be deleted safely")
        }
        let deleted = try await client.deleteDocuments(namespace, filter: identity, many: false)
        guard deleted == 1 else { throw MongoError(.write, "The document no longer exists") }
        refresh()
    }

    /// Deletes every document matching the applied filter.
    func deleteAllMatching() async throws -> Int {
        let filter = try appliedQuery.filterDocument()
        let deleted = try await client.deleteDocuments(namespace, filter: filter, many: true)
        refresh()
        return deleted
    }

    func updateAllMatching(_ update: BSONDocument) async throws -> UpdateResult {
        let filter = try appliedQuery.filterDocument()
        let result = try await client.updateDocuments(namespace, filter: filter, update: update, many: true)
        refresh()
        return result
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

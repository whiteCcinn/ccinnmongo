import BSON
import Foundation
import MongoKit
import os

/// The text a user typed into the query bar, plus numeric options.
public struct QueryInput: Codable, Hashable, Sendable {
    public enum Field: String, CaseIterable, Codable, Sendable {
        case filter, projection, sort, collation, hint
    }

    public var filter = ""
    public var projection = ""
    public var sort = ""
    public var collation = ""
    public var hint = ""
    public var skip = 0
    /// 0 = no limit.
    public var limit = 0
    public var maxTimeMS = 60_000

    public init() {}

    public var isDefault: Bool { self == QueryInput() }

    public func text(for field: Field) -> String {
        switch field {
        case .filter: filter
        case .projection: projection
        case .sort: sort
        case .collation: collation
        case .hint: hint
        }
    }

    public var validationErrors: [Field: SyntaxError] {
        var errors: [Field: SyntaxError] = [:]
        for field in Field.allCases {
            let text = self.text(for: field)
            if field == .hint, !text.trimmingCharacters(in: .whitespaces).hasPrefix("{") { continue }
            do {
                _ = try ShellSyntax.parseDocument(text, allowEmpty: true)
            } catch let error as SyntaxError {
                errors[field] = error
            } catch {}
        }
        return errors
    }

    public func filterDocument() throws -> BSONDocument { try ShellSyntax.parseDocument(filter, allowEmpty: true) }

    private func optionalDocument(_ text: String) throws -> BSONDocument? {
        let document = try ShellSyntax.parseDocument(text, allowEmpty: true)
        return document.isEmpty ? nil : document
    }

    public func hintValue() throws -> BSONValue? {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") { return .document(try ShellSyntax.parseDocument(trimmed)) }
        return .string(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
    }

    /// Find options for a zero-based page, or `nil` when the page lies beyond the user's limit.
    public func findOptions(page: Int, pageSize: Int) throws -> FindOptions? {
        let pageSize = max(1, pageSize)
        let offset = max(0, page) * pageSize
        var pageLimit = pageSize
        if limit > 0 {
            let remaining = limit - offset
            guard remaining > 0 else { return nil }
            pageLimit = min(pageSize, remaining)
        }
        return FindOptions(filter: try filterDocument(),
                           projection: try optionalDocument(projection),
                           sort: try optionalDocument(sort),
                           skip: max(0, skip) + offset,
                           limit: pageLimit,
                           collation: try optionalDocument(collation),
                           hint: try hintValue(),
                           maxTimeMS: maxTimeMS > 0 ? maxTimeMS : nil)
    }

    /// Options for exporting or counting every result of the query (ignores paging).
    public func allResultsOptions() throws -> FindOptions {
        FindOptions(filter: try filterDocument(), projection: try optionalDocument(projection), sort: try optionalDocument(sort),
                    skip: max(0, skip), limit: max(0, limit), collation: try optionalDocument(collation), hint: try hintValue(),
                    maxTimeMS: nil)
    }

    public func countOptions() throws -> CountOptions {
        CountOptions(skip: max(0, skip), limit: max(0, limit), maxTimeMS: 5_000, collation: try optionalDocument(collation), hint: try hintValue())
    }

    public func pageCount(total: Int64, pageSize: Int) -> Int {
        let pageSize = Int64(max(1, pageSize))
        var effective = max(0, total)
        if limit > 0 { effective = min(effective, Int64(limit)) }
        return Int((effective + pageSize - 1) / pageSize)
    }
}

/// Persisted history of queries per namespace.
public struct QueryHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var namespace: String
    public var query: QueryInput
    public var date: Date
    public var isFavorite: Bool

    public init(id: UUID = UUID(), namespace: String, query: QueryInput, date: Date = Date(), isFavorite: Bool = false) {
        self.id = id
        self.namespace = namespace
        self.query = query
        self.date = date
        self.isFavorite = isFavorite
    }
}

public final class QueryHistoryStore: Sendable {
    public static let maxPerNamespace = 50
    private let fileURL: URL
    private let entries: OSAllocatedUnfairLockBox<[QueryHistoryEntry]>

    public init(directory: URL = ProfileRepository.defaultDirectory) {
        fileURL = directory.appendingPathComponent("query-history.json")
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([QueryHistoryEntry].self, from: $0) } ?? []
        entries = OSAllocatedUnfairLockBox(loaded)
    }

    public func entries(for namespace: String) -> [QueryHistoryEntry] {
        entries.value.filter { $0.namespace == namespace }.sorted { ($0.isFavorite ? 1 : 0, $0.date) > ($1.isFavorite ? 1 : 0, $1.date) }
    }

    public func record(_ query: QueryInput, namespace: String) {
        guard !query.isDefault else { return }
        entries.mutate { all in
            all.removeAll { $0.namespace == namespace && $0.query == query && !$0.isFavorite }
            all.append(QueryHistoryEntry(namespace: namespace, query: query))
            let forNamespace = all.filter { $0.namespace == namespace && !$0.isFavorite }.sorted { $0.date > $1.date }
            if forNamespace.count > Self.maxPerNamespace {
                let drop = Set(forNamespace.dropFirst(Self.maxPerNamespace).map(\.id))
                all.removeAll { drop.contains($0.id) }
            }
        }
        persist()
    }

    public func toggleFavorite(_ id: UUID) {
        entries.mutate { all in
            if let index = all.firstIndex(where: { $0.id == id }) { all[index].isFavorite.toggle() }
        }
        persist()
    }

    private func persist() {
        let snapshot = entries.value
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

/// Minimal lock box for value types (keeps call sites readable).
final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Value { lock.withLock { $0 } }
    func mutate(_ body: @Sendable (inout Value) -> Void) { lock.withLock { body(&$0) } }
}

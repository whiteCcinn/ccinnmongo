import BSON
import Foundation

public struct MongoNamespace: Sendable, Hashable, CustomStringConvertible, Codable {
    public var database: String
    public var collection: String

    public init(database: String, collection: String) {
        self.database = database
        self.collection = collection
    }

    /// Splits `db.collection` at the first dot (collection names may contain dots).
    public init?(fullName: String) {
        guard let dot = fullName.firstIndex(of: ".") else { return nil }
        database = String(fullName[..<dot])
        collection = String(fullName[fullName.index(after: dot)...])
        guard !database.isEmpty, !collection.isEmpty else { return nil }
    }

    public var fullName: String { "\(database).\(collection)" }
    public var description: String { fullName }
}

// MARK: - Options

public struct FindOptions: Sendable, Equatable {
    public var filter: BSONDocument
    public var projection: BSONDocument?
    public var sort: BSONDocument?
    public var skip: Int
    /// Maximum documents to return; 0 means no limit.
    public var limit: Int
    public var collation: BSONDocument?
    public var hint: BSONValue?
    public var maxTimeMS: Int?
    public var batchSize: Int?

    public init(filter: BSONDocument = [:], projection: BSONDocument? = nil, sort: BSONDocument? = nil, skip: Int = 0,
                limit: Int = 0, collation: BSONDocument? = nil, hint: BSONValue? = nil, maxTimeMS: Int? = nil, batchSize: Int? = nil) {
        self.filter = filter
        self.projection = projection
        self.sort = sort
        self.skip = skip
        self.limit = limit
        self.collation = collation
        self.hint = hint
        self.maxTimeMS = maxTimeMS
        self.batchSize = batchSize
    }
}

public struct CountOptions: Sendable, Equatable {
    public var skip: Int
    public var limit: Int
    public var maxTimeMS: Int?
    public var collation: BSONDocument?
    public var hint: BSONValue?

    public init(skip: Int = 0, limit: Int = 0, maxTimeMS: Int? = 5_000, collation: BSONDocument? = nil, hint: BSONValue? = nil) {
        self.skip = skip
        self.limit = limit
        self.maxTimeMS = maxTimeMS
        self.collation = collation
        self.hint = hint
    }
}

public struct AggregateOptions: Sendable, Equatable {
    public var allowDiskUse: Bool
    public var maxTimeMS: Int?
    public var collation: BSONDocument?
    public var batchSize: Int?
    /// Stop reading after this many results (0 = all).
    public var maxResults: Int

    public init(allowDiskUse: Bool = false, maxTimeMS: Int? = nil, collation: BSONDocument? = nil, batchSize: Int? = nil, maxResults: Int = 0) {
        self.allowDiskUse = allowDiskUse
        self.maxTimeMS = maxTimeMS
        self.collation = collation
        self.batchSize = batchSize
        self.maxResults = maxResults
    }
}

public struct IndexOptions: Sendable, Equatable {
    public var name: String?
    public var unique: Bool
    public var sparse: Bool
    public var expireAfterSeconds: Int?
    public var partialFilterExpression: BSONDocument?
    public var background: Bool
    public var collation: BSONDocument?
    public var hidden: Bool

    public init(name: String? = nil, unique: Bool = false, sparse: Bool = false, expireAfterSeconds: Int? = nil,
                partialFilterExpression: BSONDocument? = nil, background: Bool = false, collation: BSONDocument? = nil, hidden: Bool = false) {
        self.name = name
        self.unique = unique
        self.sparse = sparse
        self.expireAfterSeconds = expireAfterSeconds
        self.partialFilterExpression = partialFilterExpression
        self.background = background
        self.collation = collation
        self.hidden = hidden
    }
}

// MARK: - Results

public struct DatabaseInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var sizeOnDisk: Int64?
    public var isEmpty: Bool?
    public var id: String { name }

    public init(name: String, sizeOnDisk: Int64? = nil, isEmpty: Bool? = nil) {
        self.name = name
        self.sizeOnDisk = sizeOnDisk
        self.isEmpty = isEmpty
    }

    public var isSystem: Bool { ["admin", "local", "config"].contains(name) }
}

public struct CollectionInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case collection
        case view
        case timeseries
    }

    public var name: String
    public var kind: Kind
    public var options: BSONDocument
    public var isReadOnly: Bool
    public var id: String { name }

    public init(name: String, kind: Kind = .collection, options: BSONDocument = [:], isReadOnly: Bool = false) {
        self.name = name
        self.kind = kind
        self.options = options
        self.isReadOnly = isReadOnly
    }

    public var isSystem: Bool { name.hasPrefix("system.") }
    public var isCapped: Bool { options["capped"]?.isTruthy ?? false }
    public var viewOn: String? { options["viewOn"]?.stringValue }
}

public struct IndexInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var keys: BSONDocument
    public var raw: BSONDocument
    public var id: String { name }

    public init(raw: BSONDocument) {
        self.raw = raw
        name = raw["name"]?.stringValue ?? "?"
        keys = raw["key"]?.documentValue ?? [:]
    }

    public var isIdIndex: Bool { name == "_id_" }
    public var isUnique: Bool { raw["unique"]?.isTruthy ?? false }
    public var isSparse: Bool { raw["sparse"]?.isTruthy ?? false }
    public var isHidden: Bool { raw["hidden"]?.isTruthy ?? false }
    public var expireAfterSeconds: Int64? { raw["expireAfterSeconds"]?.int64Value }
    public var partialFilterExpression: BSONDocument? { raw["partialFilterExpression"]?.documentValue }
    public var collation: BSONDocument? { raw["collation"]?.documentValue }

    /// Kind of index derived from its key specification.
    public var kind: String {
        for value in keys.values {
            if case let .string(type) = value {
                switch type {
                case "text": return "Text"
                case "2dsphere": return "Geospatial"
                case "2d": return "Geospatial (2d)"
                case "hashed": return "Hashed"
                case "geoHaystack": return "Geo haystack"
                default: return type.capitalized
                }
            }
        }
        if keys.keys.contains(where: { $0.contains("$**") }) { return "Wildcard" }
        return keys.count > 1 ? "Compound" : "Regular"
    }
}

public struct IndexUsage: Sendable, Hashable {
    public var name: String
    public var operations: Int64
    public var since: Date?
}

public struct InsertResult: Sendable {
    public var insertedCount: Int
    public var insertedIDs: [BSONValue]
}

public struct UpdateResult: Sendable {
    public var matchedCount: Int
    public var modifiedCount: Int
    public var upsertedID: BSONValue?
}

/// Normalised view of `collStats`.
public struct CollectionStats: Sendable {
    public let raw: BSONDocument

    public init(raw: BSONDocument) { self.raw = raw }

    public var documentCount: Int64? { raw["count"]?.int64Value ?? raw["count"]?.doubleValue.map { Int64($0) } }
    public var size: Double? { raw["size"]?.doubleValue }
    public var averageObjectSize: Double? { raw["avgObjSize"]?.doubleValue }
    public var storageSize: Double? { raw["storageSize"]?.doubleValue }
    public var indexCount: Int? { raw["nindexes"]?.intValue }
    public var totalIndexSize: Double? { raw["totalIndexSize"]?.doubleValue }
    public var isCapped: Bool { raw["capped"]?.isTruthy ?? false }
    public var indexSizes: [String: Double] {
        guard let document = raw["indexSizes"]?.documentValue else { return [:] }
        var sizes: [String: Double] = [:]
        for element in document.elements { sizes[element.key] = element.value.doubleValue }
        return sizes
    }
}

extension BSONValue {
    /// Server counters arrive as int32, int64 or double depending on version and magnitude.
    var countValue: Int64? {
        if let integer = int64Value { return integer }
        if let double = doubleValue, double.isFinite { return Int64(exactly: double.rounded()) }
        return nil
    }
}

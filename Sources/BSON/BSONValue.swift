import Foundation

/// A single BSON value. Every BSON 1.1 type is representable, including deprecated ones,
/// so documents read from legacy servers can be written back unchanged.
public enum BSONValue: Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(BSONBinary)
    case undefined
    case objectId(ObjectId)
    case bool(Bool)
    case datetime(BSONDateTime)
    case null
    case regex(BSONRegex)
    case dbPointer(BSONDBPointer)
    case javascript(String)
    case symbol(String)
    case javascriptWithScope(BSONCodeWithScope)
    case int32(Int32)
    case timestamp(BSONTimestamp)
    case int64(Int64)
    case decimal128(Decimal128)
    case minKey
    case maxKey

    public var type: BSONType {
        switch self {
        case .double: .double
        case .string: .string
        case .document: .document
        case .array: .array
        case .binary: .binary
        case .undefined: .undefined
        case .objectId: .objectId
        case .bool: .bool
        case .datetime: .datetime
        case .null: .null
        case .regex: .regex
        case .dbPointer: .dbPointer
        case .javascript: .javascript
        case .symbol: .symbol
        case .javascriptWithScope: .javascriptWithScope
        case .int32: .int32
        case .timestamp: .timestamp
        case .int64: .int64
        case .decimal128: .decimal128
        case .minKey: .minKey
        case .maxKey: .maxKey
        }
    }
}

// MARK: - Equality

extension BSONValue: Hashable {
    /// Doubles compare by bit pattern so that NaN equals NaN and 0.0 differs from -0.0,
    /// which is what "same stored value" means for a database client.
    public static func == (lhs: BSONValue, rhs: BSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.double(a), .double(b)): a.bitPattern == b.bitPattern
        case let (.string(a), .string(b)): a == b
        case let (.document(a), .document(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.binary(a), .binary(b)): a == b
        case (.undefined, .undefined): true
        case let (.objectId(a), .objectId(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case let (.datetime(a), .datetime(b)): a == b
        case (.null, .null): true
        case let (.regex(a), .regex(b)): a == b
        case let (.dbPointer(a), .dbPointer(b)): a == b
        case let (.javascript(a), .javascript(b)): a == b
        case let (.symbol(a), .symbol(b)): a == b
        case let (.javascriptWithScope(a), .javascriptWithScope(b)): a == b
        case let (.int32(a), .int32(b)): a == b
        case let (.timestamp(a), .timestamp(b)): a == b
        case let (.int64(a), .int64(b)): a == b
        case let (.decimal128(a), .decimal128(b)): a == b
        case (.minKey, .minKey): true
        case (.maxKey, .maxKey): true
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        switch self {
        case let .double(v): hasher.combine(v.bitPattern)
        case let .string(v): hasher.combine(v)
        case let .document(v): hasher.combine(v)
        case let .array(v): hasher.combine(v)
        case let .binary(v): hasher.combine(v)
        case let .objectId(v): hasher.combine(v)
        case let .bool(v): hasher.combine(v)
        case let .datetime(v): hasher.combine(v)
        case let .regex(v): hasher.combine(v)
        case let .dbPointer(v): hasher.combine(v)
        case let .javascript(v): hasher.combine(v)
        case let .symbol(v): hasher.combine(v)
        case let .javascriptWithScope(v): hasher.combine(v)
        case let .int32(v): hasher.combine(v)
        case let .timestamp(v): hasher.combine(v)
        case let .int64(v): hasher.combine(v)
        case let .decimal128(v): hasher.combine(v)
        case .undefined, .null, .minKey, .maxKey: break
        }
    }
}

// MARK: - Accessors

extension BSONValue {
    public var stringValue: String? {
        if case let .string(v) = self { return v }
        return nil
    }

    public var documentValue: BSONDocument? {
        if case let .document(v) = self { return v }
        return nil
    }

    public var arrayValue: [BSONValue]? {
        if case let .array(v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }

    public var objectIdValue: ObjectId? {
        if case let .objectId(v) = self { return v }
        return nil
    }

    public var binaryValue: BSONBinary? {
        if case let .binary(v) = self { return v }
        return nil
    }

    public var datetimeValue: BSONDateTime? {
        if case let .datetime(v) = self { return v }
        return nil
    }

    /// Integer view of int32/int64 values and of doubles holding an exact integer.
    public var int64Value: Int64? {
        switch self {
        case let .int32(v): return Int64(v)
        case let .int64(v): return v
        case let .double(v):
            guard v.isFinite, v.rounded() == v, let exact = Int64(exactly: v) else { return nil }
            return exact
        default: return nil
        }
    }

    public var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    public var doubleValue: Double? {
        switch self {
        case let .double(v): v
        case let .int32(v): Double(v)
        case let .int64(v): Double(v)
        case let .decimal128(v): Double(v.description)
        default: nil
        }
    }

    public var isNumeric: Bool { type.isNumeric }

    /// MongoDB "truthiness" used for fields such as `ok`: true, or any non-zero number.
    public var isTruthy: Bool {
        switch self {
        case let .bool(v): v
        case let .int32(v): v != 0
        case let .int64(v): v != 0
        case let .double(v): v != 0 && !v.isNaN
        default: false
        }
    }
}

// MARK: - Literals

extension BSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension BSONValue: ExpressibleByIntegerLiteral {
    /// Integer literals become int32 when they fit, int64 otherwise (same rule as the shell parser).
    public init(integerLiteral value: Int) {
        if let small = Int32(exactly: value) {
            self = .int32(small)
        } else {
            self = .int64(Int64(value))
        }
    }
}

extension BSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension BSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension BSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: BSONValue...) { self = .array(elements) }
}

extension BSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, BSONValue)...) {
        self = .document(BSONDocument(elements.map { BSONElement(key: $0.0, value: $0.1) }))
    }
}

extension BSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Convenience constructors

extension BSONValue {
    public static func int(_ value: Int) -> BSONValue {
        if let small = Int32(exactly: value) { return .int32(small) }
        return .int64(Int64(value))
    }

    public static func date(_ date: Date) -> BSONValue { .datetime(BSONDateTime(date)) }
}

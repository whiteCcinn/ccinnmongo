/// BSON element type tags as defined by the BSON 1.1 specification.
public enum BSONType: UInt8, Sendable, CaseIterable, Hashable {
    case double = 0x01
    case string = 0x02
    case document = 0x03
    case array = 0x04
    case binary = 0x05
    case undefined = 0x06
    case objectId = 0x07
    case bool = 0x08
    case datetime = 0x09
    case null = 0x0A
    case regex = 0x0B
    case dbPointer = 0x0C
    case javascript = 0x0D
    case symbol = 0x0E
    case javascriptWithScope = 0x0F
    case int32 = 0x10
    case timestamp = 0x11
    case int64 = 0x12
    case decimal128 = 0x13
    case minKey = 0xFF
    case maxKey = 0x7F

    /// Human readable type name, aligned with the names MongoDB tools show.
    public var displayName: String {
        switch self {
        case .double: "Double"
        case .string: "String"
        case .document: "Object"
        case .array: "Array"
        case .binary: "Binary"
        case .undefined: "Undefined"
        case .objectId: "ObjectId"
        case .bool: "Boolean"
        case .datetime: "Date"
        case .null: "Null"
        case .regex: "RegExp"
        case .dbPointer: "DBPointer"
        case .javascript: "Code"
        case .symbol: "Symbol"
        case .javascriptWithScope: "CodeWScope"
        case .int32: "Int32"
        case .timestamp: "Timestamp"
        case .int64: "Int64"
        case .decimal128: "Decimal128"
        case .minKey: "MinKey"
        case .maxKey: "MaxKey"
        }
    }

    /// Alias accepted by the `$type` query operator.
    public var queryAlias: String {
        switch self {
        case .double: "double"
        case .string: "string"
        case .document: "object"
        case .array: "array"
        case .binary: "binData"
        case .undefined: "undefined"
        case .objectId: "objectId"
        case .bool: "bool"
        case .datetime: "date"
        case .null: "null"
        case .regex: "regex"
        case .dbPointer: "dbPointer"
        case .javascript: "javascript"
        case .symbol: "symbol"
        case .javascriptWithScope: "javascriptWithScope"
        case .int32: "int"
        case .timestamp: "timestamp"
        case .int64: "long"
        case .decimal128: "decimal"
        case .minKey: "minKey"
        case .maxKey: "maxKey"
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .double, .int32, .int64, .decimal128: true
        default: false
        }
    }

    public var isContainer: Bool { self == .document || self == .array }
}

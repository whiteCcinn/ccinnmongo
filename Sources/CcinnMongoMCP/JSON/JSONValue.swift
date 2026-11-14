import Foundation

/// A JSON value with ordered objects and exact integers.
///
/// MongoDB documents carried inside MCP arguments depend on key order (`sort: {a: 1, b: -1}`), and
/// JSON-RPC ids must be echoed exactly, so neither `JSONSerialization` nor `Codable` fit.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var objectValue: JSONObject? {
        if case let .object(object) = self { return object }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case let .string(string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(bool) = self { return bool }
        return nil
    }

    /// Integers, and doubles that hold an exact integer.
    public var int64Value: Int64? {
        switch self {
        case let .int(value): return value
        case let .double(value): return Int64(exactly: value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value): return value
        default: return nil
        }
    }

    public var isNull: Bool { self == .null }
}

/// One member of a `JSONObject`.
public struct JSONMember: Sendable, Hashable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// An insertion-ordered JSON object. Keys are unique: assigning an existing key replaces its value in place.
public struct JSONObject: Sendable, Hashable, Sequence {
    public private(set) var members: [JSONMember]

    public init() { members = [] }

    /// Builds an object, keeping the last value (at the first position) for repeated keys.
    public init(_ members: [JSONMember]) {
        self.members = []
        self.members.reserveCapacity(members.count)
        var positions: [String: Int] = [:]
        for member in members {
            if let index = positions[member.key] {
                self.members[index].value = member.value
            } else {
                positions[member.key] = self.members.count
                self.members.append(member)
            }
        }
    }

    public var count: Int { members.count }
    public var isEmpty: Bool { members.isEmpty }
    public var keys: [String] { members.map(\.key) }

    public subscript(key: String) -> JSONValue? {
        get { members.first { $0.key == key }?.value }
        set {
            let index = members.firstIndex { $0.key == key }
            switch (index, newValue) {
            case let (index?, value?): members[index].value = value
            case let (index?, nil): members.remove(at: index)
            case let (nil, value?): members.append(JSONMember(key: key, value: value))
            case (nil, nil): break
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[JSONMember]> { members.makeIterator() }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements.map { JSONMember(key: $0.0, value: $0.1) }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements.map { JSONMember(key: $0.0, value: $0.1) })
    }
}

extension JSONValue {
    /// Convenience for optional values that should be `null` when absent.
    public static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    public static func optional(_ value: Int64?) -> JSONValue { value.map(JSONValue.int) ?? .null }
    public static func int(_ value: Int) -> JSONValue { .int(Int64(value)) }
}

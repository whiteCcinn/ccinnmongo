/// One key/value pair of a document.
public struct BSONElement: Sendable, Hashable {
    public var key: String
    public var value: BSONValue

    public init(key: String, value: BSONValue) {
        self.key = key
        self.value = value
    }
}

/// An ordered BSON document. Field order and duplicate keys are preserved exactly as decoded.
///
/// Lookups are linear: MongoDB documents are typically small and are iterated in order for
/// display anyway, so an auxiliary index would cost more memory than it saves time.
public struct BSONDocument: Sendable, Hashable {
    public private(set) var elements: [BSONElement]

    public init() { elements = [] }

    public init(_ elements: [BSONElement]) { self.elements = elements }

    public init<S: Sequence>(pairs: S) where S.Element == (String, BSONValue) {
        elements = pairs.map { BSONElement(key: $0.0, value: $0.1) }
    }

    public var keys: [String] { elements.map(\.key) }
    public var values: [BSONValue] { elements.map(\.value) }

    /// Value of the first field named `key`; assigning replaces that field in place, appends a new
    /// field, or (with `nil`) removes the first field with that name.
    public subscript(key: String) -> BSONValue? {
        get { elements.first(where: { $0.key == key })?.value }
        set {
            if let index = elements.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    elements[index].value = newValue
                } else {
                    elements.remove(at: index)
                }
            } else if let newValue {
                elements.append(BSONElement(key: key, value: newValue))
            }
        }
    }

    public func contains(key: String) -> Bool { elements.contains(where: { $0.key == key }) }

    public mutating func append(_ key: String, _ value: BSONValue) {
        elements.append(BSONElement(key: key, value: value))
    }

    public mutating func insert(_ element: BSONElement, at index: Int) {
        elements.insert(element, at: Swift.min(Swift.max(index, 0), elements.count))
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> BSONValue? {
        guard let index = elements.firstIndex(where: { $0.key == key }) else { return nil }
        return elements.remove(at: index).value
    }

    /// Returns a copy with `key` set, keeping other fields in order.
    public func setting(_ key: String, _ value: BSONValue) -> BSONDocument {
        var copy = self
        copy[key] = value
        return copy
    }

    /// Resolves a dotted path through nested documents and array indexes, e.g. `a.b.0.c`.
    public func value(atPath path: String) -> BSONValue? {
        value(atPath: path.split(separator: ".", omittingEmptySubsequences: false).map(String.init))
    }

    public func value(atPath components: [String]) -> BSONValue? {
        guard let first = components.first else { return nil }
        guard let head = self[first] else { return nil }
        var current = head
        for component in components.dropFirst() {
            switch current {
            case let .document(doc):
                guard let next = doc[component] else { return nil }
                current = next
            case let .array(array):
                guard let index = Int(component), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }
}

extension BSONDocument: RandomAccessCollection {
    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }
    public subscript(position: Int) -> BSONElement { elements[position] }
}

extension BSONDocument: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, BSONValue)...) {
        self.elements = elements.map { BSONElement(key: $0.0, value: $0.1) }
    }
}

extension BSONDocument {
    /// Encodes the document to BSON bytes.
    public func bsonBytes() throws -> [UInt8] {
        var writer = BSONWriter()
        try writer.writeDocument(self)
        return writer.bytes
    }

    /// Decodes exactly one document occupying all of `bsonBytes`.
    public init(bsonBytes: [UInt8]) throws {
        var reader = BSONReader(bytes: bsonBytes)
        let document = try reader.readDocument()
        guard reader.isAtEnd else {
            throw BSONError.trailingBytes(count: reader.remaining)
        }
        self = document
    }

    /// Size in bytes of the encoded document, or `nil` if it cannot be encoded.
    public var encodedSize: Int? { try? bsonBytes().count }
}

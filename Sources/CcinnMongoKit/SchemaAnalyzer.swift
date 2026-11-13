import BSON

public struct TypeCount: Sendable, Hashable {
    public let type: BSONType
    public let count: Int
}

public struct SchemaField: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    /// Parent instances (documents or embedded documents) that contain this field.
    public let count: Int
    /// Parent instances examined.
    public let parentCount: Int
    /// Types of the value, most frequent first.
    public let types: [TypeCount]
    /// For arrays: types of the elements, most frequent first.
    public let arrayElementTypes: [TypeCount]
    public let sampleValues: [String]
    public let children: [SchemaField]

    public var presence: Double { parentCount == 0 ? 0 : Double(count) / Double(parentCount) }

    public func fraction(of type: BSONType) -> Double {
        guard count > 0 else { return 0 }
        return Double(types.first { $0.type == type }?.count ?? 0) / Double(count)
    }
}

public struct SchemaResult: Sendable {
    public let sampleSize: Int
    public let fields: [SchemaField]

    /// Every field path (depth first), e.g. for query completion.
    public var allFieldPaths: [String] {
        func walk(_ fields: [SchemaField]) -> [String] { fields.flatMap { [$0.path] + walk($0.children) } }
        return walk(fields)
    }
}

/// Infers field structure from sampled documents (similar to Compass' schema tab).
public enum SchemaAnalyzer {
    public static let maxSampleValues = 5

    public static func analyze(_ documents: [BSONDocument]) -> SchemaResult {
        let root = Accumulator(name: "", path: "")
        for document in documents {
            root.childParentCount += 1
            root.absorb(document, depth: 0)
        }
        return SchemaResult(sampleSize: documents.count, fields: root.orderedChildren.map { $0.build(parentCount: root.childParentCount) })
    }

    private final class Accumulator {
        let name: String
        let path: String
        var count = 0
        var typeCounts: [BSONType: Int] = [:]
        var arrayTypeCounts: [BSONType: Int] = [:]
        var samples: [String] = []
        var children: [String: Accumulator] = [:]
        var childOrder: [String] = []
        var childParentCount = 0

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        var orderedChildren: [Accumulator] { childOrder.compactMap { children[$0] } }

        func child(_ key: String) -> Accumulator {
            if let existing = children[key] { return existing }
            let created = Accumulator(name: key, path: path.isEmpty ? key : "\(path).\(key)")
            children[key] = created
            childOrder.append(key)
            return created
        }

        func absorb(_ document: BSONDocument, depth: Int) {
            guard depth < 20 else { return } // nested schema beyond this depth is not useful to display
            for element in document.elements {
                let field = child(element.key)
                field.record(element.value, depth: depth)
            }
        }

        func record(_ value: BSONValue, depth: Int) {
            count += 1
            typeCounts[value.type, default: 0] += 1
            switch value {
            case let .document(document):
                childParentCount += 1
                absorb(document, depth: depth + 1)
            case let .array(array):
                for element in array.prefix(100) {
                    arrayTypeCounts[element.type, default: 0] += 1
                    if case let .document(document) = element {
                        childParentCount += 1
                        absorb(document, depth: depth + 1)
                    } else {
                        addSample(element)
                    }
                }
            default:
                addSample(value)
            }
        }

        func addSample(_ value: BSONValue) {
            guard samples.count < SchemaAnalyzer.maxSampleValues else { return }
            let text = BSONFormatter.summary(of: value, maxLength: 60)
            if !samples.contains(text) { samples.append(text) }
        }

        func build(parentCount: Int) -> SchemaField {
            SchemaField(name: name, path: path, count: count, parentCount: parentCount,
                        types: Self.sorted(typeCounts), arrayElementTypes: Self.sorted(arrayTypeCounts),
                        sampleValues: samples,
                        children: orderedChildren.map { $0.build(parentCount: childParentCount) })
        }

        static func sorted(_ counts: [BSONType: Int]) -> [TypeCount] {
            counts.map { TypeCount(type: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.type.rawValue < $1.type.rawValue }
        }
    }
}

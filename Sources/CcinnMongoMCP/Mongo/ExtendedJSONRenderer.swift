import BSON
import Foundation

/// Converts BSON to relaxed Extended JSON v2 values.
///
/// `full` is lossless (up to the BSON depth limit). `compact` shortens long strings, large binaries,
/// long arrays and deep nesting, marking every omission in-band; it is used only when a document would
/// not otherwise fit the result budget.
public struct ExtendedJSONRenderer: Sendable {
    public struct Rendered: Sendable {
        public let value: JSONValue
        /// True when anything was shortened or omitted.
        public let wasShortened: Bool
    }

    public var maxStringLength: Int?
    public var maxBinaryBytes: Int?
    public var maxArrayElements: Int?
    public var maxDocumentFields: Int?
    public var maxDepth: Int

    public static let full = ExtendedJSONRenderer(maxStringLength: nil, maxBinaryBytes: nil, maxArrayElements: nil, maxDocumentFields: nil,
                                                  maxDepth: BSONLimits.maximumDepth + 2)
    public static let compact = ExtendedJSONRenderer(maxStringLength: 1000, maxBinaryBytes: 256, maxArrayElements: 50, maxDocumentFields: 200,
                                                     maxDepth: 12)

    public func render(_ document: BSONDocument) -> Rendered {
        var shortened = false
        let value = renderDocument(document, depth: 0, shortened: &shortened)
        return Rendered(value: value, wasShortened: shortened)
    }

    public func render(_ value: BSONValue) -> Rendered {
        var shortened = false
        let rendered = renderValue(value, depth: 0, shortened: &shortened)
        return Rendered(value: rendered, wasShortened: shortened)
    }

    private func renderDocument(_ document: BSONDocument, depth: Int, shortened: inout Bool) -> JSONValue {
        guard depth < maxDepth else {
            shortened = true
            return "{…}"
        }
        var members: [JSONMember] = []
        let shown = maxDocumentFields.map { min($0, document.count) } ?? document.count
        members.reserveCapacity(shown + 1)
        for element in document.elements.prefix(shown) {
            members.append(JSONMember(key: element.key, value: renderValue(element.value, depth: depth + 1, shortened: &shortened)))
        }
        if shown < document.count {
            shortened = true
            members.append(JSONMember(key: "…", value: .string("\(document.count - shown) more fields")))
        }
        return .object(JSONObject(members))
    }

    private func renderValue(_ value: BSONValue, depth: Int, shortened: inout Bool) -> JSONValue {
        switch value {
        case let .double(number):
            if number.isFinite { return .double(number) }
            let text = number.isNaN ? "NaN" : (number < 0 ? "-Infinity" : "Infinity")
            return ["$numberDouble": .string(text)]
        case let .string(text):
            return .string(shorten(text, shortened: &shortened))
        case let .document(document):
            return renderDocument(document, depth: depth, shortened: &shortened)
        case let .array(array):
            guard depth < maxDepth else {
                shortened = true
                return "[…]"
            }
            var elements = array
            var omitted = 0
            if let maxArrayElements, array.count > maxArrayElements {
                elements = Array(array.prefix(maxArrayElements))
                omitted = array.count - maxArrayElements
            }
            var rendered = elements.map { renderValue($0, depth: depth + 1, shortened: &shortened) }
            if omitted > 0 {
                shortened = true
                rendered.append(.string("… [\(omitted) more elements]"))
            }
            return .array(rendered)
        case let .binary(binary):
            if let maxBinaryBytes, binary.data.count > maxBinaryBytes {
                shortened = true
                return .string("<binary subtype \(binary.subtype.description), \(binary.data.count) bytes omitted>")
            }
            return ["$binary": ["base64": .string(binary.data.base64EncodedString()), "subType": .string(binary.subtype.description)]]
        case .undefined:
            return ["$undefined": true]
        case let .objectId(oid):
            return ["$oid": .string(oid.hex)]
        case let .bool(flag):
            return .bool(flag)
        case let .datetime(date):
            let millis = date.millisecondsSinceEpoch
            if millis >= 0, let iso = ISO8601.format(milliseconds: millis, style: .whenNonZero) {
                return ["$date": .string(iso)]
            }
            return ["$date": ["$numberLong": .string(String(millis))]]
        case .null:
            return .null
        case let .regex(regex):
            return ["$regularExpression": ["pattern": .string(shorten(regex.pattern, shortened: &shortened)), "options": .string(regex.options)]]
        case let .dbPointer(pointer):
            return ["$dbPointer": ["$ref": .string(pointer.namespace), "$id": ["$oid": .string(pointer.id.hex)]]]
        case let .javascript(code):
            return ["$code": .string(shorten(code, shortened: &shortened))]
        case let .symbol(symbol):
            return ["$symbol": .string(shorten(symbol, shortened: &shortened))]
        case let .javascriptWithScope(code):
            return ["$code": .string(shorten(code.code, shortened: &shortened)),
                    "$scope": renderDocument(code.scope, depth: depth, shortened: &shortened)]
        case let .int32(number):
            return .int(Int64(number))
        case let .timestamp(timestamp):
            return ["$timestamp": ["t": .int(Int64(timestamp.timestamp)), "i": .int(Int64(timestamp.increment))]]
        case let .int64(number):
            return .int(number)
        case let .decimal128(decimal):
            return ["$numberDecimal": .string(decimal.description)]
        case .minKey:
            return ["$minKey": 1]
        case .maxKey:
            return ["$maxKey": 1]
        }
    }

    private func shorten(_ text: String, shortened: inout Bool) -> String {
        guard let maxStringLength, text.count > maxStringLength else { return text }
        shortened = true
        return String(text.prefix(maxStringLength)) + "… [\(text.count - maxStringLength) more characters]"
    }
}

/// Collects streamed documents until `limit` documents are rendered or the byte budget is full, so a
/// query never holds more than one server batch beyond what is returned.
final class StreamingDocumentBatch: @unchecked Sendable {
    /// Thrown from the batch callback to stop reading (closes the server cursor).
    struct Stop: Error {}

    private let lock = NSLock()
    private let limit: Int
    private let maxBytes: Int
    private var documents: [JSONValue] = []
    private var used = 0
    private var truncated = false
    private var sawMore = false

    init(limit: Int, maxBytes: Int) {
        self.limit = max(1, limit)
        self.maxBytes = maxBytes
    }

    /// Adds a batch; throws `Stop` once nothing more is needed.
    func add(_ batch: [BSONDocument]) throws {
        let done = lock.withLock { () -> Bool in
            for document in batch {
                guard documents.count < limit else {
                    sawMore = true
                    return true
                }
                let full = ExtendedJSONRenderer.full.render(document).value
                let fullSize = JSONWriter.encodedSize(full) + 1
                if used + fullSize <= maxBytes {
                    documents.append(full)
                    used += fullSize
                    continue
                }
                truncated = true
                let compact = ExtendedJSONRenderer.compact.render(document).value
                let compactSize = JSONWriter.encodedSize(compact) + 1
                guard used + compactSize <= maxBytes else {
                    sawMore = true
                    return true
                }
                documents.append(compact)
                used += compactSize
            }
            return false
        }
        if done { throw Stop() }
    }

    var result: (documents: [JSONValue], truncated: Bool, hasMore: Bool) {
        lock.withLock { (documents, truncated, sawMore) }
    }

    var count: Int { lock.withLock { documents.count } }
}

/// Documents rendered within a byte budget (measured on their compact JSON encoding).
public struct DocumentBatch: Sendable {
    public let documents: [JSONValue]
    /// True when documents were dropped or shortened to respect the budget.
    public let truncated: Bool

    public static let defaultMaxBytes = 256 * 1024

    public static func render(_ documents: [BSONDocument], maxBytes: Int = defaultMaxBytes) -> DocumentBatch {
        var rendered: [JSONValue] = []
        rendered.reserveCapacity(documents.count)
        var used = 0
        var truncated = false
        for document in documents {
            let full = ExtendedJSONRenderer.full.render(document).value
            let fullSize = JSONWriter.encodedSize(full) + 1
            if used + fullSize <= maxBytes {
                rendered.append(full)
                used += fullSize
                continue
            }
            truncated = true
            let compact = ExtendedJSONRenderer.compact.render(document).value
            let compactSize = JSONWriter.encodedSize(compact) + 1
            guard used + compactSize <= maxBytes else { break }
            rendered.append(compact)
            used += compactSize
        }
        return DocumentBatch(documents: rendered, truncated: truncated)
    }
}

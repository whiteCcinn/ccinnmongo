import AppKit
import BSON
import GroveKit
import SwiftUI

/// Builds a syntax-coloured `AttributedString` from shell-syntax text (safe off the main actor).
enum HighlightedText {
    static let limit = 120_000

    static func make(_ text: String) -> AttributedString {
        guard text.utf16.count <= limit else { return AttributedString(text) }
        let units = Array(text.utf16)
        var result = AttributedString()
        var cursor = 0
        for span in SyntaxHighlighter.spans(for: text) {
            if span.range.lowerBound > cursor {
                result += AttributedString(String(decoding: units[cursor..<span.range.lowerBound], as: UTF16.self))
            }
            var piece = AttributedString(String(decoding: units[span.range], as: UTF16.self))
            piece.foregroundColor = Color(nsColor: NSColor.syntaxColor(for: span.role))
            result += piece
            cursor = span.range.upperBound
        }
        if cursor < units.count {
            result += AttributedString(String(decoding: units[cursor...], as: UTF16.self))
        }
        return result
    }
}

/// Single-line, type-coloured rendering of a value (tree rows, table cells, schema samples).
struct BSONValueLabel: View {
    let value: BSONValue
    var maxLength = 240

    var body: some View {
        Text(Self.text(for: value, maxLength: maxLength))
            .font(Theme.monospaced)
            .foregroundStyle(Theme.color(for: value.type))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    static func text(for value: BSONValue, maxLength: Int = 240) -> String {
        switch value {
        case let .document(document): return document.isEmpty ? "{}" : "Object"
        case let .array(array): return array.isEmpty ? "[]" : "Array (\(array.count))"
        case let .string(text):
            let flattened = text.replacingOccurrences(of: "\n", with: "↵")
            return "\"" + (flattened.count > maxLength ? String(flattened.prefix(maxLength)) + "…" : flattened) + "\""
        case let .datetime(date):
            if let iso = ISO8601.format(milliseconds: date.millisecondsSinceEpoch) {
                return iso.replacingOccurrences(of: "Z", with: "+00:00")
            }
            return "Date(\(date.millisecondsSinceEpoch))"
        case let .objectId(oid): return "ObjectId('\(oid.hex)')"
        case let .int64(number): return String(number)
        case let .int32(number): return String(number)
        case let .decimal128(number): return number.description
        default: return BSONFormatter.summary(of: value, maxLength: maxLength)
        }
    }
}

/// A flattened, visible row of the document tree.
struct TreeRow: Identifiable {
    let id: String
    let key: String
    let value: BSONValue
    let depth: Int
    let isExpanded: Bool

    var isExpandable: Bool {
        switch value {
        case let .document(document): !document.isEmpty
        case let .array(array): !array.isEmpty
        default: false
        }
    }

    static let maxChildren = 200

    /// Visible rows given the set of expanded paths. Children beyond `maxChildren` are summarised.
    static func rows(for document: BSONDocument, expanded: Set<String>, topLevelLimit: Int?) -> (rows: [TreeRow], hiddenTopLevel: Int) {
        var rows: [TreeRow] = []
        func visit(_ elements: [(String, BSONValue)], parent: String, depth: Int, limit: Int?) -> Int {
            let shown = limit.map { min($0, elements.count) } ?? elements.count
            for (key, value) in elements.prefix(shown) {
                let path = parent.isEmpty ? key : "\(parent).\(key)"
                let isOpen = expanded.contains(path)
                rows.append(TreeRow(id: path, key: key, value: value, depth: depth, isExpanded: isOpen))
                guard isOpen, depth < 40 else { continue }
                switch value {
                case let .document(nested):
                    let hidden = visit(nested.elements.map { ($0.key, $0.value) }, parent: path, depth: depth + 1, limit: maxChildren)
                    if hidden > 0 { rows.append(TreeRow(id: path + ".…", key: "…", value: .string("\(hidden) more fields"), depth: depth + 1, isExpanded: false)) }
                case let .array(array):
                    let hidden = visit(array.enumerated().map { (String($0.offset), $0.element) }, parent: path, depth: depth + 1, limit: maxChildren)
                    if hidden > 0 { rows.append(TreeRow(id: path + ".…", key: "…", value: .string("\(hidden) more items"), depth: depth + 1, isExpanded: false)) }
                default:
                    break
                }
            }
            return elements.count - shown
        }
        let hidden = visit(document.elements.map { ($0.key, $0.value) }, parent: "", depth: 0, limit: topLevelLimit)
        return (rows, hidden)
    }
}

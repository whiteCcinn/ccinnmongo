import BSON
import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jsonArray = "JSON array"
    case ndjson = "JSON lines (NDJSON)"
    case csv = "CSV"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .jsonArray: "json"
        case .ndjson: "ndjson"
        case .csv: "csv"
        }
    }
}

/// Incremental Extended JSON writer, so large exports can stream batch by batch.
public struct DocumentExportWriter: Sendable {
    public enum Format: Sendable {
        case jsonArray
        case ndjson
    }

    public let format: Format
    private var wroteAny = false
    private let pretty = BSONFormatter(style: .relaxedExtendedJSON, indent: 2)
    private let compact = BSONFormatter(style: .relaxedExtendedJSON)

    public init(format: Format) {
        self.format = format
    }

    public mutating func begin() -> String {
        format == .jsonArray ? "[" : ""
    }

    public mutating func write(_ documents: [BSONDocument]) -> String {
        var output = ""
        for document in documents {
            switch format {
            case .jsonArray:
                output += wroteAny ? ",\n" : "\n"
                output += pretty.format(document).split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  " + $0 }.joined(separator: "\n")
            case .ndjson:
                output += compact.format(document) + "\n"
            }
            wroteAny = true
        }
        return output
    }

    public mutating func finish() -> String {
        format == .jsonArray ? (wroteAny ? "\n]\n" : "]\n") : ""
    }
}

/// CSV with one column per flattened field path (`a.b.c`); arrays are written as JSON.
public enum CSVExporter {
    public static func fieldPaths(of documents: [BSONDocument]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for document in documents {
            for (path, _) in flatten(document) where seen.insert(path).inserted {
                order.append(path)
            }
        }
        return order
    }

    public static func header(_ paths: [String]) -> String {
        paths.map(escape).joined(separator: ",") + "\n"
    }

    public static func row(_ document: BSONDocument, paths: [String]) -> String {
        var values: [String: BSONValue] = [:]
        for (path, value) in flatten(document) where values[path] == nil { values[path] = value }
        return paths.map { values[$0].map(cell).map(escape) ?? "" }.joined(separator: ",") + "\n"
    }

    static func flatten(_ document: BSONDocument, prefix: String = "", depth: Int = 0) -> [(String, BSONValue)] {
        var result: [(String, BSONValue)] = []
        for element in document.elements {
            let path = prefix.isEmpty ? element.key : "\(prefix).\(element.key)"
            if case let .document(nested) = element.value, !nested.isEmpty, depth < 32 {
                result += flatten(nested, prefix: path, depth: depth + 1)
            } else {
                result.append((path, element.value))
            }
        }
        return result
    }

    static func cell(_ value: BSONValue) -> String {
        switch value {
        case let .string(text):
            // Neutralise spreadsheet formulas (CSV injection): =, +, -, @, tab and CR prefixes.
            if let first = text.first, "=+-@\t\r".contains(first) { "'" + text } else { text }
        case let .int32(number): String(number)
        case let .int64(number): String(number)
        case let .double(number): number.isFinite ? number.description : (number.isNaN ? "NaN" : (number < 0 ? "-Infinity" : "Infinity"))
        case let .decimal128(number): number.description
        case let .bool(flag): flag ? "true" : "false"
        case .null, .undefined: ""
        case let .objectId(oid): oid.hex
        case let .datetime(date): ISO8601.format(milliseconds: date.millisecondsSinceEpoch) ?? String(date.millisecondsSinceEpoch)
        case let .array(array): BSONFormatter(style: .relaxedExtendedJSON).format(array: array)
        default: BSONFormatter(style: .relaxedExtendedJSON).format(value)
        }
    }

    static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum DocumentImporter {
    /// Parses a JSON array or newline-delimited documents (Extended JSON or shell syntax).
    public static func parse(_ text: String) throws -> [BSONDocument] {
        try ShellSyntax.parseDocumentSequence(text)
    }
}

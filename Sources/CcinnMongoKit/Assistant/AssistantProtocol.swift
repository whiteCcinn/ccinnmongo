import BSON
import Foundation

public struct AssistantProtocolError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public let rawReply: String?

    public init(_ message: String, rawReply: String? = nil) {
        self.message = message
        self.rawReply = rawReply
    }

    public var errorDescription: String? { message }
}

/// A read operation the assistant proposes or asks CcinnMongo to run.
public struct AssistantQuery: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case find
        case count
        case aggregate
    }

    public var kind: Kind
    public var filter: BSONDocument
    public var projection: BSONDocument?
    public var sort: BSONDocument?
    public var limit: Int?
    public var pipeline: [BSONDocument]

    public init(kind: Kind, filter: BSONDocument = [:], projection: BSONDocument? = nil, sort: BSONDocument? = nil,
                limit: Int? = nil, pipeline: [BSONDocument] = []) {
        self.kind = kind
        self.filter = filter
        self.projection = projection
        self.sort = sort
        self.limit = limit
        self.pipeline = pipeline
    }

    /// mongo-shell rendering for display, e.g. `db.orders.find({…}).sort({…}).limit(5)`.
    public func shellText(collection: String) -> String {
        let formatter = BSONFormatter(style: .shell)
        let target = "db.\(collection)"
        switch kind {
        case .find:
            var text = "\(target).find(\(formatter.format(filter))"
            if let projection, !projection.isEmpty { text += ", \(formatter.format(projection))" }
            text += ")"
            if let sort, !sort.isEmpty { text += ".sort(\(formatter.format(sort)))" }
            if let limit { text += ".limit(\(limit))" }
            return text
        case .count:
            return "\(target).count(\(formatter.format(filter)))"
        case .aggregate:
            return "\(target).aggregate(\(BSONFormatter(style: .shell, indent: 2).format(array: pipeline.map(BSONValue.document))))"
        }
    }
}

public enum AssistantReply: Sendable, Equatable {
    /// The agent wants CcinnMongo to run a read-only query (or, in generate modes, proposes it).
    case query(AssistantQuery, reason: String?)
    /// Final answer, optionally with a query the user can apply.
    case answer(text: String, suggestion: AssistantQuery?)
}

/// Parses agent replies. Tolerates code fences and surrounding prose; query parts may be mongo-shell
/// syntax strings (`"{total: {$gt: 100}}"`) or JSON/Extended JSON objects.
public enum AssistantReplyParser {
    public static func parse(_ text: String) throws -> AssistantReply {
        guard let json = extractJSONObject(from: text) else {
            throw AssistantProtocolError("The reply did not contain a JSON object.", rawReply: text)
        }
        let document: BSONDocument
        do {
            document = try ShellSyntax.parseDocument(json)
        } catch {
            throw AssistantProtocolError("The reply JSON could not be parsed: \(error)", rawReply: text)
        }
        switch document["type"]?.stringValue {
        case "query":
            guard let query = document["query"]?.documentValue else {
                throw AssistantProtocolError("A \"query\" reply must contain a \"query\" object.", rawReply: text)
            }
            return .query(try parseQuery(query, raw: text), reason: document["reason"]?.stringValue)
        case "answer":
            guard let answer = document["text"]?.stringValue else {
                throw AssistantProtocolError("An \"answer\" reply must contain \"text\".", rawReply: text)
            }
            let suggestion = document["query"]?.documentValue.flatMap { try? parseQuery($0, raw: text) }
            return .answer(text: answer, suggestion: suggestion)
        default:
            throw AssistantProtocolError("The reply \"type\" must be \"query\" or \"answer\".", rawReply: text)
        }
    }

    static func parseQuery(_ document: BSONDocument, raw: String) throws -> AssistantQuery {
        let kindName = document["kind"]?.stringValue ?? "find"
        guard let kind = AssistantQuery.Kind(rawValue: kindName) else {
            throw AssistantProtocolError("Unknown query kind \"\(kindName)\".", rawReply: raw)
        }
        do {
            var query = AssistantQuery(kind: kind)
            query.filter = try documentField(document["filter"]) ?? [:]
            query.projection = try documentField(document["projection"])
            query.sort = try documentField(document["sort"])
            query.limit = document["limit"]?.intValue
            query.pipeline = try pipelineField(document["pipeline"])
            if kind == .aggregate, query.pipeline.isEmpty {
                throw AssistantProtocolError("An aggregate query needs a non-empty \"pipeline\".", rawReply: raw)
            }
            return query
        } catch let error as SyntaxError {
            throw AssistantProtocolError("A query field is not valid MongoDB syntax: \(error)", rawReply: raw)
        }
    }

    private static func documentField(_ value: BSONValue?) throws -> BSONDocument? {
        switch value {
        case nil, .null?: return nil
        case let .document(document)?: return document
        case let .string(text)?:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : try ShellSyntax.parseDocument(trimmed)
        default:
            throw AssistantProtocolError("Expected a document or a string in shell syntax.")
        }
    }

    private static func pipelineField(_ value: BSONValue?) throws -> [BSONDocument] {
        let values: [BSONValue]
        switch value {
        case nil, .null?: return []
        case let .array(array)?: values = array
        case let .string(text)?: values = try ShellSyntax.parseArray(text, allowEmpty: true)
        default: throw AssistantProtocolError("\"pipeline\" must be an array.")
        }
        return try values.map { value in
            guard case let .document(stage) = value else { throw AssistantProtocolError("Every pipeline stage must be a document.") }
            return stage
        }
    }

    /// Returns the first balanced `{…}` (respecting double-quoted strings) that parses and has a "type" key.
    public static func extractJSONObject(from text: String) -> String? {
        let units = Array(text.utf16)
        var candidates = 0
        var start = 0
        while start < units.count, candidates < 64 {
            guard units[start] == 0x7B else {
                start += 1
                continue
            }
            candidates += 1
            if let end = matchingBrace(units, from: start) {
                let candidate = String(decoding: units[start...end], as: UTF16.self)
                if let document = try? ShellSyntax.parseDocument(candidate), document["type"] != nil {
                    return candidate
                }
            }
            start += 1
        }
        return nil
    }

    private static func matchingBrace(_ units: [UInt16], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var index = start
        while index < units.count {
            let unit = units[index]
            if inString {
                if unit == 0x5C {
                    index += 2
                    continue
                }
                if unit == 0x22 { inString = false }
            } else if unit == 0x22 {
                inString = true
            } else if unit == 0x7B {
                depth += 1
            } else if unit == 0x7D {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}

/// Read-only guard for everything the agent asks CcinnMongo to execute.
public enum QuerySafetyPolicy {
    public static let maxDocuments = 50
    public static let maxTimeMS = 15_000
    static let forbiddenStages: Set<String> = ["$out", "$merge"]
    static let forbiddenOperators: Set<String> = ["$where", "$function", "$accumulator"]

    /// Validates and returns a bounded copy of `query`, or throws if it could write data or run JavaScript.
    public static func validate(_ query: AssistantQuery) throws -> AssistantQuery {
        try scan(.document(query.filter), depth: 0)
        if let projection = query.projection { try scan(.document(projection), depth: 0) }
        for stage in query.pipeline { try scan(.document(stage), depth: 0) }

        var bounded = query
        switch query.kind {
        case .find:
            bounded.limit = min(max(1, query.limit ?? maxDocuments), maxDocuments)
        case .aggregate:
            bounded.pipeline.append(["$limit": .int(maxDocuments)])
        case .count:
            break
        }
        return bounded
    }

    private static func scan(_ value: BSONValue, depth: Int) throws {
        guard depth < 64 else { throw AssistantProtocolError("The query is nested too deeply.") }
        switch value {
        case let .document(document):
            for element in document.elements {
                if forbiddenStages.contains(element.key) {
                    throw AssistantProtocolError("\(element.key) writes data and is not allowed for assistant queries.")
                }
                if forbiddenOperators.contains(element.key) {
                    throw AssistantProtocolError("\(element.key) runs server-side JavaScript and is not allowed for assistant queries.")
                }
                try scan(element.value, depth: depth + 1)
            }
        case let .array(array):
            for element in array { try scan(element, depth: depth + 1) }
        case .javascript, .javascriptWithScope:
            throw AssistantProtocolError("JavaScript values are not allowed in assistant queries.")
        default:
            break
        }
    }
}

public struct AssistantQueryResult: Sendable {
    public let documents: [BSONDocument]
    public let count: Int64?

    public init(documents: [BSONDocument], count: Int64?) {
        self.documents = documents
        self.count = count
    }
}

/// Compact, size-bounded rendering of query results for the agent.
public enum AssistantResultFormatter {
    public static let maxBytes = 12_000
    public static let maxDocuments = 20
    static let maxStringLength = 200

    public static func summary(_ result: AssistantQueryResult) -> String {
        if let count = result.count { return "{\"count\": \(count)}" }
        let formatter = BSONFormatter(style: .relaxedExtendedJSON)
        var lines = ["\(result.documents.count) document(s) returned:"]
        var bytes = lines[0].utf8.count
        var shown = 0
        for document in result.documents.prefix(maxDocuments) {
            let line = formatter.format(truncated(document, depth: 0))
            guard bytes + line.utf8.count <= maxBytes else { break }
            lines.append(line)
            bytes += line.utf8.count + 1
            shown += 1
        }
        if shown < result.documents.count {
            lines.append("… (truncated: showing \(shown) of \(result.documents.count) documents)")
        }
        return lines.joined(separator: "\n")
    }

    private static func truncated(_ document: BSONDocument, depth: Int) -> BSONDocument {
        BSONDocument(document.elements.prefix(60).map { BSONElement(key: $0.key, value: truncated($0.value, depth: depth + 1)) })
    }

    private static func truncated(_ value: BSONValue, depth: Int) -> BSONValue {
        switch value {
        case let .string(text) where text.count > maxStringLength:
            return .string(String(text.prefix(maxStringLength)) + "…")
        case let .document(document) where depth < 6:
            return .document(truncated(document, depth: depth))
        case let .array(array) where depth < 6:
            return .array(array.prefix(20).map { truncated($0, depth: depth + 1) })
        case .document, .array:
            return .string("…")
        case let .binary(binary) where binary.data.count > 64:
            return .string("<binary \(binary.data.count) bytes>")
        default:
            return value
        }
    }
}

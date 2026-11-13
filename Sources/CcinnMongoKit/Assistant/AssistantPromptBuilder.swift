import BSON
import Foundation
import MongoKit

/// Builds prompts. Inputs are limited to `AssistantContext` + transcript, which by construction carry
/// no hosts, connection strings or credentials.
public enum AssistantPromptBuilder {
    static let queryShape = """
    {"kind": "find" | "count" | "aggregate",
     "filter": "<MongoDB shell syntax document, e.g. {status: 'paid', total: {$gt: 100}}>",
     "projection": "<optional shell syntax document>", "sort": "<optional shell syntax document>",
     "limit": <optional integer>,
     "pipeline": "<for aggregate: shell syntax array of stages>"}
    """

    public static func systemPrompt(for mode: AssistantMode) -> String {
        var text = """
        You are the query assistant inside CcinnMongo, a desktop MongoDB client.
        You have no tools, files or network access: you only read the context provided and reply.
        Always reply with exactly ONE JSON object and no other text (no Markdown fences, no explanations outside the JSON).
        Write query values in MongoDB shell syntax inside JSON strings; you may use ObjectId(), ISODate(), NumberLong(), NumberDecimal() and /regex/i.
        Only use operators supported by the server version stated in the context.
        Never propose operations that modify data unless the user explicitly asks, and even then only describe them in "text".

        """
        switch mode {
        case .generateFind:
            text += """
            Task: translate the user's request into a single find query for the collection.
            Reply: {"type": "query", "reason": "<one short sentence>", "query": \(queryShape)} with "kind": "find" (or "count" if they only want a number).
            """
        case .generatePipeline:
            text += """
            Task: translate the user's request into an aggregation pipeline for the collection.
            Reply: {"type": "query", "reason": "<one short sentence>", "query": \(queryShape)} with "kind": "aggregate" and a "pipeline".
            """
        case let .conversation(allowQueries):
            if allowQueries {
                text += """
                Task: answer the user's questions about the data. You may ask CcinnMongo to run read-only queries for you.
                To run a query reply: {"type": "query", "reason": "<why>", "query": \(queryShape)}
                CcinnMongo runs it (results are capped at 50 documents and 15 seconds) and sends you the result; then continue.
                Prefer "count" or aggregate summaries over fetching many documents. Use at most a few queries.
                When you can answer, reply: {"type": "answer", "text": "<concise answer in Markdown>", "query": <optional query object the user can reuse>}
                Answer in the language the user writes in.
                """
            } else {
                text += """
                Task: help the user with queries for this collection. You cannot run queries.
                Reply: {"type": "answer", "text": "<concise answer in Markdown>", "query": <optional query object>}
                Answer in the language the user writes in.
                """
            }
        }
        return text
    }

    public static func prompt(mode: AssistantMode, context: AssistantContext, history: [AssistantTurn], request: String) -> String {
        prompt(mode: mode, context: context, transcript: history + [.user(request)])
    }

    public static func prompt(mode: AssistantMode, context: AssistantContext, transcript: [AssistantTurn]) -> String {
        var sections: [String] = []
        var collection = "## Collection\n\(context.namespace.fullName)"
        if let count = context.documentCount { collection += " (about \(count) documents)" }
        sections.append(collection)

        var server = "## Server\nMongoDB \(context.serverVersion) (wire version \(context.capabilities.maxWireVersion))."
        let hints = versionHints(context.capabilities)
        if !hints.isEmpty {
            server += "\n" + hints.map { "- Not available on this server: \($0)" }.joined(separator: "\n")
        }
        sections.append(server)

        if let schema = context.schema, !schema.fields.isEmpty {
            sections.append("## Fields (sampled \(schema.sampleSize) documents: path — types — presence)\n" + schemaSummary(schema))
        }
        if !context.indexes.isEmpty {
            sections.append("## Indexes\n" + context.indexes.joined(separator: ", "))
        }
        if !context.samples.isEmpty {
            let formatter = BSONFormatter(style: .shell)
            let samples = context.samples.prefix(3).map { String(formatter.format($0).prefix(1_500)) }
            sections.append("## Sample documents\n" + samples.joined(separator: "\n"))
        }
        if let query = context.currentQuery, !query.isDefault {
            var parts: [String] = []
            if !query.filter.isEmpty { parts.append("filter: \(query.filter)") }
            if !query.projection.isEmpty { parts.append("projection: \(query.projection)") }
            if !query.sort.isEmpty { parts.append("sort: \(query.sort)") }
            if query.limit > 0 { parts.append("limit: \(query.limit)") }
            if !parts.isEmpty { sections.append("## Query currently in the query bar\n" + parts.joined(separator: "\n")) }
        }
        sections.append("## Conversation\n" + render(transcript, collection: context.namespace.collection))
        switch mode {
        case .generateFind: sections.append("Reply now with the JSON object for the latest request (a find query).")
        case .generatePipeline: sections.append("Reply now with the JSON object for the latest request (an aggregation pipeline).")
        case .conversation: sections.append("Reply now with exactly one JSON object (\"query\" or \"answer\").")
        }
        return sections.joined(separator: "\n\n")
    }

    public static func schemaSummary(_ schema: SchemaResult, limit: Int = 120) -> String {
        var lines: [String] = []
        func walk(_ fields: [SchemaField]) {
            for field in fields where lines.count < limit {
                let types = field.types.map(\.type.displayName).joined(separator: "|")
                lines.append("- \(field.path) — \(types) — \(Int((field.presence * 100).rounded()))%")
                walk(field.children)
            }
        }
        walk(schema.fields)
        return lines.joined(separator: "\n")
    }

    public static func versionHints(_ capabilities: ServerCapabilities) -> [String] {
        let wire = capabilities.maxWireVersion
        var hints: [String] = []
        if wire < 4 { hints.append("$sample, $lookup, $indexStats and the find command (need MongoDB 3.2)") }
        if wire < 5 { hints.append("collation, $count, $facet, $bucket, $addFields, $replaceRoot, $sortByCount, $graphLookup (need MongoDB 3.4)") }
        if wire < 6 { hints.append("$expr in queries, $lookup with let/pipeline, $mergeObjects, $arrayToObject (need MongoDB 3.6)") }
        if wire < 7 { hints.append("$convert, $toString, $toInt, $toDate, $toDouble and other type conversion operators (need MongoDB 4.0)") }
        if wire < 8 { hints.append("$set/$unset stages, $merge, $replaceWith (need MongoDB 4.2)") }
        if wire < 13 { hints.append("$setWindowFields, $dateAdd, $dateDiff, $dateTrunc (need MongoDB 5.0)") }
        return hints
    }

    static func render(_ transcript: [AssistantTurn], collection: String) -> String {
        // Keep the most recent turns when the conversation grows long.
        let recent = transcript.suffix(24)
        return recent.map { turn -> String in
            switch turn {
            case let .user(text): return "User: \(text)"
            case let .agentQuery(query, reason):
                return "Assistant (requested query\(reason.map { ": \($0)" } ?? "")): \(query.shellText(collection: collection))"
            case let .queryResult(summary): return "CcinnMongo (query result): \(summary)"
            case let .queryRejected(message): return "CcinnMongo: \(message)"
            case let .agentAnswer(text): return "Assistant: \(text)"
            case let .protocolCorrection(message): return "CcinnMongo: \(message)"
            }
        }.joined(separator: "\n\n")
    }
}

/// Static description of every MongoDB tool: names, descriptions, JSON Schemas and annotations.
enum MongoToolCatalog {
    enum Kind: Sendable {
        case connections
        case read
        case write
    }

    struct Spec: Sendable {
        let name: String
        let title: String
        let description: String
        let kind: Kind
        let idempotent: Bool
        let properties: [(String, JSONValue)]
        let required: [String]

        var argumentNames: [String] { properties.map(\.0) }

        var definition: MCPToolDefinition {
            let schema: JSONValue = [
                "type": "object",
                "properties": .object(JSONObject(properties.map { JSONMember(key: $0.0, value: $0.1) })),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": false,
            ]
            return MCPToolDefinition(name: name, title: title, description: description, inputSchema: schema,
                                     readOnly: kind != .write, destructive: kind == .write, idempotent: idempotent)
        }
    }

    // MARK: Limits

    static let defaultLimit = 200
    static let maxLimit = 1_000
    static let defaultTimeoutMS = 30_000
    static let maxTimeoutMS = 120_000
    static let defaultSampleSize = 100
    static let maxSampleSize = 1_000
    static let defaultMaxDocuments = 100
    static let maxMaxDocuments = 10_000
    static let maxSkip = Int(Int32.max)

    // MARK: Properties

    static let connection: (String, JSONValue) = ("connection", [
        "type": "string",
        "description": "Saved connection name or id from list_connections. Optional when only one connection is enabled or the server was started with --profile.",
    ])
    static let database: (String, JSONValue) = ("database", ["type": "string", "description": "Database name."])
    static let collection: (String, JSONValue) = ("collection", ["type": "string", "description": "Collection or view name."])
    static let timeout: (String, JSONValue) = ("timeout_ms", [
        "type": "integer", "minimum": 1, "maximum": .int(maxTimeoutMS),
        "description": .string("Time limit in milliseconds (default \(defaultTimeoutMS), max \(maxTimeoutMS))."),
    ])

    static func documentProperty(_ name: String, _ description: String) -> (String, JSONValue) {
        (name, [
            "type": ["object", "string"],
            "description": .string(description + " Give an Extended JSON object (e.g. {\"_id\": {\"$oid\": \"…\"}}) or a mongo-shell syntax string (e.g. \"{ total: { $gt: 100 } }\")."),
        ])
    }

    static let filter = documentProperty("filter", "Query filter; omit to match all documents.")
    static let writeFilter = documentProperty("filter", "Filter selecting the documents to change; {} matches every document.")
    static let projection = documentProperty("projection", "Fields to include or exclude, e.g. {\"name\": 1, \"_id\": 0}.")
    static let sort = documentProperty("sort", "Sort order, e.g. {\"createdAt\": -1}. Key order is significant.")
    static let skip: (String, JSONValue) = ("skip", ["type": "integer", "minimum": 0, "maximum": .int(maxSkip), "description": "Number of documents to skip (default 0)."])
    static let limit: (String, JSONValue) = ("limit", [
        "type": "integer", "minimum": 1, "maximum": .int(maxLimit),
        "description": .string("Maximum documents to return (default \(defaultLimit), max \(maxLimit)). The result reports has_more when more exist."),
    ])
    static let pipeline: (String, JSONValue) = ("pipeline", [
        "type": ["array", "string"],
        "items": ["type": "object"],
        "description": "Aggregation pipeline: an array of stage objects (Extended JSON) or a mongo-shell syntax string. $out, $merge, $changeStream and server-side JavaScript are rejected.",
    ])
    static let maxDocuments: (String, JSONValue) = ("max_documents", [
        "type": "integer", "minimum": 1, "maximum": .int(maxMaxDocuments),
        "description": .string("Refuse to change anything if more documents match (default \(defaultMaxDocuments), max \(maxMaxDocuments))."),
    ])
    static let dryRun: (String, JSONValue) = ("dry_run", ["type": "boolean", "description": "Only count the matching documents; change nothing (default false)."])

    // MARK: Tools

    static let readSpecs: [Spec] = [
        Spec(name: "list_connections", title: "List connections",
             description: "Lists the saved CcinnMongo connections the user enabled for AI access, with hosts, access level and MongoDB details. Never returns credentials.",
             kind: .connections, idempotent: true, properties: [], required: []),
        Spec(name: "server_info", title: "Server information",
             description: "Returns the MongoDB server version, wire protocol, topology and unavailable_features: operators and stages this server version does not support. Call it before writing queries for an unfamiliar connection.",
             kind: .read, idempotent: true, properties: [connection, timeout], required: []),
        Spec(name: "list_databases", title: "List databases",
             description: "Lists databases with their size on disk.",
             kind: .read, idempotent: true, properties: [connection, timeout], required: []),
        Spec(name: "list_collections", title: "List collections",
             description: "Lists collections and views of a database (system collections only when include_system is true).",
             kind: .read, idempotent: true,
             properties: [connection, database,
                          ("include_system", ["type": "boolean", "description": "Include system.* collections (default false)."]),
                          timeout],
             required: ["database"]),
        Spec(name: "collection_schema", title: "Collection schema",
             description: "Infers field paths, BSON types (as $type aliases), presence and sample values from a random sample of documents.",
             kind: .read, idempotent: false,
             properties: [connection, database, collection,
                          ("sample_size", ["type": "integer", "minimum": 1, "maximum": .int(maxSampleSize),
                                           "description": .string("Documents to sample (default \(defaultSampleSize), max \(maxSampleSize)).")]),
                          timeout],
             required: ["database", "collection"]),
        Spec(name: "list_indexes", title: "List indexes",
             description: "Lists the indexes of a collection with their keys, options and, where the server supports it, usage counts.",
             kind: .read, idempotent: true, properties: [connection, database, collection, timeout], required: ["database", "collection"]),
        Spec(name: "find", title: "Find documents",
             description: "Returns documents matching a filter as relaxed Extended JSON, with optional projection, sort, skip and limit.",
             kind: .read, idempotent: true,
             properties: [connection, database, collection, filter, projection, sort, skip, limit, timeout],
             required: ["database", "collection"]),
        Spec(name: "aggregate", title: "Aggregate",
             description: "Runs a read-only aggregation pipeline and returns the results as relaxed Extended JSON. Use server_info to check which stages the server supports.",
             kind: .read, idempotent: true,
             properties: [connection, database, collection, pipeline, limit,
                          ("allow_disk_use", ["type": "boolean", "description": "Let large $group/$sort stages use temporary files on the server (default false)."]),
                          timeout],
             required: ["database", "collection", "pipeline"]),
        Spec(name: "count_documents", title: "Count documents",
             description: "Counts the documents matching a filter.",
             kind: .read, idempotent: true, properties: [connection, database, collection, filter, timeout], required: ["database", "collection"]),
        Spec(name: "explain", title: "Explain query",
             description: "Explains how the server executes a find (filter/projection/sort/skip/limit) or an aggregation pipeline, with execution statistics: indexes used, collection scans, in-memory sorts, documents and keys examined.",
             kind: .read, idempotent: false,
             properties: [connection, database, collection, filter, projection, sort, skip,
                          ("limit", ["type": "integer", "minimum": 1, "maximum": .int(maxLimit), "description": "Limit for the explained find."]),
                          ("pipeline", ["type": ["array", "string"], "items": ["type": "object"],
                                        "description": "Explain this aggregation pipeline instead of a find (do not combine with find arguments)."]),
                          ("include_raw", ["type": "boolean", "description": "Also return the raw explain output (default false)."]),
                          timeout],
             required: ["database", "collection"]),
    ]

    static let writeSpecs: [Spec] = [
        Spec(name: "insert_one", title: "Insert one document",
             description: "Inserts exactly one document (an _id is added when missing). Only for connections with read & write AI access.",
             kind: .write, idempotent: false,
             properties: [connection, database, collection,
                          documentProperty("document", "The document to insert."), timeout],
             required: ["database", "collection", "document"]),
        Spec(name: "update_many", title: "Update documents",
             description: "Applies update operators (e.g. {\"$set\": {…}}) to every document matching the filter. Counts the matches first and changes nothing when more than max_documents match; use dry_run to preview. Only for connections with read & write AI access.",
             kind: .write, idempotent: false,
             properties: [connection, database, collection, writeFilter,
                          documentProperty("update", "Update operators such as {\"$set\": {\"status\": \"shipped\"}}; replacement documents are rejected."),
                          ("upsert", ["type": "boolean", "description": "Insert a document when nothing matches (default false)."]),
                          dryRun, maxDocuments, timeout],
             required: ["database", "collection", "filter", "update"]),
        Spec(name: "delete_many", title: "Delete documents",
             description: "Deletes every document matching the filter. Counts the matches first and deletes nothing when more than max_documents match; use dry_run to preview. Only for connections with read & write AI access.",
             kind: .write, idempotent: false,
             properties: [connection, database, collection, writeFilter, dryRun, maxDocuments, timeout],
             required: ["database", "collection", "filter"]),
    ]

    static let all: [String: Spec] = Dictionary(uniqueKeysWithValues: (readSpecs + writeSpecs).map { ($0.name, $0) })
}

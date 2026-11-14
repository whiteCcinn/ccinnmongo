import BSON
import CcinnMongoKit

/// A failure while executing a tool, reported to the client as an `isError` result.
public struct MCPToolFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Decides, before anything reaches the server, whether an operation requested over MCP is allowed.
///
/// Builds on the assistant's `QuerySafetyPolicy` (no `$out`/`$merge`, no server-side JavaScript at any
/// depth) and adds MCP-specific rules: no change streams and no credential-bearing collections.
public enum MCPQueryPolicy {
    /// Collections whose documents contain credentials or replicate them: users (including the copies kept by the
    /// 2.6/3.0 auth schema upgrade), cluster HMAC keys (also `config.external_validation_keys` on sharded 5.0+)
    /// and the oplog.
    static let protectedCollections: Set<String> = ["system.users", "system.backup_users", "system.new_users", "system.keys",
                                                    "external_validation_keys", "oplog.rs", "oplog.$main"]
    /// Stages that never terminate on their own.
    static let unboundedStages: Set<String> = ["$changeStream"]
    /// Keys whose string value names another collection inside a pipeline.
    static let collectionReferenceKeys: Set<String> = ["from", "coll", "$unionWith"]

    public static func checkReadableNamespace(database: String, collection: String) throws {
        if protectedCollections.contains(collection) {
            throw MCPToolFailure("\(database).\(collection) holds credentials or replicated writes and cannot be read over MCP.")
        }
    }

    public static func checkRead(filter: BSONDocument, projection: BSONDocument?, sort: BSONDocument?) throws {
        try checkAssistantPolicy(AssistantQuery(kind: .find, filter: filter, projection: projection, sort: sort))
        for document in [filter, projection, sort].compactMap({ $0 }) {
            try scan(.document(document), depth: 0)
        }
    }

    public static func checkPipeline(_ pipeline: [BSONDocument]) throws {
        try checkAssistantPolicy(AssistantQuery(kind: .aggregate, pipeline: pipeline))
        for stage in pipeline { try scan(.document(stage), depth: 0) }
    }

    /// Documents written by the write tools must not carry server-side JavaScript either.
    public static func checkWrite(_ document: BSONDocument) throws {
        try checkAssistantPolicy(AssistantQuery(kind: .find, filter: document))
    }

    private static func checkAssistantPolicy(_ query: AssistantQuery) throws {
        do {
            try QuerySafetyPolicy.check(query)
        } catch let error as AssistantProtocolError {
            throw MCPToolFailure(error.message.replacingOccurrences(of: "assistant queries", with: "MCP queries"))
        }
    }

    private static func scan(_ value: BSONValue, depth: Int) throws {
        guard depth < 64 else { throw MCPToolFailure("The query is nested too deeply.") }
        switch value {
        case let .document(document):
            for element in document.elements {
                if unboundedStages.contains(element.key) {
                    throw MCPToolFailure("\(element.key) opens a cursor that never ends and is not allowed over MCP.")
                }
                if collectionReferenceKeys.contains(element.key), case let .string(name) = element.value,
                   protectedCollections.contains(name) {
                    throw MCPToolFailure("\(name) holds credentials or replicated writes and cannot be read over MCP.")
                }
                try scan(element.value, depth: depth + 1)
            }
        case let .array(array):
            for element in array { try scan(element, depth: depth + 1) }
        default:
            break
        }
    }
}

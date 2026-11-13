import BSON
import Foundation
import MongoKit

/// Executes (already safety-checked) assistant queries with server-side time limits.
public struct MongoAssistantExecutor: AssistantQueryExecuting {
    public let client: MongoClient
    public let namespace: MongoNamespace

    public init(client: MongoClient, namespace: MongoNamespace) {
        self.client = client
        self.namespace = namespace
    }

    public func execute(_ query: AssistantQuery) async throws -> AssistantQueryResult {
        let bounded = try QuerySafetyPolicy.validate(query)
        switch bounded.kind {
        case .find:
            let documents = try await client.find(namespace, options: FindOptions(filter: bounded.filter, projection: bounded.projection,
                                                                                   sort: bounded.sort, limit: bounded.limit ?? QuerySafetyPolicy.maxDocuments,
                                                                                   maxTimeMS: QuerySafetyPolicy.maxTimeMS))
            return AssistantQueryResult(documents: documents, count: nil)
        case .count:
            guard let count = try await client.count(namespace, filter: bounded.filter,
                                                      options: CountOptions(maxTimeMS: QuerySafetyPolicy.maxTimeMS)) else {
                throw MongoError(.command, "The count exceeded the \(QuerySafetyPolicy.maxTimeMS / 1000)-second time limit")
            }
            return AssistantQueryResult(documents: [], count: count)
        case .aggregate:
            let documents = try await client.aggregate(namespace, pipeline: bounded.pipeline,
                                                       options: AggregateOptions(maxTimeMS: QuerySafetyPolicy.maxTimeMS, maxResults: QuerySafetyPolicy.maxDocuments))
            return AssistantQueryResult(documents: documents, count: nil)
        }
    }
}

extension AssistantContext {
    /// Gathers schema, size and index names for a collection. Sample documents are included only on request.
    public static func load(client: MongoClient, namespace: MongoNamespace, serverInfo: ServerInfo,
                            includeSamples: Bool, currentQuery: QueryInput?) async -> AssistantContext {
        async let sampled = try? client.sample(namespace, size: 200)
        async let count = try? client.count(namespace, options: CountOptions(maxTimeMS: 3_000))
        async let indexes = try? client.listIndexes(namespace)
        let documents = await sampled ?? []
        return AssistantContext(namespace: namespace,
                                serverVersion: serverInfo.version,
                                capabilities: serverInfo.capabilities,
                                documentCount: (await count) ?? nil,
                                schema: documents.isEmpty ? nil : SchemaAnalyzer.analyze(documents),
                                samples: includeSamples ? Array(documents.prefix(3)) : [],
                                indexes: (await indexes ?? []).map { "\($0.name) \(BSONFormatter(style: .shell).format($0.keys))" },
                                currentQuery: currentQuery)
    }
}

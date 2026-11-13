import BSON

/// One stage of a query plan, normalised across classic, slot-based (SBE), aggregate and the
/// pre-3.0 legacy explain formats.
public struct PlanNode: Identifiable, Sendable, Hashable {
    public let id: Int
    public let stage: String
    public var indexName: String?
    public var details: [String]
    public var documentsReturned: Int64?
    public var documentsExamined: Int64?
    public var keysExamined: Int64?
    public var executionTimeMillis: Int64?
    public var children: [PlanNode]

    /// Depth-first, parent before children.
    public var flattened: [PlanNode] {
        [self] + children.flatMap(\.flattened)
    }

    public var isCollectionScan: Bool { stage == "COLLSCAN" }
    public var isBlockingSort: Bool { stage == "SORT" }
}

public struct ExplainPlan: Sendable {
    public enum Format: String, Sendable {
        case legacy = "Legacy (MongoDB ≤ 2.6)"
        case classic = "Classic engine"
        case slotBased = "Slot-based engine (SBE)"
        case unknown = "Unknown"
    }

    public let raw: BSONDocument
    public let format: Format
    public let root: PlanNode?
    public let documentsReturned: Int64?
    public let documentsExamined: Int64?
    public let keysExamined: Int64?
    public let executionTimeMillis: Int64?
    public let indexesUsed: [String]
    public let usesCollectionScan: Bool
    public let hasInMemorySort: Bool

    public init(_ raw: BSONDocument) {
        self.raw = raw
        var builder = PlanBuilder()
        let parsed = builder.parse(raw)
        format = parsed.format
        root = parsed.root
        documentsReturned = parsed.stats.returned
        documentsExamined = parsed.stats.docsExamined
        keysExamined = parsed.stats.keysExamined
        executionTimeMillis = parsed.stats.millis

        let nodes = root?.flattened ?? []
        var seen = Set<String>()
        indexesUsed = nodes.compactMap(\.indexName).filter { seen.insert($0).inserted }
        usesCollectionScan = nodes.contains(where: \.isCollectionScan)
        hasInMemorySort = nodes.contains(where: \.isBlockingSort) || builder.legacyScanAndOrder
    }

    /// Fraction of examined documents that were returned (1.0 is ideal), when known.
    public var selectivity: Double? {
        guard let returned = documentsReturned, let examined = documentsExamined, examined > 0 else { return nil }
        return Double(returned) / Double(examined)
    }
}

private struct PlanBuilder {
    struct Stats {
        var returned: Int64?
        var docsExamined: Int64?
        var keysExamined: Int64?
        var millis: Int64?
    }

    private var nextID = 0
    private(set) var legacyScanAndOrder = false

    mutating func parse(_ raw: BSONDocument) -> (format: ExplainPlan.Format, root: PlanNode?, stats: Stats) {
        // Modern find / pushed-down aggregate.
        if let planner = raw["queryPlanner"]?.documentValue {
            let execution = raw["executionStats"]?.documentValue
            let (format, root) = planTree(planner: planner, execution: execution)
            return (format, root, stats(from: execution))
        }
        // Aggregate: {stages: [{$cursor: {...}}, {$group: ...}, ...]}.
        if let stages = raw["stages"]?.arrayValue {
            return parseAggregateStages(stages)
        }
        // Sharded aggregate (classic): {shards: {name: {stages: [...]}}}.
        if let shards = raw["shards"]?.documentValue, let first = shards.elements.first?.value.documentValue {
            return parse(first)
        }
        // Legacy (MongoDB 2.6) find explain.
        if raw["cursor"]?.stringValue != nil {
            let root = legacyNode(raw)
            return (.legacy, root, Stats(returned: raw["n"]?.countValue,
                                         docsExamined: raw["nscannedObjects"]?.countValue,
                                         keysExamined: legacyKeysExamined(raw),
                                         millis: raw["millis"]?.countValue))
        }
        return (.unknown, nil, Stats())
    }

    private func stats(from execution: BSONDocument?) -> Stats {
        guard let execution else { return Stats() }
        return Stats(returned: execution["nReturned"]?.countValue,
                     docsExamined: execution["totalDocsExamined"]?.countValue,
                     keysExamined: execution["totalKeysExamined"]?.countValue,
                     millis: execution["executionTimeMillis"]?.countValue)
    }

    private mutating func planTree(planner: BSONDocument, execution: BSONDocument?) -> (ExplainPlan.Format, PlanNode?) {
        guard let winning = planner["winningPlan"]?.documentValue else { return (.unknown, nil) }
        if let queryPlan = winning["queryPlan"]?.documentValue {
            return (.slotBased, node(queryPlan))
        }
        // Prefer executionStages: same shape as winningPlan but with per-stage counters.
        if let stages = execution?["executionStages"]?.documentValue, stages["stage"] != nil, stages["stage"]?.stringValue != "mkobj" {
            return (.classic, node(stages))
        }
        return (.classic, node(winning))
    }

    private mutating func parseAggregateStages(_ stages: [BSONValue]) -> (ExplainPlan.Format, PlanNode?, Stats) {
        var format = ExplainPlan.Format.classic
        var current: PlanNode?
        var stats = Stats()
        for value in stages {
            guard let stage = value.documentValue, let name = stage.keys.first else { continue }
            if name == "$cursor", let cursor = stage["$cursor"]?.documentValue {
                if let planner = cursor["queryPlanner"]?.documentValue {
                    let (cursorFormat, root) = planTree(planner: planner, execution: cursor["executionStats"]?.documentValue)
                    format = cursorFormat
                    current = root
                    stats = self.stats(from: cursor["executionStats"]?.documentValue)
                } else if let plan = cursor["plan"]?.documentValue {
                    format = .legacy
                    current = legacyNode(plan)
                }
                continue
            }
            var node = makeNode(stage: name, details: [BSONFormatter.summary(of: stage[name] ?? .null, maxLength: 120)])
            node.documentsReturned = stage["nReturned"]?.countValue
            node.executionTimeMillis = stage["executionTimeMillisEstimate"]?.countValue
            if let child = current { node.children = [child] }
            current = node
        }
        return (format, current, stats)
    }

    // MARK: Classic / SBE stage documents

    private mutating func node(_ document: BSONDocument) -> PlanNode {
        let stage = document["stage"]?.stringValue ?? "?"
        var details: [String] = []
        if let pattern = document["keyPattern"] { details.append("key: " + BSONFormatter.summary(of: pattern, maxLength: 80)) }
        if let filter = document["filter"] { details.append("filter: " + BSONFormatter.summary(of: filter, maxLength: 120)) }
        if let direction = document["direction"]?.stringValue { details.append("direction: \(direction)") }
        if let sortPattern = document["sortPattern"] { details.append("sort: " + BSONFormatter.summary(of: sortPattern, maxLength: 80)) }
        if let limit = document["limitAmount"]?.countValue { details.append("limit: \(limit)") }

        var result = makeNode(stage: stage, details: details)
        result.indexName = document["indexName"]?.stringValue
        result.documentsReturned = document["nReturned"]?.countValue
        result.documentsExamined = document["docsExamined"]?.countValue
        result.keysExamined = document["keysExamined"]?.countValue
        result.executionTimeMillis = document["executionTimeMillisEstimate"]?.countValue

        var children: [PlanNode] = []
        for key in ["inputStage", "thenStage", "elseStage", "outerStage", "innerStage"] {
            if let child = document[key]?.documentValue { children.append(node(child)) }
        }
        for value in document["inputStages"]?.arrayValue ?? [] {
            if let child = value.documentValue { children.append(node(child)) }
        }
        for value in document["shards"]?.arrayValue ?? [] {
            guard let shard = value.documentValue else { continue }
            if let plan = shard["winningPlan"]?.documentValue ?? shard["executionStages"]?.documentValue {
                let child = plan["queryPlan"]?.documentValue ?? plan
                var shardNode = node(child)
                if let name = shard["shardName"]?.stringValue { shardNode.details.insert("shard: \(name)", at: 0) }
                children.append(shardNode)
            }
        }
        result.children = children
        return result
    }

    // MARK: Legacy (2.6)

    private mutating func legacyNode(_ document: BSONDocument) -> PlanNode {
        if document["scanAndOrder"]?.isTruthy == true { legacyScanAndOrder = true }
        let cursor = document["cursor"]?.stringValue ?? "?"
        var children: [PlanNode] = []
        for clause in document["clauses"]?.arrayValue ?? [] {
            if let clause = clause.documentValue { children.append(legacyNode(clause)) }
        }
        let stage: String
        var indexName: String?
        if cursor.hasPrefix("BtreeCursor") {
            stage = "IXSCAN"
            indexName = cursor.dropFirst("BtreeCursor".count).split(separator: " ").first.map(String.init)
        } else if cursor == "BasicCursor" {
            stage = "COLLSCAN"
        } else if cursor == "QueryOptimizerCursor" {
            stage = "OR"
        } else {
            stage = cursor
        }
        var node = makeNode(stage: stage, details: [cursor])
        node.indexName = indexName
        node.documentsReturned = document["n"]?.countValue
        node.documentsExamined = document["nscannedObjects"]?.countValue
        node.keysExamined = indexName == nil ? nil : document["nscanned"]?.countValue
        node.executionTimeMillis = document["millis"]?.countValue
        node.children = children
        if document["scanAndOrder"]?.isTruthy == true {
            var sort = makeNode(stage: "SORT", details: ["scanAndOrder"])
            sort.children = [node]
            return sort
        }
        return node
    }

    private func legacyKeysExamined(_ document: BSONDocument) -> Int64? {
        guard let cursor = document["cursor"]?.stringValue, cursor != "BasicCursor" else { return 0 }
        return document["nscanned"]?.countValue
    }

    private mutating func makeNode(stage: String, details: [String]) -> PlanNode {
        nextID += 1
        return PlanNode(id: nextID, stage: stage, indexName: nil, details: details, children: [])
    }
}

extension BSONValue {
    /// Counters arrive as int32, int64 or double depending on server version.
    var countValue: Int64? {
        if let integer = int64Value { return integer }
        if let double = doubleValue, double.isFinite { return Int64(exactly: double.rounded()) }
        return nil
    }
}

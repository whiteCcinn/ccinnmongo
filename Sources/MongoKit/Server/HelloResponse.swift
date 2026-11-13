import BSON

public enum ServerType: String, Sendable {
    case standalone
    case mongos
    case rsPrimary
    case rsSecondary
    case rsArbiter
    case rsOther
    case rsGhost
    case unknown

    public var displayName: String {
        switch self {
        case .standalone: "Standalone"
        case .mongos: "Sharded cluster (mongos)"
        case .rsPrimary: "Replica set primary"
        case .rsSecondary: "Replica set secondary"
        case .rsArbiter: "Replica set arbiter"
        case .rsOther: "Replica set member"
        case .rsGhost: "Replica set (initialising)"
        case .unknown: "Unknown"
        }
    }

    public var isDataBearing: Bool {
        self == .standalone || self == .mongos || self == .rsPrimary || self == .rsSecondary
    }
}

/// Parsed reply of the `isMaster`/`hello` handshake.
public struct HelloResponse: Sendable {
    public let raw: BSONDocument

    public init(_ raw: BSONDocument) { self.raw = raw }

    public var isWritablePrimary: Bool {
        raw["isWritablePrimary"]?.isTruthy ?? raw["ismaster"]?.isTruthy ?? false
    }
    public var isSecondary: Bool { raw["secondary"]?.isTruthy ?? false }
    public var isArbiter: Bool { raw["arbiterOnly"]?.isTruthy ?? false }
    public var isHidden: Bool { raw["hidden"]?.isTruthy ?? false }
    public var setName: String? { raw["setName"]?.stringValue }
    public var primary: String? { raw["primary"]?.stringValue }
    public var me: String? { raw["me"]?.stringValue }
    public var hosts: [String] { stringArray("hosts") }
    public var passives: [String] { stringArray("passives") }
    public var arbiters: [String] { stringArray("arbiters") }
    public var isMongos: Bool { raw["msg"]?.stringValue == "isdbgrid" }
    public var maxWireVersion: Int { raw["maxWireVersion"]?.intValue ?? 0 }
    public var minWireVersion: Int { raw["minWireVersion"]?.intValue ?? 0 }
    public var maxBsonObjectSize: Int { raw["maxBsonObjectSize"]?.intValue ?? 16 * 1024 * 1024 }
    public var maxMessageSizeBytes: Int { raw["maxMessageSizeBytes"]?.intValue ?? 48_000_000 }
    public var maxWriteBatchSize: Int { raw["maxWriteBatchSize"]?.intValue ?? 1000 }
    public var saslSupportedMechs: [String]? {
        guard let array = raw["saslSupportedMechs"]?.arrayValue else { return nil }
        return array.compactMap(\.stringValue)
    }

    public var serverType: ServerType {
        if raw["isreplicaset"]?.isTruthy == true { return .rsGhost }
        if isMongos { return .mongos }
        if setName != nil {
            if isWritablePrimary { return .rsPrimary }
            if isSecondary { return .rsSecondary }
            if isArbiter { return .rsArbiter }
            return .rsOther
        }
        return .standalone
    }

    /// All data-bearing members advertised by a replica-set member.
    public var memberAddresses: [String] { hosts + passives }

    private func stringArray(_ key: String) -> [String] {
        raw[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// Feature switches derived from the wire version. This is the only place that maps versions to
/// behaviour; strategies ask capabilities rather than comparing version numbers themselves.
public struct ServerCapabilities: Sendable, Equatable {
    /// MongoDB 2.6 introduced write commands and is the oldest server supported.
    public static let minimumSupportedWireVersion = 2

    public let maxWireVersion: Int

    public init(maxWireVersion: Int) { self.maxWireVersion = maxWireVersion }

    /// MongoDB 3.6+ (wire 6) accepts OP_MSG; MongoDB 6.0+ no longer accepts OP_QUERY commands.
    public var usesOpMsg: Bool { maxWireVersion >= 6 }
    /// MongoDB 3.0+: listCollections / listIndexes commands, SCRAM-SHA-1.
    public var hasListCommands: Bool { maxWireVersion >= 3 }
    /// MongoDB 3.2+: find/getMore/killCursors commands, explain of find, $sample, $indexStats.
    public var hasFindCommand: Bool { maxWireVersion >= 4 }
    public var hasSampleStage: Bool { maxWireVersion >= 4 }
    public var hasIndexStats: Bool { maxWireVersion >= 4 }
    /// MongoDB 3.4+: collation and views.
    public var hasCollation: Bool { maxWireVersion >= 5 }
    public var hasViews: Bool { maxWireVersion >= 5 }
    /// MongoDB 3.6+: aggregate must use a cursor; explain command for aggregate.
    public var requiresAggregateCursor: Bool { maxWireVersion >= 6 }
    public var hasAggregateExplainCommand: Bool { maxWireVersion >= 6 }
    /// MongoDB 4.0+: SCRAM-SHA-256, listDatabases authorizedDatabases (4.0.5+).
    public var hasScramSHA256: Bool { maxWireVersion >= 7 }
    public var hasAuthorizedDatabases: Bool { maxWireVersion >= 7 }
    /// MongoDB 4.4+: hidden indexes.
    public var hasHiddenIndexes: Bool { maxWireVersion >= 9 }

    public var protocolName: String { usesOpMsg ? "OP_MSG" : "OP_QUERY (legacy)" }

    /// Best-effort server generation for display when buildInfo is unavailable.
    public var approximateVersion: String {
        switch maxWireVersion {
        case ..<2: "≤ 2.4"
        case 2: "2.6"
        case 3: "3.0"
        case 4: "3.2"
        case 5: "3.4"
        case 6: "3.6"
        case 7: "4.0"
        case 8: "4.2"
        case 9: "4.4"
        case 10...13: "5.0"
        case 14...17: "6.0"
        case 18...21: "7.0"
        default: "8.0+"
        }
    }
}

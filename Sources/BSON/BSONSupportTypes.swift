import Foundation

/// BSON binary value with its subtype.
public struct BSONBinary: Sendable, Hashable {
    /// Binary subtypes defined by the BSON specification. Unknown/user subtypes are preserved as raw values.
    public struct Subtype: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
        public var rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public init(_ rawValue: UInt8) { self.rawValue = rawValue }

        public static let generic = Subtype(0x00)
        public static let function = Subtype(0x01)
        public static let binaryOld = Subtype(0x02)
        public static let uuidOld = Subtype(0x03)
        public static let uuid = Subtype(0x04)
        public static let md5 = Subtype(0x05)
        public static let encrypted = Subtype(0x06)
        public static let column = Subtype(0x07)
        public static let sensitive = Subtype(0x08)
        public static let vector = Subtype(0x09)
        public static let userDefined = Subtype(0x80)

        public var description: String { String(format: "%02x", rawValue) }
    }

    public var subtype: Subtype
    public var data: Data

    public init(subtype: Subtype, data: Data) {
        self.subtype = subtype
        // Re-base slices so later index arithmetic always starts at zero.
        self.data = Data(data)
    }

    public init(uuid: UUID) {
        let u = uuid.uuid
        self.init(subtype: .uuid, data: Data([
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ]))
    }

    /// The UUID represented by a subtype 4 (or legacy 3) value with exactly 16 bytes.
    public var uuid: UUID? {
        guard subtype == .uuid || subtype == .uuidOld, data.count == 16 else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// BSON UTC datetime: signed milliseconds since the Unix epoch. Kept raw so any 64-bit value survives.
public struct BSONDateTime: Sendable, Hashable, Comparable {
    public var millisecondsSinceEpoch: Int64

    public init(millisecondsSinceEpoch: Int64) {
        self.millisecondsSinceEpoch = millisecondsSinceEpoch
    }

    public init(_ date: Date) {
        let millis = (date.timeIntervalSince1970 * 1000).rounded(.down)
        if millis >= Double(Int64.max) {
            millisecondsSinceEpoch = .max
        } else if millis <= Double(Int64.min) {
            millisecondsSinceEpoch = .min
        } else {
            millisecondsSinceEpoch = Int64(millis)
        }
    }

    public static func now() -> BSONDateTime { BSONDateTime(Date()) }

    public var date: Date { Date(timeIntervalSince1970: Double(millisecondsSinceEpoch) / 1000) }

    public static func < (lhs: BSONDateTime, rhs: BSONDateTime) -> Bool {
        lhs.millisecondsSinceEpoch < rhs.millisecondsSinceEpoch
    }
}

/// BSON regular expression. Options are kept exactly as stored.
public struct BSONRegex: Sendable, Hashable {
    public var pattern: String
    public var options: String

    public init(pattern: String, options: String = "") {
        self.pattern = pattern
        self.options = options
    }

    /// Options sorted alphabetically and de-duplicated, as the BSON specification requires for new values.
    public static func normalizedOptions(_ options: String) -> String {
        String(Set(options).sorted())
    }
}

/// Deprecated DBPointer value.
public struct BSONDBPointer: Sendable, Hashable {
    public var namespace: String
    public var id: ObjectId

    public init(namespace: String, id: ObjectId) {
        self.namespace = namespace
        self.id = id
    }
}

/// Deprecated JavaScript code with scope.
public struct BSONCodeWithScope: Sendable, Hashable {
    public var code: String
    public var scope: BSONDocument

    public init(code: String, scope: BSONDocument) {
        self.code = code
        self.scope = scope
    }
}

/// BSON internal timestamp (seconds + ordinal), used by replication.
public struct BSONTimestamp: Sendable, Hashable, Comparable {
    public var timestamp: UInt32
    public var increment: UInt32

    public init(timestamp: UInt32, increment: UInt32) {
        self.timestamp = timestamp
        self.increment = increment
    }

    public static func < (lhs: BSONTimestamp, rhs: BSONTimestamp) -> Bool {
        (lhs.timestamp, lhs.increment) < (rhs.timestamp, rhs.increment)
    }
}

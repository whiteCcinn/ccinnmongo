import Foundation

/// Bounds-checked sequential reader over BSON bytes.
///
/// Every read validates the remaining length first, so malformed input results in a thrown
/// `BSONError` instead of a trap; lengths are always validated before any allocation.
public struct BSONReader: Sendable {
    /// Maximum nesting depth accepted when decoding. MongoDB stores at most 100 levels; the margin
    /// covers reply envelopes (cursor → batch → document). Shared by the writer and the shell parser
    /// so recursion depth (and therefore stack usage) is bounded everywhere.
    public static let maximumDepth = BSONLimits.maximumDepth

    private let bytes: [UInt8]
    public private(set) var position: Int
    private let limit: Int

    public init(bytes: [UInt8]) {
        self.bytes = bytes
        position = 0
        limit = bytes.count
    }

    public init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        position = max(0, min(range.lowerBound, bytes.count))
        limit = max(position, min(range.upperBound, bytes.count))
    }

    public var remaining: Int { limit - position }
    public var isAtEnd: Bool { position >= limit }

    // MARK: Primitives

    @inline(__always)
    mutating func require(_ count: Int, _ context: @autoclosure () -> String) throws {
        guard count >= 0, count <= limit - position else {
            throw BSONError.truncated(context: context())
        }
    }

    public mutating func readUInt8(_ context: @autoclosure () -> String = "byte") throws -> UInt8 {
        try require(1, context())
        let value = bytes[position]
        position += 1
        return value
    }

    public mutating func readInt32(_ context: @autoclosure () -> String = "int32") throws -> Int32 {
        Int32(bitPattern: try readUInt32(context()))
    }

    public mutating func readUInt32(_ context: @autoclosure () -> String = "uint32") throws -> UInt32 {
        try require(4, context())
        let p = position
        let value = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
        position += 4
        return value
    }

    public mutating func readInt64(_ context: @autoclosure () -> String = "int64") throws -> Int64 {
        Int64(bitPattern: try readUInt64(context()))
    }

    public mutating func readUInt64(_ context: @autoclosure () -> String = "uint64") throws -> UInt64 {
        try require(8, context())
        var value: UInt64 = 0
        for offset in (0..<8).reversed() {
            value = value << 8 | UInt64(bytes[position + offset])
        }
        position += 8
        return value
    }

    public mutating func readBytes(_ count: Int, _ context: @autoclosure () -> String = "bytes") throws -> ArraySlice<UInt8> {
        try require(count, context())
        let slice = bytes[position..<(position + count)]
        position += count
        return slice
    }

    public mutating func skip(_ count: Int) throws {
        try require(count, "skipped bytes")
        position += count
    }

    /// Reads a NUL-terminated UTF-8 string bounded by `end`.
    public mutating func readCString(_ context: @autoclosure () -> String = "cstring", end: Int? = nil) throws -> String {
        let boundary = min(end ?? limit, limit)
        var index = position
        while index < boundary, bytes[index] != 0 { index += 1 }
        guard index < boundary else { throw BSONError.missingTerminator(context: context()) }
        let string = String(decoding: bytes[position..<index], as: UTF8.self)
        position = index + 1
        return string
    }

    /// Reads a length-prefixed BSON string.
    mutating func readString(_ context: String) throws -> String {
        let length = Int(try readInt32(context))
        guard length >= 1 else { throw BSONError.invalidLength(context: context, length: length) }
        try require(length, context)
        guard bytes[position + length - 1] == 0 else { throw BSONError.missingTerminator(context: context) }
        let string = String(decoding: bytes[position..<(position + length - 1)], as: UTF8.self)
        position += length
        return string
    }

    // MARK: Documents

    /// Reads one embedded document starting at the current position.
    public mutating func readDocument() throws -> BSONDocument {
        try readDocument(depth: 0, context: "document")
    }

    mutating func readDocument(depth: Int, context: String) throws -> BSONDocument {
        guard depth < Self.maximumDepth else { throw BSONError.depthLimitExceeded(limit: Self.maximumDepth) }
        let start = position
        let length = Int(try readInt32("\(context) length"))
        guard length >= 5 else { throw BSONError.invalidLength(context: context, length: length) }
        guard length <= limit - start else { throw BSONError.truncated(context: context) }
        let end = start + length
        guard bytes[end - 1] == 0 else { throw BSONError.missingTerminator(context: context) }

        var elements: [BSONElement] = []
        while position < end - 1 {
            let typeByte = bytes[position]
            position += 1
            let key = try readCString("field name", end: end - 1)
            guard let type = BSONType(rawValue: typeByte) else {
                throw BSONError.unknownType(typeByte, key: key)
            }
            let value = try readValue(type: type, key: key, depth: depth, end: end - 1)
            elements.append(BSONElement(key: key, value: value))
        }
        guard position == end - 1 else { throw BSONError.invalidLength(context: context, length: length) }
        position = end
        return BSONDocument(elements)
    }

    /// Recursive path kept deliberately small: only containers recurse, everything else is decoded
    /// in `readScalar`, which is never inlined so its locals do not inflate each recursion frame.
    private mutating func readValue(type: BSONType, key: String, depth: Int, end: Int) throws -> BSONValue {
        let value: BSONValue
        switch type {
        case .document:
            value = .document(try readDocument(depth: depth + 1, context: "field '\(key)'"))
        case .array:
            // Array keys ("0", "1", ...) are ignored; legacy data sometimes has non-sequential keys.
            value = .array(try readDocument(depth: depth + 1, context: "array '\(key)'").values)
        case .javascriptWithScope:
            value = try readCodeWithScope(key: key, depth: depth)
        default:
            value = try readScalar(type: type, key: key, end: end)
        }
        guard position <= end else { throw BSONError.truncated(context: "field '\(key)'") }
        return value
    }

    @inline(never)
    private mutating func readCodeWithScope(key: String, depth: Int) throws -> BSONValue {
        let context = "field '\(key)'"
        let start = position
        let total = Int(try readInt32(context))
        // int32 total + int32 string length + 1 byte string + 5 byte empty document
        guard total >= 14, total <= limit - start else {
            throw BSONError.invalidLength(context: context, length: total)
        }
        let code = try readString(context)
        let scope = try readDocument(depth: depth + 1, context: "\(context) scope")
        guard position - start == total else {
            throw BSONError.invalidLength(context: context, length: total)
        }
        return .javascriptWithScope(BSONCodeWithScope(code: code, scope: scope))
    }

    @inline(never)
    private mutating func readScalar(type: BSONType, key: String, end: Int) throws -> BSONValue {
        let context = "field '\(key)'"
        switch type {
        case .double:
            return .double(Double(bitPattern: try readUInt64(context)))
        case .string:
            return .string(try readString(context))
        case .binary:
            return .binary(try readBinary(context))
        case .undefined:
            return .undefined
        case .objectId:
            let raw = try readBytes(12, context)
            guard let oid = ObjectId(bytes: raw) else { throw BSONError.invalidValue(context: context) }
            return .objectId(oid)
        case .bool:
            let byte = try readUInt8(context)
            guard byte <= 1 else { throw BSONError.invalidValue(context: "\(context) boolean byte \(byte)") }
            return .bool(byte == 1)
        case .datetime:
            return .datetime(BSONDateTime(millisecondsSinceEpoch: try readInt64(context)))
        case .null:
            return .null
        case .regex:
            let pattern = try readCString("\(context) pattern", end: end)
            let options = try readCString("\(context) options", end: end)
            return .regex(BSONRegex(pattern: pattern, options: options))
        case .dbPointer:
            let namespace = try readString(context)
            let raw = try readBytes(12, context)
            guard let oid = ObjectId(bytes: raw) else { throw BSONError.invalidValue(context: context) }
            return .dbPointer(BSONDBPointer(namespace: namespace, id: oid))
        case .javascript:
            return .javascript(try readString(context))
        case .symbol:
            return .symbol(try readString(context))
        case .int32:
            return .int32(try readInt32(context))
        case .timestamp:
            let increment = try readUInt32(context)
            let seconds = try readUInt32(context)
            return .timestamp(BSONTimestamp(timestamp: seconds, increment: increment))
        case .int64:
            return .int64(try readInt64(context))
        case .decimal128:
            let low = try readUInt64(context)
            let high = try readUInt64(context)
            return .decimal128(Decimal128(high: high, low: low))
        case .minKey:
            return .minKey
        case .maxKey:
            return .maxKey
        case .document, .array, .javascriptWithScope:
            throw BSONError.invalidValue(context: "\(context) container decoded as scalar")
        }
    }

    private mutating func readBinary(_ context: String) throws -> BSONBinary {
        let length = Int(try readInt32(context))
        guard length >= 0 else { throw BSONError.invalidLength(context: context, length: length) }
        let subtype = BSONBinary.Subtype(try readUInt8(context))
        if subtype == .binaryOld {
            let inner = Int(try readInt32("\(context) old binary length"))
            guard inner >= 0, inner == length - 4 else {
                throw BSONError.invalidLength(context: "\(context) old binary", length: inner)
            }
            return BSONBinary(subtype: subtype, data: Data(try readBytes(inner, context)))
        }
        return BSONBinary(subtype: subtype, data: Data(try readBytes(length, context)))
    }
}

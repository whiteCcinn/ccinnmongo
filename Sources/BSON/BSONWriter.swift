import Foundation

/// Appends BSON-encoded data to a growable byte buffer. Lengths are back-patched, so each value is
/// written in a single pass without pre-computing sizes.
public struct BSONWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    // MARK: Primitives

    public mutating func writeInt32(_ value: Int32) {
        let v = UInt32(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    public mutating func writeUInt32(_ value: UInt32) { writeInt32(Int32(bitPattern: value)) }

    public mutating func writeInt64(_ value: Int64) { writeUInt64(UInt64(bitPattern: value)) }

    public mutating func writeUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    public mutating func writeBytes<C: Collection>(_ data: C) where C.Element == UInt8 {
        bytes.append(contentsOf: data)
    }

    public mutating func writeCString(_ string: String, context: String) throws {
        let utf8 = string.utf8
        if utf8.contains(0) { throw BSONError.invalidKey(context.isEmpty ? string : context) }
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    public mutating func writeString(_ string: String) throws {
        let utf8 = string.utf8
        guard utf8.count < Int32.max else { throw BSONError.documentTooLarge(size: utf8.count) }
        writeInt32(Int32(utf8.count + 1))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    /// Reserves an int32 length slot and returns its offset.
    mutating func reserveLength() -> Int {
        let offset = bytes.count
        writeInt32(0)
        return offset
    }

    /// Writes `bytes.count - start` into the length slot at `start`.
    mutating func patchLength(at start: Int) throws {
        let length = bytes.count - start
        guard length <= Int32.max else { throw BSONError.documentTooLarge(size: length) }
        let v = UInt32(length)
        bytes[start] = UInt8(truncatingIfNeeded: v)
        bytes[start + 1] = UInt8(truncatingIfNeeded: v >> 8)
        bytes[start + 2] = UInt8(truncatingIfNeeded: v >> 16)
        bytes[start + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    // MARK: Documents

    public mutating func writeDocument(_ document: BSONDocument) throws {
        try writeDocument(document, depth: 0)
    }

    mutating func writeDocument(_ document: BSONDocument, depth: Int) throws {
        guard depth < BSONLimits.maximumDepth else { throw BSONError.depthLimitExceeded(limit: BSONLimits.maximumDepth) }
        let start = reserveLength()
        for element in document.elements {
            try writeElement(key: element.key, value: element.value, depth: depth)
        }
        bytes.append(0)
        try patchLength(at: start)
    }

    mutating func writeArray(_ array: [BSONValue], depth: Int) throws {
        guard depth < BSONLimits.maximumDepth else { throw BSONError.depthLimitExceeded(limit: BSONLimits.maximumDepth) }
        let start = reserveLength()
        for (index, value) in array.enumerated() {
            try writeElement(key: String(index), value: value, depth: depth)
        }
        bytes.append(0)
        try patchLength(at: start)
    }

    mutating func writeElement(key: String, value: BSONValue, depth: Int) throws {
        bytes.append(value.type.rawValue)
        try writeCString(key, context: key)
        switch value {
        case let .document(v):
            try writeDocument(v, depth: depth + 1)
        case let .array(v):
            try writeArray(v, depth: depth + 1)
        case let .javascriptWithScope(v):
            let start = reserveLength()
            try writeString(v.code)
            try writeDocument(v.scope, depth: depth + 1)
            try patchLength(at: start)
        default:
            try writeScalar(value)
        }
    }

    /// Non-recursive values; kept out of line so recursion frames stay small.
    @inline(never)
    mutating func writeScalar(_ value: BSONValue) throws {
        switch value {
        case let .double(v):
            writeUInt64(v.bitPattern)
        case let .string(v), let .javascript(v), let .symbol(v):
            try writeString(v)
        case .document, .array, .javascriptWithScope:
            throw BSONError.invalidValue(context: "container encoded as scalar")
        case let .binary(v):
            try writeBinary(v)
        case .undefined, .null, .minKey, .maxKey:
            break
        case let .objectId(v):
            writeBytes(v.bytes)
        case let .bool(v):
            bytes.append(v ? 1 : 0)
        case let .datetime(v):
            writeInt64(v.millisecondsSinceEpoch)
        case let .regex(v):
            try writeCString(v.pattern, context: "regular expression pattern")
            try writeCString(v.options, context: "regular expression options")
        case let .dbPointer(v):
            try writeString(v.namespace)
            writeBytes(v.id.bytes)
        case let .int32(v):
            writeInt32(v)
        case let .timestamp(v):
            writeUInt32(v.increment)
            writeUInt32(v.timestamp)
        case let .int64(v):
            writeInt64(v)
        case let .decimal128(v):
            writeUInt64(v.low)
            writeUInt64(v.high)
        }
    }

    mutating func writeBinary(_ binary: BSONBinary) throws {
        let count = binary.data.count
        if binary.subtype == .binaryOld {
            // Subtype 2 carries a redundant inner length.
            guard count + 4 <= Int32.max else { throw BSONError.documentTooLarge(size: count) }
            writeInt32(Int32(count + 4))
            bytes.append(binary.subtype.rawValue)
            writeInt32(Int32(count))
        } else {
            guard count <= Int32.max else { throw BSONError.documentTooLarge(size: count) }
            writeInt32(Int32(count))
            bytes.append(binary.subtype.rawValue)
        }
        bytes.append(contentsOf: binary.data)
    }
}

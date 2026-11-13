import Foundation
import os

/// 12-byte MongoDB ObjectId stored as two words for cheap hashing and comparison.
public struct ObjectId: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Bytes 0..<8, big-endian.
    @usableFromInline let head: UInt64
    /// Bytes 8..<12, big-endian.
    @usableFromInline let tail: UInt32

    /// Generates a new ObjectId: 4-byte timestamp, 5-byte process-unique random value, 3-byte counter.
    public init() {
        self = ObjectIdGenerator.shared.next()
    }

    init(head: UInt64, tail: UInt32) {
        self.head = head
        self.tail = tail
    }

    /// Creates an ObjectId from exactly 12 bytes.
    public init?<C: Collection>(bytes: C) where C.Element == UInt8 {
        guard bytes.count == 12 else { return nil }
        var head: UInt64 = 0
        var tail: UInt32 = 0
        for (offset, byte) in bytes.enumerated() {
            if offset < 8 {
                head = (head << 8) | UInt64(byte)
            } else {
                tail = (tail << 8) | UInt32(byte)
            }
        }
        self.init(head: head, tail: tail)
    }

    /// Parses a 24-character hexadecimal string (case-insensitive).
    public init?(hex: String) {
        let utf8 = hex.utf8
        guard utf8.count == 24 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(12)
        var high: UInt8 = 0
        for (index, char) in utf8.enumerated() {
            guard let nibble = Self.nibble(char) else { return nil }
            if index.isMultiple(of: 2) {
                high = nibble
            } else {
                bytes.append(high << 4 | nibble)
            }
        }
        self.init(bytes: bytes)
    }

    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 { result[index] = UInt8(truncatingIfNeeded: head >> UInt64(56 - index * 8)) }
        for index in 0..<4 { result[8 + index] = UInt8(truncatingIfNeeded: tail >> UInt32(24 - index * 8)) }
        return result
    }

    public var hex: String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(24)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Creation time encoded in the first four bytes.
    public var timestampSeconds: UInt32 { UInt32(truncatingIfNeeded: head >> 32) }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestampSeconds)) }

    public var description: String { hex }

    public static func < (lhs: ObjectId, rhs: ObjectId) -> Bool {
        (lhs.head, lhs.tail) < (rhs.head, rhs.tail)
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): char - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// Process-wide ObjectId generator. The only shared mutable state is a 24-bit counter guarded by an
/// unfair lock held for a single increment, so contention stays negligible even at high rates.
final class ObjectIdGenerator: Sendable {
    static let shared = ObjectIdGenerator()

    private let processUnique: UInt64 // 40 bits
    private let counter: OSAllocatedUnfairLock<UInt32>

    private init() {
        var rng = SystemRandomNumberGenerator()
        processUnique = UInt64.random(in: 0...0xFF_FFFF_FFFF, using: &rng)
        counter = OSAllocatedUnfairLock(initialState: UInt32.random(in: 0...0xFF_FFFF, using: &rng))
    }

    func next() -> ObjectId {
        let seconds = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
        let count = counter.withLock { value -> UInt32 in
            value = (value &+ 1) & 0xFF_FFFF
            return value
        }
        // head = 4 bytes time | first 4 bytes of the 5-byte random value
        let head = (UInt64(seconds) << 32) | (processUnique >> 8)
        // tail = last byte of random value | 3-byte counter
        let tail = (UInt32(truncatingIfNeeded: processUnique & 0xFF) << 24) | count
        return ObjectId(head: head, tail: tail)
    }
}

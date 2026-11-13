/// Splits a byte stream into complete wire messages.
///
/// Uses a read cursor with amortised compaction, so reassembling a large reply from many small
/// network chunks stays linear instead of shifting the buffer on every message.
public struct MessageFramer: Sendable {
    /// Default limit: MongoDB's maxMessageSizeBytes (48 MB) plus headroom.
    public static let defaultMaxMessageSize = 48 * 1024 * 1024 + 64 * 1024

    private var buffer: [UInt8] = []
    private var readIndex = 0
    public let maxMessageSize: Int

    public init(maxMessageSize: Int = MessageFramer.defaultMaxMessageSize) {
        self.maxMessageSize = maxMessageSize
    }

    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ chunk: [UInt8]) {
        if readIndex > 0, readIndex >= buffer.count / 2 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        buffer.append(contentsOf: chunk)
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        readIndex = 0
    }

    /// Returns the next complete message, `nil` if more bytes are needed, or throws on an impossible length.
    public mutating func nextMessage() throws -> [UInt8]? {
        guard bufferedByteCount >= 4 else { return nil }
        let p = readIndex
        let raw = UInt32(buffer[p]) | UInt32(buffer[p + 1]) << 8 | UInt32(buffer[p + 2]) << 16 | UInt32(buffer[p + 3]) << 24
        let length = Int(Int32(bitPattern: raw))
        guard length >= MessageHeader.size else { throw MongoWireError.invalidMessageLength(length) }
        guard length <= maxMessageSize else { throw MongoWireError.messageTooLarge(size: length, limit: maxMessageSize) }
        guard bufferedByteCount >= length else {
            buffer.reserveCapacity(readIndex + length)
            return nil
        }
        let message = Array(buffer[p..<(p + length)])
        readIndex += length
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        }
        return message
    }
}

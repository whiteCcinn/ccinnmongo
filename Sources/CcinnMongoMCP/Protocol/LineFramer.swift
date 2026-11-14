/// Splits a byte stream into newline-delimited messages with a hard size limit.
///
/// The buffer never grows beyond `maxLineBytes + 1`: once a line exceeds the limit the framer drops
/// its bytes until the next newline and reports the line once as `.oversized`, so a hostile or broken
/// client cannot exhaust memory and the session continues with the next message.
public struct LineFramer: Sendable {
    public enum Event: Sendable, Equatable {
        case line([UInt8])
        /// A line longer than the limit was dropped (byte count, excluding the newline).
        case oversized(Int)
    }

    public let maxLineBytes: Int
    private var buffer: [UInt8] = []
    private var discardedBytes: Int?

    public init(maxLineBytes: Int) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ chunk: [UInt8]) -> [Event] {
        var events: [Event] = []
        var remaining = chunk[...]
        while !remaining.isEmpty {
            let newline = remaining.firstIndex(of: 0x0A)
            let segment = remaining[..<(newline ?? remaining.endIndex)]
            if let discarded = discardedBytes {
                discardedBytes = discarded + segment.count
            } else if buffer.count + segment.count > maxLineBytes + 1 {
                // +1 leaves room for an optional trailing carriage return.
                discardedBytes = buffer.count + segment.count
                buffer.removeAll(keepingCapacity: false)
            } else {
                buffer.append(contentsOf: segment)
            }
            guard let newline else { break }
            if let event = completeLine() { events.append(event) }
            remaining = remaining[remaining.index(after: newline)...]
        }
        return events
    }

    /// Flushes a final line that was not terminated by a newline (end of input).
    public mutating func finish() -> [Event] {
        guard discardedBytes != nil || !buffer.isEmpty else { return [] }
        return completeLine().map { [$0] } ?? []
    }

    private mutating func completeLine() -> Event? {
        defer {
            buffer.removeAll(keepingCapacity: buffer.count <= 64 * 1024)
            discardedBytes = nil
        }
        if let discarded = discardedBytes { return .oversized(discarded) }
        var line = buffer[...]
        if line.last == 0x0D { line = line.dropLast() }
        if line.count > maxLineBytes { return .oversized(line.count) }
        let isBlank = line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        return isBlank ? nil : .line(Array(line))
    }
}

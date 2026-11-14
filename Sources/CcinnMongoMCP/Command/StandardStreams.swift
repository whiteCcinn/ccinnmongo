import Darwin
import Dispatch

/// Reads standard input in chunks on a dedicated serial queue (blocking `read(2)` never occupies the
/// Swift concurrency pool). Chunks are produced on demand, so a slow consumer applies backpressure.
public enum StandardInput {
    public static func chunks(fileDescriptor: Int32 = STDIN_FILENO, chunkSize: Int = 64 * 1024) -> AsyncStream<[UInt8]> {
        let reader = BlockingReader(fileDescriptor: fileDescriptor, chunkSize: chunkSize)
        return AsyncStream(unfolding: { await reader.next() })
    }

    private final class BlockingReader: Sendable {
        private let fileDescriptor: Int32
        private let chunkSize: Int
        private let queue = DispatchQueue(label: "io.github.whiteccinn.ccinnmongo.mcp.stdin")

        init(fileDescriptor: Int32, chunkSize: Int) {
            self.fileDescriptor = fileDescriptor
            self.chunkSize = max(1, chunkSize)
        }

        /// The next chunk, or nil at end of input or on a read error.
        func next() async -> [UInt8]? {
            await withCheckedContinuation { continuation in
                queue.async { [fileDescriptor, chunkSize] in
                    var buffer = [UInt8](repeating: 0, count: chunkSize)
                    while true {
                        let count = buffer.withUnsafeMutableBytes { raw -> Int in
                            guard let base = raw.baseAddress else { return -1 }
                            return read(fileDescriptor, base, raw.count)
                        }
                        if count > 0 {
                            continuation.resume(returning: Array(buffer.prefix(count)))
                            return
                        }
                        if count < 0, errno == EINTR { continue }
                        continuation.resume(returning: nil)
                        return
                    }
                }
            }
        }
    }
}

/// Writes newline-terminated messages to standard output. A serial queue keeps whole messages
/// from interleaving and keeps blocking writes off the Swift concurrency pool.
public final class StandardOutputWriter: MCPOutput {
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "io.github.whiteccinn.ccinnmongo.mcp.stdout")

    public init(fileDescriptor: Int32 = STDOUT_FILENO) {
        self.fileDescriptor = fileDescriptor
    }

    public func send(_ line: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [fileDescriptor] in
                var bytes = line
                bytes.append(0x0A)
                var offset = 0
                while offset < bytes.count {
                    let written = bytes.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return write(fileDescriptor, base + offset, raw.count - offset)
                    }
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else if written < 0, errno == EAGAIN {
                        usleep(1_000)
                    } else {
                        continuation.resume(throwing: MCPOutputError.writeFailed(errno))
                        return
                    }
                }
                continuation.resume()
            }
        }
    }
}

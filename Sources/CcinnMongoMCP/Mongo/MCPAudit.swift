import Darwin
import Foundation

/// One audited tool call. Contains no secrets: operations are summarised (filters, field names) and
/// connection details are limited to the profile name and id.
public struct MCPAuditRecord: Sendable, Equatable {
    public let date: Date
    public let connection: String?
    public let connectionID: UUID?
    public let tool: String
    public let operation: String
    public let durationMilliseconds: Int
    public let documents: Int?
    public let error: String?

    public static let maxOperationLength = 2_000

    public init(date: Date, connection: String?, connectionID: UUID?, tool: String, operation: String,
                durationMilliseconds: Int, documents: Int?, error: String?) {
        self.date = date
        self.connection = connection
        self.connectionID = connectionID
        self.tool = tool
        self.operation = operation.count > Self.maxOperationLength ? String(operation.prefix(Self.maxOperationLength)) + "…" : operation
        self.durationMilliseconds = durationMilliseconds
        self.documents = documents
        self.error = error.map { $0.count > 1_000 ? String($0.prefix(1_000)) + "…" : $0 }
    }

    /// One compact JSON object (no newline).
    public func jsonLine() -> [UInt8] {
        var object: JSONObject = [
            "time": .string(Self.timestamp(date)),
            "source": "mcp",
            "connection": .optional(connection),
            "connection_id": .optional(connectionID?.uuidString),
            "tool": .string(tool),
            "operation": .string(operation),
            "duration_ms": .int(Int64(durationMilliseconds)),
        ]
        if let documents { object["documents"] = .int(Int64(documents)) }
        object["error"] = .optional(error)
        return JSONWriter.encode(.object(object))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public protocol MCPAuditSink: Sendable {
    func record(_ entry: MCPAuditRecord) async
}

/// Appends records to `mcp-audit.jsonl` (mode 0600), rotating to `mcp-audit.1.jsonl` past `maxBytes`.
public actor MCPAuditLog: MCPAuditSink {
    public static let fileName = "mcp-audit.jsonl"
    public static let rotatedFileName = "mcp-audit.1.jsonl"
    static let lockFileName = ".mcp-audit.lock"

    private let directory: URL
    private let maxBytes: Int
    private var reportedFailure = false

    public init(directory: URL, maxBytes: Int = 5 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = max(1024, maxBytes)
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public func record(_ entry: MCPAuditRecord) {
        var line = entry.jsonLine()
        line.append(0x0A)
        do {
            try append(Data(line))
        } catch {
            if !reportedFailure {
                reportedFailure = true
                FileHandle.standardError.write(Data("ccinnmongo mcp: could not write the audit log: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// Appends one line with a single `write(2)` on an `O_APPEND` descriptor. Several MCP processes (e.g.
    /// Claude Code and Codex) may share the file, so the size check, rotation and append run under an exclusive
    /// `flock` on a lock file: without it, two processes could both decide to rotate and the second rename would
    /// replace the rotated history with a nearly empty file.
    private func append(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(Self.lockFileName).path
        let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(lock, LOCK_UN) }

        let path = fileURL.path
        if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           size.intValue + data.count > maxBytes {
            let rotated = directory.appendingPathComponent(Self.rotatedFileName).path
            _ = rename(path, rotated)
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(descriptor, base, raw.count)
        }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

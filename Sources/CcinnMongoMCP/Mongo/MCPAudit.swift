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

    private func append(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue + data.count > maxBytes {
            let rotated = directory.appendingPathComponent(Self.rotatedFileName)
            try? manager.removeItem(at: rotated)
            try manager.moveItem(at: url, to: rotated)
        }
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

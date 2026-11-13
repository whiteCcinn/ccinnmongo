import BSON
import Foundation
import MongoWire

/// One authenticated socket to one server.
///
/// The actor serialises use of the socket; the pool additionally guarantees exclusive checkout.
/// Any I/O or framing failure marks the connection broken for good so it is never reused.
public actor MongoConnection {
    public nonisolated let id: Int
    public nonisolated let address: ServerAddress

    private let transport: any MongoTransport
    private var framer = MessageFramer()
    private var nextRequestID: Int32 = 1
    private var inFlight = false
    private var commandProtocol: any CommandWireProtocol = OpQueryCommandProtocol()
    private var secondaryOk = false
    private var mongosReadPreference: BSONDocument?

    public private(set) var isBroken = false
    public private(set) var hello: HelloResponse?

    public init(id: Int, address: ServerAddress, transport: any MongoTransport) {
        self.id = id
        self.address = address
        self.transport = transport
    }

    public var capabilities: ServerCapabilities { ServerCapabilities(maxWireVersion: hello?.maxWireVersion ?? 0) }

    // MARK: Handshake

    /// Sends the legacy `isMaster` handshake (understood by every server version) and selects the
    /// command protocol from the reported wire version.
    @discardableResult
    func handshake(appName: String?, saslSupportedMechsFor user: String?) async throws -> HelloResponse {
        var command: BSONDocument = ["isMaster": 1, "helloOk": true, "client": .document(Self.clientMetadata(appName: appName)), "compression": []]
        if let user { command["saslSupportedMechs"] = .string(user) }

        let reply = try await sendCommand(command, database: "admin", using: OpQueryCommandProtocol())
        guard reply.isOK else { throw MongoError.fromReply(reply, defaultMessage: "Handshake failed") }

        let hello = HelloResponse(reply)
        guard hello.maxWireVersion >= ServerCapabilities.minimumSupportedWireVersion else {
            throw MongoError(.unsupportedServer, "\(address) runs MongoDB \(ServerCapabilities(maxWireVersion: hello.maxWireVersion).approximateVersion), but the minimum supported version is MongoDB 2.6")
        }
        self.hello = hello
        let capabilities = ServerCapabilities(maxWireVersion: hello.maxWireVersion)
        commandProtocol = capabilities.usesOpMsg ? OpMsgCommandProtocol() : OpQueryCommandProtocol()
        framer = MessageFramer(maxMessageSize: max(hello.maxMessageSizeBytes, 48_000_000) + 64 * 1024)
        // Direct connections to non-primary replica-set members need secondary reads enabled.
        switch hello.serverType {
        case .rsSecondary, .rsArbiter, .rsOther, .rsGhost: secondaryOk = true
        default: secondaryOk = false
        }
        return hello
    }

    /// Routes reads through mongos according to the user's read preference.
    func configureReadPreference(_ mode: ReadPreferenceMode) {
        guard hello?.isMongos == true, mode != .primary else {
            mongosReadPreference = nil
            return
        }
        mongosReadPreference = ["mode": .string(mode.rawValue)]
    }

    static func clientMetadata(appName: String?) -> BSONDocument {
        var metadata: BSONDocument = [:]
        if let appName, !appName.isEmpty { metadata["application"] = ["name": .string(String(appName.prefix(128)))] }
        metadata["driver"] = ["name": "CcinnMongo", "version": "1.0.0"]
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        metadata["os"] = ["type": "Darwin", "name": "macOS", "architecture": .string(architecture),
                          "version": .string("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")]
        metadata["platform"] = "Swift"
        return metadata
    }

    // MARK: Commands

    /// Runs a command and throws `MongoError` when the reply has `ok: 0`.
    public func runCommand(_ command: BSONDocument, database: String) async throws -> BSONDocument {
        let reply = try await runCommandRaw(command, database: database)
        guard reply.isOK else { throw MongoError.fromReply(reply) }
        return reply
    }

    /// Runs a command and returns the reply as-is, including failures (`ok: 0`).
    public func runCommandRaw(_ command: BSONDocument, database: String) async throws -> BSONDocument {
        try await sendCommand(command, database: database, using: commandProtocol)
    }

    private func sendCommand(_ command: BSONDocument, database: String, using wireProtocol: any CommandWireProtocol) async throws -> BSONDocument {
        let request = wireProtocol.makeRequest(command: command, database: database, secondaryOk: secondaryOk, readPreference: mongosReadPreference)
        guard let message = try await roundTrip(request) else {
            throw MongoError(.protocolViolation, "No reply received for command")
        }
        do {
            return try wireProtocol.replyDocument(from: message)
        } catch {
            markBroken()
            throw error
        }
    }

    // MARK: Legacy opcodes (MongoDB < 3.2)

    func legacyQuery(_ query: OpQuery) async throws -> OpReply {
        var query = query
        if secondaryOk { query.flags.insert(.secondaryOk) }
        return try await legacyReply(to: .query(query))
    }

    func legacyGetMore(_ getMore: OpGetMore) async throws -> OpReply {
        try await legacyReply(to: .getMore(getMore))
    }

    func legacyKillCursors(_ cursorIDs: [Int64]) async throws {
        guard !cursorIDs.isEmpty else { return }
        _ = try await roundTrip(.killCursors(OpKillCursors(cursorIDs: cursorIDs)))
    }

    private func legacyReply(to request: WireRequest) async throws -> OpReply {
        guard let message = try await roundTrip(request) else {
            throw MongoError(.protocolViolation, "No reply received")
        }
        guard case let .reply(reply) = message.reply else {
            markBroken()
            throw MongoError(.protocolViolation, "Expected OP_REPLY")
        }
        if reply.flags.contains(.queryFailure) {
            let document = reply.documents.first ?? [:]
            throw MongoError.fromReply(document, defaultMessage: "Query failed")
        }
        if reply.flags.contains(.cursorNotFound) {
            throw MongoError(.command, "The server cursor was not found (it may have timed out)", code: 43, codeName: "CursorNotFound")
        }
        return reply
    }

    // MARK: Lifecycle

    public func close() {
        markBroken()
    }

    private func markBroken() {
        isBroken = true
        transport.close()
    }

    /// Closes the socket from any context (used for cancellation and pool shutdown).
    public nonisolated func forceClose() {
        transport.close()
    }

    // MARK: I/O

    private func roundTrip(_ request: WireRequest) async throws -> ReceivedMessage? {
        guard !isBroken else {
            throw MongoError(.connectionClosed, "The connection to \(address) is closed")
        }
        guard !inFlight else {
            throw MongoError(.protocolViolation, "Connection \(id) is already executing an operation")
        }
        if Task.isCancelled { throw MongoError.cancelled() }

        inFlight = true
        defer { inFlight = false }

        let requestID = nextRequestID
        nextRequestID = nextRequestID == .max ? 1 : nextRequestID + 1
        let bytes: [UInt8]
        do {
            bytes = try request.encode(requestID: requestID)
        } catch {
            // Nothing was written, so the connection stays usable.
            throw MongoError(.invalidArgument, "Could not encode the request: \(error)")
        }
        if let limit = hello?.maxMessageSizeBytes, bytes.count > limit {
            throw MongoError(.invalidArgument, "The request is \(bytes.count) bytes, larger than the server limit of \(limit) bytes")
        }

        let transport = self.transport
        do {
            return try await withTaskCancellationHandler {
                try await transport.send(bytes)
                guard request.expectsReply else { return nil }
                return try await readReply(to: requestID)
            } onCancel: {
                transport.close()
            }
        } catch {
            markBroken()
            if Task.isCancelled { throw MongoError.cancelled() }
            throw Self.mapIOError(error, address: address)
        }
    }

    private func readReply(to requestID: Int32) async throws -> ReceivedMessage {
        while true {
            if let bytes = try framer.nextMessage() {
                let message = try WireDecoder.decode(bytes)
                if message.header.responseTo == requestID { return message }
                continue // stale reply to an abandoned request
            }
            framer.append(try await transport.receive())
        }
    }

    static func mapIOError(_ error: any Error, address: ServerAddress) -> MongoError {
        switch error {
        case let mongo as MongoError:
            return mongo
        case let wire as MongoWireError:
            return MongoError(.protocolViolation, "\(address): \(wire.description)")
        case let bson as BSONError:
            return MongoError(.protocolViolation, "\(address) sent invalid BSON: \(bson.description)")
        default:
            return MongoError(.network, "Connection to \(address) failed: \(error.localizedDescription)")
        }
    }
}

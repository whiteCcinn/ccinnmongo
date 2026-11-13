import BSON
import Foundation
import MongoWire
import os
@testable import MongoKit

/// In-process fake MongoDB server speaking the real wire protocol, configurable by wire version.
/// It records every request so tests can assert which opcodes and commands were used.
final class FakeMongoServer: @unchecked Sendable {
    enum Request: Sendable {
        case command(database: String, body: BSONDocument, viaOpMsg: Bool, secondaryOk: Bool)
        case query(namespace: String, query: BSONDocument, skip: Int32, numberToReturn: Int32, selector: BSONDocument?, flags: Int32)
        case getMore(namespace: String, numberToReturn: Int32, cursorID: Int64)
        case killCursors([Int64])

        var commandName: String? {
            if case let .command(_, body, _, _) = self { return body.elements.first?.key }
            return nil
        }
    }

    enum Response {
        /// Command reply (wrapped in OP_REPLY or OP_MSG to match the request).
        case document(BSONDocument)
        /// OP_REPLY for legacy queries/getMores.
        case legacy(cursorID: Int64, documents: [BSONDocument], flags: Int32 = 0)
        /// Close the socket without replying.
        case disconnect
        case none
    }

    struct Configuration: Sendable {
        var maxWireVersion: Int
        var setName: String?
        var isWritablePrimary = true
        var isSecondary = false
        var hosts: [String] = []
        var primary: String?
        var isMongos = false
        var saslSupportedMechs: [String]?
        /// Split every reply into chunks of this size to exercise framing.
        var chunkSize: Int?
        /// Accept connections but never answer anything (not even the handshake).
        var silent = false
    }

    let configuration: Configuration
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let handler: @Sendable (Request) -> Response

    struct State {
        var requests: [Request] = []
        var transportsCreated = 0
        var openTransports = 0
    }

    init(_ configuration: Configuration, handler: @escaping @Sendable (Request) -> Response = { _ in .document(["ok": 1]) }) {
        self.configuration = configuration
        self.handler = handler
    }

    var requests: [Request] { state.withLock { $0.requests } }
    var transportsCreated: Int { state.withLock { $0.transportsCreated } }
    var openTransports: Int { state.withLock { $0.openTransports } }
    var commandNames: [String] { requests.compactMap(\.commandName) }

    var helloDocument: BSONDocument {
        var doc: BSONDocument = [
            "ismaster": .bool(configuration.isWritablePrimary),
            "maxBsonObjectSize": 16_777_216,
            "maxMessageSizeBytes": 48_000_000,
            "maxWriteBatchSize": .int32(configuration.maxWireVersion >= 6 ? 100_000 : 1000),
            "maxWireVersion": .int32(Int32(configuration.maxWireVersion)),
            "minWireVersion": 0,
            "ok": 1.0,
        ]
        if configuration.isSecondary { doc["secondary"] = true }
        if let setName = configuration.setName {
            doc["setName"] = .string(setName)
            doc["hosts"] = .array(configuration.hosts.map { .string($0) })
            if let primary = configuration.primary { doc["primary"] = .string(primary) }
        }
        if configuration.isMongos { doc["msg"] = "isdbgrid" }
        if let mechs = configuration.saslSupportedMechs { doc["saslSupportedMechs"] = .array(mechs.map { .string($0) }) }
        return doc
    }

    func makeTransport() -> any MongoTransport {
        state.withLock {
            $0.transportsCreated += 1
            $0.openTransports += 1
        }
        return FakeTransport(server: self)
    }

    var transportFactory: TransportFactory {
        { _, _ in self.makeTransport() }
    }

    fileprivate func transportClosed() {
        state.withLock { $0.openTransports -= 1 }
    }

    /// Decodes a request, records it, and produces reply bytes (or nil for no reply / disconnect).
    fileprivate func handle(_ bytes: [UInt8]) -> (reply: [UInt8]?, disconnect: Bool) {
        guard let (requestID, request) = try? Self.decode(bytes) else { return (nil, true) }
        state.withLock { $0.requests.append(request) }
        if configuration.silent { return (nil, false) }

        if case let .command(_, body, viaOpMsg, _) = request, let name = body.elements.first?.key,
           name == "isMaster" || name == "ismaster" || name == "hello" {
            return (try? Self.encodeReply(.document(helloDocument), to: requestID, viaOpMsg: viaOpMsg), false)
        }
        let response = handler(request)
        switch response {
        case .disconnect: return (nil, true)
        case .none: return (nil, false)
        default:
            let viaOpMsg: Bool
            if case let .command(_, _, opMsg, _) = request { viaOpMsg = opMsg } else { viaOpMsg = false }
            return (try? Self.encodeReply(response, to: requestID, viaOpMsg: viaOpMsg), false)
        }
    }

    static func decode(_ bytes: [UInt8]) throws -> (Int32, Request) {
        var reader = BSONReader(bytes: bytes)
        _ = try reader.readInt32()
        let requestID = try reader.readInt32()
        _ = try reader.readInt32()
        let opCode = try reader.readInt32()
        switch opCode {
        case 2004:
            let flags = try reader.readInt32()
            let namespace = try reader.readCString()
            let skip = try reader.readInt32()
            let numberToReturn = try reader.readInt32()
            let query = try reader.readDocument()
            let selector = reader.isAtEnd ? nil : try reader.readDocument()
            if namespace.hasSuffix(".$cmd") {
                var body = query
                if case let .document(inner)? = query["$query"] { body = inner }
                let database = String(namespace.dropLast(5))
                return (requestID, .command(database: database, body: body, viaOpMsg: false, secondaryOk: flags & 4 != 0))
            }
            return (requestID, .query(namespace: namespace, query: query, skip: skip, numberToReturn: numberToReturn, selector: selector, flags: flags))
        case 2005:
            _ = try reader.readInt32()
            let namespace = try reader.readCString()
            let numberToReturn = try reader.readInt32()
            let cursorID = try reader.readInt64()
            return (requestID, .getMore(namespace: namespace, numberToReturn: numberToReturn, cursorID: cursorID))
        case 2007:
            _ = try reader.readInt32()
            let count = Int(try reader.readInt32())
            var ids: [Int64] = []
            for _ in 0..<max(0, count) { ids.append(try reader.readInt64()) }
            return (requestID, .killCursors(ids))
        case 2013:
            let message = try WireDecoder.decode(bytes)
            guard case let .msg(msg) = message.reply else { throw MongoWireError.malformed("not OP_MSG") }
            var body = msg.body
            let database = body["$db"]?.stringValue ?? "admin"
            let secondaryOk = body["$readPreference"] != nil
            body["$db"] = nil
            body["$readPreference"] = nil
            return (requestID, .command(database: database, body: body, viaOpMsg: true, secondaryOk: secondaryOk))
        default:
            throw MongoWireError.unsupportedOpCode(opCode)
        }
    }

    static func encodeReply(_ response: Response, to requestID: Int32, viaOpMsg: Bool) throws -> [UInt8] {
        var writer = BSONWriter()
        writer.writeInt32(0)
        writer.writeInt32(Int32.random(in: 1...1_000_000))
        writer.writeInt32(requestID)
        switch response {
        case let .document(document) where viaOpMsg:
            writer.writeInt32(2013)
            writer.writeUInt32(0)
            writer.writeBytes([0])
            try writer.writeDocument(document)
        case let .document(document):
            try writeOpReply(&writer, cursorID: 0, documents: [document], flags: 0)
        case let .legacy(cursorID, documents, flags):
            try writeOpReply(&writer, cursorID: cursorID, documents: documents, flags: flags)
        case .disconnect, .none:
            break
        }
        var bytes = writer.bytes
        let total = UInt32(bytes.count)
        for index in 0..<4 { bytes[index] = UInt8(truncatingIfNeeded: total >> UInt32(index * 8)) }
        return bytes
    }

    private static func writeOpReply(_ writer: inout BSONWriter, cursorID: Int64, documents: [BSONDocument], flags: Int32) throws {
        writer.writeInt32(1)
        writer.writeInt32(flags)
        writer.writeInt64(cursorID)
        writer.writeInt32(0)
        writer.writeInt32(Int32(documents.count))
        for document in documents { try writer.writeDocument(document) }
    }
}

/// Transport whose peer is a `FakeMongoServer`.
final class FakeTransport: MongoTransport, @unchecked Sendable {
    private struct State {
        var pending: [[UInt8]] = []
        var waiter: CheckedContinuation<[UInt8], any Error>?
        var closed = false
    }

    private let server: FakeMongoServer
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(server: FakeMongoServer) {
        self.server = server
    }

    func send(_ bytes: [UInt8]) async throws {
        if state.withLock({ $0.closed }) { throw MongoError(.connectionClosed, "fake transport closed") }
        let (reply, disconnect) = server.handle(bytes)
        if disconnect {
            close()
            return
        }
        guard let reply else { return }
        var chunks: [[UInt8]] = [reply]
        if let size = server.configuration.chunkSize, size > 0 {
            chunks = stride(from: 0, to: reply.count, by: size).map { Array(reply[$0..<min($0 + size, reply.count)]) }
        }
        for chunk in chunks { deliver(chunk) }
    }

    private func deliver(_ chunk: [UInt8]) {
        let waiter: CheckedContinuation<[UInt8], any Error>? = state.withLock { state in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.pending.append(chunk)
            return nil
        }
        waiter?.resume(returning: chunk)
    }

    private enum ReceiveOutcome: Sendable {
        case chunk([UInt8])
        case closed
        case wait
    }

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            let outcome: ReceiveOutcome = state.withLock { state in
                if !state.pending.isEmpty { return .chunk(state.pending.removeFirst()) }
                if state.closed { return .closed }
                state.waiter = continuation
                return .wait
            }
            switch outcome {
            case let .chunk(bytes): continuation.resume(returning: bytes)
            case .closed: continuation.resume(throwing: MongoError(.connectionClosed, "fake server closed the connection"))
            case .wait: break
            }
        }
    }

    func close() {
        let (waiter, wasOpen): (CheckedContinuation<[UInt8], any Error>?, Bool) = state.withLock { state in
            let wasOpen = !state.closed
            state.closed = true
            let waiter = state.waiter
            state.waiter = nil
            return (waiter, wasOpen)
        }
        if wasOpen { server.transportClosed() }
        waiter?.resume(throwing: MongoError(.connectionClosed, "fake transport closed"))
    }
}

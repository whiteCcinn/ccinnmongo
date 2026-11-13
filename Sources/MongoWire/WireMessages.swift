import BSON

/// MongoDB wire-protocol opcodes.
public enum OpCode: Int32, Sendable {
    case reply = 1
    case update = 2001
    case insert = 2002
    case query = 2004
    case getMore = 2005
    case delete = 2006
    case killCursors = 2007
    case compressed = 2012
    case msg = 2013
}

public struct MessageHeader: Sendable, Equatable {
    public static let size = 16

    public var messageLength: Int32
    public var requestID: Int32
    public var responseTo: Int32
    public var opCode: Int32
}

public enum MongoWireError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMessageLength(Int)
    case messageTooLarge(size: Int, limit: Int)
    case unsupportedOpCode(Int32)
    case malformed(String)

    public var description: String {
        switch self {
        case let .invalidMessageLength(length): "Invalid wire message length \(length)"
        case let .messageTooLarge(size, limit): "Wire message of \(size) bytes exceeds the limit of \(limit) bytes"
        case let .unsupportedOpCode(code): "Unsupported wire opcode \(code)"
        case let .malformed(reason): "Malformed server reply: \(reason)"
        }
    }
}

// MARK: - Flags

public struct OpQueryFlags: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let tailableCursor = OpQueryFlags(rawValue: 1 << 1)
    /// Historically called `slaveOk`: allows reads from secondaries.
    public static let secondaryOk = OpQueryFlags(rawValue: 1 << 2)
    public static let noCursorTimeout = OpQueryFlags(rawValue: 1 << 4)
    public static let awaitData = OpQueryFlags(rawValue: 1 << 5)
    public static let exhaust = OpQueryFlags(rawValue: 1 << 6)
    public static let partial = OpQueryFlags(rawValue: 1 << 7)
}

public struct OpMsgFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let checksumPresent = OpMsgFlags(rawValue: 1 << 0)
    public static let moreToCome = OpMsgFlags(rawValue: 1 << 1)
    public static let exhaustAllowed = OpMsgFlags(rawValue: 1 << 16)
}

public struct OpReplyFlags: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let cursorNotFound = OpReplyFlags(rawValue: 1 << 0)
    public static let queryFailure = OpReplyFlags(rawValue: 1 << 1)
    public static let shardConfigStale = OpReplyFlags(rawValue: 1 << 2)
    public static let awaitCapable = OpReplyFlags(rawValue: 1 << 3)
}

// MARK: - Requests

/// Legacy query (MongoDB ≤ 3.4 for commands and finds; handshake on every version).
public struct OpQuery: Sendable {
    public var flags: OpQueryFlags
    public var fullCollectionName: String
    public var numberToSkip: Int32
    public var numberToReturn: Int32
    public var query: BSONDocument
    public var returnFieldsSelector: BSONDocument?

    public init(flags: OpQueryFlags = [], fullCollectionName: String, numberToSkip: Int32 = 0,
                numberToReturn: Int32, query: BSONDocument, returnFieldsSelector: BSONDocument? = nil) {
        self.flags = flags
        self.fullCollectionName = fullCollectionName
        self.numberToSkip = numberToSkip
        self.numberToReturn = numberToReturn
        self.query = query
        self.returnFieldsSelector = returnFieldsSelector
    }
}

public struct OpGetMore: Sendable {
    public var fullCollectionName: String
    public var numberToReturn: Int32
    public var cursorID: Int64

    public init(fullCollectionName: String, numberToReturn: Int32, cursorID: Int64) {
        self.fullCollectionName = fullCollectionName
        self.numberToReturn = numberToReturn
        self.cursorID = cursorID
    }
}

public struct OpKillCursors: Sendable {
    public var cursorIDs: [Int64]
    public init(cursorIDs: [Int64]) { self.cursorIDs = cursorIDs }
}

public struct DocumentSequence: Sendable, Equatable {
    public var identifier: String
    public var documents: [BSONDocument]

    public init(identifier: String, documents: [BSONDocument]) {
        self.identifier = identifier
        self.documents = documents
    }
}

/// Extensible message format used by MongoDB 3.6+.
public struct OpMsg: Sendable {
    public var flags: OpMsgFlags
    public var body: BSONDocument
    public var sequences: [DocumentSequence]

    public init(flags: OpMsgFlags = [], body: BSONDocument, sequences: [DocumentSequence] = []) {
        self.flags = flags
        self.body = body
        self.sequences = sequences
    }
}

public enum WireRequest: Sendable {
    case query(OpQuery)
    case getMore(OpGetMore)
    case killCursors(OpKillCursors)
    case msg(OpMsg)

    /// `OP_KILL_CURSORS` and fire-and-forget `OP_MSG` produce no reply.
    public var expectsReply: Bool {
        switch self {
        case .killCursors: false
        case let .msg(msg): !msg.flags.contains(.moreToCome)
        case .query, .getMore: true
        }
    }

    public func encode(requestID: Int32) throws -> [UInt8] {
        var writer = BSONWriter(capacity: 512)
        writer.writeInt32(0) // length, patched below
        writer.writeInt32(requestID)
        writer.writeInt32(0)

        switch self {
        case let .query(query):
            writer.writeInt32(OpCode.query.rawValue)
            writer.writeInt32(query.flags.rawValue)
            try writer.writeCString(query.fullCollectionName, context: "collection name")
            writer.writeInt32(query.numberToSkip)
            writer.writeInt32(query.numberToReturn)
            try writer.writeDocument(query.query)
            if let selector = query.returnFieldsSelector {
                try writer.writeDocument(selector)
            }
        case let .getMore(getMore):
            writer.writeInt32(OpCode.getMore.rawValue)
            writer.writeInt32(0)
            try writer.writeCString(getMore.fullCollectionName, context: "collection name")
            writer.writeInt32(getMore.numberToReturn)
            writer.writeInt64(getMore.cursorID)
        case let .killCursors(kill):
            writer.writeInt32(OpCode.killCursors.rawValue)
            writer.writeInt32(0)
            writer.writeInt32(Int32(clamping: kill.cursorIDs.count))
            for id in kill.cursorIDs { writer.writeInt64(id) }
        case let .msg(msg):
            writer.writeInt32(OpCode.msg.rawValue)
            writer.writeUInt32(msg.flags.subtracting(.checksumPresent).rawValue)
            writer.writeBytes([0])
            try writer.writeDocument(msg.body)
            for sequence in msg.sequences {
                writer.writeBytes([1])
                var section = BSONWriter()
                section.writeInt32(0)
                try section.writeCString(sequence.identifier, context: "sequence identifier")
                for document in sequence.documents { try section.writeDocument(document) }
                var sectionBytes = section.bytes
                Self.patchLength(&sectionBytes, at: 0, value: sectionBytes.count)
                writer.writeBytes(sectionBytes)
            }
        }

        var bytes = writer.bytes
        guard bytes.count <= Int32.max else { throw MongoWireError.messageTooLarge(size: bytes.count, limit: Int(Int32.max)) }
        Self.patchLength(&bytes, at: 0, value: bytes.count)
        return bytes
    }

    private static func patchLength(_ bytes: inout [UInt8], at offset: Int, value: Int) {
        let v = UInt32(truncatingIfNeeded: value)
        bytes[offset] = UInt8(truncatingIfNeeded: v)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: v >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }
}

// MARK: - Replies

public struct OpReply: Sendable {
    public var flags: OpReplyFlags
    public var cursorID: Int64
    public var startingFrom: Int32
    public var documents: [BSONDocument]
}

public enum WireReply: Sendable {
    case reply(OpReply)
    case msg(OpMsg)
}

public struct ReceivedMessage: Sendable {
    public var header: MessageHeader
    public var reply: WireReply
}

public enum WireDecoder {
    /// Decodes one complete message (as produced by `MessageFramer`).
    public static func decode(_ bytes: [UInt8]) throws -> ReceivedMessage {
        var reader = BSONReader(bytes: bytes)
        let length = Int(try reader.readInt32("message length"))
        guard length == bytes.count, length >= MessageHeader.size else {
            throw MongoWireError.invalidMessageLength(length)
        }
        let header = MessageHeader(messageLength: Int32(length),
                                   requestID: try reader.readInt32("request id"),
                                   responseTo: try reader.readInt32("response to"),
                                   opCode: try reader.readInt32("opcode"))
        switch OpCode(rawValue: header.opCode) {
        case .reply:
            return ReceivedMessage(header: header, reply: .reply(try decodeReply(&reader)))
        case .msg:
            return ReceivedMessage(header: header, reply: .msg(try decodeMsg(bytes, from: reader.position)))
        default:
            throw MongoWireError.unsupportedOpCode(header.opCode)
        }
    }

    private static func decodeReply(_ reader: inout BSONReader) throws -> OpReply {
        let flags = OpReplyFlags(rawValue: try reader.readInt32("reply flags"))
        let cursorID = try reader.readInt64("cursor id")
        let startingFrom = try reader.readInt32("starting from")
        let numberReturned = Int(try reader.readInt32("number returned"))
        guard numberReturned >= 0 else { throw MongoWireError.malformed("negative document count \(numberReturned)") }
        var documents: [BSONDocument] = []
        // Each document needs at least 5 bytes; refuse counts the payload cannot possibly hold.
        guard numberReturned <= reader.remaining / 5 else {
            throw MongoWireError.malformed("reply claims \(numberReturned) documents in \(reader.remaining) bytes")
        }
        documents.reserveCapacity(numberReturned)
        for _ in 0..<numberReturned {
            documents.append(try reader.readDocument())
        }
        guard reader.isAtEnd else { throw MongoWireError.malformed("\(reader.remaining) trailing bytes after OP_REPLY documents") }
        return OpReply(flags: flags, cursorID: cursorID, startingFrom: startingFrom, documents: documents)
    }

    private static func decodeMsg(_ bytes: [UInt8], from start: Int) throws -> OpMsg {
        var flagsReader = BSONReader(bytes: bytes, range: start..<bytes.count)
        let flags = OpMsgFlags(rawValue: try flagsReader.readUInt32("OP_MSG flags"))
        var end = bytes.count
        if flags.contains(.checksumPresent) {
            end -= 4
            guard end >= flagsReader.position else { throw MongoWireError.malformed("OP_MSG checksum missing") }
        }
        var reader = BSONReader(bytes: bytes, range: flagsReader.position..<end)
        var body: BSONDocument?
        var sequences: [DocumentSequence] = []
        while !reader.isAtEnd {
            let kind = try reader.readUInt8("section kind")
            switch kind {
            case 0:
                guard body == nil else { throw MongoWireError.malformed("OP_MSG has more than one body section") }
                body = try reader.readDocument()
            case 1:
                let sectionStart = reader.position
                let size = Int(try reader.readInt32("sequence size"))
                guard size >= 5, size <= reader.remaining + 4 else { throw MongoWireError.malformed("invalid document sequence size \(size)") }
                let sectionEnd = sectionStart + size
                let identifier = try reader.readCString("sequence identifier", end: sectionEnd)
                var sectionReader = BSONReader(bytes: bytes, range: reader.position..<sectionEnd)
                var documents: [BSONDocument] = []
                while !sectionReader.isAtEnd { documents.append(try sectionReader.readDocument()) }
                try reader.skip(sectionEnd - reader.position)
                sequences.append(DocumentSequence(identifier: identifier, documents: documents))
            default:
                throw MongoWireError.malformed("unknown OP_MSG section kind \(kind)")
            }
        }
        guard let body else { throw MongoWireError.malformed("OP_MSG without a body section") }
        return OpMsg(flags: flags, body: body, sequences: sequences)
    }
}

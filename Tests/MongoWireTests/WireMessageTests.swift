import Testing
import BSON
@testable import MongoWire

@Suite("Wire messages")
struct WireMessageTests {
    private func header(of bytes: [UInt8]) -> (length: Int32, requestID: Int32, responseTo: Int32, opCode: Int32) {
        var reader = BSONReader(bytes: bytes)
        return (try! reader.readInt32(), try! reader.readInt32(), try! reader.readInt32(), try! reader.readInt32())
    }

    @Test func encodesOpQueryCommand() throws {
        let query = OpQuery(flags: [.secondaryOk], fullCollectionName: "admin.$cmd", numberToSkip: 0,
                            numberToReturn: -1, query: ["isMaster": 1])
        let bytes = try WireRequest.query(query).encode(requestID: 7)
        let doc = try ["isMaster": 1 as BSONValue].bsonBytesForTest()
        // Built step by step: one long chain of `+` on array literals is too slow for older type checkers (Swift 6.2 in CI).
        var expectedBody: [UInt8] = [4, 0, 0, 0]
        expectedBody.append(contentsOf: Array("admin.$cmd".utf8))
        expectedBody.append(0)
        expectedBody.append(contentsOf: [0, 0, 0, 0] as [UInt8])
        expectedBody.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF] as [UInt8])
        expectedBody.append(contentsOf: doc)
        let h = header(of: bytes)
        #expect(Int(h.length) == bytes.count)
        #expect(h.requestID == 7)
        #expect(h.responseTo == 0)
        #expect(h.opCode == 2004)
        #expect(Array(bytes[16...]) == expectedBody)
    }

    @Test func encodesOpQueryWithFieldSelector() throws {
        let query = OpQuery(fullCollectionName: "db.c", numberToSkip: 5, numberToReturn: 20,
                            query: ["a": 1], returnFieldsSelector: ["b": 1])
        let bytes = try WireRequest.query(query).encode(requestID: 1)
        let selector = try ["b": 1 as BSONValue].bsonBytesForTest()
        #expect(Array(bytes.suffix(selector.count)) == selector)
    }

    @Test func opMsgRoundTrip() throws {
        let message = OpMsg(flags: [], body: ["find": "c", "$db": "test"],
                            sequences: [DocumentSequence(identifier: "documents", documents: [["a": 1], ["b": 2]])])
        let bytes = try WireRequest.msg(message).encode(requestID: 42)
        #expect(header(of: bytes).opCode == 2013)
        let decoded = try WireDecoder.decode(bytes)
        guard case let .msg(msg) = decoded.reply else {
            Issue.record("expected OP_MSG")
            return
        }
        #expect(decoded.header.requestID == 42)
        #expect(msg.body == message.body)
        #expect(msg.sequences == message.sequences)
    }

    @Test func opMsgChecksumIsSkipped() throws {
        var bytes = try WireRequest.msg(OpMsg(body: ["ok": 1])).encode(requestID: 1)
        bytes[16] = 1 // checksumPresent
        bytes += [0xDE, 0xAD, 0xBE, 0xEF]
        let total = UInt32(bytes.count)
        bytes[0] = UInt8(total & 0xFF); bytes[1] = UInt8(total >> 8 & 0xFF)
        let decoded = try WireDecoder.decode(bytes)
        guard case let .msg(msg) = decoded.reply else {
            Issue.record("expected OP_MSG")
            return
        }
        #expect(msg.body == ["ok": 1])
    }

    @Test func decodesOpReply() throws {
        let bytes = try Self.opReply(responseTo: 9, flags: 0, cursorID: 1234, documents: [["ok": 1], ["x": "y"]])
        let decoded = try WireDecoder.decode(bytes)
        #expect(decoded.header.responseTo == 9)
        guard case let .reply(reply) = decoded.reply else {
            Issue.record("expected OP_REPLY")
            return
        }
        #expect(reply.cursorID == 1234)
        #expect(reply.documents == [["ok": 1], ["x": "y"]])
    }

    @Test func opReplyWithWrongDocumentCountIsRejected() throws {
        var bytes = try Self.opReply(responseTo: 1, flags: 0, cursorID: 0, documents: [["ok": 1]])
        bytes[32] = 5 // numberReturned = 5 but only one document present
        #expect(throws: (any Error).self) { try WireDecoder.decode(bytes) }
    }

    @Test func encodesGetMoreAndKillCursors() throws {
        let getMore = try WireRequest.getMore(OpGetMore(fullCollectionName: "db.c", numberToReturn: 10, cursorID: 99)).encode(requestID: 3)
        #expect(header(of: getMore).opCode == 2005)
        #expect(getMore.count == 16 + 4 + 5 + 4 + 8)
        let kill = WireRequest.killCursors(OpKillCursors(cursorIDs: [1, 2]))
        #expect(!kill.expectsReply)
        let killBytes = try kill.encode(requestID: 4)
        #expect(header(of: killBytes).opCode == 2007)
        #expect(killBytes.count == 16 + 4 + 4 + 16)
    }

    @Test func rejectsUnsupportedOpCode() throws {
        var bytes = try Self.opReply(responseTo: 1, flags: 0, cursorID: 0, documents: [])
        bytes[12] = 0xDC; bytes[13] = 0x07 // 2012 OP_COMPRESSED
        #expect(throws: MongoWireError.self) { try WireDecoder.decode(bytes) }
    }

    @Test func malformedRepliesNeverCrash() throws {
        let valid = try Self.opReply(responseTo: 1, flags: 0, cursorID: 5, documents: [["a": 1], ["b": "two"]])
        let msg = try WireRequest.msg(OpMsg(body: ["ok": 1, "cursor": ["firstBatch": [1, 2, 3]]])).encode(requestID: 2)
        var rng = SystemRandomNumberGenerator()
        for base in [valid, msg] {
            for _ in 0..<3_000 {
                var bytes = base
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
                if Bool.random(using: &rng) { bytes.removeLast(Int.random(in: 0...min(8, bytes.count), using: &rng)) }
                _ = try? WireDecoder.decode(bytes)
            }
        }
    }

    static func opReply(responseTo: Int32, flags: Int32, cursorID: Int64, documents: [BSONDocument]) throws -> [UInt8] {
        var writer = BSONWriter()
        writer.writeInt32(0)
        writer.writeInt32(100)
        writer.writeInt32(responseTo)
        writer.writeInt32(1)
        writer.writeInt32(flags)
        writer.writeInt64(cursorID)
        writer.writeInt32(0)
        writer.writeInt32(Int32(documents.count))
        for doc in documents { try writer.writeDocument(doc) }
        var bytes = writer.bytes
        let total = UInt32(bytes.count)
        bytes[0] = UInt8(total & 0xFF); bytes[1] = UInt8(total >> 8 & 0xFF); bytes[2] = UInt8(total >> 16 & 0xFF)
        return bytes
    }
}

extension BSONDocument {
    func bsonBytesForTest() throws -> [UInt8] { try bsonBytes() }
}

extension Dictionary where Key == String, Value == BSONValue {
    func bsonBytesForTest() throws -> [UInt8] {
        try BSONDocument(pairs: map { ($0.key, $0.value) }).bsonBytes()
    }
}

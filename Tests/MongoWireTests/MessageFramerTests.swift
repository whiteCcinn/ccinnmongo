import Testing
import BSON
@testable import MongoWire

@Suite("Message framer")
struct MessageFramerTests {
    private func message(_ n: Int) throws -> [UInt8] {
        try WireMessageTests.opReply(responseTo: Int32(n), flags: 0, cursorID: 0, documents: [["n": .int32(Int32(n))]])
    }

    @Test func reassemblesSplitMessages() throws {
        let bytes = try message(1)
        var framer = MessageFramer()
        for byte in bytes.dropLast() {
            framer.append([byte])
            #expect(try framer.nextMessage() == nil)
        }
        framer.append([bytes.last!])
        #expect(try framer.nextMessage() == bytes)
        #expect(framer.bufferedByteCount == 0)
    }

    @Test func splitsMergedMessages() throws {
        let a = try message(1), b = try message(2), c = try message(3)
        var framer = MessageFramer()
        framer.append(a + b + Array(c.prefix(5)))
        #expect(try framer.nextMessage() == a)
        #expect(try framer.nextMessage() == b)
        #expect(try framer.nextMessage() == nil)
        framer.append(Array(c.dropFirst(5)))
        #expect(try framer.nextMessage() == c)
    }

    @Test func rejectsImpossibleLengths() {
        var framer = MessageFramer(maxMessageSize: 1024)
        framer.append([0x0A, 0, 0, 0])
        #expect(throws: MongoWireError.self) { try framer.nextMessage() }

        var tooLarge = MessageFramer(maxMessageSize: 1024)
        tooLarge.append([0x00, 0x10, 0, 0])
        #expect(throws: MongoWireError.self) { try tooLarge.nextMessage() }

        var negative = MessageFramer()
        negative.append([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: MongoWireError.self) { try negative.nextMessage() }
    }

    @Test func manyMessagesStayLinear() throws {
        var framer = MessageFramer()
        let one = try message(7)
        var stream: [UInt8] = []
        for _ in 0..<5_000 { stream += one }
        var received = 0
        var offset = 0
        while offset < stream.count {
            let size = min(1_000, stream.count - offset)
            framer.append(Array(stream[offset..<(offset + size)]))
            offset += size
            while try framer.nextMessage() != nil { received += 1 }
        }
        #expect(received == 5_000)
    }
}

import Foundation
import Testing
@testable import BSON

@Suite("BSON malformed input safety")
struct BSONMalformedTests {
    @Test func truncatedDocumentIsRejected() {
        var bytes = BSONCodecTests.helloWorld
        bytes.removeLast(3)
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func declaredLengthLargerThanBufferIsRejected() {
        var bytes = BSONCodecTests.helloWorld
        bytes[0] = 0xFF
        bytes[1] = 0xFF
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func negativeLengthIsRejected() {
        let bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func missingTerminatorIsRejected() {
        var bytes = BSONCodecTests.helloWorld
        bytes[bytes.count - 1] = 0x01
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func stringLengthOverrunIsRejected() {
        var bytes = BSONCodecTests.helloWorld
        bytes[11] = 0x7F // string length way past the document end
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func zeroStringLengthIsRejected() {
        var bytes = BSONCodecTests.helloWorld
        bytes[11] = 0x00
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func unknownTypeIsRejected() {
        var bytes = BSONCodecTests.helloWorld
        bytes[4] = 0x42
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func invalidBooleanIsRejected() {
        let bytes: [UInt8] = [0x09, 0x00, 0x00, 0x00, 0x08, 0x62, 0x00, 0x02, 0x00]
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    @Test func trailingBytesAreRejected() {
        let bytes = BSONCodecTests.helloWorld + [0x00]
        #expect(throws: BSONError.self) { try BSONDocument(bsonBytes: bytes) }
    }

    /// Raw bytes of `{a: {a: ... {}}}` with `depth` documents in total, built without recursion.
    static func nestedBytes(depth: Int) -> [UInt8] {
        var inner: [UInt8] = [5, 0, 0, 0, 0]
        for _ in 1..<depth {
            let length = UInt32(4 + 1 + 2 + inner.count + 1)
            var outer: [UInt8] = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), 0]
            outer += [0x03, 0x61, 0x00]
            outer += inner
            outer.append(0)
            inner = outer
        }
        return inner
    }

    @Test func excessiveNestingIsRejectedWhenDecoding() {
        let bytes = Self.nestedBytes(depth: BSONLimits.maximumDepth + 50)
        #expect(throws: BSONError.depthLimitExceeded(limit: BSONLimits.maximumDepth)) {
            try BSONDocument(bsonBytes: bytes)
        }
    }

    @Test func excessiveNestingIsRejectedWhenEncoding() {
        var value: BSONValue = .int32(1)
        for _ in 0..<(BSONLimits.maximumDepth + 5) { value = .document(["a": value]) }
        let doc: BSONDocument = ["root": value]
        #expect(throws: BSONError.self) { try doc.bsonBytes() }
    }

    /// The deepest legal document must round trip on a secondary thread (512 KB stack) in debug builds.
    @Test func maximumLegalDepthIsStackSafe() async throws {
        let bytes = Self.nestedBytes(depth: BSONLimits.maximumDepth)
        let roundTripped = try await Task.detached {
            try BSONDocument(bsonBytes: bytes).bsonBytes()
        }.value
        #expect(roundTripped == bytes)
    }

    @Test func randomBytesNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        var decodedCount = 0
        for iteration in 0..<10_000 {
            let length = Int.random(in: 0...96, using: &generator)
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            // Give half of the samples a plausible header so the decoder walks deeper.
            if iteration.isMultiple(of: 2), bytes.count >= 5 {
                let total = UInt32(bytes.count)
                bytes[0] = UInt8(total & 0xFF); bytes[1] = UInt8((total >> 8) & 0xFF)
                bytes[2] = 0; bytes[3] = 0; bytes[bytes.count - 1] = 0
            }
            if (try? BSONDocument(bsonBytes: bytes)) != nil { decodedCount += 1 }
        }
        #expect(decodedCount >= 0)
    }

    @Test func mutatedValidDocumentsNeverCrash() throws {
        let original = try BSONCodecTests.everyTypeDocument().bsonBytes()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            var bytes = original
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? BSONDocument(bsonBytes: bytes)
        }
    }
}

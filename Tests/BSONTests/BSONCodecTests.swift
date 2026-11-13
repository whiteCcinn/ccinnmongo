import Foundation
import Testing
@testable import BSON

@Suite("BSON binary codec")
struct BSONCodecTests {
    /// `{"hello": "world"}` from bsonspec.org.
    static let helloWorld: [UInt8] = [
        0x16, 0x00, 0x00, 0x00, 0x02, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x00,
        0x06, 0x00, 0x00, 0x00, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x00, 0x00,
    ]

    /// `{"BSON": ["awesome", 5.05, 1986]}` from bsonspec.org.
    static let awesome: [UInt8] = [
        0x31, 0x00, 0x00, 0x00, 0x04, 0x42, 0x53, 0x4F, 0x4E, 0x00, 0x26, 0x00,
        0x00, 0x00, 0x02, 0x30, 0x00, 0x08, 0x00, 0x00, 0x00, 0x61, 0x77, 0x65,
        0x73, 0x6F, 0x6D, 0x65, 0x00, 0x01, 0x31, 0x00, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x14, 0x40, 0x10, 0x32, 0x00, 0xC2, 0x07, 0x00, 0x00, 0x00,
        0x00,
    ]

    @Test func decodesSpecExamples() throws {
        let hello = try BSONDocument(bsonBytes: Self.helloWorld)
        #expect(hello["hello"] == .string("world"))

        let awesome = try BSONDocument(bsonBytes: Self.awesome)
        #expect(awesome["BSON"] == .array([.string("awesome"), .double(5.05), .int32(1986)]))
    }

    @Test func encodesSpecExamples() throws {
        let hello: BSONDocument = ["hello": "world"]
        #expect(try hello.bsonBytes() == Self.helloWorld)

        let awesome: BSONDocument = ["BSON": [.string("awesome"), .double(5.05), .int32(1986)]]
        #expect(try awesome.bsonBytes() == Self.awesome)
    }

    static func everyTypeDocument() -> BSONDocument {
        let oid = ObjectId(hex: "507f1f77bcf86cd799439011")!
        var doc = BSONDocument()
        doc.append("double", .double(-12.5))
        doc.append("string", .string("grove 🌳 ünïcødé"))
        doc.append("document", .document(["nested": .int32(1), "deeper": .document(["x": .null])]))
        doc.append("array", .array([.int32(1), .string("two"), .document(["three": .int64(3)])]))
        doc.append("binary", .binary(BSONBinary(subtype: .generic, data: Data([0, 1, 2, 255]))))
        doc.append("oldBinary", .binary(BSONBinary(subtype: .binaryOld, data: Data([9, 8, 7]))))
        doc.append("uuid", .binary(BSONBinary(uuid: UUID(uuidString: "C8EDE1E9-7B17-4E0A-B2D5-2CC4E1E0A1E6")!)))
        doc.append("undefined", .undefined)
        doc.append("objectId", .objectId(oid))
        doc.append("true", .bool(true))
        doc.append("false", .bool(false))
        doc.append("datetime", .datetime(BSONDateTime(millisecondsSinceEpoch: 1_700_000_000_123)))
        doc.append("null", .null)
        doc.append("regex", .regex(BSONRegex(pattern: "^gro+ve$", options: "im")))
        doc.append("dbPointer", .dbPointer(BSONDBPointer(namespace: "db.coll", id: oid)))
        doc.append("javascript", .javascript("function() { return 1; }"))
        doc.append("symbol", .symbol("sym"))
        doc.append("codeWithScope", .javascriptWithScope(BSONCodeWithScope(code: "x + y", scope: ["x": .int32(1)])))
        doc.append("int32", .int32(-2_147_483_648))
        doc.append("timestamp", .timestamp(BSONTimestamp(timestamp: 1_700_000_000, increment: 42)))
        doc.append("int64", .int64(Int64.max))
        doc.append("decimal128", .decimal128(Decimal128(string: "-1.23E+3000")!))
        doc.append("minKey", .minKey)
        doc.append("maxKey", .maxKey)
        return doc
    }

    @Test func everyTypeRoundTripsByteForByte() throws {
        let doc = Self.everyTypeDocument()
        let bytes = try doc.bsonBytes()
        let decoded = try BSONDocument(bsonBytes: bytes)
        #expect(decoded == doc)
        #expect(try decoded.bsonBytes() == bytes)
        #expect(decoded.count == doc.count)
    }

    @Test func preservesOrderAndDuplicateKeys() throws {
        var doc = BSONDocument()
        doc.append("b", .int32(1))
        doc.append("a", .int32(2))
        doc.append("b", .int32(3))
        let decoded = try BSONDocument(bsonBytes: try doc.bsonBytes())
        #expect(decoded.keys == ["b", "a", "b"])
        #expect(decoded.elements.map(\.value) == [.int32(1), .int32(2), .int32(3)])
    }

    @Test func numericTypesStayDistinct() throws {
        let doc: BSONDocument = ["i": .int32(1), "l": .int64(1), "d": .double(1.0)]
        let decoded = try BSONDocument(bsonBytes: try doc.bsonBytes())
        #expect(decoded["i"]?.type == .int32)
        #expect(decoded["l"]?.type == .int64)
        #expect(decoded["d"]?.type == .double)
        #expect(decoded["i"] != decoded["l"])
    }

    @Test func farFutureDateRoundTrips() throws {
        let doc: BSONDocument = ["max": .datetime(BSONDateTime(millisecondsSinceEpoch: .max)),
                                 "min": .datetime(BSONDateTime(millisecondsSinceEpoch: .min))]
        let decoded = try BSONDocument(bsonBytes: try doc.bsonBytes())
        #expect(decoded == doc)
    }

    @Test func doublesCompareByBitPattern() throws {
        let nan: BSONValue = .double(.nan)
        #expect(nan == .double(.nan))
        #expect(BSONValue.double(0.0) != .double(-0.0))
    }

    @Test func keyWithNullByteCannotBeEncoded() {
        let doc: BSONDocument = ["bad\0key": .int32(1)]
        #expect(throws: BSONError.self) { try doc.bsonBytes() }
    }

    @Test func subscriptSetReplacesAndRemoves() {
        var doc: BSONDocument = ["a": 1, "b": 2]
        doc["a"] = .string("x")
        doc["c"] = .bool(true)
        doc["b"] = nil
        #expect(doc.keys == ["a", "c"])
        #expect(doc["a"] == .string("x"))
    }

    @Test func dottedPathLookup() {
        let doc: BSONDocument = ["a": .document(["b": .array([.int32(10), .document(["c": "deep"])])])]
        #expect(doc.value(atPath: "a.b.1.c") == .string("deep"))
        #expect(doc.value(atPath: "a.b.0") == .int32(10))
        #expect(doc.value(atPath: "a.z") == nil)
    }

    @Test func literalsProduceExpectedTypes() {
        let doc: BSONDocument = ["small": 5, "big": 5_000_000_000, "f": 1.5, "s": "x", "t": true, "n": nil]
        #expect(doc["small"] == .int32(5))
        #expect(doc["big"] == .int64(5_000_000_000))
        #expect(doc["f"] == .double(1.5))
        #expect(doc["s"] == .string("x"))
        #expect(doc["t"] == .bool(true))
        #expect(doc["n"] == .null)
    }

    @Test func numericAccessors() {
        #expect(BSONValue.int32(7).int64Value == 7)
        #expect(BSONValue.double(7.0).int64Value == 7)
        #expect(BSONValue.double(7.5).int64Value == nil)
        #expect(BSONValue.int64(9).doubleValue == 9.0)
        #expect(BSONValue.string("9").int64Value == nil)
        #expect(BSONValue.bool(true).isTruthy)
        #expect(BSONValue.int32(1).isTruthy)
        #expect(!BSONValue.double(0).isTruthy)
    }

    @Test func decodesSequenceOfDocuments() throws {
        let bytes = Self.helloWorld + Self.awesome
        var reader = BSONReader(bytes: bytes)
        let first = try reader.readDocument()
        let second = try reader.readDocument()
        #expect(first["hello"] == .string("world"))
        #expect(second["BSON"]?.arrayValue?.count == 3)
        #expect(reader.isAtEnd)
    }
}

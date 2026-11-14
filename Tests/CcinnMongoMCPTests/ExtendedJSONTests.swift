import BSON
import Foundation
import Testing
@testable import CcinnMongoMCP

@Suite("Relaxed Extended JSON rendering")
struct ExtendedJSONTests {
    @Test func rendersEveryBSONType() throws {
        let oid = try #require(ObjectId(hex: "507f1f77bcf86cd799439011"))
        var document = BSONDocument()
        document.append("double", .double(-12.5))
        document.append("integralDouble", .double(3))
        document.append("nan", .double(.nan))
        document.append("inf", .double(-.infinity))
        document.append("string", .string("ünï 🌳"))
        document.append("document", .document(["a": .int32(1)]))
        document.append("array", .array([.int32(1), .string("x")]))
        document.append("binary", .binary(BSONBinary(subtype: .generic, data: Data([0, 1, 255]))))
        document.append("undefined", .undefined)
        document.append("objectId", .objectId(oid))
        document.append("bool", .bool(true))
        document.append("date", .datetime(BSONDateTime(millisecondsSinceEpoch: 1_700_000_000_123)))
        document.append("oldDate", .datetime(BSONDateTime(millisecondsSinceEpoch: -1000)))
        document.append("null", .null)
        document.append("regex", .regex(BSONRegex(pattern: "^a", options: "i")))
        document.append("dbPointer", .dbPointer(BSONDBPointer(namespace: "db.c", id: oid)))
        document.append("code", .javascript("function(){}"))
        document.append("symbol", .symbol("sym"))
        document.append("codeWithScope", .javascriptWithScope(BSONCodeWithScope(code: "x", scope: ["x": .int32(1)])))
        document.append("int32", .int32(-7))
        document.append("timestamp", .timestamp(BSONTimestamp(timestamp: 10, increment: 2)))
        document.append("int64", .int64(Int64.max))
        document.append("decimal", .decimal128(try #require(Decimal128(string: "1.50"))))
        document.append("minKey", .minKey)
        document.append("maxKey", .maxKey)

        let rendered = ExtendedJSONRenderer.full.render(document)
        #expect(!rendered.wasShortened)
        let text = JSONWriter.string(rendered.value)
        #expect(text == #"{"double":-12.5,"integralDouble":3.0,"nan":{"$numberDouble":"NaN"},"inf":{"$numberDouble":"-Infinity"},"# +
            #""string":"ünï 🌳","document":{"a":1},"array":[1,"x"],"binary":{"$binary":{"base64":"AAH/","subType":"00"}},"# +
            #""undefined":{"$undefined":true},"objectId":{"$oid":"507f1f77bcf86cd799439011"},"bool":true,"# +
            #""date":{"$date":"2023-11-14T22:13:20.123Z"},"oldDate":{"$date":{"$numberLong":"-1000"}},"null":null,"# +
            #""regex":{"$regularExpression":{"pattern":"^a","options":"i"}},"# +
            #""dbPointer":{"$dbPointer":{"$ref":"db.c","$id":{"$oid":"507f1f77bcf86cd799439011"}}},"code":{"$code":"function(){}"},"# +
            #""symbol":{"$symbol":"sym"},"codeWithScope":{"$code":"x","$scope":{"x":1}},"int32":-7,"# +
            #""timestamp":{"$timestamp":{"t":10,"i":2}},"int64":9223372036854775807,"decimal":{"$numberDecimal":"1.50"},"# +
            #""minKey":{"$minKey":1},"maxKey":{"$maxKey":1}}"#)
    }

    @Test func compactModeShortensLargeValues() {
        let document: BSONDocument = [
            "text": .string(String(repeating: "a", count: 5000)),
            "blob": .binary(BSONBinary(subtype: .generic, data: Data(count: 10_000))),
            "list": .array((0..<500).map { .int32(Int32($0)) }),
        ]
        let rendered = ExtendedJSONRenderer.compact.render(document)
        #expect(rendered.wasShortened)
        let object = rendered.value.objectValue
        let text = object?["text"]?.stringValue ?? ""
        #expect(text.hasPrefix(String(repeating: "a", count: 1000)))
        #expect(text.hasSuffix("… [4000 more characters]"))
        #expect(object?["blob"]?.stringValue == "<binary subtype 00, 10000 bytes omitted>")
        let list = object?["list"]?.arrayValue ?? []
        #expect(list.count == 51)
        #expect(list.last == "… [450 more elements]")
    }

    @Test func compactModeCapsDepth() {
        var value: BSONValue = .int32(1)
        for _ in 0..<40 { value = .document(["n": value]) }
        guard case let .document(document) = value else { return }
        let rendered = ExtendedJSONRenderer.compact.render(document)
        #expect(rendered.wasShortened)
        #expect(JSONWriter.string(rendered.value).contains("\"{…}\""))
    }

    @Test func documentsFitTheBudget() {
        let documents = (0..<100).map { index -> BSONDocument in
            ["_id": .int32(Int32(index)), "pad": .string(String(repeating: "x", count: 1000))]
        }
        let batch = DocumentBatch.render(documents, maxBytes: 20_000)
        #expect(batch.truncated)
        #expect(batch.documents.count < 100)
        #expect(batch.documents.count > 10)
        let total = batch.documents.reduce(0) { $0 + JSONWriter.encodedSize($1) + 1 }
        #expect(total <= 20_000)
    }

    @Test func smallResultsAreNotTruncated() {
        let documents: [BSONDocument] = [["a": 1], ["a": 2]]
        let batch = DocumentBatch.render(documents, maxBytes: 20_000)
        #expect(!batch.truncated)
        #expect(batch.documents == [["a": 1], ["a": 2]])
    }

    @Test func oversizedSingleDocumentIsShortenedInsteadOfDropped() {
        let documents: [BSONDocument] = [["_id": 1, "big": .string(String(repeating: "y", count: 100_000))], ["_id": 2]]
        let batch = DocumentBatch.render(documents, maxBytes: 4_000)
        #expect(batch.truncated)
        #expect(batch.documents.count == 2)
        #expect(batch.documents[0].objectValue?["big"]?.stringValue?.hasSuffix("more characters]") == true)
        #expect(batch.documents[1] == ["_id": 2])
    }
}

import BSON
import Testing
@testable import CcinnMongoKit

@Suite("Schema analysis")
struct SchemaAnalyzerTests {
    @Test func reportsPresenceAndTypeDistribution() {
        var documents: [BSONDocument] = []
        for index in 0..<10 {
            var document: BSONDocument = ["_id": .int32(Int32(index))]
            document["age"] = index < 6 ? .int32(Int32(20 + index)) : .string("unknown")
            if index < 5 { document["email"] = .string("u\(index)@x.io") }
            documents.append(document)
        }
        let schema = SchemaAnalyzer.analyze(documents)
        #expect(schema.sampleSize == 10)
        let age = try! #require(schema.fields.first { $0.name == "age" })
        #expect(age.presence == 1.0)
        #expect(age.types.map(\.type) == [.int32, .string])
        #expect(age.types.map(\.count) == [6, 4])
        let email = try! #require(schema.fields.first { $0.name == "email" })
        #expect(email.presence == 0.5)
        #expect(email.sampleValues.count <= SchemaAnalyzer.maxSampleValues)
    }

    @Test func nestedDocumentsAndArrays() {
        let documents: [BSONDocument] = [
            ["address": ["city": "KL", "zip": 50000], "tags": ["a", "b"]],
            ["address": ["city": "Penang"], "tags": [.int32(1)]],
        ]
        let schema = SchemaAnalyzer.analyze(documents)
        let address = try! #require(schema.fields.first { $0.name == "address" })
        #expect(address.children.map(\.name) == ["city", "zip"])
        #expect(address.children.first { $0.name == "zip" }?.presence == 0.5)
        #expect(address.children.first { $0.name == "zip" }?.path == "address.zip")
        let tags = try! #require(schema.fields.first { $0.name == "tags" })
        #expect(tags.types.map(\.type) == [.array])
        #expect(Set(tags.arrayElementTypes.map(\.type)) == [.string, .int32])
    }

    @Test func fieldOrderFollowsFirstAppearance() {
        let schema = SchemaAnalyzer.analyze([["b": 1, "a": 1], ["c": 1, "a": 2]])
        #expect(schema.fields.map(\.name) == ["b", "a", "c"])
        #expect(schema.allFieldPaths == ["b", "a", "c"])
    }

    @Test func emptyInput() {
        let schema = SchemaAnalyzer.analyze([])
        #expect(schema.fields.isEmpty)
        #expect(schema.sampleSize == 0)
    }
}

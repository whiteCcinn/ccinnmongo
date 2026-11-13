import BSON
import Foundation
import Testing
@testable import CcinnMongoKit

@Suite("Export and import")
struct ExportTests {
    let oid = ObjectId(hex: "507f1f77bcf86cd799439011")!

    @Test func csvFlattensNestedFieldsWithUnionHeader() {
        let documents: [BSONDocument] = [
            ["_id": .objectId(oid), "name": "Ann, \"A\"", "address": ["city": "KL"], "tags": ["x", "y"]],
            ["_id": 2, "address": ["zip": 50000], "when": .datetime(BSONDateTime(millisecondsSinceEpoch: 0)), "ok": true, "none": .null],
        ]
        let paths = CSVExporter.fieldPaths(of: documents)
        #expect(paths == ["_id", "name", "address.city", "tags", "address.zip", "when", "ok", "none"])
        let csv = CSVExporter.header(paths) + documents.map { CSVExporter.row($0, paths: paths) }.joined()
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "_id,name,address.city,tags,address.zip,when,ok,none")
        #expect(lines[1] == #"507f1f77bcf86cd799439011,"Ann, ""A""",KL,"[""x"", ""y""]",,,,"#)
        #expect(lines[2] == "2,,,,50000,1970-01-01T00:00:00.000Z,true,")
    }

    @Test func jsonArrayAndNDJSONWriters() throws {
        let documents: [BSONDocument] = [["_id": .objectId(oid), "n": .int64(5)], ["_id": 2]]
        var array = DocumentExportWriter(format: .jsonArray)
        var output = array.begin()
        output += array.write(documents)
        output += array.finish()
        let reparsed = try ShellSyntax.parseDocumentSequence(output)
        #expect(reparsed.count == 2)
        #expect(reparsed[0]["_id"] == .objectId(oid))

        var lines = DocumentExportWriter(format: .ndjson)
        let ndjson = lines.begin() + lines.write(documents) + lines.finish()
        #expect(ndjson.split(separator: "\n").count == 2)
        #expect(try ShellSyntax.parseDocumentSequence(ndjson).count == 2)
    }

    @Test func importReadsArraysAndNDJSON() throws {
        let ndjson = #"{"a": 1}"# + "\n" + #"{"a": {"$numberLong": "2"}}"# + "\n"
        let documents = try DocumentImporter.parse(ndjson)
        #expect(documents.map { $0["a"] } == [.int32(1), .int64(2)])
    }
}

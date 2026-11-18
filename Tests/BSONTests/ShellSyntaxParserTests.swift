import Foundation
import Testing
@testable import BSON

@Suite("Shell syntax parser")
struct ShellSyntaxParserTests {
    @Test func parsesQueryWithConstructors() throws {
        let doc = try ShellSyntax.parseDocument(
            #"{_id: ObjectId('65a0c0ffee0000000000beef'), at: {$gte: ISODate("2024-01-01")}, n: NumberLong(5)}"#
        )
        #expect(doc["_id"] == .objectId(ObjectId(hex: "65a0c0ffee0000000000beef")!))
        #expect(doc["at"] == .document(["$gte": .datetime(BSONDateTime(millisecondsSinceEpoch: 1_704_067_200_000))]))
        #expect(doc["n"] == .int64(5))
    }

    @Test func parsesRegexLiteral() throws {
        let doc = try ShellSyntax.parseDocument("{name: /^gro+ve$/i}")
        #expect(doc["name"] == .regex(BSONRegex(pattern: "^gro+ve$", options: "i")))
    }

    @Test func regexLiteralWithEscapedSlashAndClass() throws {
        let doc = try ShellSyntax.parseDocument(#"{u: /https?:\/\/[^/]+\//}"#)
        #expect(doc["u"] == .regex(BSONRegex(pattern: #"https?:\/\/[^/]+\/"#, options: "")))
    }

    @Test func typesNumberLiterals() throws {
        let doc = try ShellSyntax.parseDocument("{a: 1, b: 3000000000, c: 1.0, d: 1e3, e: -2147483648, f: -5, g: 0x1F, h: .5}")
        #expect(doc["a"] == .int32(1))
        #expect(doc["b"] == .int64(3_000_000_000))
        #expect(doc["c"] == .double(1.0))
        #expect(doc["d"] == .double(1000))
        #expect(doc["e"] == .int32(.min))
        #expect(doc["f"] == .int32(-5))
        #expect(doc["g"] == .int32(31))
        #expect(doc["h"] == .double(0.5))
    }

    @Test func hugeIntegerBecomesDouble() throws {
        let doc = try ShellSyntax.parseDocument("{a: 99999999999999999999}")
        #expect(doc["a"] == .double(1e20))
    }

    @Test func relaxedSyntaxFeatures() throws {
        let text = """
        {
          // line comment
          'single': 'quoted',
          "double": "quoted",
          unquoted$key_1: true, /* block
          comment */
          "a.b": null,
          trailing: [1, 2, 3,],
          esc: "tab\\tnewline\\nquote\\"uni\\u00e9",
          ok: false,
        }
        """
        let doc = try ShellSyntax.parseDocument(text)
        #expect(doc.keys == ["single", "double", "unquoted$key_1", "a.b", "trailing", "esc", "ok"])
        #expect(doc["single"] == .string("quoted"))
        #expect(doc["trailing"] == .array([.int32(1), .int32(2), .int32(3)]))
        #expect(doc["esc"] == .string("tab\tnewline\nquote\"unié"))
    }

    @Test func parsesAllConstructors() throws {
        let text = """
        {
          oid: ObjectId("507f1f77bcf86cd799439011"),
          d1: new Date("2024-02-29T12:34:56.789Z"),
          d2: Date(0),
          d3: ISODate("2024-01-01T08:00:00+08:00"),
          i: NumberInt("42"),
          l: NumberLong("9007199254740993"),
          dec: NumberDecimal("1.10"),
          dec2: NumberDecimal(2.5),
          ts: Timestamp(1700000000, 7),
          ts2: Timestamp({t: 1, i: 2}),
          bin: BinData(0, "AAEC"),
          hex: HexData(5, "00ff"),
          uuid: UUID("c8ede1e9-7b17-4e0a-b2d5-2cc4e1e0a1e6"),
          min: MinKey(),
          max: MaxKey,
          ref: DBRef("users", ObjectId("507f1f77bcf86cd799439011"), "app"),
          code: Code("return 1"),
          scoped: Code("x", {x: 1}),
          re: RegExp("a/b", "si"),
          undef: undefined,
          inf: -Infinity,
          nan: NaN
        }
        """
        let doc = try ShellSyntax.parseDocument(text)
        let oid = ObjectId(hex: "507f1f77bcf86cd799439011")!
        #expect(doc["oid"] == .objectId(oid))
        #expect(doc["d1"] == .datetime(BSONDateTime(millisecondsSinceEpoch: 1_709_210_096_789)))
        #expect(doc["d2"] == .datetime(BSONDateTime(millisecondsSinceEpoch: 0)))
        #expect(doc["d3"] == .datetime(BSONDateTime(millisecondsSinceEpoch: 1_704_067_200_000)))
        #expect(doc["i"] == .int32(42))
        #expect(doc["l"] == .int64(9_007_199_254_740_993))
        #expect(doc["dec"] == .decimal128(Decimal128(string: "1.10")!))
        #expect(doc["dec2"] == .decimal128(Decimal128(string: "2.5")!))
        #expect(doc["ts"] == .timestamp(BSONTimestamp(timestamp: 1_700_000_000, increment: 7)))
        #expect(doc["ts2"] == .timestamp(BSONTimestamp(timestamp: 1, increment: 2)))
        #expect(doc["bin"] == .binary(BSONBinary(subtype: .generic, data: Data([0, 1, 2]))))
        #expect(doc["hex"] == .binary(BSONBinary(subtype: .md5, data: Data([0, 255]))))
        #expect(doc["uuid"]?.binaryValue?.uuid == UUID(uuidString: "c8ede1e9-7b17-4e0a-b2d5-2cc4e1e0a1e6"))
        #expect(doc["min"] == .minKey)
        #expect(doc["max"] == .maxKey)
        #expect(doc["ref"] == .document(["$ref": "users", "$id": .objectId(oid), "$db": "app"]))
        #expect(doc["code"] == .javascript("return 1"))
        #expect(doc["scoped"] == .javascriptWithScope(BSONCodeWithScope(code: "x", scope: ["x": 1])))
        #expect(doc["re"] == .regex(BSONRegex(pattern: "a/b", options: "is")))
        #expect(doc["undef"] == .undefined)
        #expect(doc["inf"] == .double(-.infinity))
        #expect(doc["nan"] == .double(.nan))
    }

    @Test func objectIdWithoutArgumentGeneratesNewId() throws {
        let doc = try ShellSyntax.parseDocument("{_id: ObjectId()}")
        #expect(doc["_id"]?.objectIdValue != nil)
    }

    @Test func canonicalExtendedJSONWrappers() throws {
        let text = """
        {"n": {"$numberLong": "42"}, "i": {"$numberInt": "7"}, "d": {"$numberDouble": "-Infinity"},
         "dec": {"$numberDecimal": "1E+3"}, "oid": {"$oid": "507f1f77bcf86cd799439011"},
         "date": {"$date": {"$numberLong": "1000"}}, "date2": {"$date": "1970-01-01T00:00:01Z"},
         "bin": {"$binary": {"base64": "AAE=", "subType": "04"}},
         "legacyBin": {"$binary": "AAE=", "$type": "80"},
         "ts": {"$timestamp": {"t": 5, "i": 6}},
         "re": {"$regularExpression": {"pattern": "^a", "options": "mi"}},
         "sym": {"$symbol": "s"}, "code": {"$code": "c"}, "cws": {"$code": "c", "$scope": {"a": 1}},
         "min": {"$minKey": 1}, "max": {"$maxKey": 1}, "undef": {"$undefined": true},
         "ptr": {"$dbPointer": {"$ref": "db.c", "$id": {"$oid": "507f1f77bcf86cd799439011"}}},
         "uuid": {"$uuid": "c8ede1e9-7b17-4e0a-b2d5-2cc4e1e0a1e6"}}
        """
        let doc = try ShellSyntax.parseDocument(text)
        let oid = ObjectId(hex: "507f1f77bcf86cd799439011")!
        #expect(doc["n"] == .int64(42))
        #expect(doc["i"] == .int32(7))
        #expect(doc["d"] == .double(-.infinity))
        #expect(doc["dec"] == .decimal128(Decimal128(string: "1E+3")!))
        #expect(doc["oid"] == .objectId(oid))
        #expect(doc["date"] == .datetime(BSONDateTime(millisecondsSinceEpoch: 1000)))
        #expect(doc["date2"] == .datetime(BSONDateTime(millisecondsSinceEpoch: 1000)))
        #expect(doc["bin"] == .binary(BSONBinary(subtype: .uuid, data: Data([0, 1]))))
        #expect(doc["legacyBin"] == .binary(BSONBinary(subtype: .userDefined, data: Data([0, 1]))))
        #expect(doc["ts"] == .timestamp(BSONTimestamp(timestamp: 5, increment: 6)))
        #expect(doc["re"] == .regex(BSONRegex(pattern: "^a", options: "im")))
        #expect(doc["sym"] == .symbol("s"))
        #expect(doc["code"] == .javascript("c"))
        #expect(doc["cws"] == .javascriptWithScope(BSONCodeWithScope(code: "c", scope: ["a": 1])))
        #expect(doc["min"] == .minKey)
        #expect(doc["max"] == .maxKey)
        #expect(doc["undef"] == .undefined)
        #expect(doc["ptr"] == .dbPointer(BSONDBPointer(namespace: "db.c", id: oid)))
        #expect(doc["uuid"]?.binaryValue?.subtype == .uuid)
    }

    @Test func queryOperatorsAreNotTreatedAsWrappers() throws {
        let doc = try ShellSyntax.parseDocument(#"{name: {$regex: "^a", $options: "i"}, t: {$type: "string"}, d: {$date: 5, extra: 1}}"#)
        #expect(doc["name"] == .document(["$regex": "^a", "$options": "i"]))
        #expect(doc["t"] == .document(["$type": "string"]))
        #expect(doc["d"] == .document(["$date": 5, "extra": 1]))
    }

    @Test func reportsLineAndColumn() {
        #expect(throws: SyntaxError.self) { try ShellSyntax.parseDocument("{a: 1") }
        do {
            _ = try ShellSyntax.parseDocument("{a: 1")
        } catch let error as SyntaxError {
            #expect(error.line == 1)
            #expect(error.column == 6)
            #expect(error.message.contains("end of input"))
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            _ = try ShellSyntax.parseDocument("{\n  a: 1,\n  b: foo\n}")
        } catch let error as SyntaxError {
            #expect(error.line == 3)
            #expect(error.column == 6)
            #expect(error.message.contains("foo"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(arguments: [
        "", "{", "}", "{a}", "{a:}", "{a: 1 b: 2}", "[1, 2", "{a: ObjectId('xyz')}", "{a: ISODate('nope')}",
        "{a: NumberInt('9999999999')}", "{a: 'unterminated}", "{a: /unterminated}", "{a: Foo(1)}",
        "{a: 1}}", "{a: NumberDecimal('1.2.3')}", "{a: BinData(0, '!!!')}", "{a: --1}", "{a: new 5}",
        "{a: Timestamp(1)}", "{a: UUID('123')}", "{a: 'x' 'y'}", "{,}", "{a: 1,,}",
    ])
    func rejectsInvalidInput(_ text: String) {
        #expect(throws: SyntaxError.self, "accepted: \(text)") { try ShellSyntax.parseDocument(text) }
    }

    @Test func emptyInputAllowedWhenRequested() throws {
        #expect(try ShellSyntax.parseDocument("   \n", allowEmpty: true) == BSONDocument())
    }

    @Test func parsesPipelineArray() throws {
        let stages = try ShellSyntax.parseArray(#"[{$match: {a: 1}}, {$count: "n"}]"#)
        #expect(stages.count == 2)
        #expect(stages[1] == .document(["$count": "n"]))
    }

    @Test func parsesDocumentSequences() throws {
        let ndjson = "{\"a\": 1}\n{\"a\": 2}\n\n{\"a\": 3}\n"
        #expect(try ShellSyntax.parseDocumentSequence(ndjson).count == 3)
        let array = "[{a: 1}, {a: 2}]"
        #expect(try ShellSyntax.parseDocumentSequence(array).count == 2)
        #expect(throws: SyntaxError.self) { try ShellSyntax.parseDocumentSequence("[1, 2]") }
    }

    @Test func deepNestingIsRejectedNotCrashing() async {
        let depth = BSONLimits.maximumDepth + 10
        let text = String(repeating: "{a: ", count: depth) + "1" + String(repeating: "}", count: depth)
        _ = await Task.detached {
            #expect(throws: SyntaxError.self) { try ShellSyntax.parseDocument(text) }
        }.value
    }

    @Test func garbageNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("{}[]():,'\"/\\*-+.0123456789eExabc$_ \n\tObjectIdISODateNumberLong")
        for _ in 0..<5_000 {
            let length = Int.random(in: 0...60, using: &rng)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
            _ = try? ShellSyntax.parseDocument(text)
        }
    }
}

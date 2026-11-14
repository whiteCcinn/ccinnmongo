import Foundation
import Testing
@testable import CcinnMongoMCP

@Suite("JSON parser and writer")
struct JSONTests {
    @Test func parsesScalars() throws {
        #expect(try JSONParser.parse("null") == .null)
        #expect(try JSONParser.parse(" true ") == .bool(true))
        #expect(try JSONParser.parse("false") == .bool(false))
        #expect(try JSONParser.parse("0") == .int(0))
        #expect(try JSONParser.parse("-42") == .int(-42))
        #expect(try JSONParser.parse("9223372036854775807") == .int(Int64.max))
        #expect(try JSONParser.parse("-9223372036854775808") == .int(Int64.min))
        #expect(try JSONParser.parse("9223372036854775808") == .double(9_223_372_036_854_775_808))
        #expect(try JSONParser.parse("1.5") == .double(1.5))
        #expect(try JSONParser.parse("-2.5e3") == .double(-2500))
        #expect(try JSONParser.parse("1E-2") == .double(0.01))
        #expect(try JSONParser.parse("\"hi\"") == .string("hi"))
    }

    @Test func parsesEscapesAndUnicode() throws {
        #expect(try JSONParser.parse(#""a\"b\\c\/d\b\f\n\r\t""#) == .string("a\"b\\c/d\u{8}\u{c}\n\r\t"))
        #expect(try JSONParser.parse(#""\u00e9\u4e2d""#) == .string("é中"))
        #expect(try JSONParser.parse(#""\ud83c\udf33""#) == .string("🌳"))
        #expect(try JSONParser.parse("\"ünïcødé 🌳\"") == .string("ünïcødé 🌳"))
        // Lone surrogates cannot be represented in Swift strings; they become U+FFFD instead of failing.
        #expect(try JSONParser.parse(#""\ud800x""#) == .string("\u{FFFD}x"))
        #expect(try JSONParser.parse(#""\udc00""#) == .string("\u{FFFD}"))
    }

    @Test func preservesObjectKeyOrder() throws {
        let value = try JSONParser.parse(#"{"z": 1, "a": 2, "m": {"b": 1, "a": -1}}"#)
        #expect(value.objectValue?.keys == ["z", "a", "m"])
        #expect(value.objectValue?["m"]?.objectValue?.keys == ["b", "a"])
        #expect(JSONWriter.string(value) == #"{"z":1,"a":2,"m":{"b":1,"a":-1}}"#)
    }

    @Test func duplicateKeysKeepTheLastValueAtTheFirstPosition() throws {
        let value = try JSONParser.parse(#"{"a": 1, "b": 2, "a": 3}"#)
        #expect(value.objectValue?.keys == ["a", "b"])
        #expect(value.objectValue?["a"] == .int(3))
    }

    @Test func manyDuplicateKeysStayLinear() throws {
        // 200k members with only a few distinct keys must not degrade quadratically.
        var text = "{"
        for index in 0..<200_000 { text += (index == 0 ? "" : ",") + "\"k\(index % 50)\":\(index)" }
        text += "}"
        let start = ContinuousClock.now
        let value = try JSONParser.parse(text)
        #expect(value.objectValue?.count == 50)
        #expect(ContinuousClock.now - start < .seconds(5))
        // Many distinct keys too.
        var distinct = "{"
        for index in 0..<100_000 { distinct += (index == 0 ? "" : ",") + "\"k\(index)\":1" }
        distinct += "}"
        #expect(try JSONParser.parse(distinct).objectValue?.count == 100_000)
    }

    @Test func rejectsMalformedInput() {
        let bad = ["", " ", "{", "}", "[1,]", "{\"a\":}", "{\"a\" 1}", "{a: 1}", "'x'", "01", "1.", ".5", "-", "1e", "+1",
                   "tru", "nul", "\"abc", "\"\\x\"", "\"\\u12\"", "[1 2]", "{\"a\":1,}", "1 2", "\"a\u{0}b\"", "\"tab\there\"",
                   "1e400", "-1e400", "NaN", "Infinity", "[", "[[[]]"]
        for text in bad {
            #expect(throws: JSONParseError.self, "\(text.debugDescription) should be rejected") { try JSONParser.parse(text) }
        }
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(bytes: [0x22, 0xFF, 0xFE, 0x22]) }
    }

    @Test func enforcesDepthLimit() throws {
        let deep = String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
        #expect(throws: JSONParseError.self) { try JSONParser.parse(deep) }
        let ok = String(repeating: "[", count: 128) + String(repeating: "]", count: 128)
        #expect(throws: Never.self) { try JSONParser.parse(ok) }
        // A pathological 1M-deep input fails fast instead of overflowing the stack.
        let huge = String(repeating: "{\"a\":", count: 1_000_000)
        #expect(throws: JSONParseError.self) { try JSONParser.parse(huge) }
    }

    @Test func writerEscapesControlCharactersSoOutputIsOneLine() throws {
        let value: JSONValue = ["text": .string("line1\nline2\r\t\"q\" \\ \u{1}\u{1F} é 🌳 \u{2028}")]
        let text = JSONWriter.string(value)
        #expect(!text.contains("\n"))
        #expect(!text.contains("\r"))
        #expect(text == #"{"text":"line1\nline2\r\t\"q\" \\ \u0001\u001f é 🌳 \u2028"}"#)
        #expect(try JSONParser.parse(text) == value)
    }

    @Test func writerHandlesNumbers() throws {
        #expect(JSONWriter.string(.double(1)) == "1.0")
        #expect(JSONWriter.string(.double(0.1)) == "0.1")
        #expect(JSONWriter.string(.double(-0.0)) == "-0.0")
        #expect(JSONWriter.string(.double(1e300)) == "1e+300")
        #expect(JSONWriter.string(.double(.nan)) == "null")
        #expect(JSONWriter.string(.double(.infinity)) == "null")
        #expect(JSONWriter.string(.int(Int64.min)) == "-9223372036854775808")
        for number in [1e300, 5e-324, 123.456, -0.000001] {
            #expect(try JSONParser.parse(JSONWriter.string(.double(number))) == .double(number))
        }
    }

    @Test func roundTripsComplexValues() throws {
        let text = #"{"jsonrpc":"2.0","id":7,"params":{"arguments":{"filter":{"$and":[{"a":{"$gt":1.5}},{"b":null}]},"tags":["x",true,false]}}}"#
        let value = try JSONParser.parse(text)
        #expect(JSONWriter.string(value) == text)
    }

    @Test func accessorsAndLiterals() {
        let value: JSONValue = ["n": 3, "d": 2.0, "s": "x", "b": true, "a": [1, 2], "o": ["k": nil]]
        let object = value.objectValue
        #expect(object?["n"]?.int64Value == 3)
        #expect(object?["d"]?.int64Value == 2)
        #expect(object?["d"]?.doubleValue == 2)
        #expect(object?["s"]?.stringValue == "x")
        #expect(object?["b"]?.boolValue == true)
        #expect(object?["a"]?.arrayValue?.count == 2)
        #expect(object?["o"]?.objectValue?["k"] == .null)
        #expect(object?["missing"] == nil)
        #expect(JSONValue.double(2.5).int64Value == nil)
        #expect(JSONValue.double(1e30).int64Value == nil)
    }

    @Test func objectMutation() {
        var object: JSONObject = ["a": 1]
        object["b"] = 2
        object["a"] = 3
        #expect(object.keys == ["a", "b"])
        #expect(object["a"] == .int(3))
        object["a"] = nil
        #expect(object.keys == ["b"])
    }
}

import Foundation
import Testing
@testable import BSON

@Suite("Formatting and Extended JSON")
struct FormatterTests {
    let oid = ObjectId(hex: "507f1f77bcf86cd799439011")!

    @Test func shellCompactFormatting() {
        let doc: BSONDocument = [
            "_id": .objectId(oid), "n": .int64(5), "i": .int32(3), "d": .double(2.0), "s": "hi \"you\"",
            "when": .datetime(BSONDateTime(millisecondsSinceEpoch: 1_704_067_200_123)),
            "dash-key": .array([.bool(true), .null]),
        ]
        let text = BSONFormatter(style: .shell).format(doc)
        #expect(text == #"{ _id: ObjectId("507f1f77bcf86cd799439011"), n: NumberLong(5), i: 3, d: 2.0, s: "hi \"you\"", when: ISODate("2024-01-01T00:00:00.123Z"), "dash-key": [true, null] }"#)
    }

    @Test func shellPrettyFormatting() {
        let doc: BSONDocument = ["a": .document(["b": .array([1, 2])]), "e": .document([:]), "z": .array([])]
        let text = BSONFormatter(style: .shell, indent: 2).format(doc)
        #expect(text == """
        {
          a: {
            b: [
              1,
              2
            ]
          },
          e: {},
          z: []
        }
        """)
    }

    @Test func relaxedExtendedJSON() {
        let doc: BSONDocument = ["_id": .objectId(oid), "n": .int64(5), "d": .double(1.5), "inf": .double(.infinity),
                                 "when": .datetime(BSONDateTime(millisecondsSinceEpoch: 0)),
                                 "old": .datetime(BSONDateTime(millisecondsSinceEpoch: -1))]
        let text = BSONFormatter(style: .relaxedExtendedJSON).format(doc)
        #expect(text == #"{"_id": {"$oid": "507f1f77bcf86cd799439011"}, "n": 5, "d": 1.5, "inf": {"$numberDouble": "Infinity"}, "when": {"$date": "1970-01-01T00:00:00Z"}, "old": {"$date": {"$numberLong": "-1"}}}"#)
    }

    @Test func canonicalExtendedJSON() {
        let doc: BSONDocument = ["i": .int32(1), "l": .int64(2), "d": .double(3.0),
                                 "dec": .decimal128(Decimal128(string: "4.0")!),
                                 "when": .datetime(BSONDateTime(millisecondsSinceEpoch: 5))]
        let text = BSONFormatter(style: .canonicalExtendedJSON).format(doc)
        #expect(text == #"{"i": {"$numberInt": "1"}, "l": {"$numberLong": "2"}, "d": {"$numberDouble": "3.0"}, "dec": {"$numberDecimal": "4.0"}, "when": {"$date": {"$numberLong": "5"}}}"#)
    }

    @Test func regexFormatting() {
        let formatter = BSONFormatter(style: .shell)
        #expect(formatter.format(.regex(BSONRegex(pattern: "^a.*", options: "i"))) == "/^a.*/i")
        #expect(formatter.format(.regex(BSONRegex(pattern: #"a\/b"#, options: ""))) == #"/a\/b/"#)
        #expect(formatter.format(.regex(BSONRegex(pattern: "a/b", options: "m"))) == #"RegExp("a/b", "m")"#)
        #expect(formatter.format(.regex(BSONRegex(pattern: "", options: ""))) == #"RegExp("", "")"#)
    }

    @Test func formatsSpecialDoubles() {
        let formatter = BSONFormatter(style: .shell)
        #expect(formatter.format(.double(.nan)) == "NaN")
        #expect(formatter.format(.double(-.infinity)) == "-Infinity")
        #expect(formatter.format(.double(-0.0)) == "-0.0")
        #expect(formatter.format(.double(1e16)) == "1e+16")
    }

    @Test func largeInt64UsesQuotedForm() {
        let formatter = BSONFormatter(style: .shell)
        #expect(formatter.format(.int64(9_007_199_254_740_993)) == #"NumberLong("9007199254740993")"#)
        #expect(formatter.format(.int64(-3)) == "NumberLong(-3)")
    }

    @Test func outOfRangeDateUsesNumericForm() {
        let formatter = BSONFormatter(style: .shell)
        #expect(formatter.format(.datetime(BSONDateTime(millisecondsSinceEpoch: .max))) == "new Date(9223372036854775807)")
    }

    @Test(arguments: [nil, 2] as [Int?])
    func shellRoundTripPreservesEveryType(indent: Int?) throws {
        let doc = BSONCodecTests.everyTypeDocument()
        let text = BSONFormatter(style: .shell, indent: indent).format(doc)
        let parsed = try ShellSyntax.parseDocument(text)
        #expect(parsed == doc, "\(text)")
    }

    @Test(arguments: [BSONFormatter.Style.relaxedExtendedJSON, .canonicalExtendedJSON])
    func extendedJSONRoundTripPreservesTypes(style: BSONFormatter.Style) throws {
        let doc = BSONCodecTests.everyTypeDocument()
        let text = BSONFormatter(style: style, indent: 2).format(doc)
        let parsed = try ShellSyntax.parseDocument(text)
        // Relaxed Extended JSON is lossy by design: int64 values become plain numbers, which re-parse
        // as int32 when they fit. Canonical Extended JSON must be exact.
        let expected = style == .relaxedExtendedJSON ? Self.narrowingSmallInt64(doc) : doc
        #expect(parsed == expected, "\(text)")
    }

    static func narrowingSmallInt64(_ doc: BSONDocument) -> BSONDocument {
        BSONDocument(doc.elements.map { BSONElement(key: $0.key, value: narrowingSmallInt64($0.value)) })
    }

    static func narrowingSmallInt64(_ value: BSONValue) -> BSONValue {
        switch value {
        case let .int64(number): Int32(exactly: number).map(BSONValue.int32) ?? value
        case let .document(doc): .document(narrowingSmallInt64(doc))
        case let .array(array): .array(array.map(narrowingSmallInt64))
        default: value
        }
    }

    @Test func randomDocumentsRoundTripThroughShellSyntax() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let doc = RandomDocument.make(depth: 3, using: &rng)
            let text = BSONFormatter(style: .shell, indent: 2).format(doc)
            let parsed = try ShellSyntax.parseDocument(text)
            #expect(parsed == doc, "\(text)")
        }
    }

    @Test func summaryOfHugeValuesIsBounded() {
        let huge: BSONValue = .array((0..<200_000).map { .document(["i": .int32(Int32($0)), "s": .string(String(repeating: "x", count: 50))]) })
        let clock = ContinuousClock()
        let start = clock.now
        let summary = BSONFormatter.summary(of: huge, maxLength: 90)
        #expect(clock.now - start < .milliseconds(50))
        #expect(summary.count <= 91)
        #expect(summary.hasPrefix("[{ i: 0"))
        let longString = BSONFormatter.summary(of: .string(String(repeating: "y", count: 5_000_000)), maxLength: 20)
        #expect(longString.count <= 21)
    }

    @Test func summaryTruncatesLongValues() {
        let long = String(repeating: "x", count: 500)
        let summary = BSONFormatter.summary(of: .string(long), maxLength: 20)
        #expect(summary.count <= 21)
        #expect(summary.hasSuffix("…"))
        #expect(BSONFormatter.summary(of: .document(["a": 1, "b": 2]), maxLength: 80) == "{ a: 1, b: 2 }")
        #expect(BSONFormatter.summary(of: .array(Array(repeating: .int32(1), count: 3)), maxLength: 80) == "[1, 1, 1]")
    }
}

/// Deterministic-shape random document generator for property tests.
enum RandomDocument {
    static func make(depth: Int, using rng: inout SystemRandomNumberGenerator) -> BSONDocument {
        var doc = BSONDocument()
        for index in 0..<Int.random(in: 0...6, using: &rng) {
            doc.append(randomKey(index, using: &rng), value(depth: depth, using: &rng))
        }
        return doc
    }

    static func randomKey(_ index: Int, using rng: inout SystemRandomNumberGenerator) -> String {
        ["k\(index)", "with space \(index)", "ü\(index)", "$op\(index)", "a.b\(index)", "\"q\(index)\""]
            .randomElement(using: &rng)!
    }

    static func value(depth: Int, using rng: inout SystemRandomNumberGenerator) -> BSONValue {
        let pick = Int.random(in: 0...(depth > 0 ? 17 : 15), using: &rng)
        switch pick {
        case 0: return .double(Double.random(in: -1e9...1e9, using: &rng))
        case 1: return .string(["", "plain", "quote\"and\\slash", "line\nbreak", "emoji 🌳", "\u{0001}ctrl"].randomElement(using: &rng)!)
        case 2: return .int32(Int32.random(in: .min ... .max, using: &rng))
        case 3: return .int64(Int64.random(in: .min ... .max, using: &rng))
        case 4: return .bool(Bool.random(using: &rng))
        case 5: return .null
        case 6: return .objectId(ObjectId())
        case 7: return .datetime(BSONDateTime(millisecondsSinceEpoch: Int64.random(in: -62_135_596_800_000...253_402_300_799_999, using: &rng)))
        case 8: return .datetime(BSONDateTime(millisecondsSinceEpoch: Int64.random(in: .min ... .max, using: &rng)))
        case 9: return .binary(BSONBinary(subtype: BSONBinary.Subtype(UInt8.random(in: 0...9, using: &rng)),
                                          data: Data((0..<Int.random(in: 0...20, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })))
        case 10: return .regex(BSONRegex(pattern: ["^a", "x/y", #"\d+\/"#, ""].randomElement(using: &rng)!, options: ["", "i", "imsx"].randomElement(using: &rng)!))
        case 11: return .timestamp(BSONTimestamp(timestamp: UInt32.random(in: 0 ... .max, using: &rng), increment: UInt32.random(in: 0 ... .max, using: &rng)))
        case 12: return .decimal128(Decimal128(string: ["0", "-1.50", "1E+300", "123456789.000001", "NaN", "-Infinity"].randomElement(using: &rng)!)!)
        case 13: return [.minKey, .maxKey, .undefined].randomElement(using: &rng)!
        case 14: return .double([.nan, .infinity, -.infinity, -0.0, 0.1, 1e300, 5e-324].randomElement(using: &rng)!)
        case 15: return [.javascript("f()"), .symbol("s"), .dbPointer(BSONDBPointer(namespace: "a.b", id: ObjectId()))].randomElement(using: &rng)!
        case 16: return .document(make(depth: depth - 1, using: &rng))
        default: return .array((0..<Int.random(in: 0...4, using: &rng)).map { _ in value(depth: depth - 1, using: &rng) })
        }
    }
}

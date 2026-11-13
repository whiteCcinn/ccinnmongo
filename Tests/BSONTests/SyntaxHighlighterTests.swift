import Testing
@testable import BSON

@Suite("Syntax highlighter")
struct SyntaxHighlighterTests {
    private func roles(_ text: String) -> [(String, SyntaxRole)] {
        let units = Array(text.utf16)
        return SyntaxHighlighter.spans(for: text).map { (String(decoding: units[$0.range], as: UTF16.self), $0.role) }
    }

    @Test func classifiesKeysOperatorsAndValues() {
        let result = roles(#"{name: "x", $or: [{"$gt": 5}], at: ISODate("2024-01-01"), ok: true, re: /a/i, f: "$total"} // c"#)
        let lookup = Dictionary(result.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        #expect(lookup["name"] == .key)
        #expect(lookup["$or"] == .operatorKey)
        #expect(lookup["\"$gt\""] == .operatorKey)
        #expect(lookup["\"x\""] == .string)
        #expect(lookup["5"] == .number)
        #expect(lookup["ISODate"] == .constructor)
        #expect(lookup["true"] == .keyword)
        #expect(lookup["/a/i"] == .regex)
        #expect(lookup["\"$total\""] == .fieldReference)
        #expect(lookup["// c"] == .comment)
    }

    @Test func unterminatedTokensAreInvalid() {
        #expect(roles(#"{a: "open"#).last?.1 == .invalid)
        #expect(roles("{a: /open").last?.1 == .invalid)
        #expect(roles("{a: 1 /* open").last?.1 == .invalid)
    }

    @Test func rangesAreUTF16Offsets() {
        let spans = SyntaxHighlighter.spans(for: #"{"🌳": 1}"#)
        // "🌳" is two UTF-16 units, so the quoted key spans 4 units starting at offset 1.
        #expect(spans[1].range == 1..<5)
        #expect(spans[1].role == .key)
    }
}

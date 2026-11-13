import Testing
@testable import CcinnMongoKit

@Suite("Markdown block parser")
struct MarkdownBlockParserTests {
    @Test func parsesTableWithAlignment() {
        let text = """
        | Channel | Revenue | Orders |
        |---|---:|:---:|
        | **web** | 51,860.00 | 200 |
        | mobile | 26,205.00 | 100 |
        """
        let blocks = MarkdownBlockParser.parse(text)
        #expect(blocks == [.table(header: ["Channel", "Revenue", "Orders"], alignments: [.leading, .trailing, .center],
                                  rows: [["**web**", "51,860.00", "200"], ["mobile", "26,205.00", "100"]])])
    }

    @Test func tableRowsArePaddedOrTrimmedToHeaderWidth() {
        let text = "a | b\n--|--\n1\n1 | 2 | 3"
        guard case let .table(_, _, rows) = MarkdownBlockParser.parse(text).first else {
            Issue.record("expected table")
            return
        }
        #expect(rows == [["1", ""], ["1", "2"]])
    }

    @Test func escapedAndCodePipesStayInCells() {
        let text = "| op | meaning |\n|---|---|\n| `a|b` | x \\| y |"
        guard case let .table(_, _, rows) = MarkdownBlockParser.parse(text).first else {
            Issue.record("expected table")
            return
        }
        #expect(rows == [["`a|b`", "x | y"]])
    }

    @Test func parsesMixedBlocks() {
        let text = """
        ## Result

        Web is **bigger**.
        Second line.

        - one
        - two
          - nested

        1. first
        2) second

        > quoted

        ---

        ```js
        db.orders.find({})
        ```
        """
        let blocks = MarkdownBlockParser.parse(text)
        #expect(blocks == [
            .heading(level: 2, text: "Result"),
            .paragraph("Web is **bigger**.\nSecond line."),
            .bulletList([.init(level: 0, text: "one"), .init(level: 0, text: "two"), .init(level: 1, text: "nested")]),
            .orderedList(start: 1, items: ["first", "second"]),
            .quote("quoted"),
            .rule,
            .code(language: "js", text: "db.orders.find({})"),
        ])
    }

    @Test func unterminatedFenceKeepsRemainingText() {
        let blocks = MarkdownBlockParser.parse("```\nlet a = 1\nlet b = 2")
        #expect(blocks == [.code(language: nil, text: "let a = 1\nlet b = 2")])
    }

    @Test func pipeLinesWithoutSeparatorAreParagraphs() {
        #expect(MarkdownBlockParser.parse("a | b") == [.paragraph("a | b")])
    }

    @Test func emptyAndWhitespaceInput() {
        #expect(MarkdownBlockParser.parse("").isEmpty)
        #expect(MarkdownBlockParser.parse("\n  \n").isEmpty)
    }
}

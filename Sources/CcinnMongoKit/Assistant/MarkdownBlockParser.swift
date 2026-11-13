import Foundation

/// Block-level Markdown structure for rendering assistant answers. Inline formatting (bold,
/// italic, code, links) is left in the text for `AttributedString(markdown:)` to handle.
public enum MarkdownBlock: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    public struct ListItem: Sendable, Equatable {
        public let level: Int
        public let text: String

        public init(level: Int, text: String) {
            self.level = level
            self.text = text
        }
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([ListItem])
    case orderedList(start: Int, items: [String])
    case code(language: String?, text: String)
    case table(header: [String], alignments: [Alignment], rows: [[String]])
    case quote(String)
    case rule
}

/// A small, forgiving parser for the Markdown that chat models produce (GitHub-flavoured subset).
/// Linear in the input size and never throws.
public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if let fence = fenceMarker(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1 // closing fence (or end of input)
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }
            if let heading = heading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }
            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }
            if index + 1 < lines.count, trimmed.contains("|"), let alignments = separatorAlignments(lines[index + 1]) {
                let header = cells(trimmed)
                let width = header.count
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !rowLine.isEmpty else { break }
                    var row = cells(rowLine)
                    if row.count < width { row += Array(repeating: "", count: width - row.count) }
                    rows.append(Array(row.prefix(width)))
                    index += 1
                }
                let normalized = alignments.count >= width ? Array(alignments.prefix(width))
                    : alignments + Array(repeating: .leading, count: width - alignments.count)
                blocks.append(.table(header: header, alignments: normalized, rows: rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if bulletItem(line) != nil {
                var items: [MarkdownBlock.ListItem] = []
                while index < lines.count, let item = bulletItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }
            if let first = orderedItem(line) {
                var items: [String] = []
                while index < lines.count, let item = orderedItem(lines[index]) {
                    items.append(item.text)
                    index += 1
                }
                blocks.append(.orderedList(start: first.number, items: items))
                continue
            }
            var paragraph: [String] = []
            while index < lines.count {
                let current = lines[index]
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                if currentTrimmed.isEmpty || startsBlock(current, next: index + 1 < lines.count ? lines[index + 1] : nil), !paragraph.isEmpty {
                    break
                }
                if currentTrimmed.isEmpty { break }
                paragraph.append(currentTrimmed)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: Recognisers

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func bulletItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        guard let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " else { return nil }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if isRule(String(rest)) { return nil }
        return MarkdownBlock.ListItem(level: width / 2, text: text)
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " else { return nil }
        return (number, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    private static func startsBlock(_ line: String, next: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if fenceMarker(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">") { return true }
        if bulletItem(line) != nil || orderedItem(line) != nil { return true }
        if let next, trimmed.contains("|"), separatorAlignments(next) != nil { return true }
        return false
    }

    /// Alignments if `line` is a table separator row such as `|---|:---:|--:|`.
    private static func separatorAlignments(_ line: String) -> [MarkdownBlock.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.allSatisfy({ "-: ".contains($0) }) else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var alignments: [MarkdownBlock.Alignment] = []
        for part in parts {
            let cell = part.replacingOccurrences(of: " ", with: "")
            guard !cell.isEmpty, cell.contains("-"), cell.allSatisfy({ $0 == "-" || $0 == ":" }),
                  !cell.dropFirst().dropLast().contains(":") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// Splits a table row on `|`, honouring `\|` escapes and pipes inside backtick code spans.
    static func cells(_ row: String) -> [String] {
        var content = row.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|"), !content.hasSuffix("\\|") { content.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var iterator = content.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                if let next = iterator.next() {
                    if next == "|" { current.append("|") } else { current.append(character); current.append(next) }
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

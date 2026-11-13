/// Semantic role of a span of source text, derived from the same tokenizer the parser uses so
/// highlighting can never disagree with parsing.
public enum SyntaxRole: Sendable, Hashable {
    case key
    case operatorKey
    case string
    case fieldReference
    case number
    case keyword
    case constructor
    case regex
    case comment
    case punctuation
    case identifier
    case invalid
}

public struct SyntaxSpan: Sendable, Hashable {
    public let role: SyntaxRole
    /// UTF-16 range, directly usable as an `NSRange`.
    public let range: Range<Int>
}

public enum SyntaxHighlighter {
    static let keywords: Set<String> = ["true", "false", "null", "undefined", "NaN", "Infinity", "new", "MinKey", "MaxKey"]
    static let constructors = Set(Constructors.names)

    public static func spans(for text: String) -> [SyntaxSpan] {
        let tokenizer = ShellSyntaxTokenizer(text: text)
        let tokens = tokenizer.tokenize(includeComments: true)
        let units = tokenizer.units
        var spans: [SyntaxSpan] = []
        spans.reserveCapacity(tokens.count)

        func nextSignificant(after index: Int) -> SyntaxToken.Kind? {
            var probe = index + 1
            while probe < tokens.count {
                if tokens[probe].kind != .comment { return tokens[probe].kind }
                probe += 1
            }
            return nil
        }

        func firstUnit(_ token: SyntaxToken, skippingQuote: Bool) -> UInt16? {
            let offset = token.range.lowerBound + (skippingQuote ? 1 : 0)
            return offset < token.range.upperBound ? units[offset] : nil
        }

        for (index, token) in tokens.enumerated() {
            let role: SyntaxRole
            switch token.kind {
            case .leftBrace, .rightBrace, .leftBracket, .rightBracket, .leftParen, .rightParen, .colon, .comma:
                role = .punctuation
            case .minus, .plus, .number:
                role = .number
            case .regex:
                role = token.isTerminated ? .regex : .invalid
            case .comment:
                role = .comment
            case .invalid:
                role = .invalid
            case .string:
                if !token.isTerminated {
                    role = .invalid
                } else if nextSignificant(after: index) == .colon {
                    role = firstUnit(token, skippingQuote: true) == Ascii.dollar ? .operatorKey : .key
                } else {
                    role = firstUnit(token, skippingQuote: true) == Ascii.dollar ? .fieldReference : .string
                }
            case .identifier:
                let name = String(decoding: units[token.range], as: UTF16.self)
                if nextSignificant(after: index) == .colon {
                    role = name.hasPrefix("$") ? .operatorKey : .key
                } else if constructors.contains(name), nextSignificant(after: index) == .leftParen || name == "MinKey" || name == "MaxKey" {
                    role = .constructor
                } else if keywords.contains(name) {
                    role = .keyword
                } else {
                    role = .identifier
                }
            }
            spans.append(SyntaxSpan(role: role, range: token.range))
        }
        return spans
    }
}

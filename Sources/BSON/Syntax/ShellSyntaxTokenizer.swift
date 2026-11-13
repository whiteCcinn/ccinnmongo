/// A lexical token of mongo-shell / Extended JSON syntax. Ranges are UTF-16 offsets so they map
/// directly onto `NSRange` for syntax highlighting.
public struct SyntaxToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case leftBrace, rightBrace, leftBracket, rightBracket, leftParen, rightParen
        case colon, comma, minus, plus
        case string
        case number
        case identifier
        case regex
        case comment
        /// Unrecognised character or unterminated literal.
        case invalid
    }

    public let kind: Kind
    public let range: Range<Int>
    /// False for strings, regexes and block comments that reach the end of input unclosed.
    public let isTerminated: Bool

    public init(kind: Kind, range: Range<Int>, isTerminated: Bool = true) {
        self.kind = kind
        self.range = range
        self.isTerminated = isTerminated
    }
}

/// Converts text into tokens. Never fails: problems are reported as `.invalid` or unterminated
/// tokens so the same pass can drive both highlighting (tolerant) and parsing (strict).
public struct ShellSyntaxTokenizer: Sendable {
    public let units: [UInt16]

    public init(text: String) {
        units = Array(text.utf16)
    }

    public init(units: [UInt16]) {
        self.units = units
    }

    public static func tokenize(_ text: String, includeComments: Bool = false) -> [SyntaxToken] {
        ShellSyntaxTokenizer(text: text).tokenize(includeComments: includeComments)
    }

    public func tokenize(includeComments: Bool = false) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        tokens.reserveCapacity(units.count / 3)
        var index = 0
        let count = units.count

        while index < count {
            let unit = units[index]
            if Self.isWhitespace(unit) {
                index += 1
                continue
            }
            let start = index
            switch unit {
            case Ascii.leftBrace: tokens.append(.init(kind: .leftBrace, range: start..<start + 1)); index += 1
            case Ascii.rightBrace: tokens.append(.init(kind: .rightBrace, range: start..<start + 1)); index += 1
            case Ascii.leftBracket: tokens.append(.init(kind: .leftBracket, range: start..<start + 1)); index += 1
            case Ascii.rightBracket: tokens.append(.init(kind: .rightBracket, range: start..<start + 1)); index += 1
            case Ascii.leftParen: tokens.append(.init(kind: .leftParen, range: start..<start + 1)); index += 1
            case Ascii.rightParen: tokens.append(.init(kind: .rightParen, range: start..<start + 1)); index += 1
            case Ascii.colon: tokens.append(.init(kind: .colon, range: start..<start + 1)); index += 1
            case Ascii.comma: tokens.append(.init(kind: .comma, range: start..<start + 1)); index += 1
            case Ascii.minus: tokens.append(.init(kind: .minus, range: start..<start + 1)); index += 1
            case Ascii.plus: tokens.append(.init(kind: .plus, range: start..<start + 1)); index += 1
            case Ascii.doubleQuote, Ascii.singleQuote:
                let (end, terminated) = scanString(from: start, quote: unit)
                tokens.append(.init(kind: .string, range: start..<end, isTerminated: terminated))
                index = end
            case Ascii.slash:
                let next = index + 1 < count ? units[index + 1] : 0
                if next == Ascii.slash {
                    var end = index + 2
                    while end < count, units[end] != Ascii.newline { end += 1 }
                    if includeComments { tokens.append(.init(kind: .comment, range: start..<end)) }
                    index = end
                } else if next == Ascii.star {
                    var end = index + 2
                    var terminated = false
                    while end < count {
                        if units[end] == Ascii.star, end + 1 < count, units[end + 1] == Ascii.slash {
                            end += 2
                            terminated = true
                            break
                        }
                        end += 1
                    }
                    if includeComments || !terminated {
                        tokens.append(.init(kind: terminated ? .comment : .invalid, range: start..<end, isTerminated: terminated))
                    }
                    index = end
                } else {
                    let (end, terminated) = scanRegex(from: start)
                    tokens.append(.init(kind: .regex, range: start..<end, isTerminated: terminated))
                    index = end
                }
            default:
                if Self.isDigit(unit) || (unit == Ascii.dot && index + 1 < count && Self.isDigit(units[index + 1])) {
                    let end = scanNumber(from: start)
                    tokens.append(.init(kind: .number, range: start..<end))
                    index = end
                } else if Self.isIdentifierStart(unit) {
                    var end = index + 1
                    while end < count, Self.isIdentifierPart(units[end]) { end += 1 }
                    tokens.append(.init(kind: .identifier, range: start..<end))
                    index = end
                } else {
                    tokens.append(.init(kind: .invalid, range: start..<start + 1))
                    index += 1
                }
            }
        }
        return tokens
    }

    // MARK: Scanners

    private func scanString(from start: Int, quote: UInt16) -> (end: Int, terminated: Bool) {
        var index = start + 1
        while index < units.count {
            let unit = units[index]
            if unit == Ascii.backslash {
                index += 2
                continue
            }
            if unit == quote { return (index + 1, true) }
            if unit == Ascii.newline { return (index, false) }
            index += 1
        }
        return (min(index, units.count), false)
    }

    private func scanRegex(from start: Int) -> (end: Int, terminated: Bool) {
        var index = start + 1
        var inClass = false
        while index < units.count {
            let unit = units[index]
            if unit == Ascii.newline { return (index, false) }
            if unit == Ascii.backslash {
                index += 2
                continue
            }
            if unit == Ascii.leftBracket {
                inClass = true
            } else if unit == Ascii.rightBracket {
                inClass = false
            } else if unit == Ascii.slash, !inClass {
                index += 1
                while index < units.count, Self.isAsciiLetter(units[index]) { index += 1 }
                return (index, true)
            }
            index += 1
        }
        return (min(index, units.count), false)
    }

    private func scanNumber(from start: Int) -> Int {
        var index = start
        let count = units.count
        if units[index] == Ascii.zero, index + 1 < count, units[index + 1] == Ascii.lowerX || units[index + 1] == Ascii.upperX {
            index += 2
            while index < count, Self.isHexDigit(units[index]) { index += 1 }
            return index
        }
        while index < count, Self.isDigit(units[index]) { index += 1 }
        if index < count, units[index] == Ascii.dot {
            index += 1
            while index < count, Self.isDigit(units[index]) { index += 1 }
        }
        if index < count, units[index] == Ascii.lowerE || units[index] == Ascii.upperE {
            var probe = index + 1
            if probe < count, units[probe] == Ascii.plus || units[probe] == Ascii.minus { probe += 1 }
            if probe < count, Self.isDigit(units[probe]) {
                index = probe
                while index < count, Self.isDigit(units[index]) { index += 1 }
            }
        }
        // Absorb trailing identifier characters so `12abc` becomes one (invalid) number token.
        while index < count, Self.isIdentifierPart(units[index]), units[index] != Ascii.dot { index += 1 }
        return index
    }

    // MARK: Character classes

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
            || unit == 0xA0 || unit == 0xFEFF || unit == 0x2028 || unit == 0x2029
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= Ascii.zero && unit <= Ascii.nine }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x61 && unit <= 0x66) || (unit >= 0x41 && unit <= 0x46)
    }

    static func isAsciiLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        isAsciiLetter(unit) || unit == Ascii.dollar || unit == Ascii.underscore || (unit >= 0x80 && !isWhitespace(unit))
    }

    /// Identifier characters additionally allow digits and `.` so dotted paths can be written unquoted.
    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit) || unit == Ascii.dot
    }
}

enum Ascii {
    static let leftBrace: UInt16 = 0x7B
    static let rightBrace: UInt16 = 0x7D
    static let leftBracket: UInt16 = 0x5B
    static let rightBracket: UInt16 = 0x5D
    static let leftParen: UInt16 = 0x28
    static let rightParen: UInt16 = 0x29
    static let colon: UInt16 = 0x3A
    static let comma: UInt16 = 0x2C
    static let minus: UInt16 = 0x2D
    static let plus: UInt16 = 0x2B
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let backslash: UInt16 = 0x5C
    static let star: UInt16 = 0x2A
    static let doubleQuote: UInt16 = 0x22
    static let singleQuote: UInt16 = 0x27
    static let newline: UInt16 = 0x0A
    static let zero: UInt16 = 0x30
    static let nine: UInt16 = 0x39
    static let lowerE: UInt16 = 0x65
    static let upperE: UInt16 = 0x45
    static let lowerX: UInt16 = 0x78
    static let upperX: UInt16 = 0x58
    static let dollar: UInt16 = 0x24
    static let underscore: UInt16 = 0x5F
}

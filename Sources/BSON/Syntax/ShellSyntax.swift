import Foundation

/// Entry points for parsing mongo-shell syntax and Extended JSON into BSON.
public enum ShellSyntax {
    /// Parses a single document. With `allowEmpty`, blank input (or only comments) yields `{}`.
    public static func parseDocument(_ text: String, allowEmpty: Bool = false) throws -> BSONDocument {
        var parser = ShellSyntaxParser(text: text)
        if allowEmpty, parser.isAtEnd { return BSONDocument() }
        let start = parser.currentOffset
        let value = try parser.parseValue(depth: 0)
        try parser.expectEnd()
        guard case let .document(document) = value else {
            throw parser.error("Expected a document in braces { … }", at: start)
        }
        return document
    }

    /// Parses any single value.
    public static func parseValue(_ text: String) throws -> BSONValue {
        var parser = ShellSyntaxParser(text: text)
        let value = try parser.parseValue(depth: 0)
        try parser.expectEnd()
        return value
    }

    /// Parses an array such as an aggregation pipeline.
    public static func parseArray(_ text: String, allowEmpty: Bool = false) throws -> [BSONValue] {
        var parser = ShellSyntaxParser(text: text)
        if allowEmpty, parser.isAtEnd { return [] }
        let start = parser.currentOffset
        let value = try parser.parseValue(depth: 0)
        try parser.expectEnd()
        guard case let .array(array) = value else {
            throw parser.error("Expected an array in brackets [ … ]", at: start)
        }
        return array
    }

    /// Parses either a JSON array of documents or a whitespace/newline separated sequence of documents (NDJSON).
    public static func parseDocumentSequence(_ text: String) throws -> [BSONDocument] {
        var parser = ShellSyntaxParser(text: text)
        var documents: [BSONDocument] = []
        if parser.currentKind == .leftBracket {
            let start = parser.currentOffset
            let value = try parser.parseValue(depth: 0)
            try parser.expectEnd()
            guard case let .array(values) = value else { throw parser.error("Expected an array", at: start) }
            for element in values {
                guard case let .document(document) = element else {
                    throw parser.error("Every array element must be a document", at: start)
                }
                documents.append(document)
            }
            return documents
        }
        while !parser.isAtEnd {
            let start = parser.currentOffset
            let value = try parser.parseValue(depth: 0)
            guard case let .document(document) = value else {
                throw parser.error("Expected a document", at: start)
            }
            documents.append(document)
            parser.skipOptionalComma()
        }
        return documents
    }
}

/// Recursive-descent parser over tokens from `ShellSyntaxTokenizer`. Recursion depth is bounded by
/// `BSONLimits.maximumDepth`, so hostile input cannot exhaust the stack.
struct ShellSyntaxParser {
    private let units: [UInt16]
    private let tokens: [SyntaxToken]
    private var position = 0

    init(text: String) {
        units = Array(text.utf16)
        tokens = ShellSyntaxTokenizer(units: units).tokenize(includeComments: false)
    }

    // MARK: Token cursor

    var isAtEnd: Bool { position >= tokens.count }
    var currentKind: SyntaxToken.Kind? { position < tokens.count ? tokens[position].kind : nil }
    var currentOffset: Int { position < tokens.count ? tokens[position].range.lowerBound : units.count }

    private var current: SyntaxToken? { position < tokens.count ? tokens[position] : nil }

    private mutating func advance() -> SyntaxToken? {
        guard position < tokens.count else { return nil }
        defer { position += 1 }
        return tokens[position]
    }

    func error(_ message: String, at offset: Int) -> SyntaxError {
        SyntaxError(message: message, offset: offset, in: units)
    }

    private func text(of token: SyntaxToken) -> String {
        String(decoding: units[token.range], as: UTF16.self)
    }

    private func unexpected(_ token: SyntaxToken?, expected: String) -> SyntaxError {
        guard let token else {
            return error("Unexpected end of input, expected \(expected)", at: units.count)
        }
        if token.kind == .invalid {
            if token.range.count >= 2, units[token.range.lowerBound] == Ascii.slash {
                return error("Unterminated comment", at: token.range.lowerBound)
            }
            return error("Unexpected character '\(text(of: token))'", at: token.range.lowerBound)
        }
        let snippet = String(text(of: token).prefix(24))
        return error("Unexpected '\(snippet)', expected \(expected)", at: token.range.lowerBound)
    }

    mutating func expectEnd() throws {
        if let token = current {
            throw error("Unexpected '\(String(text(of: token).prefix(24)))' after the end of the value", at: token.range.lowerBound)
        }
    }

    mutating func skipOptionalComma() {
        if currentKind == .comma { position += 1 }
    }

    private mutating func expect(_ kind: SyntaxToken.Kind, _ description: String) throws {
        guard let token = current, token.kind == kind else { throw unexpected(current, expected: description) }
        position += 1
    }

    // MARK: Values

    mutating func parseValue(depth: Int) throws -> BSONValue {
        guard depth <= BSONLimits.maximumDepth else {
            throw error("Nesting is deeper than \(BSONLimits.maximumDepth) levels", at: currentOffset)
        }
        guard let token = current else { throw unexpected(nil, expected: "a value") }

        switch token.kind {
        case .leftBrace:
            return try parseObject(depth: depth)
        case .leftBracket:
            return .array(try parseArrayBody(depth: depth))
        case .string:
            position += 1
            return .string(try decodeString(token))
        case .number:
            position += 1
            return try numberValue(token, negative: false)
        case .minus, .plus:
            return try parseSigned()
        case .regex:
            position += 1
            return try regexValue(token)
        case .identifier:
            return try parseIdentifierValue(depth: depth)
        default:
            throw unexpected(token, expected: "a value")
        }
    }

    private mutating func parseSigned() throws -> BSONValue {
        guard let signToken = advance() else { throw unexpected(nil, expected: "a value") }
        let negative = signToken.kind == .minus
        guard let token = current else { throw unexpected(nil, expected: "a number") }
        switch token.kind {
        case .number:
            position += 1
            return try numberValue(token, negative: negative)
        case .identifier where text(of: token) == "Infinity":
            position += 1
            return .double(negative ? -.infinity : .infinity)
        case .identifier where text(of: token) == "NaN":
            position += 1
            return .double(.nan)
        default:
            throw unexpected(token, expected: "a number after '\(negative ? "-" : "+")'")
        }
    }

    private mutating func parseObject(depth: Int) throws -> BSONValue {
        let openOffset = currentOffset
        try expect(.leftBrace, "'{'")
        var document = BSONDocument()
        while true {
            if currentKind == .rightBrace {
                position += 1
                break
            }
            let key = try parseKey()
            try expect(.colon, "':' after field name '\(key)'")
            let value = try parseValue(depth: depth + 1)
            document.append(key, value)
            if currentKind == .comma {
                position += 1
            } else if currentKind == .rightBrace {
                position += 1
                break
            } else {
                throw unexpected(current, expected: "',' or '}'")
            }
        }
        do {
            if let wrapped = try ExtendedJSONWrapper.decode(document) { return wrapped }
        } catch let message as ExtendedJSONWrapper.Failure {
            throw error(message.reason, at: openOffset)
        }
        return .document(document)
    }

    private mutating func parseArrayBody(depth: Int) throws -> [BSONValue] {
        try expect(.leftBracket, "'['")
        var values: [BSONValue] = []
        while true {
            if currentKind == .rightBracket {
                position += 1
                break
            }
            values.append(try parseValue(depth: depth + 1))
            if currentKind == .comma {
                position += 1
            } else if currentKind == .rightBracket {
                position += 1
                break
            } else {
                throw unexpected(current, expected: "',' or ']'")
            }
        }
        return values
    }

    private mutating func parseKey() throws -> String {
        guard let token = current else { throw unexpected(nil, expected: "a field name or '}'") }
        switch token.kind {
        case .string:
            position += 1
            return try decodeString(token)
        case .identifier, .number:
            position += 1
            return text(of: token)
        default:
            throw unexpected(token, expected: "a field name or '}'")
        }
    }

    private mutating func parseIdentifierValue(depth: Int) throws -> BSONValue {
        guard let token = advance() else { throw unexpected(nil, expected: "a value") }
        var name = text(of: token)
        var nameToken = token
        var isNew = false
        if name == "new" {
            guard let next = current, next.kind == .identifier else {
                throw unexpected(current, expected: "a constructor name after 'new'")
            }
            position += 1
            isNew = true
            name = text(of: next)
            nameToken = next
        }

        if currentKind == .leftParen {
            let arguments = try parseArguments(depth: depth)
            return try Constructors.build(name: name, arguments: arguments, isNew: isNew) { message in
                self.error(message, at: nameToken.range.lowerBound)
            }
        }

        if !isNew {
            switch name {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "undefined": return .undefined
            case "NaN": return .double(.nan)
            case "Infinity": return .double(.infinity)
            case "MinKey": return .minKey
            case "MaxKey": return .maxKey
            default: break
            }
        }
        throw error("Unexpected identifier '\(name)'", at: nameToken.range.lowerBound)
    }

    private mutating func parseArguments(depth: Int) throws -> [Constructors.Argument] {
        try expect(.leftParen, "'('")
        var arguments: [Constructors.Argument] = []
        while true {
            if currentKind == .rightParen {
                position += 1
                break
            }
            let rawNumber = rawNumberText()
            let value = try parseValue(depth: depth + 1)
            arguments.append(Constructors.Argument(value: value, rawNumber: rawNumber))
            if currentKind == .comma {
                position += 1
            } else if currentKind == .rightParen {
                position += 1
                break
            } else {
                throw unexpected(current, expected: "',' or ')'")
            }
        }
        return arguments
    }

    /// Source text of a (possibly signed) numeric literal at the cursor, kept so
    /// `NumberDecimal(0.1)` and `NumberLong(9007199254740993)` are exact.
    private func rawNumberText() -> String? {
        guard let token = current else { return nil }
        if token.kind == .number { return text(of: token) }
        if token.kind == .minus || token.kind == .plus, position + 1 < tokens.count, tokens[position + 1].kind == .number {
            return (token.kind == .minus ? "-" : "") + text(of: tokens[position + 1])
        }
        return nil
    }

    // MARK: Literals

    private func numberValue(_ token: SyntaxToken, negative: Bool) throws -> BSONValue {
        let raw = text(of: token)
        let signed = negative ? "-" + raw : raw
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            guard let magnitude = UInt64(raw.dropFirst(2), radix: 16) else {
                throw error("Invalid hexadecimal number '\(raw)'", at: token.range.lowerBound)
            }
            if let value = Int64(exactly: magnitude) {
                return .int(Int(negative ? -value : value))
            }
            return .double(negative ? -Double(magnitude) : Double(magnitude))
        }
        let isFloating = raw.contains(where: { $0 == "." || $0 == "e" || $0 == "E" })
        if !isFloating, let integer = Int64(signed) {
            if let small = Int32(exactly: integer) { return .int32(small) }
            return .int64(integer)
        }
        guard let double = Double(signed), raw.allSatisfy({ $0.isNumber || $0 == "." || $0 == "e" || $0 == "E" || $0 == "+" || $0 == "-" }) else {
            throw error("Invalid number '\(raw)'", at: token.range.lowerBound)
        }
        return .double(double)
    }

    private func regexValue(_ token: SyntaxToken) throws -> BSONValue {
        guard token.isTerminated else {
            throw error("Unterminated regular expression", at: token.range.lowerBound)
        }
        let slice = Array(units[token.range])
        guard let closing = slice.lastIndex(of: Ascii.slash), closing > 0 else {
            throw error("Invalid regular expression", at: token.range.lowerBound)
        }
        let pattern = String(decoding: slice[1..<closing], as: UTF16.self)
        let flags = String(decoding: slice[(closing + 1)...], as: UTF16.self)
        guard flags.allSatisfy({ "imxslu".contains($0) }) else {
            throw error("Unsupported regular expression flags '\(flags)'", at: token.range.lowerBound)
        }
        return .regex(BSONRegex(pattern: pattern, options: BSONRegex.normalizedOptions(flags)))
    }

    /// Decodes a quoted string literal with JavaScript escapes.
    private func decodeString(_ token: SyntaxToken) throws -> String {
        guard token.isTerminated, token.range.count >= 2 else {
            throw error("Unterminated string", at: token.range.lowerBound)
        }
        let start = token.range.lowerBound + 1
        let end = token.range.upperBound - 1
        var output: [UInt16] = []
        output.reserveCapacity(end - start)
        var index = start
        while index < end {
            let unit = units[index]
            guard unit == Ascii.backslash else {
                output.append(unit)
                index += 1
                continue
            }
            guard index + 1 < end else { throw error("Invalid escape at end of string", at: index) }
            let escaped = units[index + 1]
            index += 2
            switch escaped {
            case 0x6E: output.append(0x0A) // n
            case 0x74: output.append(0x09) // t
            case 0x72: output.append(0x0D) // r
            case 0x62: output.append(0x08) // b
            case 0x66: output.append(0x0C) // f
            case 0x76: output.append(0x0B) // v
            case 0x30: output.append(0x00) // 0
            case 0x0A: break // line continuation
            case 0x78: // xHH
                guard index + 2 <= end, let value = hexValue(index..<index + 2) else {
                    throw error("Invalid \\x escape", at: index - 2)
                }
                output.append(UInt16(value))
                index += 2
            case 0x75: // uXXXX or u{X...}
                if index < end, units[index] == Ascii.leftBrace {
                    guard let close = units[index..<end].firstIndex(of: Ascii.rightBrace),
                          let scalarValue = hexValue((index + 1)..<close),
                          let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: scalarValue)) else {
                        throw error("Invalid \\u{…} escape", at: index - 2)
                    }
                    output.append(contentsOf: String(Character(scalar)).utf16)
                    index = close + 1
                } else {
                    guard index + 4 <= end, let value = hexValue(index..<index + 4) else {
                        throw error("Invalid \\u escape", at: index - 2)
                    }
                    output.append(UInt16(value))
                    index += 4
                }
            default:
                output.append(escaped) // \" \' \\ \/ and unknown escapes keep the character
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    private func hexValue(_ range: Range<Int>) -> UInt64? {
        guard !range.isEmpty, range.count <= 8, range.upperBound <= units.count else { return nil }
        var value: UInt64 = 0
        for index in range {
            let unit = units[index]
            let digit: UInt16
            switch unit {
            case 0x30...0x39: digit = unit - 0x30
            case 0x61...0x66: digit = unit - 0x61 + 10
            case 0x41...0x46: digit = unit - 0x41 + 10
            default: return nil
            }
            value = value << 4 | UInt64(digit)
        }
        return value
    }
}

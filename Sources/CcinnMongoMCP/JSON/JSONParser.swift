import Foundation

public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    /// Byte offset where the problem was detected.
    public let offset: Int

    public var description: String { "\(message) at byte \(offset)" }
}

/// Strict RFC 8259 parser over UTF-8 bytes. Bounded recursion, no traps on any input.
public enum JSONParser {
    public static let defaultMaxDepth = 128

    public static func parse(_ text: String, maxDepth: Int = defaultMaxDepth) throws -> JSONValue {
        try parse(bytes: Array(text.utf8), maxDepth: maxDepth)
    }

    public static func parse(bytes: [UInt8], maxDepth: Int = defaultMaxDepth) throws -> JSONValue {
        var parser = Parser(bytes: bytes, maxDepth: maxDepth)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw parser.error("Unexpected data after the JSON value") }
        return value
    }
}

private struct Parser {
    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    var isAtEnd: Bool { index >= bytes.count }

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func expect(_ literal: String, value: JSONValue) throws -> JSONValue {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count, bytes[index..<(index + expected.count)].elementsEqual(expected) else {
            throw error("Invalid literal")
        }
        index += expected.count
        return value
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard let byte = peek() else { throw error("Unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject(depth: depth + 1)
        case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try expect("true", value: .bool(true))
        case UInt8(ascii: "f"): return try expect("false", value: .bool(false))
        case UInt8(ascii: "n"): return try expect("null", value: .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("Unexpected character")
        }
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        guard depth <= maxDepth else { throw error("JSON is nested more than \(maxDepth) levels deep") }
        index += 1 // {
        var members: [JSONMember] = []
        var positions: [String: Int]? = nil
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(JSONObject())
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw error("Expected a string key") }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue(depth: depth)
            // Duplicate keys: the last value wins, at the first position. Small objects scan linearly;
            // larger ones switch to a hash index so hostile input stays linear.
            if positions == nil, members.count >= 16 {
                var built: [String: Int] = [:]
                for (offset, member) in members.enumerated() { built[member.key] = offset }
                positions = built
            }
            if positions != nil {
                if let existing = positions?[key] {
                    members[existing].value = value
                } else {
                    positions?[key] = members.count
                    members.append(JSONMember(key: key, value: value))
                }
            } else if let existing = members.firstIndex(where: { $0.key == key }) {
                members[existing].value = value
            } else {
                members.append(JSONMember(key: key, value: value))
            }
            skipWhitespace()
            guard let next = peek() else { throw error("Unexpected end of input in object") }
            index += 1
            if next == UInt8(ascii: "}") { break }
            guard next == UInt8(ascii: ",") else {
                index -= 1
                throw error("Expected ',' or '}'")
            }
        }
        // Members are already unique, so the initializer's de-duplication is a no-op here.
        return .object(JSONObject(members))
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        guard depth <= maxDepth else { throw error("JSON is nested more than \(maxDepth) levels deep") }
        index += 1 // [
        var elements: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array([])
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue(depth: depth))
            skipWhitespace()
            guard let next = peek() else { throw error("Unexpected end of input in array") }
            index += 1
            if next == UInt8(ascii: "]") { break }
            guard next == UInt8(ascii: ",") else {
                index -= 1
                throw error("Expected ',' or ']'")
            }
        }
        return .array(elements)
    }

    mutating func parseString() throws -> String {
        index += 1 // opening quote
        let start = index
        // Fast path: no escapes.
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let string = try decodeUTF8(bytes[start..<index])
                index += 1
                return string
            }
            if byte == UInt8(ascii: "\\") { break }
            guard byte >= 0x20 else { throw error("Unescaped control character in string") }
            index += 1
        }
        // Slow path with escapes.
        var scratch: [UInt8] = Array(bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return try decodeUTF8(scratch[...])
            case UInt8(ascii: "\\"):
                index += 1
                guard let escaped = peek() else { throw error("Unterminated escape") }
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): scratch.append(0x22)
                case UInt8(ascii: "\\"): scratch.append(0x5C)
                case UInt8(ascii: "/"): scratch.append(0x2F)
                case UInt8(ascii: "b"): scratch.append(0x08)
                case UInt8(ascii: "f"): scratch.append(0x0C)
                case UInt8(ascii: "n"): scratch.append(0x0A)
                case UInt8(ascii: "r"): scratch.append(0x0D)
                case UInt8(ascii: "t"): scratch.append(0x09)
                case UInt8(ascii: "u"): appendUTF8(of: try parseUnicodeEscape(), to: &scratch)
                default: throw error("Invalid escape sequence")
                }
            default:
                guard byte >= 0x20 else { throw error("Unescaped control character in string") }
                scratch.append(byte)
                index += 1
            }
        }
        throw error("Unterminated string")
    }

    /// Parses the hex digits after `\u`, combining surrogate pairs; lone surrogates become U+FFFD.
    mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try parseHex4()
        switch first {
        case 0xD800...0xDBFF:
            // High surrogate: a low surrogate escape must follow.
            if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let second = try parseHex4()
                if (0xDC00...0xDFFF).contains(second) {
                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(combined) ?? "\u{FFFD}"
                }
                index = saved
            }
            return "\u{FFFD}"
        case 0xDC00...0xDFFF:
            return "\u{FFFD}"
        default:
            return Unicode.Scalar(first) ?? "\u{FFFD}"
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Incomplete \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("Invalid \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    func appendUTF8(of scalar: Unicode.Scalar, to buffer: inout [UInt8]) {
        buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
    }

    func decodeUTF8(_ slice: ArraySlice<UInt8>) throws -> String {
        guard let string = String(bytes: slice, encoding: .utf8) else {
            throw error("Invalid UTF-8 in string")
        }
        return string
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
            throw error("Invalid number")
        }
        if first == UInt8(ascii: "0") {
            index += 1
            if let next = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) {
                throw error("Leading zeros are not allowed")
            }
        } else {
            skipDigits()
        }
        var isInteger = true
        if peek() == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard skipDigits() > 0 else { throw error("Expected digits after the decimal point") }
        }
        if let exponent = peek(), exponent == UInt8(ascii: "e") || exponent == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
            guard skipDigits() > 0 else { throw error("Expected digits in the exponent") }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger, let integer = Int64(text) { return .int(integer) }
        guard let double = Double(text), double.isFinite else { throw error("Number out of range") }
        return .double(double)
    }

    @discardableResult
    mutating func skipDigits() -> Int {
        let start = index
        while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        return index - start
    }
}

import Foundation

/// Converts BSON to text.
///
/// - `shell`: mongo-shell syntax that round-trips every type through `ShellSyntax` (used for display and editing).
/// - `relaxedExtendedJSON` / `canonicalExtendedJSON`: Extended JSON v2 for export and interchange.
public struct BSONFormatter: Sendable {
    public enum Style: Sendable, Hashable {
        case shell
        case relaxedExtendedJSON
        case canonicalExtendedJSON
    }

    public var style: Style
    /// Spaces per indentation level; `nil` produces a single line.
    public var indent: Int?
    /// When set, formatting stops (with "…") once the output exceeds this many UTF-8 bytes, so
    /// previews of huge values cost O(limit) instead of O(value size).
    var byteLimit: Int?

    private func exceedsBudget(_ output: String) -> Bool {
        guard let byteLimit else { return false }
        return output.utf8.count > byteLimit
    }

    public init(style: Style = .shell, indent: Int? = nil) {
        self.style = style
        self.indent = indent
    }

    public func format(_ document: BSONDocument) -> String {
        var output = ""
        output.reserveCapacity(128)
        writeDocument(document, level: 0, into: &output)
        return output
    }

    public func format(_ value: BSONValue) -> String {
        var output = ""
        writeValue(value, level: 0, into: &output)
        return output
    }

    public func format(array: [BSONValue]) -> String {
        var output = ""
        writeArray(array, level: 0, into: &output)
        return output
    }

    // MARK: Containers

    private var isShell: Bool { style == .shell }

    private func newline(_ level: Int, into output: inout String) {
        guard let indent else { return }
        output += "\n"
        output += String(repeating: " ", count: indent * level)
    }

    private func writeDocument(_ document: BSONDocument, level: Int, into output: inout String) {
        if document.isEmpty {
            output += "{}"
            return
        }
        guard level < BSONLimits.maximumDepth else {
            output += "{…}"
            return
        }
        output += "{"
        let compactShell = indent == nil && isShell
        if compactShell { output += " " }
        for (index, element) in document.elements.enumerated() {
            if exceedsBudget(output) {
                output += " …"
                break
            }
            if index > 0 { output += indent == nil ? ", " : "," }
            newline(level + 1, into: &output)
            writeKey(element.key, into: &output)
            output += ": "
            writeValue(element.value, level: level + 1, into: &output)
        }
        newline(level, into: &output)
        if compactShell { output += " " }
        output += "}"
    }

    private func writeArray(_ array: [BSONValue], level: Int, into output: inout String) {
        if array.isEmpty {
            output += "[]"
            return
        }
        guard level < BSONLimits.maximumDepth else {
            output += "[…]"
            return
        }
        output += "["
        for (index, value) in array.enumerated() {
            if exceedsBudget(output) {
                output += " …"
                break
            }
            if index > 0 { output += indent == nil ? ", " : "," }
            newline(level + 1, into: &output)
            writeValue(value, level: level + 1, into: &output)
        }
        newline(level, into: &output)
        output += "]"
    }

    private func writeKey(_ key: String, into output: inout String) {
        if isShell, Self.isPlainIdentifier(key) {
            output += key
        } else {
            Self.writeQuoted(key, into: &output)
        }
    }

    // MARK: Values

    private func writeValue(_ value: BSONValue, level: Int, into output: inout String) {
        switch value {
        case let .document(document): writeDocument(document, level: level, into: &output)
        case let .array(array): writeArray(array, level: level, into: &output)
        case let .javascriptWithScope(code):
            if isShell {
                output += "Code("
                Self.writeQuoted(code.code, into: &output)
                output += ", "
                writeDocument(code.scope, level: level, into: &output)
                output += ")"
            } else {
                output += "{\"$code\": "
                Self.writeQuoted(code.code, into: &output)
                output += ", \"$scope\": "
                writeDocument(code.scope, level: level, into: &output)
                output += "}"
            }
        default:
            writeScalar(value, into: &output)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func writeScalar(_ value: BSONValue, into output: inout String) {
        switch value {
        case let .string(text):
            if let byteLimit, text.utf8.count > byteLimit {
                Self.writeQuoted(String(text.prefix(byteLimit)), into: &output)
            } else {
                Self.writeQuoted(text, into: &output)
            }
        case let .bool(flag):
            output += flag ? "true" : "false"
        case .null:
            output += "null"
        case let .int32(number):
            output += style == .canonicalExtendedJSON ? "{\"$numberInt\": \"\(number)\"}" : String(number)
        case let .int64(number):
            switch style {
            case .shell:
                output += Swift.abs(number) > 9_007_199_254_740_992 || number == .min ? "NumberLong(\"\(number)\")" : "NumberLong(\(number))"
            case .relaxedExtendedJSON:
                output += String(number)
            case .canonicalExtendedJSON:
                output += "{\"$numberLong\": \"\(number)\"}"
            }
        case let .double(number):
            writeDouble(number, into: &output)
        case let .decimal128(decimal):
            output += isShell ? "NumberDecimal(\"\(decimal)\")" : "{\"$numberDecimal\": \"\(decimal)\"}"
        case let .objectId(oid):
            output += isShell ? "ObjectId(\"\(oid.hex)\")" : "{\"$oid\": \"\(oid.hex)\"}"
        case let .datetime(date):
            writeDate(date, into: &output)
        case let .binary(binary):
            writeBinary(binary, into: &output)
        case let .regex(regex):
            writeRegex(regex, into: &output)
        case let .timestamp(ts):
            output += isShell ? "Timestamp(\(ts.timestamp), \(ts.increment))" : "{\"$timestamp\": {\"t\": \(ts.timestamp), \"i\": \(ts.increment)}}"
        case .minKey:
            output += isShell ? "MinKey()" : "{\"$minKey\": 1}"
        case .maxKey:
            output += isShell ? "MaxKey()" : "{\"$maxKey\": 1}"
        case .undefined:
            output += isShell ? "undefined" : "{\"$undefined\": true}"
        case let .javascript(code):
            if isShell {
                output += "Code("
                Self.writeQuoted(code, into: &output)
                output += ")"
            } else {
                output += "{\"$code\": "
                Self.writeQuoted(code, into: &output)
                output += "}"
            }
        case let .symbol(symbol):
            if isShell {
                output += "Symbol("
                Self.writeQuoted(symbol, into: &output)
                output += ")"
            } else {
                output += "{\"$symbol\": "
                Self.writeQuoted(symbol, into: &output)
                output += "}"
            }
        case let .dbPointer(pointer):
            if isShell {
                output += "DBPointer("
                Self.writeQuoted(pointer.namespace, into: &output)
                output += ", ObjectId(\"\(pointer.id.hex)\"))"
            } else {
                output += "{\"$dbPointer\": {\"$ref\": "
                Self.writeQuoted(pointer.namespace, into: &output)
                output += ", \"$id\": {\"$oid\": \"\(pointer.id.hex)\"}}}"
            }
        case .document, .array, .javascriptWithScope:
            break // handled by writeValue
        }
    }

    private func writeDouble(_ number: Double, into output: inout String) {
        let text: String
        if number.isNaN {
            text = "NaN"
        } else if number.isInfinite {
            text = number < 0 ? "-Infinity" : "Infinity"
        } else {
            // Swift prints the shortest round-tripping form and always keeps a '.' or exponent.
            text = number.description
        }
        switch style {
        case .shell:
            output += text
        case .relaxedExtendedJSON:
            output += number.isFinite ? text : "{\"$numberDouble\": \"\(text)\"}"
        case .canonicalExtendedJSON:
            output += "{\"$numberDouble\": \"\(text)\"}"
        }
    }

    private func writeDate(_ date: BSONDateTime, into output: inout String) {
        let millis = date.millisecondsSinceEpoch
        switch style {
        case .shell:
            if let iso = ISO8601.format(milliseconds: millis, style: .always) {
                output += "ISODate(\"\(iso)\")"
            } else {
                output += "new Date(\(millis))"
            }
        case .relaxedExtendedJSON:
            if millis >= 0, let iso = ISO8601.format(milliseconds: millis, style: .whenNonZero) {
                output += "{\"$date\": \"\(iso)\"}"
            } else {
                output += "{\"$date\": {\"$numberLong\": \"\(millis)\"}}"
            }
        case .canonicalExtendedJSON:
            output += "{\"$date\": {\"$numberLong\": \"\(millis)\"}}"
        }
    }

    private func writeBinary(_ binary: BSONBinary, into output: inout String) {
        let base64 = (byteLimit.map { binary.data.prefix($0) } ?? binary.data).base64EncodedString()
        if isShell {
            if binary.subtype == .uuid, let uuid = binary.uuid {
                output += "UUID(\"\(uuid.uuidString.lowercased())\")"
            } else {
                output += "BinData(\(binary.subtype.rawValue), \"\(base64)\")"
            }
        } else {
            output += "{\"$binary\": {\"base64\": \"\(base64)\", \"subType\": \"\(binary.subtype.description)\"}}"
        }
    }

    private func writeRegex(_ regex: BSONRegex, into output: inout String) {
        if isShell {
            if Self.isLiteralSafe(regex.pattern), regex.options.allSatisfy({ $0.isLetter }) {
                output += "/\(regex.pattern)/\(regex.options)"
            } else {
                output += "RegExp("
                Self.writeQuoted(regex.pattern, into: &output)
                output += ", "
                Self.writeQuoted(regex.options, into: &output)
                output += ")"
            }
        } else {
            output += "{\"$regularExpression\": {\"pattern\": "
            Self.writeQuoted(regex.pattern, into: &output)
            output += ", \"options\": "
            Self.writeQuoted(regex.options, into: &output)
            output += "}}"
        }
    }

    // MARK: Helpers

    /// A pattern can be written as `/…/` if it is non-empty, has no line breaks, and every `/` is escaped.
    static func isLiteralSafe(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, !pattern.hasPrefix("*"), !pattern.hasPrefix("/") else { return false }
        var escaped = false
        for scalar in pattern.unicodeScalars {
            if escaped {
                escaped = false
                if scalar == "\n" || scalar == "\r" { return false }
                continue
            }
            switch scalar {
            case "\\": escaped = true
            case "/", "\n", "\r", "\u{2028}", "\u{2029}": return false
            default: break
            }
        }
        return !escaped
    }

    static func isPlainIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        guard first == "$" || first == "_" || (first.isASCII && first.properties.isAlphabetic) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "$" || $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

    static func writeQuoted(_ text: String, into output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{2028}": output += "\\u2028"
            case "\u{2029}": output += "\\u2029"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    /// Single-line shell-style preview truncated to `maxLength` characters (plus an ellipsis).
    public static func summary(of value: BSONValue, maxLength: Int) -> String {
        var formatter = BSONFormatter(style: .shell)
        formatter.byteLimit = max(64, maxLength * 4)
        let text = formatter.format(value)
        guard text.count > maxLength else { return text }
        return String(text.prefix(max(0, maxLength))) + "…"
    }
}

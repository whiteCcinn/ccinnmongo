import Foundation

/// Compact JSON encoder. Control characters are always escaped, so the output never contains a raw
/// newline and can be framed as a single line. Non-finite doubles become `null`.
public enum JSONWriter {
    public static func encode(_ value: JSONValue) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(256)
        write(value, into: &output)
        return output
    }

    public static func string(_ value: JSONValue) -> String {
        String(decoding: encode(value), as: UTF8.self)
    }

    /// Number of bytes `value` encodes to.
    public static func encodedSize(_ value: JSONValue) -> Int { encode(value).count }

    static func write(_ value: JSONValue, into output: inout [UInt8]) {
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case let .bool(bool):
            output.append(contentsOf: (bool ? "true" : "false").utf8)
        case let .int(integer):
            output.append(contentsOf: String(integer).utf8)
        case let .double(double):
            if double.isFinite {
                output.append(contentsOf: double.description.utf8)
            } else {
                output.append(contentsOf: "null".utf8)
            }
        case let .string(string):
            writeString(string, into: &output)
        case let .array(array):
            output.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                write(element, into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case let .object(object):
            output.append(UInt8(ascii: "{"))
            for (index, member) in object.members.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                writeString(member.key, into: &output)
                output.append(UInt8(ascii: ":"))
                write(member.value, into: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func writeString(_ string: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        let bytes = Array(string.utf8)
        var runStart = 0
        var index = 0
        // Unescaped runs are copied in bulk; only bytes that need escaping are handled one by one.
        while index < bytes.count {
            let byte = bytes[index]
            let escapeLength: Int
            if byte == 0x22 || byte == 0x5C || byte < 0x20 {
                escapeLength = 1
            } else if byte == 0xE2, index + 2 < bytes.count, bytes[index + 1] == 0x80, bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                // U+2028/U+2029 are valid JSON but are line terminators for some line-oriented readers.
                escapeLength = 3
            } else {
                index += 1
                continue
            }
            output.append(contentsOf: bytes[runStart..<index])
            switch byte {
            case 0x22: output.append(contentsOf: [0x5C, 0x22])
            case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: output.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: output.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: output.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: output.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: output.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0xE2: appendUnicodeEscape(bytes[index + 2] == 0xA8 ? 0x2028 : 0x2029, into: &output)
            default: appendUnicodeEscape(UInt16(byte), into: &output)
            }
            index += escapeLength
            runStart = index
        }
        output.append(contentsOf: bytes[runStart..<bytes.count])
        output.append(UInt8(ascii: "\""))
    }

    private static func appendUnicodeEscape(_ value: UInt16, into output: inout [UInt8]) {
        output.append(contentsOf: [0x5C, UInt8(ascii: "u")])
        for shift in stride(from: 12, through: 0, by: -4) {
            output.append(hexDigits[Int((value >> UInt16(shift)) & 0xF)])
        }
    }
}

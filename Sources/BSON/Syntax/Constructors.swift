import Foundation

/// Mongo-shell constructor functions (`ObjectId(...)`, `ISODate(...)`, ...).
enum Constructors {
    struct Argument {
        let value: BSONValue
        /// Source text when the argument is a numeric literal.
        let rawNumber: String?
    }

    typealias ErrorFactory = (String) -> SyntaxError

    static func build(name: String, arguments args: [Argument], isNew: Bool, fail: ErrorFactory) throws -> BSONValue {
        func requireCount(_ range: ClosedRange<Int>) throws {
            guard range.contains(args.count) else {
                let expected = range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
                throw fail("\(name)() expects \(expected) argument\(range.upperBound == 1 ? "" : "s"), got \(args.count)")
            }
        }
        func string(_ index: Int) throws -> String {
            guard index < args.count, case let .string(value) = args[index].value else {
                throw fail("\(name)() argument \(index + 1) must be a string")
            }
            return value
        }
        func integer(_ index: Int) throws -> Int64 {
            guard index < args.count else { throw fail("\(name)() is missing argument \(index + 1)") }
            if let value = args[index].value.int64Value { return value }
            if case let .string(text) = args[index].value, let value = Int64(text) { return value }
            throw fail("\(name)() argument \(index + 1) must be an integer")
        }

        switch name {
        case "ObjectId":
            try requireCount(0...1)
            if args.isEmpty { return .objectId(ObjectId()) }
            let hex = try string(0)
            guard let oid = ObjectId(hex: hex) else { throw fail("Invalid ObjectId '\(hex)': expected 24 hexadecimal characters") }
            return .objectId(oid)

        case "ISODate", "Date":
            if args.isEmpty { return .datetime(.now()) }
            try requireCount(1...1)
            switch args[0].value {
            case let .string(text):
                guard let millis = ISO8601.parse(text) else { throw fail("Invalid ISO-8601 date '\(text)'") }
                return .datetime(BSONDateTime(millisecondsSinceEpoch: millis))
            case let .datetime(value):
                return .datetime(value)
            default:
                if let raw = args[0].rawNumber, let millis = Int64(raw) {
                    return .datetime(BSONDateTime(millisecondsSinceEpoch: millis))
                }
                guard let number = args[0].value.doubleValue, number.isFinite,
                      number >= Double(Int64.min), number < Double(Int64.max) else {
                    throw fail("\(name)() expects an ISO-8601 string or milliseconds since the epoch")
                }
                return .datetime(BSONDateTime(millisecondsSinceEpoch: Int64(number.rounded(.towardZero))))
            }

        case "NumberInt", "Int32":
            try requireCount(1...1)
            let value = try integer(0)
            guard let small = Int32(exactly: value) else { throw fail("\(value) does not fit in a 32-bit integer") }
            return .int32(small)

        case "NumberLong", "Long", "Int64":
            try requireCount(1...1)
            if let raw = args[0].rawNumber, let exact = Int64(raw) { return .int64(exact) }
            return .int64(try integer(0))

        case "NumberDecimal", "Decimal128":
            try requireCount(1...1)
            let text: String
            if let raw = args[0].rawNumber {
                text = raw
            } else {
                text = try string(0)
            }
            guard let decimal = Decimal128(string: text) else { throw fail("Invalid decimal '\(text)'") }
            return .decimal128(decimal)

        case "Double":
            try requireCount(1...1)
            if case let .string(text) = args[0].value, let value = Double(text) { return .double(value) }
            guard let value = args[0].value.doubleValue else { throw fail("Double() expects a number") }
            return .double(value)

        case "Timestamp":
            let seconds: Int64
            let increment: Int64
            if args.count == 1, case let .document(doc) = args[0].value {
                guard let t = doc["t"]?.int64Value, let i = doc["i"]?.int64Value else {
                    throw fail("Timestamp({t, i}) requires integer fields t and i")
                }
                seconds = t
                increment = i
            } else {
                try requireCount(2...2)
                seconds = try integer(0)
                increment = try integer(1)
            }
            guard let t = UInt32(exactly: seconds), let i = UInt32(exactly: increment) else {
                throw fail("Timestamp values must be between 0 and 4294967295")
            }
            return .timestamp(BSONTimestamp(timestamp: t, increment: i))

        case "BinData", "Binary":
            try requireCount(2...2)
            let subtype = try integer(0)
            guard let byte = UInt8(exactly: subtype) else { throw fail("Binary subtype must be between 0 and 255") }
            let base64 = try string(1)
            guard let data = Data(base64Encoded: base64) else { throw fail("Invalid base64 data") }
            return .binary(BSONBinary(subtype: .init(byte), data: data))

        case "HexData":
            try requireCount(2...2)
            let subtype = try integer(0)
            guard let byte = UInt8(exactly: subtype) else { throw fail("Binary subtype must be between 0 and 255") }
            guard let data = HexBytes.decode(try string(1)) else { throw fail("Invalid hexadecimal data") }
            return .binary(BSONBinary(subtype: .init(byte), data: data))

        case "MD5":
            try requireCount(1...1)
            guard let data = HexBytes.decode(try string(0)), data.count == 16 else { throw fail("MD5() expects 32 hexadecimal characters") }
            return .binary(BSONBinary(subtype: .md5, data: data))

        case "UUID":
            try requireCount(0...1)
            if args.isEmpty { return .binary(BSONBinary(uuid: UUID())) }
            let text = try string(0)
            guard let uuid = UUIDParsing.parse(text) else { throw fail("Invalid UUID '\(text)'") }
            return .binary(BSONBinary(uuid: uuid))

        case "MinKey":
            try requireCount(0...0)
            return .minKey

        case "MaxKey":
            try requireCount(0...0)
            return .maxKey

        case "DBRef":
            try requireCount(2...3)
            var doc: BSONDocument = ["$ref": .string(try string(0)), "$id": args[1].value]
            if args.count == 3 { doc["$db"] = .string(try string(2)) }
            return .document(doc)

        case "Code":
            try requireCount(1...2)
            let code = try string(0)
            if args.count == 2 {
                guard case let .document(scope) = args[1].value else { throw fail("Code() scope must be a document") }
                return .javascriptWithScope(BSONCodeWithScope(code: code, scope: scope))
            }
            return .javascript(code)

        case "RegExp", "BSONRegExp":
            try requireCount(1...2)
            let pattern = try string(0)
            let flags = args.count == 2 ? try string(1) : ""
            guard flags.allSatisfy({ "imxslu".contains($0) }) else { throw fail("Unsupported regular expression flags '\(flags)'") }
            return .regex(BSONRegex(pattern: pattern, options: BSONRegex.normalizedOptions(flags)))

        case "Symbol":
            try requireCount(1...1)
            return .symbol(try string(0))

        case "DBPointer":
            try requireCount(2...2)
            guard case let .objectId(oid) = args[1].value else { throw fail("DBPointer() expects an ObjectId as second argument") }
            return .dbPointer(BSONDBPointer(namespace: try string(0), id: oid))

        default:
            throw fail("Unknown function '\(isNew ? "new " : "")\(name)()'")
        }
    }

    /// Names recognised as constructors (used for completion and highlighting).
    static let names: [String] = [
        "ObjectId", "ISODate", "Date", "NumberInt", "Int32", "NumberLong", "Long", "Int64", "NumberDecimal",
        "Decimal128", "Double", "Timestamp", "BinData", "Binary", "HexData", "MD5", "UUID", "MinKey", "MaxKey",
        "DBRef", "Code", "RegExp", "BSONRegExp", "Symbol", "DBPointer",
    ]
}

enum HexBytes {
    static func decode(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x61...0x66: c - 0x61 + 10
        case 0x41...0x46: c - 0x41 + 10
        default: nil
        }
    }
}

enum UUIDParsing {
    /// Accepts the canonical dashed form or 32 bare hexadecimal digits.
    static func parse(_ text: String) -> UUID? {
        if let uuid = UUID(uuidString: text) { return uuid }
        let hex = text.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, let data = HexBytes.decode(hex) else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

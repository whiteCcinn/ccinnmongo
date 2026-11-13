import Foundation

/// Recognises Extended JSON v2 type wrappers (canonical and relaxed, plus legacy `$binary`/`$type`).
///
/// A document is only treated as a wrapper when its key set matches a wrapper shape exactly, so
/// query operators such as `$regex`/`$options` or `$type` alone are left untouched.
enum ExtendedJSONWrapper {
    struct Failure: Error {
        let reason: String
    }

    /// Returns the wrapped value, `nil` if `document` is not a wrapper, or throws if it has the
    /// shape of a wrapper but invalid contents.
    static func decode(_ document: BSONDocument) throws -> BSONValue? {
        guard let firstKey = document.elements.first?.key, firstKey.hasPrefix("$") else { return nil }
        switch document.count {
        case 1: return try decodeSingle(key: firstKey, value: document.elements[0].value)
        case 2: return try decodePair(document)
        default: return nil
        }
    }

    private static func decodeSingle(key: String, value: BSONValue) throws -> BSONValue? {
        switch key {
        case "$oid":
            guard case let .string(hex) = value, let oid = ObjectId(hex: hex) else { throw Failure(reason: "Invalid $oid value") }
            return .objectId(oid)

        case "$symbol":
            guard case let .string(text) = value else { throw Failure(reason: "$symbol must be a string") }
            return .symbol(text)

        case "$numberInt":
            guard let int = integer(value), let small = Int32(exactly: int) else { throw Failure(reason: "Invalid $numberInt value") }
            return .int32(small)

        case "$numberLong":
            guard let int = integer(value) else { throw Failure(reason: "Invalid $numberLong value") }
            return .int64(int)

        case "$numberDouble":
            guard case let .string(text) = value else { throw Failure(reason: "$numberDouble must be a string") }
            switch text {
            case "Infinity": return .double(.infinity)
            case "-Infinity": return .double(-.infinity)
            case "NaN": return .double(.nan)
            default:
                guard let double = Double(text) else { throw Failure(reason: "Invalid $numberDouble value") }
                return .double(double)
            }

        case "$numberDecimal":
            guard case let .string(text) = value, let decimal = Decimal128(string: text) else {
                throw Failure(reason: "Invalid $numberDecimal value")
            }
            return .decimal128(decimal)

        case "$binary":
            guard case let .document(inner) = value, inner.count == 2,
                  case let .string(base64)? = inner["base64"], case let .string(subtypeHex)? = inner["subType"] else {
                throw Failure(reason: "$binary must contain base64 and subType")
            }
            return try binary(base64: base64, subtypeHex: subtypeHex)

        case "$uuid":
            guard case let .string(text) = value, let uuid = UUIDParsing.parse(text) else { throw Failure(reason: "Invalid $uuid value") }
            return .binary(BSONBinary(uuid: uuid))

        case "$code":
            guard case let .string(code) = value else { throw Failure(reason: "$code must be a string") }
            return .javascript(code)

        case "$timestamp":
            guard case let .document(inner) = value, inner.count == 2,
                  let t = inner["t"]?.int64Value, let i = inner["i"]?.int64Value,
                  let seconds = UInt32(exactly: t), let increment = UInt32(exactly: i) else {
                throw Failure(reason: "$timestamp must contain unsigned 32-bit t and i")
            }
            return .timestamp(BSONTimestamp(timestamp: seconds, increment: increment))

        case "$regularExpression":
            guard case let .document(inner) = value, inner.count == 2,
                  case let .string(pattern)? = inner["pattern"], case let .string(options)? = inner["options"] else {
                throw Failure(reason: "$regularExpression must contain pattern and options")
            }
            return .regex(BSONRegex(pattern: pattern, options: BSONRegex.normalizedOptions(options)))

        case "$dbPointer":
            guard case let .document(inner) = value, inner.count == 2,
                  case let .string(namespace)? = inner["$ref"], case let .objectId(oid)? = inner["$id"] else {
                throw Failure(reason: "$dbPointer must contain $ref and an ObjectId $id")
            }
            return .dbPointer(BSONDBPointer(namespace: namespace, id: oid))

        case "$date":
            switch value {
            case let .string(text):
                guard let millis = ISO8601.parse(text) else { throw Failure(reason: "Invalid $date string '\(text)'") }
                return .datetime(BSONDateTime(millisecondsSinceEpoch: millis))
            case .int32, .int64:
                guard let millis = value.int64Value else { throw Failure(reason: "Invalid $date value") }
                return .datetime(BSONDateTime(millisecondsSinceEpoch: millis))
            case let .double(double):
                guard double.isFinite, double >= Double(Int64.min), double < Double(Int64.max) else {
                    throw Failure(reason: "Invalid $date value")
                }
                return .datetime(BSONDateTime(millisecondsSinceEpoch: Int64(double)))
            default:
                throw Failure(reason: "Invalid $date value")
            }

        case "$minKey":
            guard value == .int32(1) || value == .int64(1) else { throw Failure(reason: "$minKey must be 1") }
            return .minKey

        case "$maxKey":
            guard value == .int32(1) || value == .int64(1) else { throw Failure(reason: "$maxKey must be 1") }
            return .maxKey

        case "$undefined":
            guard value == .bool(true) else { throw Failure(reason: "$undefined must be true") }
            return .undefined

        default:
            return nil
        }
    }

    private static func decodePair(_ document: BSONDocument) throws -> BSONValue? {
        let keys = Set(document.keys)
        if keys == ["$code", "$scope"] {
            guard case let .string(code)? = document["$code"], case let .document(scope)? = document["$scope"] else {
                throw Failure(reason: "$code with $scope requires a string and a document")
            }
            return .javascriptWithScope(BSONCodeWithScope(code: code, scope: scope))
        }
        if keys == ["$binary", "$type"] {
            // Legacy form; only when both are strings (otherwise `$type` is the query operator).
            guard case let .string(base64)? = document["$binary"], case let .string(subtypeHex)? = document["$type"] else {
                return nil
            }
            return try binary(base64: base64, subtypeHex: subtypeHex)
        }
        return nil
    }

    private static func binary(base64: String, subtypeHex: String) throws -> BSONValue {
        guard let data = Data(base64Encoded: base64) else { throw Failure(reason: "Invalid base64 in $binary") }
        guard (1...2).contains(subtypeHex.count), let subtype = UInt8(subtypeHex, radix: 16) else {
            throw Failure(reason: "Invalid $binary subType '\(subtypeHex)'")
        }
        return .binary(BSONBinary(subtype: .init(subtype), data: data))
    }

    private static func integer(_ value: BSONValue) -> Int64? {
        switch value {
        case let .string(text): Int64(text)
        case .int32, .int64: value.int64Value
        default: nil
        }
    }
}

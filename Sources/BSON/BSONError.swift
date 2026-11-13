/// Errors raised while encoding or decoding BSON bytes.
public enum BSONError: Error, Sendable, Equatable, CustomStringConvertible {
    case truncated(context: String)
    case invalidLength(context: String, length: Int)
    case missingTerminator(context: String)
    case unknownType(UInt8, key: String)
    case invalidValue(context: String)
    case depthLimitExceeded(limit: Int)
    case trailingBytes(count: Int)
    case invalidKey(String)
    case documentTooLarge(size: Int)

    public var description: String {
        switch self {
        case let .truncated(context): "BSON data is truncated while reading \(context)"
        case let .invalidLength(context, length): "Invalid BSON length \(length) for \(context)"
        case let .missingTerminator(context): "Missing null terminator in \(context)"
        case let .unknownType(type, key): "Unknown BSON type 0x\(String(type, radix: 16)) for field '\(key)'"
        case let .invalidValue(context): "Invalid BSON value: \(context)"
        case let .depthLimitExceeded(limit): "BSON nesting exceeds the maximum depth of \(limit)"
        case let .trailingBytes(count): "\(count) unexpected trailing bytes after BSON document"
        case let .invalidKey(key): "Field name '\(key.replacingOccurrences(of: "\0", with: "\\0"))' contains a null byte"
        case let .documentTooLarge(size): "BSON document of \(size) bytes exceeds the maximum encodable size"
        }
    }
}

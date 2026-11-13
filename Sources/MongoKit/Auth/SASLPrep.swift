import Foundation

/// SASLprep (RFC 4013) profile of stringprep, as required for SCRAM-SHA-256 passwords.
///
/// Implements mapping (B.1 → nothing, C.1.2 → space), NFKC normalisation and the prohibited
/// output tables that matter in practice (controls, private use, non-characters, surrogates,
/// tagging). Pure-ASCII printable input takes a fast path.
enum SASLPrep {
    static func prepare(_ input: String) throws -> String {
        if input.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return input }

        var mapped = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if mappedToNothing.contains(scalar.value) { continue }
            if nonASCIISpaces.contains(scalar.value) {
                mapped.append(" ")
            } else {
                mapped.append(scalar)
            }
        }
        let normalized = String(mapped).precomposedStringWithCompatibilityMapping

        for scalar in normalized.unicodeScalars where isProhibited(scalar.value) {
            throw MongoError(.authentication, "The password contains a character (U+\(String(scalar.value, radix: 16, uppercase: true))) that is not allowed by SASLprep")
        }
        return normalized
    }

    /// RFC 3454 table B.1.
    private static let mappedToNothing: Set<UInt32> = [
        0x00AD, 0x034F, 0x1806, 0x180B, 0x180C, 0x180D, 0x200B, 0x200C, 0x200D, 0x2060,
        0xFE00, 0xFE01, 0xFE02, 0xFE03, 0xFE04, 0xFE05, 0xFE06, 0xFE07, 0xFE08, 0xFE09,
        0xFE0A, 0xFE0B, 0xFE0C, 0xFE0D, 0xFE0E, 0xFE0F, 0xFEFF,
    ]

    /// RFC 3454 table C.1.2.
    private static let nonASCIISpaces: Set<UInt32> = [
        0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
        0x2008, 0x2009, 0x200A, 0x200B, 0x202F, 0x205F, 0x3000,
    ]

    private static func isProhibited(_ value: UInt32) -> Bool {
        switch value {
        case 0x0000...0x001F, 0x007F...0x009F: return true // C.2 controls
        case 0x06DD, 0x070F, 0x180E, 0x200C, 0x200D, 0x2028, 0x2029, 0x2060...0x2063, 0x206A...0x206F, 0xFEFF, 0xFFF9...0xFFFC:
            return true // C.2.2
        case 0x1D173...0x1D17A: return true
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD: return true // C.3 private use
        case 0xFDD0...0xFDEF: return true // C.4 non-characters
        case 0xD800...0xDFFF: return true // C.5 surrogates
        case 0xFFFD: return true // C.6
        case 0x2FF0...0x2FFB: return true // C.7
        case 0x0340, 0x0341, 0x200E, 0x200F, 0x202A...0x202E, 0x206A...0x206F: return true // C.8
        case 0xE0001, 0xE0020...0xE007F: return true // C.9 tagging
        default:
            // C.4: last two code points of every plane are non-characters.
            return value & 0xFFFE == 0xFFFE
        }
    }
}

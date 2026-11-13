/// IEEE 754-2008 128-bit decimal (BID encoding) as used by BSON.
///
/// The value is stored as raw bits; conversion to and from strings follows the
/// BSON Decimal128 specification, rejecting inputs that cannot be represented exactly.
public struct Decimal128: Sendable, Hashable, CustomStringConvertible {
    public let high: UInt64
    public let low: UInt64

    static let exponentBias = 6176
    static let maxExponent = 6111
    static let minExponent = -6176
    static let maxDigits = 34

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    // MARK: - String → Decimal128

    /// Parses a decimal string. Returns `nil` for malformed input or values that would need rounding.
    public init?(string: String) {
        var chars = Array(string.utf8)[...]
        guard !chars.isEmpty else { return nil }

        var negative = false
        if let first = chars.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            negative = first == UInt8(ascii: "-")
            chars = chars.dropFirst()
        }

        let lowered = String(decoding: chars, as: UTF8.self).lowercased()
        if lowered == "inf" || lowered == "infinity" {
            self.init(high: (negative ? 0xF800_0000_0000_0000 : 0x7800_0000_0000_0000), low: 0)
            return
        }
        if lowered == "nan" {
            self.init(high: 0x7C00_0000_0000_0000, low: 0)
            return
        }

        var digits: [UInt8] = []
        var sawDigit = false
        var sawPoint = false
        var fractionDigits = 0
        var index = chars.startIndex

        while index < chars.endIndex {
            let char = chars[index]
            if char >= UInt8(ascii: "0"), char <= UInt8(ascii: "9") {
                sawDigit = true
                digits.append(char - UInt8(ascii: "0"))
                if sawPoint { fractionDigits += 1 }
            } else if char == UInt8(ascii: ".") {
                if sawPoint { return nil }
                sawPoint = true
            } else {
                break
            }
            index += 1
        }
        guard sawDigit else { return nil }

        var exponentPart = 0
        if index < chars.endIndex {
            guard chars[index] == UInt8(ascii: "e") || chars[index] == UInt8(ascii: "E") else { return nil }
            index += 1
            var exponentNegative = false
            if index < chars.endIndex, chars[index] == UInt8(ascii: "+") || chars[index] == UInt8(ascii: "-") {
                exponentNegative = chars[index] == UInt8(ascii: "-")
                index += 1
            }
            guard index < chars.endIndex else { return nil }
            while index < chars.endIndex {
                let char = chars[index]
                guard char >= UInt8(ascii: "0"), char <= UInt8(ascii: "9") else { return nil }
                // Cap well above any representable exponent to avoid integer overflow.
                if exponentPart < 1_000_000 {
                    exponentPart = exponentPart * 10 + Int(char - UInt8(ascii: "0"))
                }
                index += 1
            }
            if exponentNegative { exponentPart = -exponentPart }
        }

        // Strip leading zeros (keep at least one digit).
        var firstNonZero = 0
        while firstNonZero < digits.count - 1, digits[firstNonZero] == 0 { firstNonZero += 1 }
        digits.removeFirst(firstNonZero)

        var exponent = exponentPart - fractionDigits
        let isZero = digits.allSatisfy { $0 == 0 }

        if isZero {
            digits = [0]
            exponent = min(max(exponent, Self.minExponent), Self.maxExponent)
        } else {
            // Drop trailing zeros that do not fit in 34 digits.
            while digits.count > Self.maxDigits, digits.last == 0 {
                digits.removeLast()
                exponent += 1
            }
            guard digits.count <= Self.maxDigits else { return nil }

            // Clamp large exponents by padding the coefficient with zeros.
            while exponent > Self.maxExponent {
                guard digits.count < Self.maxDigits else { return nil }
                digits.append(0)
                exponent -= 1
            }
            // Clamp small exponents by removing trailing zeros; anything else would round.
            while exponent < Self.minExponent {
                guard digits.count > 1, digits.last == 0 else { return nil }
                digits.removeLast()
                exponent += 1
            }
        }

        var coefficient = UInt128Parts(high: 0, low: 0)
        for digit in digits {
            coefficient = coefficient.multipliedByTen().adding(UInt64(digit))
        }

        let biased = UInt64(exponent + Self.exponentBias)
        var high = (biased & 0x3FFF) << 49 | (coefficient.high & 0x1_FFFF_FFFF_FFFF)
        if negative { high |= 1 << 63 }
        self.init(high: high, low: coefficient.low)
    }

    // MARK: - Decimal128 → String

    public var isNaN: Bool { (high >> 58) & 0x1F == 0x1F }
    public var isInfinite: Bool { (high >> 58) & 0x1F == 0x1E }
    public var isNegative: Bool { high >> 63 == 1 }

    public var description: String {
        if isNaN { return "NaN" }
        if isInfinite { return isNegative ? "-Infinity" : "Infinity" }

        let biasedExponent: Int
        var coefficient: UInt128Parts
        if (high >> 61) & 0x3 == 0x3 {
            // "11" combination form: the implicit 0b100 prefix exceeds 10^34 - 1, so the value is non-canonical zero.
            biasedExponent = Int((high >> 47) & 0x3FFF)
            coefficient = UInt128Parts(high: 0, low: 0)
        } else {
            biasedExponent = Int((high >> 49) & 0x3FFF)
            coefficient = UInt128Parts(high: high & 0x1_FFFF_FFFF_FFFF, low: low)
            if coefficient > UInt128Parts.maxCoefficient {
                coefficient = UInt128Parts(high: 0, low: 0)
            }
        }
        let exponent = biasedExponent - Self.exponentBias

        var digitChars: [UInt8] = []
        if coefficient.isZero {
            digitChars = [UInt8(ascii: "0")]
        } else {
            var value = coefficient
            while !value.isZero {
                let (quotient, remainder) = value.dividedByTen()
                digitChars.append(UInt8(ascii: "0") + UInt8(remainder))
                value = quotient
            }
            digitChars.reverse()
        }

        var output = isNegative ? "-" : ""
        let adjusted = exponent + digitChars.count - 1

        if exponent <= 0, adjusted >= -6 {
            if exponent == 0 {
                output += String(decoding: digitChars, as: UTF8.self)
            } else {
                let pointPosition = digitChars.count + exponent
                if pointPosition > 0 {
                    output += String(decoding: digitChars[..<pointPosition], as: UTF8.self)
                    output += "."
                    output += String(decoding: digitChars[pointPosition...], as: UTF8.self)
                } else {
                    output += "0."
                    output += String(repeating: "0", count: -pointPosition)
                    output += String(decoding: digitChars, as: UTF8.self)
                }
            }
        } else {
            output += String(UnicodeScalar(digitChars[0]))
            if digitChars.count > 1 {
                output += "."
                output += String(decoding: digitChars[1...], as: UTF8.self)
            }
            output += "E"
            output += adjusted >= 0 ? "+\(adjusted)" : "\(adjusted)"
        }
        return output
    }
}

/// Minimal unsigned 128-bit arithmetic needed for Decimal128 coefficients (avoids the macOS 15-only UInt128).
struct UInt128Parts: Comparable {
    var high: UInt64
    var low: UInt64

    /// 10^34 - 1.
    static let maxCoefficient = UInt128Parts(high: 0x1_ED09_BEAD_87C0, low: 0x378D_8E63_FFFF_FFFF)

    var isZero: Bool { high == 0 && low == 0 }

    func multipliedByTen() -> UInt128Parts {
        let lowProduct = low.multipliedFullWidth(by: 10)
        let highProduct = high &* 10 &+ lowProduct.high
        return UInt128Parts(high: highProduct, low: lowProduct.low)
    }

    func adding(_ value: UInt64) -> UInt128Parts {
        let (sum, overflow) = low.addingReportingOverflow(value)
        return UInt128Parts(high: high &+ (overflow ? 1 : 0), low: sum)
    }

    func dividedByTen() -> (quotient: UInt128Parts, remainder: UInt64) {
        let (highQuotient, highRemainder) = high.quotientAndRemainder(dividingBy: 10)
        // highRemainder < 10, so the full-width division cannot overflow.
        let (lowQuotient, lowRemainder) = UInt64(10).dividingFullWidth((high: highRemainder, low: low))
        return (UInt128Parts(high: highQuotient, low: lowQuotient), lowRemainder)
    }

    static func < (lhs: UInt128Parts, rhs: UInt128Parts) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }
}

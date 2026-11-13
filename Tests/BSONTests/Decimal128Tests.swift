import Testing
@testable import BSON

@Suite("Decimal128")
struct Decimal128Tests {
    @Test(arguments: [
        ("0", 0x3040_0000_0000_0000 as UInt64, 0 as UInt64),
        ("-0", 0xB040_0000_0000_0000, 0),
        ("1", 0x3040_0000_0000_0000, 1),
        ("-1", 0xB040_0000_0000_0000, 1),
        ("0.1", 0x303E_0000_0000_0000, 1),
        ("Infinity", 0x7800_0000_0000_0000, 0),
        ("-Infinity", 0xF800_0000_0000_0000, 0),
        ("NaN", 0x7C00_0000_0000_0000, 0),
        ("9.999999999999999999999999999999999E+6144", 0x5FFF_ED09_BEAD_87C0, 0x378D_8E63_FFFF_FFFF),
    ])
    func knownBitPatterns(string: String, high: UInt64, low: UInt64) throws {
        let value = try #require(Decimal128(string: string))
        #expect(value.high == high)
        #expect(value.low == low)
        #expect(Decimal128(high: high, low: low).description == string)
    }

    @Test(arguments: [
        "0", "-0", "1", "-1", "0.1", "0.001234", "1.234E-7", "1E+3", "100", "1.0", "0E+3", "-0.00",
        "-1.23E+3000", "1234567890123456789012345678901234", "1.000000000000000000000000000000000E+6144",
        "1E-6176", "0E-6176", "0E+6111", "12345678901234567890.12345678901234", "-9.9E-12",
        "0.000001", "1E-7",
    ])
    func canonicalStringsRoundTrip(_ string: String) throws {
        let value = try #require(Decimal128(string: string), "failed to parse \(string)")
        #expect(value.description == string)
    }

    @Test(arguments: [
        ("1E6112", "1.0E+6112"),
        ("0E+10000", "0E+6111"),
        ("0E-10000", "0E-6176"),
        ("1.50e2", "150"),
        ("+12", "12"),
        ("inf", "Infinity"),
        ("-INFINITY", "-Infinity"),
        ("nan", "NaN"),
        ("00012.3400", "12.3400"),
        ("10E-6177", "1E-6176"),
        (".5", "0.5"),
        ("5.", "5"),
    ])
    func nonCanonicalInputsNormalise(input: String, expected: String) throws {
        let value = try #require(Decimal128(string: input), "failed to parse \(input)")
        #expect(value.description == expected)
    }

    @Test(arguments: [
        "", "-", "E5", "1E", "1.2.3", "1e+", "abc", "1 ", " 1", "1E-6177", "1E+99999999999999999999",
        "12345678901234567890123456789012345", "--1", "0x10", "1,0", ".", "Infinityx",
    ])
    func invalidStringsAreRejected(_ string: String) {
        #expect(Decimal128(string: string) == nil, "unexpectedly parsed \(string)")
    }

    @Test func nonCanonicalCoefficientDecodesAsZero() {
        // Combination field "11" form: implicit 0b100 prefix makes coefficient > 10^34 - 1.
        #expect(Decimal128(high: 0x6C10_0000_0000_0000, low: 0).description == "0")
        // Coefficient above 10^34 - 1 in the normal form is also non-canonical.
        #expect(Decimal128(high: 0x3041_ED09_BEAD_87C0, low: 0x378D_8E64_0000_0000).description == "0")
    }

    @Test func trailingZerosBeyond34DigitsAreDropped() throws {
        let value = try #require(Decimal128(string: "10000000000000000000000000000000000"))
        #expect(value.description == "1.000000000000000000000000000000000E+34")
    }
}

@testable import StoicJSON
import Testing

/// What `NumberParts` makes of a lexeme: the sign, the significant digits and
/// the exponent of the first digit. The expectations are worked out by hand
/// from the definition (value = d.ddd × 10^exponent), not read from the code.
@Suite("Number parts")
struct NumberPartsTests {
    private struct Case {
        var lexeme: String
        var negative: Bool
        var digits: [UInt8]
        var exponent: Int

        init(_ lexeme: String, negative: Bool = false, _ digits: [UInt8], exponent: Int) {
            self.lexeme = lexeme
            self.negative = negative
            self.digits = digits
            self.exponent = exponent
        }
    }

    /// The exponent a lexeme with more than `1 << 40` of them is saturated to.
    private static let cap = 1 << 40

    private static let cases: [Case] = [
        // Zero is one value, however it is spelled, and never negative.
        Case("0", [], exponent: 0),
        Case("-0", [], exponent: 0),
        Case("0.0", [], exponent: 0),
        Case("-0.000e5", [], exponent: 0),
        Case("0e99999999999999999999", [], exponent: 0),
        // Whole numbers, and the trailing zeros that are not significant.
        Case("1", [1], exponent: 0),
        Case("-1", negative: true, [1], exponent: 0),
        Case("10", [1], exponent: 1),
        Case("100e-2", [1], exponent: 0),
        Case("9007199254740993", [9, 0, 0, 7, 1, 9, 9, 2, 5, 4, 7, 4, 0, 9, 9, 3], exponent: 15),
        // A fraction, and the zeros before its first digit.
        Case("1.5", [1, 5], exponent: 0),
        Case("0.001", [1], exponent: -3),
        Case("0.5e-2", [5], exponent: -3),
        // Exponents, with and without a sign, in either case.
        Case("1e5", [1], exponent: 5),
        Case("1E5", [1], exponent: 5),
        Case("1E+5", [1], exponent: 5),
        Case("1e-5", [1], exponent: -5),
        Case("1e+0", [1], exponent: 0),
        Case("1e-0", [1], exponent: 0),
        Case("1e00005", [1], exponent: 5),
        Case("-1.50e+0", negative: true, [1, 5], exponent: 0),
        Case("123.456e2", [1, 2, 3, 4, 5, 6], exponent: 4),
        Case("-0.0125E-3", negative: true, [1, 2, 5], exponent: -5),
        // An exponent too large for any Double is kept as large as it can be, then saturated.
        Case("1e1099511627775", [1], exponent: cap - 1),
        Case("1e1099511627776", [1], exponent: cap),
        Case("1e1099511627777", [1], exponent: cap),
        Case("1e99999999999999999999", [1], exponent: cap),
        Case("1e-99999999999999999999", [1], exponent: -cap),
        Case("-12.5e+99999999999999999999999999999", negative: true, [1, 2, 5], exponent: cap + 1),
        // The digits of a long run are all kept.
        // (The fiftieth digit is a zero, so it is not significant: forty-nine digits, placed as fifty.)
        Case("12345678901234567890123456789012345678901234567890", Array((1...49).map { UInt8($0 % 10) }), exponent: 49),
        Case("1" + String(repeating: "0", count: 1000), [1], exponent: 1000),
        Case("0." + String(repeating: "0", count: 1000) + "1", [1], exponent: -1001),
        Case("1." + String(repeating: "0", count: 999) + "5", [1] + [UInt8](repeating: 0, count: 999) + [5], exponent: 0),
    ]

    @Test func eachLexemeIsReadAsItsSignDigitsAndExponent() {
        for expected in Self.cases {
            let parts = NumberParts(lexeme: expected.lexeme)
            let name = expected.lexeme.count > 40 ? "\(expected.lexeme.prefix(20))… (\(expected.lexeme.count) bytes)" : expected.lexeme
            #expect(parts.negative == expected.negative, "\(name): sign")
            #expect(parts.digits == expected.digits, "\(name): digits")
            #expect(parts.exponent == expected.exponent, "\(name): exponent")
        }
    }
}

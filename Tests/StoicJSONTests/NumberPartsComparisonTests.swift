@testable import StoicJSON
import Testing

/// The lexer `NumberParts.init(lexeme:)` had before it was put on the shared
/// number scanner, copied as it was, and compared with the live one over a
/// wide table. It is here for the comparison and goes with it.
private func legacyParts(_ lexeme: String) -> (negative: Bool, digits: [UInt8], exponent: Int) {
    let exponentCap = 1 << 40
    var negative = false
    var digits: [UInt8] = []
    var integerDigits = 0
    var inFraction = false
    var exponentValue = 0
    var exponentNegative = false
    var inExponent = false

    for byte in lexeme.utf8 {
        switch byte {
        case UInt8(ascii: "-"):
            if inExponent { exponentNegative = true } else { negative = true }
        case UInt8(ascii: "+"):
            break
        case UInt8(ascii: "."):
            inFraction = true
        case UInt8(ascii: "e"), UInt8(ascii: "E"):
            inExponent = true
        default:
            let digit = Int(byte) - 0x30
            if inExponent {
                exponentValue = min(exponentValue * 10 + digit, exponentCap)
            } else {
                digits.append(UInt8(truncatingIfNeeded: digit))
                if !inFraction { integerDigits += 1 }
            }
        }
    }

    // value = 0.d1d2d3... × 10^pointPosition
    var pointPosition = integerDigits + (exponentNegative ? -exponentValue : exponentValue)
    var leading = 0
    while leading < digits.count, digits[leading] == 0 { leading += 1 }
    if leading == digits.count {
        return (false, [], 0)
    }
    digits.removeFirst(leading)
    pointPosition -= leading
    while digits.last == 0 { digits.removeLast() }

    return (negative, digits, pointPosition - 1)
}

/// A generator that gives the same numbers on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Number parts against the lexer they replace")
struct NumberPartsComparisonTests {
    private static func zeros(_ count: Int) -> String { String(repeating: "0", count: count) }

    /// Every combination of a sign, an integer part, a fraction and an exponent
    /// from lists chosen to meet each boundary the two lexers have.
    private static let tabulated: [String] = {
        let signs = ["", "-"]
        let integers = [
            "0", "1", "5", "9", "10", "100", "123", "1000000", "9007199254740993",
            String(repeating: "9", count: 38), "123456789012345678901234567890123456789",
            "1" + zeros(38), "1" + zeros(100), "7" + String(repeating: "31", count: 50), "1" + zeros(1000),
        ]
        let fractions: [String?] = [
            nil, "0", "5", "50", "000", "001", "0001", "123456789", "5" + zeros(40), zeros(40) + "1",
            String(repeating: "9", count: 38), String(repeating: "42", count: 50),
        ]
        let exponents: [String?] = [
            nil, "e0", "E0", "e+0", "e-0", "e5", "E5", "e+5", "E+5", "e-5", "E-5", "e05", "e0005", "e000005", "e0000005",
            "e999999", "e1000000", "e-999999", "e-1000000", "e308", "e-308", "e400", "e-400",
            "e1099511627775", "e1099511627776", "e1099511627777", "e-1099511627777",
            "e99999999999999999999", "e-99999999999999999999", "e123456789012345678901234567890",
        ]
        var lexemes: [String] = []
        for sign in signs {
            for integer in integers {
                for fraction in fractions {
                    for exponent in exponents {
                        lexemes.append(sign + integer + (fraction.map { "." + $0 } ?? "") + (exponent ?? ""))
                    }
                }
            }
        }
        return lexemes
    }()

    /// Lexemes of random shape: lengths, exponents and signs from a fixed seed.
    private static let random: [String] = {
        var generator = SplitMix64(state: 20_260_711)
        func digits(_ count: Int, using generator: inout SplitMix64) -> String {
            String((0..<count).map { _ in Character(UnicodeScalar(UInt8(0x30 + Int.random(in: 0...9, using: &generator)))) })
        }
        var lexemes: [String] = []
        for _ in 0..<20_000 {
            var text = Bool.random(using: &generator) ? "-" : ""
            let integerLength = Int.random(in: 1...60, using: &generator)
            text += integerLength == 1 ? digits(1, using: &generator) : String(Int.random(in: 1...9, using: &generator)) + digits(integerLength - 1, using: &generator)
            if Bool.random(using: &generator) { text += "." + digits(Int.random(in: 1...60, using: &generator), using: &generator) }
            if Bool.random(using: &generator) {
                text += Bool.random(using: &generator) ? "e" : "E"
                switch Int.random(in: 0...2, using: &generator) {
                case 0: text += "+"
                case 1: text += "-"
                default: break
                }
                text += digits(Int.random(in: 1...25, using: &generator), using: &generator)
            }
            lexemes.append(text)
        }
        // What Double.description spells: the lexemes JSONNumber(_ value: Double) reads back.
        for _ in 0..<20_000 {
            let value = Double(bitPattern: generator.next())
            if value.isFinite { lexemes.append(value.description) }
        }
        return lexemes
    }()

    @Test func theLiveLexerReadsEveryLexemeAsTheOldOneDid() {
        var mismatches: [String] = []
        for lexeme in Self.tabulated + Self.random {
            let old = legacyParts(lexeme)
            let parts = NumberParts(lexeme: lexeme)
            if parts.negative != old.negative || parts.digits != old.digits || parts.exponent != old.exponent {
                mismatches.append(lexeme.count > 60 ? "\(lexeme.prefix(30))… (\(lexeme.count) bytes)" : lexeme)
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(5))")
        #expect(Self.tabulated.count + Self.random.count > 30_000, "the table is not empty")
    }
}

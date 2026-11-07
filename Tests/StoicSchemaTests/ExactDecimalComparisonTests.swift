import StoicJSON
import Testing

@testable import StoicSchema

/// The lexer `ExactDecimal.init(_:)` had before it was put on the shared
/// number scanner, copied as it was, and compared with the live one over a
/// wide table. It is here for the comparison and goes with it.
private func legacyDecimal(_ number: JSONNumber) -> (isNegative: Bool, coefficient: UInt128, exponent: Int)? {
    var negative = false
    var digits: [UInt8] = []
    var scale = 0  // digits after the decimal point
    var exponentValue = 0
    var seenPoint = false
    var inExponent = false
    var exponentNegative = false
    var exponentDigits = 0
    for byte in number.lexeme.utf8 {
        if inExponent {
            switch byte {
            case UInt8(ascii: "-"): exponentNegative = true
            case UInt8(ascii: "+"): break
            default:
                exponentDigits += 1
                guard exponentDigits <= 6 else { return nil }
                exponentValue = exponentValue * 10 + Int(byte - 0x30)
            }
            continue
        }
        switch byte {
        case UInt8(ascii: "-"): negative = true
        case UInt8(ascii: "."): seenPoint = true
        case UInt8(ascii: "e"), UInt8(ascii: "E"): inExponent = true
        default:
            if seenPoint { scale += 1 }
            digits.append(byte - 0x30)
        }
    }
    var start = 0
    while start < digits.count, digits[start] == 0 { start += 1 }
    var end = digits.count
    var trailing = 0
    while end > start, digits[end - 1] == 0 {
        end -= 1
        trailing += 1
    }
    let significant = digits[start..<end]
    guard significant.count <= 38 else { return nil }
    var value: UInt128 = 0
    for digit in significant { value = value * 10 + UInt128(digit) }
    if value == 0 { return (false, 0, 0) }
    return (negative, value, (exponentNegative ? -exponentValue : exponentValue) - scale + trailing)
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

@Suite("Exact decimals against the lexer they replace")
struct ExactDecimalComparisonTests {
    private static func zeros(_ count: Int) -> String { String(repeating: "0", count: count) }

    /// Every combination of a sign, an integer part, a fraction and an exponent
    /// from lists chosen to meet each boundary the two lexers have. A
    /// `JSONNumber` exists only for a lexeme a `Double` can hold, so the
    /// largest exponents are met only by the numbers they leave in range,
    /// zero among them.
    private static let tabulated: [JSONNumber] = {
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
        var numbers: [JSONNumber] = []
        for sign in signs {
            for integer in integers {
                for fraction in fractions {
                    for exponent in exponents {
                        let lexeme = sign + integer + (fraction.map { "." + $0 } ?? "") + (exponent ?? "")
                        if let number = JSONNumber(lexeme: lexeme) { numbers.append(number) }
                    }
                }
            }
        }
        return numbers
    }()

    /// Lexemes of random shape: lengths, exponents and signs from a fixed seed.
    private static let random: [JSONNumber] = {
        var generator = SplitMix64(state: 20_260_712)
        func digits(_ count: Int, using generator: inout SplitMix64) -> String {
            String((0..<count).map { _ in Character(UnicodeScalar(UInt8(0x30 + Int.random(in: 0...9, using: &generator)))) })
        }
        var numbers: [JSONNumber] = []
        for _ in 0..<20_000 {
            var text = Bool.random(using: &generator) ? "-" : ""
            let integerLength = Int.random(in: 1...45, using: &generator)
            text += integerLength == 1 ? digits(1, using: &generator) : String(Int.random(in: 1...9, using: &generator)) + digits(integerLength - 1, using: &generator)
            if Bool.random(using: &generator) { text += "." + digits(Int.random(in: 1...45, using: &generator), using: &generator) }
            if Bool.random(using: &generator) {
                text += Bool.random(using: &generator) ? "e" : "E"
                switch Int.random(in: 0...2, using: &generator) {
                case 0: text += "+"
                case 1: text += "-"
                default: break
                }
                text += digits(Int.random(in: 1...8, using: &generator), using: &generator)
            }
            if let number = JSONNumber(lexeme: text) { numbers.append(number) }
        }
        // What a Double spells: the numbers JSONNumber(_ value: Double) makes.
        for _ in 0..<20_000 {
            if let number = JSONNumber(Double(bitPattern: generator.next())) { numbers.append(number) }
        }
        return numbers
    }()

    @Test func theLiveLexerReadsEveryNumberAsTheOldOneDid() {
        var mismatches: [String] = []
        var declined = 0
        for number in Self.tabulated + Self.random {
            let old = legacyDecimal(number)
            let decimal = ExactDecimal(number)
            if old == nil { declined += 1 }
            let same: Bool
            if let old, let decimal {
                same = decimal.isNegative == old.isNegative && decimal.coefficient == old.coefficient && decimal.exponent == old.exponent
            } else {
                same = old == nil && decimal == nil
            }
            if !same {
                let lexeme = number.lexeme
                mismatches.append(lexeme.count > 60 ? "\(lexeme.prefix(30))… (\(lexeme.count) bytes)" : lexeme)
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(5))")
        #expect(Self.tabulated.count + Self.random.count > 20_000, "the table is not empty")
        #expect(declined > 1_000, "and it reaches the numbers that are declined (\(declined))")
    }
}

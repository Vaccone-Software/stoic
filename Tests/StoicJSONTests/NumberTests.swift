import StoicJSON
import Testing

private func number(_ lexeme: String) throws -> JSONNumber {
    try #require(JSONNumber(lexeme: lexeme), "\(lexeme) is not a JSON number")
}

@Suite("Numbers")
struct NumberTests {
    // MARK: Exactness

    @Test func integerAbove2To53IsExactInt64ButNotExactDouble() throws {
        let n = try number("9007199254740993")
        #expect(n.int64 == 9_007_199_254_740_993)
        #expect(n.uint64 == 9_007_199_254_740_993)
        #expect(n.isInteger)
        #expect(n.double == 9_007_199_254_740_992)  // the nearest double, not the number
        #expect(!n.isExactlyRepresentableAsDouble)
    }

    @Test func integersUpTo2To53AreExactDoubles() throws {
        for text in ["0", "1", "-1", "9007199254740991", "9007199254740992", "-9007199254740992"] {
            let n = try number(text)
            #expect(n.isExactlyRepresentableAsDouble, "\(text)")
        }
    }

    @Test func parsedNumbersKeepTheirLexeme() throws {
        let value = try #require(parse("[9007199254740993, 1.50, 1E+2, -0]").value)
        let lexemes = value.array?.compactMap { $0.number?.lexeme }
        #expect(lexemes == ["9007199254740993", "1.50", "1E+2", "-0"])
    }

    @Test func negativeZero() throws {
        let n = try number("-0")
        #expect(n.int64 == 0)
        #expect(n.uint64 == 0)
        #expect(n.double == 0)
        #expect(n.double?.sign == .minus)
        #expect(n.isExactlyRepresentableAsDouble)
        #expect(n.isInteger)
        #expect(n == (try number("0")))
        #expect(n.hashValue == (try number("0")).hashValue)
        #expect(n.lexeme == "-0")
        #expect(n.canonicalLexeme == "0")
    }

    @Test func overflowIsOutOfRangeNeverInfinity() throws {
        // A number that could be built but not parsed would break every
        // encoding's promise to parse back; so it cannot be built.
        #expect(JSONNumber(lexeme: "1e400") == nil)
        #expect(JSONNumber(lexeme: "-1e400") == nil)
        #expect(JSONNumber(lexeme: "1e99999999999999999999999") == nil)
        #expect(JSONNumber(lexeme: "1" + String(repeating: "0", count: 309)) == nil)
    }

    @Test func underflowToZeroIsOutOfRangeToo() throws {
        // Decision: a nonzero number that would round to zero is out of
        // range, like overflow. One rule, and no silent 0.
        #expect(JSONNumber(lexeme: "1E-400") == nil)
        #expect(JSONNumber(lexeme: "1e-324") == nil)
        #expect(try number("0e-400").double == 0)  // actual zero is fine
        #expect(try number("0.000e500").double == 0)
    }

    @Test func subnormalsAreInRange() throws {
        let n = try number("5e-324")
        #expect(n.double == Double.leastNonzeroMagnitude)
        #expect(n.isExactlyRepresentableAsDouble)
        #expect(try number("1.7976931348623157e308").double == Double.greatestFiniteMagnitude)
        #expect(JSONNumber(lexeme: "1.7976931348623159e308") == nil)
    }

    @Test(arguments: [801, 10_000, 100_000, 1_000_000])
    func rangeIsDecidedByTheNumberNotTheLengthOfItsText(digits: Int) throws {
        // The standard library's conversion gives up on long text; a number
        // about 0.78 is in range however many digits spell it.
        let sevens = String(repeating: "7", count: digits)
        #expect(try number("0." + sevens).double == 0.7777777777777778)
        #expect(try number("-0." + sevens + "e-300").double == -0.7777777777777778e-300)
        #expect(try number("0." + String(repeating: "0", count: digits) + "e5").double == 0)
        #expect(JSONNumber(lexeme: "0." + sevens + "e310") == nil)
        #expect(JSONNumber(lexeme: "0." + sevens + "e-330") == nil)
        #expect(try JSONValue(parsing: "[0." + sevens + "]") == [.number(number("0." + sevens))])
    }

    @Test func longLexemesRoundLikeTheStandardLibraryWhereItCanStillTell() throws {
        // Past 800 digits the conversion keeps the first 800 and a sticky 1;
        // under ten thousand the standard library still converts the whole
        // text, so the two must agree.
        var random = SeededGenerator(seed: 0xD161)
        for _ in 0..<300 {
            let length = Int.random(in: 801...4000, using: &random)
            var digits = String(Int.random(in: 1...9, using: &random))
            for _ in 1..<length { digits.append(Character(Unicode.Scalar(UInt8(ascii: "0") + UInt8.random(in: 0...9, using: &random)))) }
            let exponent = Int.random(in: -320...300, using: &random)
            let text = "0." + digits + "e" + String(exponent)
            #expect(try number(text).double == Double(text), "\(text.prefix(30))… e\(exponent)")
        }
    }

    @Test func maxUInt64() throws {
        let n = try number("18446744073709551615")
        #expect(n.uint64 == UInt64.max)
        #expect(n.int64 == nil)
        #expect(n.double == 18_446_744_073_709_551_616)
        #expect(!n.isExactlyRepresentableAsDouble)
        #expect(try number("18446744073709551616").uint64 == nil)
        #expect(try number("-1").uint64 == nil)
    }

    @Test func int64Bounds() throws {
        #expect(try number("9223372036854775807").int64 == Int64.max)
        #expect(try number("9223372036854775808").int64 == nil)
        #expect(try number("9223372036854775808").uint64 == 9_223_372_036_854_775_808)
        #expect(try number("-9223372036854775808").int64 == Int64.min)
        #expect(try number("-9223372036854775809").int64 == nil)
    }

    @Test func fractionsAndExponentsAreNotIntegersByWritingButMayBeByValue() throws {
        let one = try number("1.0")
        #expect(!one.isInteger)
        #expect(one.int64 == nil)
        #expect(one.hasIntegralValue)
        #expect(one.integralInt64 == 1)
        let hundred = try number("1e2")
        #expect(!hundred.isInteger)
        #expect(hundred.int64 == nil)
        #expect(hundred.integralInt64 == 100)
        #expect(hundred.integralUInt64 == 100)
        #expect(try number("10e-1").integralInt64 == 1)
        #expect(try number("1.5").integralInt64 == nil)
        #expect(!(try number("1.5").hasIntegralValue))
        #expect(try number("1e19").integralUInt64 == 10_000_000_000_000_000_000)
        #expect(try number("1e19").integralInt64 == nil)
        #expect(try number("1e20").integralUInt64 == nil)
        #expect(try number("-1e2").integralInt64 == -100)
        #expect(try number("-1e2").integralUInt64 == nil)
        #expect(try number("123.000").integralInt64 == 123)
        #expect(try number("12.5e1").integralInt64 == 125)
        #expect(try number("0.5e1").integralInt64 == 5)
        #expect(try number("0.0").integralInt64 == 0)
    }

    @Test func decimalsAreExactWhenTheirShortestDoubleSpellingIsTheSame() throws {
        #expect(try number("0.1").isExactlyRepresentableAsDouble)
        #expect(try number("0.30000000000000004").isExactlyRepresentableAsDouble)
        #expect(try number("1.5").isExactlyRepresentableAsDouble)
        #expect(try number("1.50").isExactlyRepresentableAsDouble)
        #expect(try number("15e-1").isExactlyRepresentableAsDouble)
        #expect(try number("1e22").isExactlyRepresentableAsDouble)
        #expect(!(try number("0.10000000000000000555").isExactlyRepresentableAsDouble))
        #expect(!(try number("3.14159265358979323846264338327950288").isExactlyRepresentableAsDouble))
    }

    // MARK: Equality and hashing

    @Test func equalityIsNumericAcrossSpellings() throws {
        let spellings = ["1", "1.0", "1e0", "1E0", "10e-1", "0.1e1", "1.000", "0.01e2", "100e-2"]
        let numbers = try spellings.map(number)
        for other in numbers {
            #expect(numbers[0] == other)
            #expect(numbers[0].hashValue == other.hashValue)
        }
        #expect(try number("1") != number("1.0000000000000000000001"))
        #expect(try number("1") != number("-1"))
        #expect(try number("10") != number("1"))
        #expect(try number("0.1") != number("0.01"))
    }

    // MARK: Construction

    @Test func integerConstructorsAreCanonical() {
        #expect(JSONNumber(0).lexeme == "0")
        #expect(JSONNumber(-5).lexeme == "-5")
        #expect(JSONNumber(Int.min).lexeme == "-9223372036854775808")
        #expect(JSONNumber(UInt.max).lexeme == "18446744073709551615")
        #expect(JSONNumber(UInt64.max).uint64 == UInt64.max)
        #expect(JSONNumber(Int8.min).int64 == -128)
    }

    @Test func doubleConstructorIsShortestRoundTripInRFC8785Layout() throws {
        let cases: [(Double, String)] = [
            (0.1, "0.1"), (1, "1"), (-1.5, "-1.5"), (100, "100"), (4.5, "4.5"),
            (0.000001, "0.000001"), (1e-7, "1e-7"), (1.5e-7, "1.5e-7"),
            (1e21, "1e+21"), (1e20, "100000000000000000000"),
            (1.2345678901234568e20, "123456789012345680000"),
            (1e300, "1e+300"), (5e-324, "5e-324"),
            (Double.greatestFiniteMagnitude, "1.7976931348623157e+308"),
            (333_333_333.333_333_29, "333333333.3333333"),
            (0.30000000000000004, "0.30000000000000004"),
            (9_007_199_254_740_992, "9007199254740992"),
            (2e-3, "0.002"), (1e-27, "1e-27"), (1.2345e25, "1.2345e+25"),
        ]
        for (value, expected) in cases {
            let n = try #require(JSONNumber(value))
            #expect(n.lexeme == expected, "\(value)")
            #expect(n.double == value)
            #expect(n.isExactlyRepresentableAsDouble)
        }
    }

    @Test func doubleConstructorKeepsNegativeZeroAndRejectsNonFinite() throws {
        #expect(JSONNumber(-0.0)?.lexeme == "-0")
        #expect(JSONNumber(0.0)?.lexeme == "0")
        #expect(JSONNumber(Double.nan) == nil)
        #expect(JSONNumber(Double.infinity) == nil)
        #expect(JSONNumber(-Double.infinity) == nil)
        #expect(JSONNumber(Double.signalingNaN) == nil)
    }

    @Test func everyConstructedDoubleRoundTrips() throws {
        var generator = SeededGenerator(seed: 0xD0_0B1E)
        for _ in 0..<2000 {
            let bits = UInt64.random(in: .min ... .max, using: &generator)
            let value = Double(bitPattern: bits)
            guard value.isFinite else { continue }
            let n = try #require(JSONNumber(value))
            #expect(n.double == value, "\(value) via \(n.lexeme)")
            #expect(n.isExactlyRepresentableAsDouble, "\(n.lexeme)")
            #expect(JSONNumber(lexeme: n.lexeme) != nil)
        }
    }

    // MARK: Lexeme validation

    @Test(arguments: ["0", "-0", "1", "-1", "10", "0.5", "-0.5", "1e5", "1E5", "1e+5", "1e-5", "1.5e5", "123456789"])
    func wellFormedLexemes(_ text: String) {
        #expect(JSONNumber(lexeme: text) != nil)
    }

    @Test(arguments: ["", "-", "+1", "01", "-01", ".5", "1.", "1.e5", "0x1", "1e", "1e+", "NaN", "Infinity", "-Infinity", " 1", "1 ", "1_0", "1,5", "١٢٣", "1e5.5", "--1", "1x"])
    func malformedLexemes(_ text: String) {
        #expect(JSONNumber(lexeme: text) == nil)
    }

    @Test func wellFormedButOutOfRangeLexemesAreRefused() throws {
        // Built, it would encode to text the parser refuses.
        #expect(JSONNumber(lexeme: "1e400") == nil)
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: "1e400") }
    }

    // MARK: Order and multiples

    @Test func orderIsNumericAcrossSpellingsAndSigns() throws {
        func order(_ a: String, _ b: String) throws -> Int {
            let (x, y) = (try number(a), try number(b))
            return x < y ? -1 : (x == y ? 0 : 1)
        }
        #expect(try order("1", "1.0") == 0)
        #expect(try order("-0", "0") == 0)
        #expect(try order("1e2", "99.99") == 1)
        #expect(try order("-1e2", "-99.99") == -1)
        #expect(try order("-5", "3") == -1)
        #expect(try order("0.001", "0.0009") == 1)
        #expect(try order("9007199254740993", "9007199254740992") == 1)
        #expect(try order("12345678901234567890123456789012345678", "12345678901234567890123456789012345679") == -1)
    }

    @Test func orderIsExactPastAnyFixedPrecision() throws {
        // Forty-two digits: a Double, or 38 digits of Decimal, calls these equal.
        let above = try number("10.0000000000000000000000000000000000000001")
        #expect(above > (try number("10")))
        #expect(try number("-10.0000000000000000000000000000000000000001") < number("-10"))
        let long = "0." + String(repeating: "9", count: 5_000)
        #expect(try number(long) < number("1"))
        #expect(try number(long + "1") > number(long))
    }

    @Test func multiplesAreDecidedOnTheDigits() throws {
        func multiple(_ a: String, of b: String) throws -> Bool { try number(a).isMultiple(of: number(b)) }
        #expect(try multiple("0.3", of: "0.1"))
        #expect(try multiple("0.15", of: "0.05"))
        #expect(try multiple("-12", of: "4"))
        #expect(try multiple("12", of: "-4"))
        #expect(try multiple("0", of: "7"))
        #expect(try !multiple("7", of: "0"))
        #expect(try !multiple("0.30000000000000001", of: "0.1"))
        #expect(try multiple("1e300", of: "7e-300") == false)
        #expect(try multiple("7e300", of: "7e-300"))
        #expect(try multiple("2.5", of: "1.25"))
        #expect(try !multiple("2.5", of: "1.5"))
        // A step of more than 37 digits takes the long-division path.
        let step = "1" + String(repeating: "0", count: 40) + "3"
        #expect(try multiple(step + "0", of: step))
        #expect(try !multiple(step + "1", of: step))
        // A long dividend is judged exactly, not rounded into one that passes.
        #expect(try !multiple("0.1" + String(repeating: "0", count: 60) + "1", of: "0.1"))
    }

    // MARK: Canonical spelling

    @Test func canonicalSpellingNormalisesEquivalentNumbers() throws {
        let cases: [(String, String)] = [
            ("1.0", "1"), ("1.50", "1.5"), ("1E+2", "100"), ("-0", "0"), ("0.0", "0"),
            ("1e21", "1e+21"), ("1e-7", "1e-7"), ("0.0000001", "1e-7"), ("0.000001", "0.000001"),
            ("10e-1", "1"), ("100e-2", "1"), ("123e1", "1230"), ("1.5E3", "1500"),
            ("0e5", "0"), ("-1.0e0", "-1"), ("12345678901234567890", "12345678901234567890"),
        ]
        for (input, expected) in cases {
            #expect(try number(input).canonicalLexeme == expected, "\(input)")
        }
    }

    @Test func canonicalSpellingNeverLosesDigitsTheSourceHad() throws {
        #expect(try number("9007199254740993").canonicalLexeme == "9007199254740993")
        #expect(try number("0.10000000000000000555").canonicalLexeme == "0.10000000000000000555")
        // Twenty-three digits: past ECMAScript's 21-digit window, so exponent form.
        #expect(try number("12345678901234567890123").canonicalLexeme == "1.2345678901234567890123e+22")
    }

    @Test func rfc8785NumberSamples() throws {
        // RFC 8785 section 3.2.4, where the number fits a double exactly.
        #expect(try number("1E30").canonicalLexeme == "1e+30")
        #expect(try number("4.50").canonicalLexeme == "4.5")
        #expect(try number("2e-3").canonicalLexeme == "0.002")
        #expect(try number("0.000000000000000000000000001").canonicalLexeme == "1e-27")
        // The RFC rounds this through a double; Stoic keeps the digits it was given.
        #expect(try number("333333333.33333329").canonicalLexeme == "333333333.33333329")
    }

    @Test func canonicalSpellingIsAFixedPoint() throws {
        for text in ["1.0", "-0", "1E30", "9007199254740993", "0.1e1", "123e-20", "1e300", "12345678901234567890123"] {
            let once = try number(text).canonicalLexeme
            #expect(try number(once).canonicalLexeme == once, "\(text)")
            #expect(try number(once) == number(text), "\(text)")
        }
    }

    @Test func descriptionIsTheLexeme() throws {
        #expect(try number("1E+2").description == "1E+2")
    }
}

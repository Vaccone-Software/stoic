import StoicJSON
import Testing

@testable import StoicSchema

/// Checks one constraint against JSON text and returns the codes it raised.
private func codes(_ constraint: Constraint, _ text: String) -> [IssueCode] {
    constraint.check(json(text)).map(\.code)
}

@Suite("Range constraints")
struct RangeConstraintTests {
    @Test func inclusiveBoundsAdmitTheirEnds() {
        let c = Constraint.range(200...4000)
        #expect(codes(c, "200").isEmpty)
        #expect(codes(c, "4000").isEmpty)
        #expect(codes(c, "199") == [.outOfRange])
        #expect(codes(c, "4001") == [.outOfRange])
        #expect(codes(c, "199.999") == [.outOfRange])
    }

    @Test func halfOpenRangesExcludeTheirUpperEnd() {
        let c = Constraint.range(0..<10)
        #expect(codes(c, "0").isEmpty)
        #expect(codes(c, "9.99").isEmpty)
        #expect(codes(c, "10") == [.outOfRange])
    }

    @Test func oneSidedRanges() {
        #expect(codes(.range(5...), "5").isEmpty)
        #expect(codes(.range(5...), "4") == [.outOfRange])
        #expect(codes(.range(...5), "5").isEmpty)
        #expect(codes(.range(...5), "6") == [.outOfRange])
        #expect(codes(.range(..<5), "5") == [.outOfRange])
        #expect(codes(.range(0.5...), "0.5").isEmpty)
    }

    @Test func exclusiveBoundsViaGreaterAndLessThan() {
        #expect(codes(.greaterThan(0), "0") == [.outOfRange])
        #expect(codes(.greaterThan(0), "0.0000001").isEmpty)
        #expect(codes(.lessThan(1), "1") == [.outOfRange])
        #expect(codes(.lessThan(1), "0.999").isEmpty)
    }

    @Test func infiniteBoundsMeanNoBound() {
        let c = Constraint.range(0...Double.infinity)
        #expect(codes(c, "0").isEmpty)
        #expect(codes(c, "1e300").isEmpty)
        #expect(codes(c, "-1") == [.outOfRange])
        guard case .range(let range) = c.kind else { return fail("not a range") }
        #expect(range.upper == nil)
    }

    @Test func decimalBoundsAreExact() {
        // 0.1 in a file satisfies 0.1...10: the bound is the lexeme "0.1".
        let c = Constraint.range(0.1...10)
        #expect(codes(c, "0.1").isEmpty)
        #expect(codes(c, "0.10").isEmpty)
        #expect(codes(c, "1e-1").isEmpty)
        #expect(codes(c, "0.09999999999999999") == [.outOfRange])
        #expect(codes(c, "10.000").isEmpty)
        #expect(codes(c, "10.0000000000000001") == [.outOfRange])
    }

    @Test func integersAboveTwoToTheFiftyThreeAreNotConfusedWithEachOther() {
        // As doubles these are the same number.
        let c = Constraint.range(...9_007_199_254_740_992)
        #expect(codes(c, "9007199254740992").isEmpty)
        #expect(codes(c, "9007199254740993") == [.outOfRange])
        #expect(codes(.range(Int64.min...Int64.max), "9223372036854775807").isEmpty)
        #expect(codes(.range(UInt64.min...UInt64.max), "18446744073709551615").isEmpty)
        #expect(codes(.range(0...UInt64.max), "-1") == [.outOfRange])
    }

    @Test func negativeZeroEqualsZero() {
        #expect(codes(.range(0...1), "-0").isEmpty)
        #expect(codes(.greaterThan(0), "-0") == [.outOfRange])
    }

    @Test func differentSpellingsOfOneNumberCompareEqual() {
        let c = Constraint.range(100...100)
        for spelling in ["100", "100.0", "1e2", "10e1", "1000e-1", "0.1e3"] {
            #expect(codes(c, spelling).isEmpty, "\(spelling)")
        }
        #expect(codes(c, "100.0001") == [.outOfRange])
    }

    @Test func hugeAndTinyMagnitudesCompare() {
        #expect(codes(.range(0...1e308), "1e308").isEmpty)
        #expect(codes(.range(0...1e308), "1.0000001e308") == [.outOfRange])
        #expect(codes(.range(1e-300...1), "1e-301") == [.outOfRange])
        #expect(codes(.range(-1e300...1e300), "-1e301") == [.outOfRange])
    }

    @Test func violationCarriesTheBoundsAsParameters() {
        let issue = Constraint.range(200...4000).check(json("5000"), at: at("scrollSpeed"))[0]
        #expect(issue.path == at("scrollSpeed"))
        #expect(issue.parameters["minimum"] == 200)
        #expect(issue.parameters["maximum"] == 4000)
        #expect(issue.expected == "a number between 200 and 4000")
        #expect(issue.actual == "5000")
        #expect(issue.message == "5000 is out of range, expected a number between 200 and 4000")
        let exclusive = Constraint.greaterThan(0).check(json("-1"))[0]
        #expect(exclusive.parameters["exclusiveMinimum"] == 0)
        #expect(exclusive.expected == "a number that is greater than 0")
    }

    @Test func rangesIgnoreNonNumbers() {
        #expect(codes(.range(1...2), "\"zzz\"").isEmpty)
        #expect(codes(.range(1...2), "null").isEmpty)
        #expect(codes(.range(1...2), "[5]").isEmpty)
    }
}

@Suite("multipleOf")
struct MultipleOfTests {
    @Test func integers() {
        #expect(codes(.multipleOf(5), "10").isEmpty)
        #expect(codes(.multipleOf(5), "0").isEmpty)
        #expect(codes(.multipleOf(5), "-15").isEmpty)
        #expect(codes(.multipleOf(5), "11") == [.notMultiple])
        #expect(codes(.multipleOf(5), "10.5") == [.notMultiple])
        #expect(codes(.multipleOf(5), "10.0").isEmpty)
    }

    @Test func decimalStepsAreExactWhereDoublesAreNot() {
        // 0.3 / 0.1 is 2.9999999999999996 in floating point.
        #expect(codes(.multipleOf(0.1), "0.3").isEmpty)
        #expect(codes(.multipleOf(0.01), "19.99").isEmpty)
        #expect(codes(.multipleOf(0.01), "19.995") == [.notMultiple])
        #expect(codes(.multipleOf(0.25), "1.75").isEmpty)
    }

    @Test func hugeIntegersAreExact() {
        #expect(codes(.multipleOf(10), "9007199254740990").isEmpty)
        #expect(codes(.multipleOf(10), "9007199254740993") == [.notMultiple])
    }

    @Test func aStepOfZeroOrLessIsAnInvalidConstraintNotACrash() {
        #expect(codes(.multipleOf(0), "5") == [.invalidConstraint])
        #expect(codes(.multipleOf(-2), "4") == [.invalidConstraint])
    }

    @Test func expectationNamesTheStep() {
        #expect(Constraint.multipleOf(5).check(json("11"))[0].expected == "a multiple of 5")
    }

    @Test func ignoresNonNumbers() {
        #expect(codes(.multipleOf(5), "\"x\"").isEmpty)
    }
}

@Suite("finite")
struct FiniteConstraintTests {
    @Test func aNumberOutsideDoubleIsNotFinite() {
        guard let huge = JSONNumber(lexeme: "1e999") else { return fail("lexeme") }
        let issues = Constraint.finite.check(.number(huge))
        #expect(issues.map(\.code) == [.notFinite])
        #expect(codes(.finite, "1e308").isEmpty)
        #expect(codes(.finite, "0").isEmpty)
    }
}

@Suite("String length")
struct LengthConstraintTests {
    @Test func charactersAreUnicodeScalars() {
        let c = Constraint.length(1...3)
        #expect(codes(c, "\"abc\"").isEmpty)
        #expect(codes(c, "\"abcd\"") == [.tooLong])
        #expect(codes(c, "\"\"") == [.tooShort])
        // e + combining acute: one grapheme, two scalars, three bytes.
        #expect(codes(.length(1...1), "\"e\\u0301\"") == [.tooLong])
        // Skin-toned thumbs up: one grapheme, two scalars, eight bytes.
        #expect(codes(.length(2...2), "\"\\ud83d\\udc4d\\ud83c\\udffd\"").isEmpty)
    }

    @Test func graphemesCountWhatTheReaderSees() {
        let c = Constraint.length(1...1, unit: .graphemes)
        #expect(codes(c, "\"e\\u0301\"").isEmpty)
        #expect(codes(c, "\"\\ud83d\\udc4d\\ud83c\\udffd\"").isEmpty)
        #expect(codes(c, "\"ab\"") == [.tooLong])
    }

    @Test func bytesCountWhatTheDatabaseStores() {
        let c = Constraint.length(...4, unit: .utf8Bytes)
        #expect(codes(c, "\"abcd\"").isEmpty)
        #expect(codes(c, "\"\\u00e9\\u00e9\\u00e9\"") == [.tooLong])  // three 2-byte scalars
        #expect(codes(c, "\"\\u00e9\\u00e9\"").isEmpty)
    }

    @Test func parametersSayHowFarOff() {
        let issue = Constraint.length(2...4).check(json("\"a\""))[0]
        #expect(issue.code == .tooShort)
        #expect(issue.parameters["count"] == 1)
        #expect(issue.parameters["minimum"] == 2)
        #expect(issue.parameters["maximum"] == 4)
        #expect(issue.expected == "a string of 2 to 4 characters")
        #expect(issue.message == "too short: 1 characters, expected a string of 2 to 4 characters")
    }

    @Test func phrasing() {
        #expect(Constraint.length(1...).description == "a string of at least 1 character")
        #expect(Constraint.length(...64).description == "a string of at most 64 characters")
        #expect(Constraint.length(8...8).description == "a string of exactly 8 characters")
        #expect(Constraint.length(0..<5, unit: .utf8Bytes).description == "a string of 0 to 4 UTF-8 bytes")
    }

    @Test func ignoresNonStrings() {
        #expect(codes(.length(1...2), "12345").isEmpty)
    }
}

@Suite("Collection count and uniqueness")
struct CountConstraintTests {
    @Test func arrays() {
        let c = Constraint.count(1...3)
        #expect(codes(c, "[1]").isEmpty)
        #expect(codes(c, "[]") == [.tooFew])
        #expect(codes(c, "[1,2,3,4]") == [.tooMany])
    }

    @Test func objectsCountEntries() {
        let issue = Constraint.count(...1).check(json(#"{"a":1,"b":2}"#))[0]
        #expect(issue.code == .tooMany)
        #expect(issue.expected == "a collection of at most 1 entry")
        #expect(issue.parameters["count"] == 2)
    }

    @Test func uniqueReportsEachRepeatAtItsIndex() {
        let issues = Constraint.unique.check(json("[1, 2, 1, 3, 2, 1]"), at: at("ids"))
        #expect(issues.map(\.path) == [
            JSONPath([.key("ids"), .index(2)]), JSONPath([.key("ids"), .index(4)]), JSONPath([.key("ids"), .index(5)]),
        ])
        #expect(issues.map(\.code) == [.notUnique, .notUnique, .notUnique])
        #expect(issues[0].parameters["firstIndex"] == 0)
        #expect(issues[1].parameters["firstIndex"] == 1)
        #expect(issues[0].message == "duplicates the element at index 0")
    }

    @Test func uniqueUsesJSONEquality() {
        #expect(codes(.unique, "[1, 1.0]") == [.notUnique])
        #expect(codes(.unique, #"["é", "é"]"#).isEmpty)  // different scalars
        #expect(codes(.unique, #"[{"a":1,"b":2}, {"b":2,"a":1}]"#) == [.notUnique])
        #expect(codes(.unique, "[[1],[2],[1]]") == [.notUnique])
        #expect(codes(.unique, "[null, 0, false, \"\"]").isEmpty)
    }

    @Test func uniqueIgnoresNonArrays() {
        #expect(codes(.unique, "5").isEmpty)
    }
}

@Suite("Pattern constraints")
struct PatternConstraintTests {
    @Test func matchesAnywhereUnlessAnchored() {
        #expect(codes(.pattern("[0-9]+"), "\"abc123def\"").isEmpty)
        #expect(codes(.pattern("^[0-9]+$"), "\"abc123def\"") == [.patternMismatch])
        #expect(codes(.pattern("^[a-z]+$"), "\"abc\"").isEmpty)
        #expect(codes(.pattern("^[a-z]+$"), "\"Abc\"") == [.patternMismatch])
        #expect(codes(.pattern("^[a-z]+$"), "\"\"") == [.patternMismatch])
    }

    @Test func dollarDoesNotMatchBeforeATrailingNewline() {
        // A validator that lets "abc\n" through `^[a-z]+$` lets a newline into
        // a header or a file name. Pin the behaviour of the engine.
        #expect(codes(.pattern("^[a-z]+$"), "\"abc\\n\"") == [.patternMismatch])
    }

    @Test func dotIsOneScalar() {
        #expect(codes(.pattern("^.$"), "\"e\\u0301\"") == [.patternMismatch])  // two scalars
        #expect(codes(.pattern("^..$"), "\"e\\u0301\"").isEmpty)
        #expect(codes(.pattern("^.$"), "\"\\ud83d\\udc4d\"").isEmpty)
    }

    @Test func alternationGroupsAndRepetition() {
        let c = Constraint.pattern("^(http|https)://[a-z.]+(:[0-9]{1,5})?$")
        #expect(codes(c, "\"https://example.com:8080\"").isEmpty)
        #expect(codes(c, "\"ftp://example.com\"") == [.patternMismatch])
        #expect(codes(c, "\"http://example.com:123456\"") == [.patternMismatch])
    }

    @Test func aPatternThatIsNotARegexIsAnInvalidConstraint() {
        let issues = Constraint.pattern("([a-z").check(json("\"a\""))
        #expect(issues.map(\.code) == [.invalidConstraint])
        #expect(issues[0].message.contains("([a-z"))
    }

    @Test func theSourceIsKeptForExport() {
        guard case .pattern(let source) = Constraint.pattern("^a+$").kind else { return fail("kind") }
        #expect(source == "^a+$")
    }

    @Test func patternIsSkippedWhenLengthAlreadyFailed() {
        // The pattern would also fail; only the cheap check reports.
        let issues = [Constraint.length(...3), .pattern("^[0-9]+$")].check(json("\"abcdef\""))
        #expect(issues.map(\.code) == [.tooLong])
        let both = [Constraint.length(...10), .pattern("^[0-9]+$")].check(json("\"abcdef\""))
        #expect(both.map(\.code) == [.patternMismatch])
    }

    @Test func aLongStringIsNotEchoedInFull() {
        let long = String(repeating: "x", count: 500)
        let issue = Constraint.pattern("^[0-9]+$").check(.string(long))[0]
        #expect((issue.actual?.unicodeScalars.count ?? 0) <= 52)
        #expect(issue.actual?.hasSuffix("\u{2026}\"") == true)
    }

    @Test func ignoresNonStrings() {
        #expect(codes(.pattern("^a$"), "5").isEmpty)
    }
}

@Suite("oneOf and custom")
struct OneOfAndCustomTests {
    @Test func oneOfMatchesByJSONEquality() {
        let c = Constraint.oneOf(["a", "b", 3, .null])
        #expect(codes(c, "\"a\"").isEmpty)
        #expect(codes(c, "3.0").isEmpty)
        #expect(codes(c, "null").isEmpty)
        #expect(codes(c, "\"c\"") == [.notOneOf])
        #expect(codes(c, "4") == [.notOneOf])
        #expect(Constraint.oneOf(["a", "b"]).check(json("\"c\""))[0].expected == #"one of "a", "b""#)
    }

    @Test func oneOfTruncatesALongListInItsExpectation() {
        let values = (0..<20).map { JSONValue.number(JSONNumber($0)) }
        let expected = Constraint.oneOf(values).check(json("99"))[0].expected
        #expect(expected == "one of 0, 1, 2, 3, 4, 5, 6, 7, \u{2026}")
    }

    @Test func customRunsItsClosureAndIsAnnotated() {
        let even = Constraint.custom(id: "even", description: "an even number") { value in
            value.number?.int64.map { $0 % 2 == 0 } ?? false
        }
        #expect(codes(even, "4").isEmpty)
        let issue = even.check(json("5"))[0]
        #expect(issue.code == .custom)
        #expect(issue.parameters["id"] == "even")
        #expect(issue.expected == "an even number")
        #expect(issue.message == "fails the `even` check: an even number")
    }

    @Test func customsCompareByIdAndDescription() {
        let a = Constraint.custom(id: "x", description: "d") { _ in true }
        let b = Constraint.custom(id: "x", description: "d") { _ in false }
        let c = Constraint.custom(id: "y", description: "d") { _ in true }
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}

@Suite("Constraint lists")
struct ConstraintListTests {
    @Test func everyViolationIsReportedInOrder() {
        let issues = [Constraint.range(10...20), .multipleOf(3)].check(json("5"))
        #expect(issues.map(\.code) == [.outOfRange, .notMultiple])
    }

    @Test func aSatisfiedListIsSilent() {
        #expect([Constraint.range(10...20), .multipleOf(3)].check(json("15")).isEmpty)
    }

    @Test func constraintsAreValuesYouCanCompare() {
        #expect(Constraint.range(1...5) == Constraint.range(1...5))
        #expect(Constraint.range(1...5) != Constraint.range(1..<5))
        #expect(Constraint.length(1...5) != Constraint.length(1...5, unit: .utf8Bytes))
        #expect(Constraint.unique == Constraint.unique)
    }

    @Test func rangeSugarKeepsIntegerBoundsExact() {
        guard case .range(let range) = Constraint.range(200...4000).kind else { return fail("kind") }
        #expect(range.lower?.value.lexeme == "200")
        #expect(range.upper?.value.lexeme == "4000")
        guard case .range(let fractional) = Constraint.range(0.1...10).kind else { return fail("kind") }
        #expect(fractional.lower?.value.lexeme == "0.1")
        #expect(fractional.upper?.value.lexeme == "10")
    }
}

@Suite("ExactDecimal")
struct ExactDecimalTests {
    private func number(_ text: String) -> JSONNumber {
        guard let number = JSONNumber(lexeme: text) else {
            fail("bad lexeme \(text)")
            return JSONNumber(0)
        }
        return number
    }

    @Test func comparesAcrossSpellingsAndSigns() {
        func order(_ a: String, _ b: String) -> Int { number(a).compared(to: number(b)) }
        #expect(order("1", "1.0") == 0)
        #expect(order("-0", "0") == 0)
        #expect(order("1e2", "99.99") == 1)
        #expect(order("-1e2", "-99.99") == -1)
        #expect(order("-5", "3") == -1)
        #expect(order("0.001", "0.0009") == 1)
        #expect(order("12345678901234567890123456789012345678", "12345678901234567890123456789012345679") == -1)
    }

    @Test func fallsBackToDoubleBeyondThirtyEightDigits() {
        let long = "1." + String(repeating: "0", count: 60) + "1"
        #expect(number(long).compared(to: number("1")) == 0)  // the fallback cannot tell
        #expect(number(long).compared(to: number("2")) == -1)
    }

    @Test func zeroHasOneRepresentation() {
        #expect(ExactDecimal(number("0.000"))?.coefficient == 0)
        #expect(ExactDecimal(number("-0e5"))?.isNegative == false)
        #expect(number("0e0").isZero)
        #expect(!number("1e-300").isZero)
    }

    @Test func absurdExponentsAreDeclinedNotComputed() {
        #expect(ExactDecimal(number("1e9999999")) == nil)
    }
}

import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

/// Decodes JSON text with a schema, parsing it with the same options the
/// schema's entry point would, and returns the full result.
private func decode<V>(_ schema: Schema<V>, _ text: String, _ options: DecodeOptions = .strict) -> Decoded<V> {
    schema.decodeReporting(text, options: options)
}

@Suite("Booleans")
struct BoolSchemaTests {
    @Test func acceptsOnlyBooleans() {
        #expect(decode(.bool, "true").value == true)
        #expect(decode(.bool, "false").value == false)
        for text in ["1", "0", "null", "\"true\"", "[]", "{}"] {
            let result = decode(.bool, text)
            #expect(result.value == nil, "\(text)")
            #expect(result.issues.map(\.code) == [.typeMismatch], "\(text)")
        }
    }

    @Test func aStringThatSpellsABooleanIsSuggested() {
        let issue = decode(.bool, "\"true\"").issues[0]
        #expect(issue.suggestions == ["true"])
        #expect(issue.description == "1:1 $: expected a boolean, found string \"true\" (did you mean `true`?)")
    }
}

@Suite("Integers")
struct IntSchemaTests {
    @Test func acceptsIntegers() {
        #expect(decode(.int(), "42").value == 42)
        #expect(decode(.int(), "-7").value == -7)
        #expect(decode(.int(), "0").value == 0)
        #expect(decode(.int(), "-0").value == 0)
        #expect(decode(.int(), "9223372036854775807").value == Int.max)
        #expect(decode(.int(), "-9223372036854775808").value == Int.min)
    }

    @Test func refusesWhatIsNotWhole() {
        let result = decode(.int(), "1.5")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.typeMismatch])
        #expect(result.issues[0].message == "expected an integer, found number 1.5")
        #expect(result.issues[0].suggestions.isEmpty)
    }

    @Test func oneWithAFractionIsRefusedStrictlyAndSuggested() {
        for (text, hint) in [("1.0", "1"), ("1e2", "100"), ("10.00", "10"), ("-3.0", "-3")] {
            let result = decode(.int(), text)
            #expect(result.value == nil, "\(text)")
            #expect(result.issues[0].code == .typeMismatch, "\(text)")
            #expect(result.issues[0].suggestions == [hint], "\(text)")
        }
    }

    @Test func lenientAcceptsAWholeNumberWithAWarning() {
        let result = decode(.int(), "1.0", .lenient)
        #expect(result.value == 1)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].severity == .warning)
        #expect(result.issues[0].code == .typeMismatch)
        #expect(decode(.int(), "1e2", .lenient).value == 100)
        // Still not 1.5.
        #expect(decode(.int(), "1.5", .lenient).value == nil)
    }

    @Test(.failureMode("design/06", "a number is out of range under .strict")) func overflowIsOutOfRangeNeverWrapped() {
        let result = decode(.int(), "9223372036854775808")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.outOfRange])
        #expect(result.issues[0].expected == "an integer between -9223372036854775808 and 9223372036854775807")
        #expect(decode(.int(), "-9223372036854775809").issues.map(\.code) == [.outOfRange])
        #expect(decode(.int(), "1e30", .lenient).issues.map(\.code) == [.outOfRange])
    }

    @Test func aStringOfDigitsIsRefusedWithTheNumberAsSuggestion() {
        let result = decode(.int(), "\"10\"")
        #expect(result.value == nil)
        #expect(result.issues[0].suggestions == ["10"])
        #expect(result.issues[0].message == "expected an integer, found string \"10\"")
        #expect(decode(.int(), "\"ten\"").issues[0].suggestions.isEmpty)
        #expect(decode(.int(), "\" 10\"").issues[0].suggestions.isEmpty)
    }

    @Test func otherKindsAreMismatches() {
        for text in ["null", "true", "[1]", "{}"] {
            #expect(decode(.int(), text).issues.map(\.code) == [.typeMismatch], "\(text)")
        }
        #expect(decode(.int(), "null").issues[0].message == "expected an integer, found null")
        #expect(decode(.int(), "[1]").issues[0].message == "expected an integer, found array")
    }

    @Test func constraintsApplyToTheNumber() {
        let schema = Schema.int(.range(1...65_535))
        #expect(decode(schema, "8080").value == 8080)
        #expect(decode(schema, "0").issues.map(\.code) == [.outOfRange])
        #expect(decode(schema, "65536").issues.map(\.code) == [.outOfRange])
        #expect(decode(Schema.int(.multipleOf(10)), "25").issues.map(\.code) == [.notMultiple])
    }

    @Test func int64AndUInt64CoverTheirFullRanges() {
        #expect(decode(.int64(), "-9223372036854775808").value == Int64.min)
        #expect(decode(.int64(), "9223372036854775808").issues.map(\.code) == [.outOfRange])
        #expect(decode(.uint64(), "18446744073709551615").value == UInt64.max)
        #expect(decode(.uint64(), "18446744073709551616").issues.map(\.code) == [.outOfRange])
        #expect(decode(.uint64(), "-1").issues.map(\.code) == [.outOfRange])
        #expect(decode(.uint64(), "0").value == 0)
        #expect(decode(.uint64(), "-0").value == 0)
    }

    @Test func narrowIntegersRefuseWhatDoesNotFit() {
        let byte = Schema<UInt8>.integer(UInt8.self)
        #expect(decode(byte, "255").value == 255)
        #expect(decode(byte, "256").issues.map(\.code) == [.outOfRange])
        #expect(decode(byte, "-1").issues.map(\.code) == [.outOfRange])
        #expect(decode(byte, "256").issues[0].expected == "an integer between 0 and 255")
        let small = Schema<Int8>.integer(Int8.self)
        #expect(decode(small, "-128").value == -128)
        #expect(decode(small, "-129").issues.map(\.code) == [.outOfRange])
    }

    @Test func nodeCarriesTypeAndConstraints() {
        guard case .integer(let type, let constraints) = Schema.int(.range(1...5)).node else { return fail("node") }
        #expect(type == .int)
        #expect(constraints == [.range(1...5)])
        #expect(IntegerType.int.minimum.lexeme == "-9223372036854775808")
        #expect(IntegerType.uint64.maximum.lexeme == "18446744073709551615")
        #expect(IntegerType(UInt8.self).maximum.lexeme == "255")
        #expect(IntegerType(Int16.self).minimum.lexeme == "-32768")
    }

    @Test func encodesExactly() {
        #expect(Schema.int().encode(42) == 42)
        #expect(Schema.int().encode(Int.min).encodedString() == "-9223372036854775808")
        #expect(Schema.uint64().encode(UInt64.max).encodedString() == "18446744073709551615")
    }
}

@Suite("Doubles")
struct DoubleSchemaTests {
    @Test func acceptsAnyFiniteNumber() {
        #expect(decode(.double(), "1.5").value == 1.5)
        #expect(decode(.double(), "3").value == 3)
        #expect(decode(.double(), "-0.25").value == -0.25)
        #expect(decode(.double(), "1e3").value == 1000)
        #expect(decode(.double(), "0.1").value == 0.1)
        #expect(decode(.double(), "5e-324").value == Double.leastNonzeroMagnitude)
    }

    @Test func aNumberTooBigForDoubleNeverReachesTheSchema() {
        // StoicJSON refuses it in text and in code alike, so a Double field
        // cannot be handed infinity or a silent zero.
        #expect(JSONNumber(lexeme: "1e400") == nil)
        #expect(JSONNumber(lexeme: "1e-400") == nil)
    }

    @Test func textWithAnOverflowingNumberIsAParseErrorFirst() {
        let result = decode(.double(), "1e400")
        #expect(result.issues.map(\.code) == [.parseError])
    }

    @Test(.failureMode("design/06", "an integer exceeds 2^53 for a Double field")) func anIntegerAboveTwoToTheFiftyThreeIsPrecisionLoss() {
        let result = decode(.double(), "9007199254740993")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.precisionLoss])
        #expect(result.issues[0].actual == "9007199254740993")
        #expect(decode(.double(), "9007199254740992").value == 9_007_199_254_740_992)
        #expect(decode(.double(), "9007199254740994").value == 9_007_199_254_740_994)
        #expect(decode(.double(), "-9007199254740993").issues.map(\.code) == [.precisionLoss])
        #expect(decode(.double(), "9007199254740993.0").issues.map(\.code) == [.precisionLoss])
        #expect(decode(.double(), "123456789012345678901234567890").issues.map(\.code) == [.precisionLoss])
        // Exactly representable large values are fine.
        #expect(decode(.double(), "1e22").value == 1e22)
        #expect(decode(.double(), "4611686018427387904").value == 4_611_686_018_427_387_904)
    }

    @Test(.failureMode("design/06", "a number rounds, as a `Double`, across one of its constraints"))
    func aNumberThatRoundsAcrossABoundIsPrecisionLoss() {
        // The digits are below 10; the Double they make is 10.0.
        let result = decode(.double(.lessThan(10)), "9.99999999999999999999")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.precisionLoss])
        #expect(result.issues[0].message == "9.99999999999999999999 is read as 10, which is not a number that is less than 10")
        #expect(decode(.double(.lessThan(10)), "9.999999999999998").value == 9.999999999999998)
        // Rounding onto an inclusive bound stays inside it.
        #expect(decode(.double(.range(0...1)), "0.99999999999999999999").value == 1)
        #expect(decode(.double(.greaterThan(0)), "1e-320").value == 1e-320)
    }

    @Test func whateverADoubleFieldReturnsItsSchemaValidates() {
        // Near every kind of bound, from both sides, with too many digits.
        let schemas: [Schema<Double>] = [
            .double(.lessThan(10)), .double(.greaterThan(-1)), .double(.range(0...1)),
            .double(.range(0.1...0.3), .multipleOf(0.1)), .double(.lessThan(1e-300)),
        ]
        var texts = [
            "9.99999999999999999999", "10.00000000000000000001", "-0.99999999999999999999",
            "-1.00000000000000000001", "0.99999999999999999999", "1.00000000000000000001",
            "0.09999999999999999999", "0.10000000000000000001", "0.29999999999999999999",
            "0.30000000000000000001", "9.99999999999999999999e-301", "1.00000000000000000001e-300",
        ]
        var random = SeededGenerator(seed: 0xB0D)
        for _ in 0..<200 {
            let nines = String(repeating: "9", count: Int.random(in: 14...24, using: &random))
            let sign = Bool.random(using: &random) ? "-" : ""
            texts.append("\(sign)0.\(nines)e\(Int.random(in: -1...2, using: &random))")
            texts.append("\(sign)1.\(String(repeating: "0", count: Int.random(in: 14...24, using: &random)))1e\(Int.random(in: -2...1, using: &random))")
        }
        for schema in schemas {
            for text in texts {
                guard let value = decode(schema, text).value else { continue }
                #expect(schema.validate(value).isEmpty, "\(text) gave \(value)")
            }
        }
    }

    @Test func ordinaryDecimalsAreNotPrecisionLoss() {
        #expect(decode(.double(), "0.30000000000000004").value == 0.30000000000000004)
        #expect(decode(.double(), "3.14159265358979323846").value != nil)
    }

    @Test func rangeIsCheckedOnTheWrittenNumber() {
        let schema = Schema.double(.range(200...4000))
        #expect(decode(schema, "1200").value == 1200)
        #expect(decode(schema, "199.99").issues.map(\.code) == [.outOfRange])
        #expect(decode(Schema.double(.range(0.1...10)), "0.1").value == 0.1)
    }

    @Test func aStringOfDigitsIsSuggestedAsANumber() {
        let result = decode(.double(), "\"2.5\"")
        #expect(result.issues[0].suggestions == ["2.5"])
    }

    @Test func nonFiniteSwiftValuesCannotBeEncoded() {
        let schema = Schema.double()
        #expect(schema.encode(.nan) == .null)
        #expect(schema.encode(.infinity) == .null)
        let issues = schema.validate(.nan)
        #expect(issues.map(\.code) == [.notFinite])
        #expect(issues[0].actual == "NaN")
        #expect(schema.validate(-.infinity)[0].actual == "-infinity")
        #expect(schema.validate(1.5).isEmpty)
    }

    @Test func encodesTheShortestRoundTrip() {
        #expect(Schema.double().encode(0.1).encodedString() == "0.1")
        #expect(Schema.double().encode(1200).encodedString() == "1200")
        #expect(Schema.double().encode(-0.0).encodedString() == "0")
    }
}

@Suite("Strings")
struct StringSchemaTests {
    @Test func acceptsStrings() {
        #expect(decode(.string(), "\"hello\"").value == "hello")
        #expect(decode(.string(), "\"\"").value == "")
        #expect(decode(.string(), "\"\\u00e9\"").value == "\u{E9}")
    }

    @Test func aNumberIsRefusedWithItsStringFormSuggested() {
        let result = decode(.string(), "10")
        #expect(result.value == nil)
        #expect(result.issues[0].suggestions == ["\"10\""])
        #expect(result.issues[0].description == "1:1 $: expected a string, found number 10 (did you mean `\"10\"`?)")
        #expect(decode(.string(), "true").issues[0].suggestions == ["\"true\""])
        #expect(decode(.string(), "null").issues[0].suggestions.isEmpty)
    }

    @Test func lengthAndPatternApply() {
        let schema = Schema.string(.length(1...5), .pattern("^[a-z]+$"))
        #expect(decode(schema, "\"abc\"").value == "abc")
        // The pattern is not run on a string whose length already failed.
        #expect(decode(schema, "\"\"").issues.map(\.code) == [.tooShort])
        #expect(decode(schema, "\"abcdefg\"").issues.map(\.code) == [.tooLong])
        #expect(decode(schema, "\"ab1\"").issues.map(\.code) == [.patternMismatch])
    }

    @Test func aPatternIsCompiledOncePerDecode() {
        // Not observable directly; this pins that many strings with one
        // pattern all check correctly through the cache.
        let schema = Schema.array(of: .string(.pattern("^[0-9]+$")))
        let result = decode(schema, #"["1","a","22","b","333"]"#)
        #expect(result.issues.map(\.path.description) == ["$[1]", "$[3]"])
    }
}

@Suite("Enumerations")
struct EnumerationSchemaTests {
    @Test func acceptsRawValues() {
        let schema = Schema.enumeration(Theme.self)
        #expect(decode(schema, "\"dark\"").value == .dark)
        #expect(decode(schema, "\"system\"").value == .system)
    }

    @Test func aWrongCaseIsRefusedAndTheRightOneSuggested() {
        let schema = Schema.enumeration(Theme.self)
        let result = decode(schema, "\"Dark\"")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.notOneOf])
        #expect(result.issues[0].suggestions == ["dark"])
        #expect(result.issues[0].expected == #"one of "light", "dark", "system""#)
        #expect(
            result.issues[0].description
                == #"1:1 $: "Dark" is not allowed, expected one of "light", "dark", "system" (did you mean `dark`?)"#)
    }

    @Test func aTypoGetsTheNearestCase() {
        let schema = Schema.enumeration(Theme.self)
        #expect(decode(schema, "\"ligth\"").issues[0].suggestions == ["light"])
        #expect(decode(schema, "\"sytsem\"").issues[0].suggestions == ["system"])
        #expect(decode(schema, "\"purple\"").issues[0].suggestions.isEmpty)
    }

    @Test func aNonStringIsATypeMismatchListingTheCases() {
        let result = decode(Schema.enumeration(Theme.self), "3")
        #expect(result.issues.map(\.code) == [.typeMismatch])
        #expect(result.issues[0].expected == #"one of "light", "dark", "system""#)
    }

    @Test func casesAreMatchedByScalarsNotCanonicalEquivalence() {
        enum Accented: String, CaseIterable, Sendable { case cafe = "caf\u{E9}" }
        let schema = Schema.enumeration(Accented.self)
        #expect(decode(schema, "\"caf\\u00e9\"").value == .cafe)
        let result = decode(schema, "\"cafe\\u0301\"")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.notOneOf])
    }

    @Test func nodeListsTheCasesInDeclarationOrder() {
        guard case .enumeration(let name, let cases) = Schema.enumeration(Theme.self).node else { return fail("node") }
        #expect(name == "Theme")
        #expect(cases == ["light", "dark", "system"])
    }

    @Test func encodes() {
        #expect(Schema.enumeration(Theme.self).encode(.dark) == "dark")
    }
}

@Suite("Optionals")
struct OptionalSchemaTests {
    @Test func aValueDecodesThroughTheWrappedSchema() {
        #expect(decode(.optional(.int()), "5").value == .some(5))
        #expect(decode(.optional(.int(.range(1...9))), "50").issues.map(\.code) == [.outOfRange])
    }

    @Test func nullIsAMismatchUnlessNullable() {
        let strict = Schema<Int?>.optional(.int())
        #expect(decode(strict, "null").issues.map(\.code) == [.typeMismatch])
        let nullable = Schema<Int?>.optional(.int(), nullable: true)
        let result = decode(nullable, "null")
        #expect(result.issues.isEmpty)
        #expect(result.value == .some(nil))
    }

    @Test func encodingNilIsAbsenceUnlessNullable() {
        let strict = Schema<Int?>.optional(.int())
        var state = EncodeState(style: .full)
        #expect(strict.encoder(nil, &state) == nil)
        #expect(strict.encode(nil) == .null)  // nothing to leave out at the root
        #expect(strict.encode(5) == 5)
        let nullable = Schema<Int?>.optional(.int(), nullable: true)
        #expect(nullable.encode(nil) == .null)
    }

    @Test func absenceIsAValue() {
        #expect(Schema<Int?>.optional(.int()).absent() == .some(nil))
        #expect(Schema.int().absent() == nil)
    }

    @Test func nodeRecordsNullability() {
        guard case .optional(_, let nullable) = Schema<Int?>.optional(.int(), nullable: true).node else {
            return fail("node")
        }
        #expect(nullable)
    }
}

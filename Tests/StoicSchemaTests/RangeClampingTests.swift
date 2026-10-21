import StoicJSON
import StoicSchemaTesting
import StoicTesting
import Testing

@testable import StoicSchema

/// Numbers a person types, some of which are repaired to a bound.
struct Feel: Sendable, Equatable {
    var speed = 1000.0
    var steps = 5
    var plain = 10.0
    var floor = 1.0
    var key = 50.0
    var either = 3.0

    static let schema = Schema.object(Feel.self, default: Feel()) {
        Field("speed", \.speed, .double(.range(200...4000)).clampingToRange(), doc: "Pixels per second.", unit: "px/s")
        Field("steps", \.steps, .int(.range(1...10)).clampingToRange(), doc: "How many steps.")
        Field("plain", \.plain, .double(.range(0...100)), doc: "Not clamped.")
        Field("floor", \.floor, .double(.range(...100), .greaterThan(0)).clampingToRange(), doc: "Above zero, at most 100.")
        Field("key", \.key, .double(.range(0...100)).clampingToRange(), doc: "A secret.", secret: true)
        Field("either", \.either, .double(.range(0...10), .range(2...5)).clampingToRange(), doc: "Two ranges.")
    }
}

@Suite("Clamping out-of-range numbers")
struct RangeClampingSchemaTests {
    @Test(.failureMode("design/06", "a number outside a clamped range is read"))
    func aNumberPastABoundBecomesTheBoundWithAWarning() {
        let decoded = Feel.schema.decode(["speed": 99999, "steps": 0])
        #expect(decoded.value?.speed == 4000)
        #expect(decoded.value?.steps == 1)
        #expect(decoded.errors.isEmpty)
        #expect(decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
            "warning $.speed out_of_range", "warning $.steps out_of_range",
        ])
        let speed = decoded.issues[0]
        #expect(speed.message == "99999 is out of range, expected a number between 200 and 4000; clamped to 4000")
        #expect(speed.parameters["clampedTo"]?.number?.lexeme == "4000")
        #expect(speed.actual == "99999")
        #expect(Feel.schema.decode(["speed": 3]).value?.speed == 200)
    }

    @Test func aNumberInsideTheRangeIsNotTouched() {
        let decoded = Feel.schema.decode(["speed": 4000, "steps": 10])
        #expect(decoded.value?.speed == 4000)
        #expect(decoded.issues.isEmpty)
    }

    @Test func itIsAWarningWhateverTheMode() {
        for options in [DecodeOptions.strict, .lenient] {
            let decoded = Feel.schema.decode(["speed": 1], options: options)
            #expect(decoded.value?.speed == 200)
            #expect(decoded.warnings.map(\.code) == [.outOfRange])
            #expect(decoded.repairs.isEmpty)
        }
    }

    @Test func aFieldThatDoesNotAskStillRefuses() {
        let decoded = Feel.schema.decode(["plain": 500])
        #expect(decoded.value == nil)
        #expect(decoded.errors.map(\.code) == [.outOfRange])
        let lenient = Feel.schema.decode(["plain": 500], options: .lenient)
        #expect(lenient.value?.plain == 10)
        #expect(lenient.repairs.map(\.code) == [.outOfRange])
    }

    @Test func aNumberThatIsNotANumberIsStillATypeMismatch() {
        let decoded = Feel.schema.decode(["speed": "fast"])
        #expect(decoded.errors.map(\.code) == [.typeMismatch])
    }

    @Test func anExclusiveBoundIsNotClampedTo() {
        #expect(Feel.schema.decode(["floor": 500]).value?.floor == 100)
        let below = Feel.schema.decode(["floor": -3])
        #expect(below.value == nil)
        #expect(below.errors.map(\.code) == [.outOfRange])
    }

    @Test func severalRangesAreAllRespected() {
        #expect(Feel.schema.decode(["either": 9]).value?.either == 5)
        #expect(Feel.schema.decode(["either": -9]).value?.either == 2)
    }

    @Test func aSecretIsNotEchoed() {
        let decoded = Feel.schema.decode(["key": 4242])
        #expect(decoded.value?.key == 100)
        #expect(decoded.issues.first?.actual == nil)
    }

    @Test func theDigitsSentDecideNotADouble() {
        // Past an integer type's own bound, with a range to clamp to.
        let huge = Schema<Int>.int(.range(1...10)).clampingToRange()
        #expect(huge.decode(.number(JSONNumber(lexeme: "99999999999999999999") ?? JSONNumber(0))).value == 10)
        let fraction = Schema<Double>.double(.range(0...1)).clampingToRange()
        #expect(fraction.decode(.number(JSONNumber(lexeme: "1.0000000000000000001") ?? JSONNumber(0))).value == 1)
    }

    @Test func itWorksInsideAnArrayAndAnOptional() {
        let list = Schema<[Int]>.array(of: .int(.range(0...9)).clampingToRange())
        let decoded = list.decode([1, 50, -4])
        #expect(decoded.value == [1, 9, 0])
        #expect(decoded.issues.map { "\($0.path)" } == ["$[1]", "$[2]"])
        let optional = Schema<Int?>.optional(.int(.range(0...9)).clampingToRange())
        #expect(optional.decode(77).value == .some(9))
    }

    @Test func positionsPointAtTheNumber() {
        let text = "{\n  \"speed\": 99999\n}"
        let decoded = Feel.schema.decodeReporting(text, options: .lenient)
        #expect(decoded.issues.first?.source?.start.line == 2)
        #expect(decoded.issues.first?.source?.start.column == 12)
    }

    @Test func theExportKeepsTheBoundsAndSaysItClamps() throws {
        let schema = Feel.schema.jsonSchema()
        let speed = try #require(schema.object?["properties"]?.object?["speed"]?.object)
        #expect(speed["minimum"]?.number?.lexeme == "200")
        #expect(speed["maximum"]?.number?.lexeme == "4000")
        #expect(speed["x-stoic-clamp"]?.bool == true)
        #expect(speed["x-stoic-transform"] == nil)
    }

    @Test func theSuiteIsCleanAndNeedsNoExamples() {
        let report = SchemaSuite(Feel.schema, equating: { $0 == $1 }).report(seed: 2, cases: 120)
        #expect(report.isClean, "\(report)")
        #expect(!report.warnings.contains { $0.message.contains("declares no examples") })
    }

    @Test func aGeneratedMutationPastABoundIsExpectedToWarn() throws {
        let generator = SchemaGenerator(Feel.schema)
        let sample = try generator.sample(seed: 4)
        let past = generator.mutations(of: sample.document, seed: 4).filter {
            $0.kind == .aboveUpperBound || $0.kind == .belowLowerBound
        }
        #expect(!past.isEmpty)
        for mutation in past where mutation.isTolerated {
            #expect(mutation.expected.allSatisfy { $0.severity == .warning && $0.code == .outOfRange })
        }
        #expect(past.contains { $0.isTolerated })
    }

    @Test(.failureMode("design/06", "a non-integer falls outside a clamped integer range"))
    func aNonIntegerIsRefusedOnEitherSideOfAClampedIntegerRange() {
        let steps = Schema<Int>.int(.range(0...10)).clampingToRange()
        for options in [DecodeOptions.strict, .lenient] {
            let inside = steps.decodeReporting("5.5", options: options)
            let outside = steps.decodeReporting("10.9", options: options)
            #expect(inside.value == nil)
            #expect(outside.value == nil)
            #expect(inside.errors.map(\.code) == [.typeMismatch])
            #expect(outside.errors.map(\.code) == [.typeMismatch])
            #expect(inside.issues[0].message == "expected an integer, found number 5.5")
            #expect(outside.issues[0].message == "expected an integer, found number 10.9")
            #expect(outside.issues[0].suggestions.isEmpty)
        }

        // The same split for a whole number written with a fraction. Strict
        // refuses both; the bound is not substituted for 6.0.
        let narrow = Schema<Int>.int(.range(0...5)).clampingToRange()
        let four = narrow.decodeReporting("4.0")
        let six = narrow.decodeReporting("6.0")
        #expect(four.value == nil)
        #expect(six.value == nil)
        #expect(four.errors.map(\.code) == [.typeMismatch])
        #expect(six.errors.map(\.code) == [.typeMismatch])
        #expect(four.issues[0].suggestions == ["4"])
        #expect(six.issues[0].suggestions == ["6"])
        #expect(narrow.decodeReporting("1e2").value == nil)
        #expect(narrow.decodeReporting("1e2").issues[0].suggestions == ["100"])

        // Lenient accepts the spelling, so a value outside the range is
        // clamped, and the spelling warning an in-range 4.0 gets is kept.
        let lenientInside = narrow.decodeReporting("4.0", options: .lenient)
        #expect(lenientInside.value == 4)
        #expect(lenientInside.issues.map { "\($0.severity) \($0.code)" } == ["warning type_mismatch"])
        #expect(lenientInside.issues[0].actual == "4.0")
        let lenientOutside = narrow.decodeReporting("6.0", options: .lenient)
        #expect(lenientOutside.value == 5)
        #expect(lenientOutside.issues.map { "\($0.severity) \($0.code)" } == [
            "warning type_mismatch", "warning out_of_range",
        ])
        #expect(lenientOutside.issues[0].actual == "6.0")
        #expect(lenientOutside.issues[1].parameters["clampedTo"]?.number?.lexeme == "5")
        let exponent = narrow.decodeReporting("1e2", options: .lenient)
        #expect(exponent.value == 5)
        #expect(exponent.issues.map(\.code) == [.typeMismatch, .outOfRange])

        // Too wide for the type is still clamped when the spelling is one
        // the mode accepts, and not when strict refuses the spelling.
        #expect(steps.decodeReporting("1e30").value == nil)
        #expect(steps.decodeReporting("1e30").errors.map(\.code) == [.typeMismatch])
        let wide = steps.decodeReporting("1e30", options: .lenient)
        #expect(wide.value == 10)
        #expect(wide.issues.map { "\($0.severity) \($0.code)" } == ["warning out_of_range"])

        // documented() keeps the integer decoder and wraps the node. The
        // spelling check has to see through that wrapper.
        let documented = Schema<Int>.int(.range(0...10)).documented("How many.").clampingToRange()
        #expect(documented.decodeReporting("10.9").errors.map(\.code) == [.typeMismatch])
        #expect(documented.decodeReporting("5.5").errors.map(\.code) == [.typeMismatch])
        #expect(documented.decodeReporting("11").value == 10)

        // A fraction of a Double is a number the schema accepts.
        let fraction = Schema<Double>.double(.range(0...1)).clampingToRange()
        #expect(fraction.decodeReporting("0.5").value == 0.5)
        #expect(fraction.decodeReporting("0.5").issues.isEmpty)
        let past = fraction.decodeReporting("1.9")
        #expect(past.value == 1)
        #expect(past.warnings.map(\.code) == [.outOfRange])
    }

    @Test func aNonIntegerInASettingsFieldIsRefusedInsideAndOutsideTheRange() {
        let inside = Feel.schema.decodeReporting(#"{"steps": 5.5}"#)
        let outside = Feel.schema.decodeReporting(#"{"steps": 10.9}"#)
        #expect(inside.value == nil)
        #expect(outside.value == nil)
        #expect(inside.errors.map { "\($0.path) \($0.code)" } == ["$.steps type_mismatch"])
        #expect(outside.errors.map { "\($0.path) \($0.code)" } == ["$.steps type_mismatch"])

        // Lenient settings repair a refused field to its default. 10.9 must
        // not become 10 while 5.5 becomes the default.
        let lenientInside = Feel.schema.decodeReporting(#"{"steps": 5.5}"#, options: .lenient)
        let lenientOutside = Feel.schema.decodeReporting(#"{"steps": 10.9}"#, options: .lenient)
        #expect(lenientInside.value?.steps == 5)
        #expect(lenientOutside.value?.steps == 5)
        #expect(lenientInside.repairs.map { "\($0.path) \($0.code)" } == ["$.steps type_mismatch"])
        #expect(lenientOutside.repairs.map { "\($0.path) \($0.code)" } == ["$.steps type_mismatch"])

        // An integer past the bound is still the bound, not the default.
        let clamped = Feel.schema.decodeReporting(#"{"steps": 40}"#, options: .lenient)
        #expect(clamped.value?.steps == 10)
        #expect(clamped.warnings.map(\.code) == [.outOfRange])
    }

    @Test func aNarrowIntegerClampsOnlyASpellingItAccepts() {
        let byte = Schema<UInt8>.integer(UInt8.self, [.range(0...10)]).clampingToRange()
        #expect(byte.decodeReporting("11.5").value == nil)
        #expect(byte.decodeReporting("11.5", options: .lenient).errors.map(\.code) == [.typeMismatch])
        #expect(byte.decodeReporting("11.0").errors.map(\.code) == [.typeMismatch])

        let eleven = byte.decodeReporting("11.0", options: .lenient)
        #expect(eleven.value == 10)
        #expect(eleven.issues.map(\.code) == [.typeMismatch, .outOfRange])

        // 300 does not fit a UInt8, so there is no spelling warning: the
        // width refusal is what the bound replaces.
        let threeHundred = byte.decodeReporting("300.0", options: .lenient)
        #expect(threeHundred.value == 10)
        #expect(threeHundred.issues.map { "\($0.severity) \($0.code)" } == ["warning out_of_range"])
        #expect(byte.decodeReporting("300").value == 10)
    }

    @Test func aFractionPastAnIntegerBoundStaysATypeMismatchForTheGenerator() throws {
        let schema = Schema<Int>.int(.range(5...10)).clampingToRange()
        let sample = try schema.generator.sample(seed: 1)
        let mutations = schema.generator.mutations(of: sample.document, seed: 1)
        let fraction = try #require(mutations.first { $0.kind == .wrongType })
        #expect(fraction.expected.allSatisfy { $0.code == .typeMismatch && $0.severity == .error })
        #expect(!fraction.isTolerated)
        let decoded = schema.decode(fraction.document)
        #expect(decoded.value == nil)
        #expect(decoded.errors.map(\.code) == [.typeMismatch])

        let above = try #require(mutations.first { $0.kind == .aboveUpperBound })
        #expect(above.isTolerated)
        #expect(above.expected.allSatisfy { $0.code == .outOfRange && $0.severity == .warning })
    }
}

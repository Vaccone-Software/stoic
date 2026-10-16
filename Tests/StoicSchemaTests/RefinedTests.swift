import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

typealias Port = Refined<IntRange<1, 65_535>>
typealias Percent = Refined<IntRange<0, 100>>

enum ScrollSpeedRule: Refinement {
    typealias Base = Double
    static var constraints: [Constraint] { [.range(0.1...10), .finite] }
}
typealias ScrollSpeed = Refined<ScrollSpeedRule>

enum Animal: Sendable, Equatable {
    case cat
    case other(String)
}

/// A refinement over an open enumeration, whose unknown case reads back with
/// a warning.
enum OpenAnimalRule: Refinement {
    typealias Base = Animal
    static var constraints: [Constraint] { [] }
    static var baseSchema: Schema<Animal> {
        .openEnumeration(
            Animal.self, cases: ["cat"], read: { $0 == "cat" ? .cat : .other($0) },
            write: { if case .other(let name) = $0 { name } else { "cat" } })
    }
}

enum PositiveRule: Refinement {
    typealias Base = Double
    static var constraints: [Constraint] { [.greaterThan(0), .lessThan(1)] }
}

enum UsernameRule: Refinement {
    typealias Base = String
    static var constraints: [Constraint] { [.length(3...16), .pattern("^[a-z][a-z0-9_]*$")] }
}

enum StepRule: Refinement {
    typealias Base = Int
    static var constraints: [Constraint] { [.range(0...100), .multipleOf(10)] }
}

enum EvenRule: Refinement {
    typealias Base = Int
    static var constraints: [Constraint] {
        [.custom(id: "even", description: "an even number") { $0.number?.int64.map { $0 % 2 == 0 } ?? false }]
    }
}

/// A refinement over a base that is not `Schematic`: it supplies the schema.
struct Celsius: Sendable, Equatable {
    var degrees: Double
}

enum BodyTemperature: Refinement {
    typealias Base = Celsius
    static var constraints: [Constraint] { [.range(30...45)] }
    static var baseSchema: Schema<Celsius> {
        Schema<Celsius>(
            node: .number(constraints: []),
            decoder: { json, state in
                guard let degrees = Schema<Double>.double().decoder(json, &state) else { return nil }
                return Celsius(degrees: degrees)
            },
            encoder: { value, state in Schema<Double>.double().encoder(value.degrees, &state) })
    }
}

@Suite("Refined")
struct RefinedTests {
    @Test func admitsWhatSatisfiesTheConstraints() throws {
        #expect(try Port(8080).value == 8080)
        #expect(try Port(1).value == 1)
        #expect(try Port(65_535).value == 65_535)
        #expect(try ScrollSpeed(0.1).value == 0.1)
        #expect(try ScrollSpeed(10).value == 10)
    }

    @Test func refusesWhatDoesNot() {
        do throws(ValidationFailure) {
            _ = try Port(0)
            fail("expected a failure")
        } catch {
            #expect(error.issues.locations == ["$ out_of_range"])
            #expect(error.description == "$: 0 is out of range, expected a number between 1 and 65535")
        }
        #expect(throws: ValidationFailure.self) { try Port(65_536) }
        #expect(throws: ValidationFailure.self) { try Port(-1) }
    }

    @Test func throwsTheTypedFailureWithEveryViolation() {
        do throws(ValidationFailure) {
            _ = try Refined<StepRule>(155)
            fail("expected a failure")
        } catch {
            #expect(error.issues.map(\.code) == [.outOfRange, .notMultiple])
        }
    }

    @Test func nanAndInfinityAreNotFinite() {
        for bad in [Double.nan, .infinity, -.infinity] {
            do throws(ValidationFailure) {
                _ = try ScrollSpeed(bad)
                fail("expected a failure for \(bad)")
            } catch {
                #expect(error.issues.map(\.code) == [.notFinite])
            }
        }
    }

    @Test func stringsUseLengthAndPattern() throws {
        #expect(try Refined<UsernameRule>("alice_9").value == "alice_9")
        #expect(throws: ValidationFailure.self) { try Refined<UsernameRule>("al") }
        #expect(throws: ValidationFailure.self) { try Refined<UsernameRule>("9alice") }
        #expect(throws: ValidationFailure.self) { try Refined<UsernameRule>("Alice") }
    }

    @Test func customConstraintsAreHonoured() throws {
        #expect(try Refined<EvenRule>(4).value == 4)
        #expect(throws: ValidationFailure.self) { try Refined<EvenRule>(5) }
    }

    @Test func exclusiveBounds() throws {
        #expect(try Refined<PositiveRule>(0.5).value == 0.5)
        #expect(throws: ValidationFailure.self) { try Refined<PositiveRule>(0) }
        #expect(throws: ValidationFailure.self) { try Refined<PositiveRule>(1) }
    }

    @Test func equatableComparableAndPrintable() throws {
        #expect(try Port(80) == Port(80))
        #expect(try Port(80) != Port(81))
        #expect(try Port(80) < Port(443))
        #expect(try [Port(443), Port(80)].sorted().map(\.value) == [80, 443])
        #expect(try Port(80).description == "80")
        #expect(Set([try Port(80), try Port(80), try Port(81)]).count == 2)
    }

    @Test func differentRefinementsAreDifferentTypes() {
        // `Percent` and `Port` share a base and nothing else; this would not
        // compile if one could stand in for the other.
        func takesPort(_: Port) {}
        takesPort(Port(clamping: 3))
        #expect(IntRange<1, 2>.self != IntRange<1, 3>.self)
    }
}

@Suite("Clamping")
struct ClampingTests {
    @Test func integersClampToTheirBounds() {
        #expect(Port(clamping: 0).value == 1)
        #expect(Port(clamping: 70_000).value == 65_535)
        #expect(Port(clamping: 8080).value == 8080)
        #expect(Percent(clamping: -5).value == 0)
        #expect(Percent(clamping: Int.max).value == 100)
        #expect(Percent(clamping: Int.min).value == 0)
    }

    @Test func doublesClampToTheirBounds() {
        #expect(ScrollSpeed(clamping: 0).value == 0.1)
        #expect(ScrollSpeed(clamping: 99).value == 10)
        #expect(ScrollSpeed(clamping: 2.5).value == 2.5)
        #expect(ScrollSpeed(clamping: .infinity).value == 10)
        #expect(ScrollSpeed(clamping: -.infinity).value == 0.1)
        #expect(ScrollSpeed(clamping: .nan).value == 0.1)
    }

    @Test func exclusiveBoundsClampToTheNearestAdmittedValue() {
        let low = Refined<PositiveRule>(clamping: -3).value
        #expect(low > 0)
        #expect(low == Double(0).nextUp)
        let high = Refined<PositiveRule>(clamping: 7).value
        #expect(high < 1)
        #expect(high == Double(1).nextDown)
    }

    @Test func clampedValuesAreAlwaysValid() throws {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let raw = Int.random(in: Int.min...Int.max, using: &generator)
            #expect(try Port(Port(clamping: raw).value) == Port(clamping: raw))
        }
    }

    @Test func fractionalAndExclusiveIntegerBoundsRoundInward() {
        enum Fractional: Refinement {
            typealias Base = Int
            static var constraints: [Constraint] { [.range(0.5...9.5)] }
        }
        #expect(Refined<Fractional>(clamping: -4).value == 1)
        #expect(Refined<Fractional>(clamping: 40).value == 9)
        enum Exclusive: Refinement {
            typealias Base = Int
            static var constraints: [Constraint] { [.greaterThan(0), .lessThan(10)] }
        }
        #expect(Refined<Exclusive>(clamping: 0).value == 1)
        #expect(Refined<Exclusive>(clamping: 10).value == 9)
    }
}

@Suite("Refined schema")
struct RefinedSchemaTests {
    @Test func decodesThroughTheBaseAndTheConstraints() {
        let schema = Schema<Port>.refined(IntRange<1, 65_535>.self)
        #expect(schema.decodeReporting("8080").value?.value == 8080)
        #expect(schema.decodeReporting("0").issues.locations == ["$ out_of_range"])
        #expect(schema.decodeReporting("\"80\"").issues.locations == ["$ type_mismatch"])
        #expect(schema.decodeReporting("80.5").issues.locations == ["$ type_mismatch"])
    }

    @Test func theSchematicConformanceGivesAnArraySchema() {
        let schema = [Port].schema
        let result = schema.decodeReporting("[80, 0, 443, 70000]")
        #expect(result.issues.locations == ["$[1] out_of_range", "$[3] out_of_range"])
        #expect(result.issues[0].expected == "a number between 1 and 65535")
    }

    @Test func theNodeCarriesTheRefinementsConstraints() {
        guard case .integer(let type, let constraints) = Port.schema.node else { return fail("node") }
        #expect(type == .int)
        #expect(constraints == [.range(1...65_535)])
        guard case .number(let doubleConstraints) = ScrollSpeed.schema.node else { return fail("node") }
        #expect(doubleConstraints == [.range(0.1...10), .finite])
    }

    @Test func encodesAsTheBase() throws {
        #expect(Port.schema.encode(try Port(8080)) == 8080)
        #expect(ScrollSpeed.schema.encode(try ScrollSpeed(2.5)) == 2.5)
    }

    @Test func roundTrips() throws {
        let port = try Port(8080)
        #expect(Port.schema.decodeReporting(Port.schema.encode(port).encodedString()).value == port)
    }

    @Test func aBaseThatIsNotSchematicSuppliesItsOwnSchema() throws {
        let schema = Refined<BodyTemperature>.schema
        #expect(schema.decodeReporting("36.6").value?.value == Celsius(degrees: 36.6))
        #expect(schema.decodeReporting("20").issues.locations == ["$ out_of_range"])
        #expect(try Refined<BodyTemperature>(Celsius(degrees: 37)).value.degrees == 37)
        #expect(throws: ValidationFailure.self) { try Refined<BodyTemperature>(Celsius(degrees: 50)) }
    }

    @Test func aPrecisionLossInTheBaseIsStillReported() {
        let result = ScrollSpeed.schema.decodeReporting("9007199254740993")
        #expect(result.issues.map(\.code) == [.precisionLoss])
    }

    @Test(.failureMode("design/06", "a number rounds, as a `Double`, across one of its constraints"))
    func aRefinedIsNeverDecodedHoldingAValueItsInitialiserRefuses() throws {
        // Below 1 as written; 1.0 as a Double, which `.lessThan(1)` refuses.
        let result = Refined<PositiveRule>.schema.decodeReporting("0.99999999999999999999")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.precisionLoss])
        #expect(throws: ValidationFailure.self) { try Refined<PositiveRule>(1) }
        // Whatever does decode, the initialiser accepts.
        for text in ["0.5", "0.9999999999999999", "0.00000000000000000001", "1e-320", "0.30000000000000000001"] {
            let decoded = try #require(Refined<PositiveRule>.schema.decodeReporting(text).value, "\(text)")
            #expect(try Refined<PositiveRule>(decoded.value) == decoded, "\(text)")
        }
    }

    @Test func aWarningFromTheBaseDoesNotRefuseAValue() throws {
        // An open enumeration reads an unknown case with a warning, and its
        // encoding back reads the same way; the value is still valid.
        let refined = try Refined<OpenAnimalRule>(.other("zebra"))
        #expect(refined.value == .other("zebra"))
    }

    @Test func refinedStringsReportAtTheirPath() {
        let schema = Schema.array(of: Refined<UsernameRule>.schema)
        let result = schema.decodeReporting(#"["alice", "A", "bob", "9x9"]"#)
        #expect(result.issues.locations == ["$[1] too_short", "$[3] pattern_mismatch"])
    }
}

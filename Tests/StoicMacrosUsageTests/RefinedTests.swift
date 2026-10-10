#if STOIC_MACROS
import StoicJSON
import StoicMacros
import StoicSchema
import StoicSchemaTesting
import Testing

@Refined(Double.self, .range(0.1...10), .finite)
enum ScrollSpeedRule {}
typealias ScrollSpeed = Refined<ScrollSpeedRule>

@Refined(String.self, .length(1...32), .pattern("^[a-z][a-z0-9-]*$"))
struct SlugRule {}

@Refined([Int].self, .count(1...3), .unique)
enum TriadRule {}

/// The same refinement by hand.
enum HandScrollSpeedRule: Refinement {
    typealias Base = Double
    static var constraints: [Constraint] { [.range(0.1...10), .finite] }
}

@Schema
struct Scroll: Equatable {
    var speed: ScrollSpeed = ScrollSpeed(clamping: 1)
    var slug: Refined<SlugRule> = Scroll.home
    private static let home: Refined<SlugRule> = {
        do { return try Refined<SlugRule>("home") } catch { preconditionFailure("\(error)") }
    }()
}

@Suite("@Refined")
struct RefinedMacroTests {
    @Test func theRefinementIsTheOneAHumanWritesByHand() {
        #expect(ScrollSpeedRule.constraints == HandScrollSpeedRule.constraints)
        #expect(String(describing: ScrollSpeed.schema.node) == String(describing: Refined<HandScrollSpeedRule>.schema.node))
        #expect(ScrollSpeed.schema.jsonSchema() == Refined<HandScrollSpeedRule>.schema.jsonSchema())
    }

    @Test func aCheckedValueCannotBeBuiltUnchecked() throws {
        #expect(throws: ValidationFailure.self) { try ScrollSpeed(20) }
        #expect(try ScrollSpeed(2).value == 2)
        #expect(ScrollSpeed(clamping: 20).value == 10)
        #expect(throws: ValidationFailure.self) { try Refined<SlugRule>("Not A Slug") }
        #expect(throws: ValidationFailure.self) { try Refined<TriadRule>([1, 1]) }
    }

    @Test func schemasOfRefinedTypesPassTheirSuites() {
        #expect(expectSchemaSuite(ScrollSpeed.schema, seed: 1, cases: 60).isClean)
        #expect(expectSchemaSuite(Refined<SlugRule>.schema, seed: 2, cases: 60).isClean)
        #expect(expectSchemaSuite(Refined<TriadRule>.schema, seed: 3, cases: 60).isClean)
    }

    @Test func aSchemaMayHoldARefinedField() {
        #expect(Scroll.schema.decode(["speed": 11]).errors.count == 1)
        #expect(Scroll.schema.decode(["slug": "ok-1"]).value?.slug.value == "ok-1")
        #expect(expectSchemaSuite(Scroll.schema, seed: 5, cases: 60).isClean)
    }
}
#endif

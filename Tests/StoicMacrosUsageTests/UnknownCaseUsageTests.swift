#if STOIC_MACROS
import StoicJSON
import StoicMacros
import StoicSchema
import StoicSchemaTesting
import Testing

/// A status a server may extend.
@Schema
enum Standing: String, Equatable {
    case good, late
    @Key("ignored") case other
    @UnknownCase case unknown
}

extension Standing {
    static let byHand: Schema<Standing> = .enumeration(Standing.self, unknownCase: .unknown)
}

@Schema
enum Rank: Int, Equatable {
    case first = 1, second = 2
    @UnknownCase case unranked = 0
}

extension Rank {
    static let byHand: Schema<Rank> = .enumeration(Rank.self, unknownCase: .unranked)
}

/// A plan that keeps what it did not understand.
@Schema
enum Plan: Equatable {
    case free
    @Key("pro_plan") case pro
    @UnknownCase case other(String)
}

extension Plan {
    static let byHand: Schema<Plan> = .openEnumeration(
        Plan.self, cases: ["free", "pro_plan"], fallback: "other",
        read: { raw in
            switch raw {
            case "free": .free
            case "pro_plan": .pro
            default: .other(raw)
            }
        },
        write: { plan in
            switch plan {
            case .free: "free"
            case .pro: "pro_plan"
            case .other(let raw): raw
            }
        })
}

/// A plain case, on an enumeration with no raw type.
@Schema
enum Mood: Equatable {
    case calm, stormy
    @UnknownCase case unclear
}

@Schema
struct Member: Equatable {
    /// The id.
    var id: Int
    /// Where they stand.
    var standing: Standing = .good
    /// Their plan.
    var plan: Plan = .free
}

@Suite("@Schema: unknown cases")
struct UnknownCaseUsageTests {
    @Test func theyAreTheSchemasWrittenByHand() {
        expectEquivalent(Standing.schema, Standing.byHand)
        expectEquivalent(Rank.schema, Rank.byHand)
        expectEquivalent(Plan.schema, Plan.byHand)
    }

    @Test func anUnknownValueIsReadAsTheUnknownCase() {
        let decoded = Standing.schema.decode(JSONValue.string("banned"))
        #expect(decoded.value == .unknown)
        #expect(decoded.issues.map(\.code) == [.unknownCase])
        #expect(decoded.warnings.count == 1)
        #expect(Rank.schema.decode(7).value == .unranked)
    }

    @Test func theCaseThatCarriesTheValueKeepsIt() {
        let decoded = Plan.schema.decode(JSONValue.string("enterprise"))
        #expect(decoded.value == .other("enterprise"))
        #expect(Plan.schema.encode(.other("enterprise")) == "enterprise")
        #expect(Plan.schema.encode(.pro) == "pro_plan")
        #expect(Plan.schema.decode(JSONValue.string("pro_plan")).issues.isEmpty)
    }

    @Test func aPlainCaseWithoutARawTypeWorksToo() {
        #expect(Mood.schema.decode(JSONValue.string("furious")).value == .unclear)
        #expect(Mood.schema.encode(.stormy) == "stormy")
    }

    @Test func aModelAcceptsTheNewerServer() {
        let decoded = Member.schema.decode(["id": 3, "standing": "banned", "plan": "gold"])
        #expect(decoded.value == Member(id: 3, standing: .unknown, plan: .other("gold")))
        #expect(decoded.errors.isEmpty)
        #expect(decoded.warnings.map(\.path.description).sorted() == ["$.plan", "$.standing"])
    }

    @Test func theSuitesAreClean() {
        for report in [
            SchemaSuite(Member.schema).report(seed: 2, cases: 100), SchemaSuite(Plan.schema).report(seed: 2, cases: 40),
            SchemaSuite(Standing.schema).report(seed: 2, cases: 40),
        ] {
            #expect(report.isClean, "\(report)")
        }
    }
}
#endif

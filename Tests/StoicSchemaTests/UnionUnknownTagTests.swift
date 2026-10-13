import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// A union that keeps everything it did not understand.
enum Reading: Sendable, Equatable {
    case celsius(Double)
    case label(String)
    case none
    case unknown(tag: String, payload: JSONObject)

    static let schema: Schema<Reading> = .union(
        discriminator: "type",
        unknown: .keepingPayload(Reading.unknown) { if case .unknown(let tag, let payload) = $0 { (tag, payload) } else { nil } }
    ) {
        Case("celsius", .double(), Reading.celsius) { if case .celsius(let t) = $0 { t } else { nil } }
        Case("label", .string(.length(1...20)), Reading.label) { if case .label(let t) = $0 { t } else { nil } }
        Case("none", Reading.none) { if case .none = $0 { true } else { false } }
    }
}

/// The same with a plain unknown case.
enum Gear: Sendable, Equatable {
    case fast(Circle)
    case slow
    case unclear

    static let schema: Schema<Gear> = .union(
        unknown: .plain(Gear.unclear, name: "unclear") { if case .unclear = $0 { true } else { false } }
    ) {
        Case("fast", Circle.schema, Gear.fast) { if case .fast(let c) = $0 { c } else { nil } }
        Case("slow", Gear.slow) { if case .slow = $0 { true } else { false } }
    }
}

/// And one that keeps the tag only.
enum Kind: Sendable, Equatable {
    case a(Int)
    case other(String)

    static let schema: Schema<Kind> = .union(
        unknown: .keepingTag(name: "other", Kind.other) { if case .other(let tag) = $0 { tag } else { nil } }
    ) {
        Case("a", .int(), Kind.a) { if case .a(let n) = $0 { n } else { nil } }
    }
}

/// An unknown case in a field, a list and a nested union.
struct SensorFeed: Sendable, Equatable {
    var readings: [Reading] = []
    var latest: Reading = .none

    static let schema = Schema.object(SensorFeed.self, default: SensorFeed()) {
        Field("readings", \.readings, .array(of: Reading.schema), doc: "In order.")
        Field("latest", \.latest, Reading.schema, doc: "The newest.")
    }
}

@Suite("Tagged unions: an unknown case")
struct UnionUnknownTagTests {
    // Row: a tagged union with an unknown case meets a tag it does not know.
    @Test(.failureMode("design/06", "a tagged union with an unknown case meets a tag it does not know"))
    func anUnknownTagIsReadAsTheUnknownCaseWithAWarning() {
        let decoded = Reading.schema.decode(["type": "kelvin", "degrees": 3.5, "source": "probe"])
        #expect(decoded.value == .unknown(tag: "kelvin", payload: ["degrees": 3.5, "source": "probe"]))
        #expect(decoded.errors.isEmpty)
        #expect(decoded.issues.count == 1)
        let issue = decoded.issues[0]
        #expect(issue.code == .unknownCase)
        #expect(issue.severity == .warning)
        #expect(issue.path.description == "$.type")
        #expect(issue.parameters["fallback"]?.string == "unknown")
        #expect(issue.actual == #""kelvin""#)
        #expect(issue.message.contains("read as `unknown`"))
        #expect(issue.expected == #"one of "celsius", "label", "none", or any other string"#)
    }

    @Test func theNearestKnownTagIsSuggested() {
        let issue = Reading.schema.decode(["type": "celsuis"]).issues[0]
        #expect(issue.suggestions == ["celsius"])
        #expect(Reading.schema.decode(["type": "kelvin"]).issues[0].suggestions.isEmpty)
    }

    @Test func theRawTagAndPayloadComeBackOutWhenTheValueIsEncoded() {
        let document: JSONValue = ["type": "kelvin", "degrees": 3.5, "nested": ["a": [1, 2, 3], "b": nil]]
        let decoded = Reading.schema.decode(document)
        let value = try! #require(decoded.value)
        #expect(Reading.schema.encode(value) == document, "as it went in")
    }

    @Test func theDiscriminatorIsWrittenFirstWhereverItWas() {
        let decoded = Reading.schema.decode(["degrees": 3.5, "type": "kelvin"])
        let written = Reading.schema.encode(decoded.value!)
        #expect(written.object?.map(\.key) == ["type", "degrees"])
    }

    @Test func aKnownTagIsStillReadAsItsCase() {
        let decoded = Reading.schema.decode(["type": "celsius", "value": 20.5])
        #expect(decoded.value == .celsius(20.5))
        #expect(decoded.issues.isEmpty)
        #expect(Reading.schema.decode(["type": "none"]).value == Reading.none)
        #expect(Reading.schema.encode(.celsius(20.5)) == ["type": "celsius", "value": 20.5])
    }

    @Test func aKnownTagWithABadPayloadIsStillAnError() {
        let decoded = Reading.schema.decode(["type": "label", "value": ""])
        #expect(decoded.value == nil)
        #expect(decoded.errors.map(\.code) == [.tooShort])
        #expect(Reading.schema.decode(["type": "label"]).errors.map(\.code) == [.missingKey])
    }

    @Test func theOtherFailuresOfADiscriminatorAreErrorsStill() {
        #expect(Reading.schema.decode(["value": 1]).issues.locations == ["$.type missing_key"])
        #expect(Reading.schema.decode(["type": 5]).issues.locations == ["$.type type_mismatch"])
        #expect(Reading.schema.decode(JSONValue.string("celsius")).issues.map(\.code) == [.typeMismatch])
        #expect(Reading.schema.decode(["type": 5]).issues[0].expected?.hasSuffix("or any other string") == true)
    }

    @Test func tagsAreMatchedExactlyAsBefore() {
        // "Celsius" is not "celsius", so it is unknown now, not an error.
        #expect(Reading.schema.decode(["type": "Celsius"]).value == .unknown(tag: "Celsius", payload: [:]))
    }

    @Test func anUnknownTagWorksInsideAnObjectAndAList() {
        let decoded = SensorFeed.schema.decode([
            "readings": [["type": "celsius", "value": 1.5], ["type": "kelvin", "d": 3], ["type": "rankine"]],
            "latest": ["type": "newton", "n": 1],
        ])
        #expect(decoded.errors.isEmpty)
        #expect(decoded.value?.readings.count == 3)
        #expect(decoded.value?.latest == .unknown(tag: "newton", payload: ["n": 1]))
        #expect(decoded.warnings.map(\.path.description).sorted() == ["$.latest.type", "$.readings[1].type", "$.readings[2].type"])
    }

    @Test func aPlainUnknownCaseKeepsNothingAndIsWrittenUnderItsName() {
        let decoded = Gear.schema.decode(["type": "turbo", "power": 9])
        #expect(decoded.value == .unclear)
        #expect(decoded.issues.map(\.code) == [.unknownCase])
        #expect(decoded.issues[0].parameters["fallback"]?.string == "unclear")
        #expect(Gear.schema.encode(.unclear) == ["type": "unclear"])
        #expect(Gear.schema.encode(.fast(Circle())) == ["type": "fast", "radius": 1, "filled": false])
        #expect(Gear.schema.decode(["type": "slow"]).value == .slow)
    }

    @Test func aTagOnlyUnknownCaseDropsThePayload() {
        let decoded = Kind.schema.decode(["type": "b", "x": 1])
        #expect(decoded.value == .other("b"))
        #expect(Kind.schema.encode(.other("b")) == ["type": "b"])
        #expect(Kind.schema.encode(.a(3)) == ["type": "a", "value": 3])
    }

    @Test func aPayloadMemberNamedLikeTheDiscriminatorDoesNotShadowIt() {
        let written = Reading.schema.encode(.unknown(tag: "kelvin", payload: ["type": "sneaky", "d": 1]))
        #expect(written == ["type": "kelvin", "d": 1])
    }

    @Test func aClosedUnionIsUnchanged() {
        let decoded = Shape.schema.decode(["type": "hexagon"])
        #expect(decoded.value == nil)
        #expect(decoded.issues.map(\.code) == [.notOneOf])
        #expect(Shape.schema.jsonSchema().object?["oneOf"]?.array?.count == 4)
    }

    @Test func theExportAcceptsAnyOtherTagAsABranchThatExcludesTheKnownOnes() throws {
        let export = Reading.schema.jsonSchema()
        let branches = try #require(export.object?["oneOf"]?.array)
        #expect(branches.count == 4)
        let last = try #require(branches.last?.object)
        #expect(last["x-stoic-unknown-case"] == true)
        #expect(last["required"] == ["type"])
        let validator = JSONSchemaValidator(export)
        #expect(validator.accepts(["type": "kelvin", "anything": [1, 2]]))
        #expect(validator.accepts(["type": "celsius", "value": 1.5]))
        #expect(!validator.accepts(["type": "celsius", "value": "hot"]), "a known tag keeps its own payload's rules")
        #expect(!validator.accepts(["type": 5]))
        #expect(!validator.accepts(["value": 5]))
        #expect(!validator.accepts(5))
    }

    @Test func theSuitePassesWithUnknownTagsMutationsExpectingTheWarning() {
        for report in [
            SchemaSuite(Reading.schema).report(seed: 3, cases: 80), SchemaSuite(Gear.schema).report(seed: 3, cases: 60),
            SchemaSuite(Kind.schema).report(seed: 3, cases: 40), SchemaSuite(SensorFeed.schema).report(seed: 3, cases: 60),
        ] {
            #expect(report.isClean, "\(report)")
        }
    }

    @Test func theMutatorExpectsAWarningWhereTheUnionIsOpen() throws {
        let sample = try Reading.schema.generator.sample(seed: 4)
        let mutations = Reading.schema.generator.mutations(of: sample.document, seed: 4)
        let byKind = Dictionary(grouping: mutations, by: \.kind)
        for kind in [Mutation.Kind.badUnionTag, .typoUnionTag] {
            for mutation in byKind[kind] ?? [] {
                #expect(mutation.expected.allSatisfy { $0.code == .unknownCase && $0.severity == .warning }, "\(mutation.summary)")
            }
        }
        #expect(byKind[.badUnionTag]?.isEmpty == false)
        #expect(byKind[.missingDiscriminator]?.isEmpty == false)
    }
}

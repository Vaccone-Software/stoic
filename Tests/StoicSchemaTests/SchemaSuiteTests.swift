import StoicJSON
import StoicSchemaTesting
import Testing

@testable import StoicSchema

/// Every schema in the test target passes its own suite. This is the test the
/// library recommends to its users, applied to the library's fixtures.
@Suite("SchemaSuite on the fixtures")
struct FixtureSuiteTests {
    private func clean<V: Sendable>(
        _ schema: Schema<V>, cases: Int = 120, equating: (@Sendable (V, V) -> Bool)? = nil,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) {
        let report = SchemaSuite(schema, equating: equating).report(seed: 1, cases: cases)
        #expect(report.isClean, "\(report)", sourceLocation: sourceLocation)
    }

    @Test func settings() { clean(Settings.schema, equating: { $0 == $1 }) }
    @Test func network() { clean(Network.schema, equating: { $0 == $1 }) }
    @Test func recursiveMenu() { clean(Menu.schema, cases: 60, equating: { $0 == $1 }) }
    @Test func shapes() { clean(Shape.schema, equating: { $0 == $1 }) }
    @Test func canvas() { clean(Canvas.schema, equating: { $0 == $1 }) }
    @Test func recursiveExpressions() { clean(Expression.schema, cases: 60, equating: { $0 == $1 }) }
    @Test func rect() { clean(Rect.schema, equating: { $0 == $1 }) }
    @Test func versionedPrefs() { clean(Prefs.schema, equating: { $0 == $1 }) }
    @Test func preservingObject() { clean(Loose.schema, equating: { $0 == $1 }) }
    @Test func timestamps() { clean(Timestamp.schema, cases: 40, equating: { $0 == $1 }) }
    @Test func endpoints() { clean(Endpoint.schema, cases: 40, equating: { $0 == $1 }) }
    @Test func frequencies() { clean(Frequency.schema, cases: 40, equating: { $0 == $1 }) }
    @Test func integerEnumerations() { clean(Schema.enumeration(Priority.self), cases: 30, equating: { $0 == $1 }) }
    @Test func refinedTypes() { clean(Port.schema, cases: 60, equating: { $0 == $1 }) }
    @Test func collections() {
        clean(Schema<[Int]>.array(of: .int(.range(0...50), .multipleOf(5)), count: 1...5, .unique), equating: { $0 == $1 })
        clean(Schema<[String: Double]>.dictionary(of: .double(.range(-1...1)), .count(1...4)), equating: { $0 == $1 })
        clean(Schema<String>.string(.length(1...12, unit: .graphemes)), cases: 60, equating: { $0 == $1 })
        clean(Schema<String>.string(.length(...20, unit: .utf8Bytes), .pattern("^[a-z]+$")), cases: 60, equating: { $0 == $1 })
    }
}

@Suite("SchemaSuite: the report")
struct SuiteReportTests {
    @Test func everyCheckRunsAndCountsItsRuns() {
        let report = SchemaSuite(Prefs.schema).report(seed: 3, cases: 40)
        for check in SchemaSuiteReport.Check.allCases where check != .generation {
            #expect((report.tally[check]?.runs ?? 0) > 0, "\(check) did not run")
        }
        #expect(report.tally[.roundTrip]?.runs == 40)
        #expect(report.tally[.sparseFixedPoint]?.runs == 80)
        #expect((report.tally[.mutations]?.runs ?? 0) > 100)
        #expect((report.tally[.suggestions]?.runs ?? 0) > 10)
        #expect(report.isClean)
        #expect(report.skipped == 0)
    }

    @Test func missingDocumentationIsAWarningNamingThePath() {
        let report = SchemaSuite(Settings.schema).report(seed: 1, cases: 5)
        #expect(report.isClean)
        let messages = report.warnings.map(\.message)
        #expect(messages.contains("$.shortcuts has no doc"))
        #expect(messages.contains("$.network.port has no doc") == false)  // documented
        #expect(!messages.contains("$.scrollSpeed has no doc"))
    }

    @Test func theReportDescribesItselfWithSeedsToReproduce() {
        let report = SchemaSuite(brokenRoundTrip).report(seed: 5, cases: 10)
        #expect(!report.isClean)
        let text = report.description
        #expect(text.contains("SchemaSuite seed 5, 10 cases"))
        #expect(text.contains("roundTrip:"))
        #expect(text.contains("reproduce with seed"))
    }

    @Test func runThrowsTheReportAndPassesWhenClean() throws {
        try SchemaSuite(Rect.schema).run(seed: 2, cases: 20)
        do {
            try SchemaSuite(brokenRoundTrip).run(seed: 2, cases: 20)
            Issue.record("expected the suite to fail")
        } catch {
            #expect(error.report.failures.count > 0)
            #expect(error.description.contains("roundTrip"))
        }
    }

    @Test func findingsPerCheckAreCappedButTheTallyCountsAll() {
        var suite = SchemaSuite(brokenRoundTrip)
        suite.findingsPerCheck = 2
        let report = suite.report(seed: 1, cases: 30)
        #expect(report.failures.filter { $0.check == .roundTrip }.count == 2)
        #expect((report.tally[.roundTrip]?.failures ?? 0) > 2)
    }

    @Test func sameSeedSameReport() {
        let a = SchemaSuite(Shape.schema).report(seed: 9, cases: 30).description
        let b = SchemaSuite(Shape.schema).report(seed: 9, cases: 30).description
        #expect(a == b)
    }
}

// MARK: - Schemas that are wrong on purpose

/// A transform whose encode is not the inverse of its decode.
private let brokenRoundTrip: Schema<Int> = .transform(
    base: .int(.range(0...100)), decode: { $0 * 2 }, encode: { $0 }, describe: "doubled", examples: [2, 4, 6])

@Suite("SchemaSuite catches broken schemas")
struct BrokenSchemaTests {
    @Test func aConversionThatIsNotInvertible() {
        let report = SchemaSuite(brokenRoundTrip).report(seed: 1, cases: 20)
        #expect(report.tally[.roundTrip]?.failures == 20)
        #expect(report.failures[0].message.contains("changed"))
        // The failing document is shrunk to the smallest example.
        #expect(report.failures[0].document != nil)
    }

    @Test func aCustomDecoderThatIgnoresTheConstraintsItAdvertises() {
        // Says "1 to 3 characters" to the export and the generators, accepts anything.
        let lax: Schema<String> = .custom(
            describing: .string(constraints: [.length(1...3)]), description: "a short string", examples: ["a", "abc"],
            decode: { json, context in json.string ?? context.fail("is not a string") },
            encode: { .string($0) })
        let report = SchemaSuite(lax).report(seed: 1, cases: 30)
        #expect(!report.isClean)
        let kinds = Set(report.failures.map(\.check))
        #expect(kinds.contains(.mutations))
        #expect(kinds.contains(.jsonSchema))
        #expect(report.failures.contains { $0.message.contains("longer") || $0.message.contains("too_long") })
    }

    @Test func aDecoderThatStopsAtTheFirstProblemFailsAccumulation() {
        struct Pair: Sendable, Equatable { var a = 1, b = 2 }
        let stopping: Schema<Pair> = .custom(
            describing: Schema.object(Pair.self, default: Pair(), unknownKeys: .reject) {
                Field("a", \.a, .int(.range(0...9)), doc: "a")
                Field("b", \.b, .int(.range(0...9)), doc: "b")
            }.node,
            description: "a pair",
            examples: [["a": 1, "b": 2]],
            decode: { json, context in
                // Decodes the fields one after another and gives up at the first failure.
                guard case .object(let object) = json else { return context.fail("is not an object") }
                guard let a = object["a"].flatMap({ context.decode($0, as: Schema<Int>.int(.range(0...9)), at: .key("a")) })
                else { return nil }
                guard let b = object["b"].flatMap({ context.decode($0, as: Schema<Int>.int(.range(0...9)), at: .key("b")) })
                else { return nil }
                return Pair(a: a, b: b)
            },
            encode: { ["a": .number(JSONNumber($0.a)), "b": .number(JSONNumber($0.b))] })
        let report = SchemaSuite(stopping).report(seed: 1, cases: 80)
        #expect(report.tally[.accumulation]?.failures ?? 0 > 0, "\(report)")
    }

    @Test func aDefaultThatIsNotValid() {
        struct Port: Sendable, Equatable { var number = 0 }
        let schema = Schema.object(Port.self, default: Port()) {
            Field("number", \.number, .int(.range(1...65_535)), doc: "The port.")
        }
        let report = SchemaSuite(schema).report(seed: 1, cases: 5)
        #expect(!report.isClean)
        #expect(report.failures.contains { $0.check == .defaults && $0.message.contains("not valid") })
    }

    @Test func aTypoThatIsNotAnsweredWithTheRightKeyIsReported() {
        // A decoder that reports unknown keys without suggestions.
        struct Box: Sendable, Equatable { var width = 1 }
        let inner = Schema.object(Box.self, default: Box(), unknownKeys: .reject) {
            Field("width", \.width, .int(.range(0...9)), doc: "w")
        }
        let mute: Schema<Box> = .custom(
            describing: inner.node, description: "a box", examples: [["width": 3]],
            decode: { json, context in
                var result = inner.decode(json)
                guard let value = result.value else {
                    for issue in result.errors {
                        context.report("rejected", code: issue.code, at: issue.path, expected: issue.expected)
                    }
                    return nil
                }
                result.issues = []
                return value
            },
            encode: { inner.encode($0) })
        let report = SchemaSuite(mute).report(seed: 1, cases: 40)
        #expect((report.tally[.suggestions]?.failures ?? 0) > 0, "\(report)")
    }

    @Test func aTransformWithoutExamplesIsAWarning() {
        let bare: Schema<Int> = .transform(
            base: .string(.pattern("^[0-9]+$"), .length(1...3)),
            decode: { text throws(TransformFailure) in
                guard let number = Int(text), number > 100 else { throw TransformFailure("is not above 100") }
                return number
            },
            encode: { String($0) }, describe: "a number above 100")
        let report = SchemaSuite(bare).report(seed: 1, cases: 20)
        #expect(report.warnings.contains { $0.message.contains("declares no examples") })
        #expect(report.tally[.generation] == nil || report.tally[.generation]?.failures == 0)
    }

    @Test func aMigrationThatProducesInvalidDocumentsIsCaughtByTheSuite() {
        struct Doc: Sendable, Equatable { var size = 10 }
        let schema = Schema.object(
            Doc.self, default: Doc(), version: 2, migrations: [.from(1, to: 2, .pinDefault("size", 9999))]
        ) {
            Field("size", \.size, .int(.range(1...100)), doc: "How big.")
        }
        let report = SchemaSuite(schema).report(seed: 1, cases: 10)
        #expect(report.failures.contains { $0.check == .migrations })
    }
}

@Suite("expectSchemaSuite")
struct ExpectSchemaSuiteTests {
    @Test func aSoundSchemaRecordsNothing() {
        let report = expectSchemaSuite(Rect.schema, seed: 4, cases: 30)
        #expect(report.isClean)
        #expect(report.warnings.isEmpty)
    }

    @Test func aBrokenSchemaRecordsEachFindingAsAnIssue() {
        withKnownIssue {
            expectSchemaSuite(brokenRoundTrip, seed: 1, cases: 5)
        }
    }

    @Test func warningsCanBeMadeToFail() {
        // Settings has a field with no doc comment.
        expectSchemaSuite(Settings.schema, seed: 1, cases: 5)
        withKnownIssue {
            expectSchemaSuite(Settings.schema, seed: 1, cases: 5, warningsFail: true)
        }
    }
}

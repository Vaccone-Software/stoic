import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

/// Checks that every generated sample is valid and that every mutation of it
/// yields exactly its expected errors. Returns a description of each failure.
private func check<V: Sendable>(_ schema: Schema<V>, _ seeds: Range<UInt64>, mutationsPerSample: Int = 8) -> [String] {
    var failures: [String] = []
    let generator = schema.generator
    for seed in seeds {
        let sample: Sample<V>
        do throws(GenerationFailure) {
            sample = try generator.sample(seed: seed)
        } catch {
            failures.append("seed \(seed): \(error)")
            continue
        }
        var random = SplitMix64(seed: seed &+ 1000)
        let all = generator.mutations(of: sample.document, seed: seed)
        var chosen = all
        chosen.shuffle(using: &random)
        for mutation in chosen.prefix(mutationsPerSample) {
            let result = schema.decode(mutation.document)
            let expectedErrors = mutation.expected.filter { $0.severity == .error }.map { "\($0.path) \($0.code)" }.sorted()
            let actualErrors = result.errors.map { "\($0.path) \($0.code)" }.sorted()
            if expectedErrors != actualErrors {
                failures.append(
                    "seed \(seed) [\(mutation.kind)] \(mutation.summary): expected \(expectedErrors), got \(actualErrors)\n  \(mutation.document.encodedString(style: .compact))"
                )
            }
            for expected in mutation.expected where expected.severity == .warning {
                if !result.warnings.contains(where: { $0.path == expected.path && $0.code == expected.code }) {
                    failures.append("seed \(seed) [\(mutation.kind)] \(mutation.summary): missing warning \(expected)")
                }
            }
            if let suggestion = mutation.expected.compactMap(\.suggestion).first {
                let suggested = result.issues.flatMap(\.suggestions)
                if !suggested.contains(suggestion) {
                    failures.append("seed \(seed) [\(mutation.kind)] \(mutation.summary): no suggestion \(suggestion), got \(suggested)")
                }
            }
        }
    }
    return failures
}

@Suite("Generators: valid values")
struct ValidValueTests {
    @Test func theSameSeedGivesTheSameSample() throws {
        let a = try Settings.schema.generator.sample(seed: 42)
        let b = try Settings.schema.generator.sample(seed: 42)
        #expect(a.document == b.document)
        #expect(a.value == b.value)
        let c = try Settings.schema.generator.sample(seed: 43)
        #expect(a.document != c.document)
    }

    @Test func samplesDrawnFromOneGeneratorDiffer() throws {
        let samples = try Settings.schema.generator.samples(count: 20, seed: 1)
        #expect(Set(samples.map { $0.document.encodedString() }).count > 15)
    }

    @Test func aCallersOwnGeneratorWorksToo() throws {
        var system = SystemRandomNumberGenerator()
        let sample = try Settings.schema.generator.sample(using: &system)
        #expect(Settings.schema.decode(sample.document).value == sample.value)
    }

    @Test func everySampleIsAccepted() throws {
        for seed in 0..<UInt64(300) {
            let sample = try Settings.schema.generator.sample(seed: seed)
            #expect(Settings.schema.validate(sample.value).isEmpty, "seed \(seed)")
        }
    }

    @Test func boundariesAreHitOften() throws {
        var speeds: Set<String> = []
        var ports: Set<Int> = []
        var tokenLengths: Set<Int> = []
        var hostCounts: Set<Int> = []
        for seed in 0..<UInt64(600) {
            let sample = try Settings.schema.generator.sample(seed: seed)
            let value = sample.value
            speeds.insert(Settings.schema.encode(value).object?["scrollSpeed"]?.encodedString() ?? "")
            ports.insert(value.network.port.value)
            tokenLengths.insert(value.apiToken.unicodeScalars.count)
            hostCounts.insert(value.network.hosts.count)
        }
        #expect(speeds.contains("200") && speeds.contains("4000"), "\(speeds.sorted().prefix(20))")
        #expect(speeds.contains("201") && speeds.contains("3999") && speeds.contains("200.00000000000003"))
        #expect([1, 2, 65_534, 65_535].allSatisfy { ports.contains($0) }, "\(ports.sorted().prefix(12))")
        #expect(tokenLengths.contains(0) && tokenLengths.contains(128) && tokenLengths.contains(127))
        #expect(hostCounts.contains(0) && hostCounts.contains(1) && hostCounts.contains(7) && hostCounts.contains(8))
    }

    @Test func stringsIncludeAstralCombiningAndJoinedCharacters() throws {
        var astral = false
        var combining = false
        var joined = false
        var awkward = false
        for seed in 0..<UInt64(400) {
            let sample = try Settings.schema.generator.sample(seed: seed)
            for host in sample.value.network.hosts + [sample.value.apiToken, sample.value.windowTitle ?? ""] {
                for scalar in host.unicodeScalars {
                    if scalar.value > 0xFFFF { astral = true }
                    if (0x300...0x36F).contains(scalar.value) { combining = true }
                    if scalar.value == 0x200D { joined = true }
                    if scalar == "\"" || scalar == "\\" { awkward = true }
                }
            }
        }
        #expect(astral && combining && joined && awkward)
    }

    @Test func zeroAndNegativeZeroAreGenerated() throws {
        let schema = Schema<Double>.double()
        var lexemes: Set<String> = []
        for seed in 0..<UInt64(300) {
            lexemes.insert(try schema.generator.sample(seed: seed).document.encodedString(style: .compact))
        }
        #expect(lexemes.contains("0"))
        #expect(lexemes.contains("-0"))
        #expect(lexemes.contains("9007199254740992"))
        #expect(lexemes.contains("5e-324"))
    }

    @Test func lengthsAreCountedInTheConstraintsUnit() throws {
        for unit in LengthUnit.allCases {
            let schema = Schema<String>.string(.length(1...6, unit: unit))
            var seen: Set<Int> = []
            for seed in 0..<UInt64(300) {
                let sample = try schema.generator.sample(seed: seed)
                let length: Int
                switch unit {
                case .characters: length = sample.value.unicodeScalars.count
                case .graphemes: length = sample.value.count
                case .utf8Bytes: length = sample.value.utf8.count
                }
                #expect((1...6).contains(length), "\(unit) \(sample.document)")
                seen.insert(length)
            }
            #expect(seen.contains(1) && seen.contains(6) && seen.contains(2) && seen.contains(5), "\(unit) \(seen.sorted())")
        }
    }

    @Test func mixedUnitsAreMetWithPlainText() throws {
        let schema = Schema<String>.string(.length(2...4), .length(...6, unit: .utf8Bytes), .length(3...5, unit: .graphemes))
        for seed in 0..<UInt64(100) {
            let sample = try schema.generator.sample(seed: seed)
            #expect((3...4).contains(sample.value.unicodeScalars.count))
        }
    }

    @Test func patternsAreMatched() throws {
        for pattern in [#"^[a-z]{3,8}-\d{2}$"#, "^(red|green|blue)$", #"^\w+@\w+\.(com|org)$"#, "^[^ ]{2,4}$", "^v?[0-9]+(\\.[0-9]+){0,2}$"] {
            let schema = Schema<String>.string(.pattern(pattern))
            var distinct: Set<String> = []
            for seed in 0..<UInt64(60) {
                let sample = try schema.generator.sample(seed: seed)
                distinct.insert(sample.value)
            }
            #expect(distinct.count > 1 || pattern == "^(red|green|blue)$", "\(pattern): \(distinct)")
        }
    }

    @Test func aPatternTheSamplerDoesNotUnderstandFallsBackToPlainCandidates() throws {
        // A pattern outside the sampler's subset that no plain candidate satisfies
        // is a clear failure, not a bad sample.
        let impossible = Schema<String>.string(.pattern("^(?=.*q)(?=.*z)[a-c]+$"))
        #expect(throws: GenerationFailure.self) { try impossible.generator.sample(seed: 1) }
    }

    @Test func uniqueAndCountedCollectionsAreMet() throws {
        let schema = Schema<[Int]>.array(of: .int(.range(0...5)), count: 3...6, .unique)
        var counts: Set<Int> = []
        for seed in 0..<UInt64(200) {
            let sample = try schema.generator.sample(seed: seed)
            #expect(Set(sample.value).count == sample.value.count)
            counts.insert(sample.value.count)
        }
        #expect(counts.contains(3) && counts.contains(6))
        let impossible = Schema<[Bool]>.array(of: .bool, count: 3...3, .unique)
        #expect(throws: GenerationFailure.self) { try impossible.generator.sample(seed: 1) }
    }

    @Test func dictionariesHaveDistinctKeys() throws {
        let schema = Schema<[String: Int]>.dictionary(of: .int(.range(0...9)), .count(2...5))
        for seed in 0..<UInt64(100) {
            let sample = try schema.generator.sample(seed: seed)
            #expect((2...5).contains(sample.value.count))
        }
    }

    @Test func recursionEnds() throws {
        for seed in 0..<UInt64(100) {
            let menu = try Menu.schema.generator.sample(seed: seed)
            #expect(Menu.schema.validate(menu.value).isEmpty)
            let expression = try Expression.schema.generator.sample(seed: seed)
            #expect(Expression.schema.validate(expression.value).isEmpty)
        }
    }

    @Test func everyCaseOfAUnionAppears() throws {
        var tags: Set<String> = []
        for seed in 0..<UInt64(100) {
            let sample = try Shape.schema.generator.sample(seed: seed)
            tags.insert(sample.document.object?["type"]?.string ?? "")
        }
        #expect(tags == ["circle", "rect", "label", "point"])
    }

    @Test func versionedDocumentsAreWrittenAtTheCurrentVersion() throws {
        for seed in 0..<UInt64(50) {
            let sample = try Prefs.schema.generator.sample(seed: seed)
            #expect(sample.document.object?["version"] == 4)
            #expect(sample.issues.isEmpty)
        }
    }

    @Test func transformsDrawFromTheirExamples() throws {
        var stamps: Set<String> = []
        for seed in 0..<UInt64(100) {
            stamps.insert(try Timestamp.schema.generator.sample(seed: seed).document.string ?? "")
        }
        #expect(stamps == ["1970-01-01T00:00:00Z", "2000-02-29T00:00:00Z", "2024-02-29T12:00:00Z"])
        #expect(Timestamp.schema.generator.transformsWithoutExamples.isEmpty)
        let bare: Schema<Int> = .transform(
            base: .string(), decode: { _ throws(TransformFailure) in 1 }, encode: { _ in "1" }, describe: "one")
        #expect(bare.generator.transformsWithoutExamples == ["$ (Int)"])
    }

    @Test func integerEnumerationsAndOptionalsAreGenerated() throws {
        var levels: Set<Priority> = []
        for seed in 0..<UInt64(60) {
            levels.insert(try Schema.enumeration(Priority.self).generator.sample(seed: seed).value)
        }
        #expect(levels == Set(Priority.allCases))
    }

    @Test func objectsComeSparseAndDense() throws {
        var sizes: Set<Int> = []
        for seed in 0..<UInt64(100) {
            sizes.insert(try Settings.schema.generator.sample(seed: seed).document.object?.count ?? -1)
        }
        #expect(sizes.contains(0) || sizes.contains(1) || sizes.contains(2))
        #expect(sizes.contains(8) || sizes.contains(9))
    }
}

@Suite("Generators: shrinking")
struct ShrinkingTests {
    @Test func shrinkingMovesTowardDefaultsAndMinima() throws {
        let generator = Settings.schema.generator
        // Find a sample with at least three hosts, then minimise while that holds.
        var found: Sample<Settings>?
        for seed in 0..<UInt64(200) where found == nil {
            let sample = try generator.sample(seed: seed)
            if sample.value.network.hosts.count >= 3 { found = sample }
        }
        guard let start = found else { return fail("no sample with three hosts") }
        let minimal = generator.minimize(start) { $0.network.hosts.count >= 3 }
        #expect(minimal.value.network.hosts.count == 3)
        // The hosts must stay distinct, so they cannot all be "a"; each is as short as it may be.
        #expect(minimal.value.network.hosts.allSatisfy { $0.unicodeScalars.count == 1 })
        #expect(minimal.value.network.hosts.contains("a"))
        #expect(minimal.value.scrollSpeed == 1200 || minimal.value.scrollSpeed == 200 || minimal.value.scrollSpeed == 0)
        #expect(minimal.value.windowTitle == nil)
        #expect(minimal.value.apiToken == "")
    }

    @Test func numbersShrinkToTheNearestBoundOrZero() throws {
        let schema = Schema<Int>.int(.range(10...1000))
        let start = try schema.generator.sample(seed: 3)
        let minimal = schema.generator.minimize(start) { _ in true }
        #expect(minimal.value == 10)
        let above = schema.generator.minimize(Sample(document: 900, value: 900, issues: [])) { $0 > 50 }
        #expect(above.value == 51)
        let unbounded = Schema<Int>.int()
        #expect(unbounded.generator.minimize(Sample(document: -77, value: -77, issues: [])) { _ in true }.value == 0)
    }

    @Test func stringsShrinkToTheShortestAllowed() throws {
        let schema = Schema<String>.string(.length(2...20))
        let start = Sample(document: "héllo wörld 😀", value: "héllo wörld 😀", issues: [])
        #expect(schema.generator.minimize(start) { _ in true }.value == "aa")
        #expect(schema.generator.minimize(start) { $0.count > 5 }.value.count == 6)
    }

    @Test func everyShrinkIsValidAndSimpler() throws {
        for seed in 0..<UInt64(60) {
            let sample = try Settings.schema.generator.sample(seed: seed)
            for smaller in Settings.schema.generator.shrink(sample) {
                #expect(Settings.schema.decode(smaller.document).value == smaller.value)
                #expect(smaller.document != sample.document)
            }
        }
    }

    @Test func minimizationTerminatesOnEverySchema() throws {
        for seed in 0..<UInt64(6) {
            let menu = try Menu.schema.generator.sample(seed: seed)
            let minimal = Menu.schema.generator.minimize(menu) { _ in true }
            #expect(minimal.value == Menu())
            let shape = try Shape.schema.generator.sample(seed: seed)
            _ = Shape.schema.generator.minimize(shape) { _ in true }
        }
    }

    @Test func collectionsShrinkToTheirMinimumCount() throws {
        let schema = Schema<[Int]>.array(of: .int(), count: 2...9)
        let start = try schema.generator.sample(seed: 11)
        #expect(schema.generator.minimize(start) { _ in true }.value == [0, 0])
    }
}

@Suite("Generators: invalid documents")
struct InvalidDocumentTests {
    @Test func settingsMutationsYieldExactlyTheirExpectedIssues() {
        let failures = check(Settings.schema, 0..<150)
        #expect(failures.isEmpty, "\(failures.prefix(6).joined(separator: "\n"))")
    }

    @Test func formBObjectsAndUnions() {
        #expect(check(Shape.schema, 0..<150).isEmpty)
        let failures = check(Canvas.schema, 0..<100)
        #expect(failures.isEmpty, "\(failures.prefix(6).joined(separator: "\n"))")
        let rect = check(Rect.schema, 0..<60)
        #expect(rect.isEmpty, "\(rect.prefix(4).joined(separator: "\n"))")
    }

    @Test func recursiveAndVersionedSchemas() {
        for failures in [check(Menu.schema, 0..<80), check(Expression.schema, 0..<80), check(Prefs.schema, 0..<100), check(Loose.schema, 0..<60)] {
            #expect(failures.isEmpty, "\(failures.prefix(6).joined(separator: "\n"))")
        }
    }

    @Test func transformsAndCustomSchemas() {
        struct Event: Sendable, Equatable {
            var at = Timestamp(secondsSinceEpoch: 0)
            var home = Endpoint(secure: true, host: "example.com")
            var level = Priority.normal
            var rate = Frequency(hertz: 50)
        }
        let schema = Schema.object(Event.self, default: Event(), unknownKeys: .reject) {
            Field("at", \.at, Timestamp.schema, doc: "When.")
            Field("home", \.home, Endpoint.schema, doc: "Where.")
            Field("level", \.level, .enumeration(Priority.self), doc: "How much.")
            Field("rate", \.rate, Frequency.schema, doc: "How often.")
        }
        let failures = check(schema, 0..<150)
        #expect(failures.isEmpty, "\(failures.prefix(6).joined(separator: "\n"))")
    }

    @Test func everyKindOfViolationIsOfferedForSomeSchema() throws {
        var offered: Set<Mutation.Kind> = []
        func collect<V: Sendable>(_ schema: Schema<V>) throws {
            for seed in 0..<UInt64(60) {
                let sample = try schema.generator.sample(seed: seed)
                for mutation in schema.generator.mutations(of: sample.document, seed: seed) { offered.insert(mutation.kind) }
            }
        }
        try collect(Settings.schema)
        try collect(Shape.schema)
        try collect(Prefs.schema)
        try collect(Rect.schema)
        let multiples = Schema<[Int]>.array(of: .int(.multipleOf(5), .range(0...100)), .count(1...3), .unique)
        try collect(multiples)
        let patterned = Schema<String>.string(.pattern("^[a-z]+$"), .length(1...8))
        try collect(patterned)
        let choice = Schema<String>.string(.oneOf(["a", "b"]))
        try collect(choice)
        try collect(Wire.schema)
        #expect(offered == Set(Mutation.Kind.allCases), "missing \(Set(Mutation.Kind.allCases).subtracting(offered))")
    }

    @Test(.failureMode("design/06", "three fields are invalid")) func independentMutationsYieldExactlyThatManyIssues() throws {
        var random = SplitMix64(seed: 9)
        var combined = 0
        for seed in 0..<UInt64(150) {
            let sample = try Settings.schema.generator.sample(seed: seed)
            for count in 2...4 {
                guard let mutation = Settings.schema.generator.mutation(of: sample.document, combining: count, using: &random)
                else { continue }
                combined += 1
                let result = Settings.schema.decode(mutation.document)
                let expectedErrors = mutation.expected.filter { $0.severity == .error }.map { "\($0.path) \($0.code)" }.sorted()
                #expect(result.errors.map { "\($0.path) \($0.code)" }.sorted() == expectedErrors, "seed \(seed): \(mutation.summary)")
                #expect(mutation.expected.count <= count)
            }
        }
        #expect(combined > 300)
    }

    @Test func aMisspeltKeyIsSuggestedBackToTheRightOne() throws {
        var typos = 0
        for seed in 0..<UInt64(80) {
            let sample = try Settings.schema.generator.sample(seed: seed)
            for mutation in Settings.schema.generator.mutations(of: sample.document, seed: seed) where mutation.kind == .typoKey {
                typos += 1
                let result = Settings.schema.decode(mutation.document)
                let issue = result.issues.first { $0.code == .unknownKey }
                #expect(issue?.suggestions.contains(mutation.expected[0].suggestion ?? "?") == true, "\(mutation.summary): \(result.issues)")
            }
        }
        #expect(typos > 100)
    }

    @Test func mutationsKeepDocumentsOtherwiseIntact() throws {
        let sample = try Settings.schema.generator.sample(seed: 5)
        for mutation in Settings.schema.generator.mutations(of: sample.document) {
            #expect(mutation.document != sample.document, "\(mutation.summary)")
            #expect(mutation.edit(sample.document) == mutation.document)
        }
    }

    @Test func aDocumentWithNoRulesAdmitsFewViolations() throws {
        let schema = Schema<JSONValue>.json()
        #expect(schema.generator.mutations(of: 5).isEmpty)
    }

    @Test func invalidDocumentsComeFromSeededSamples() throws {
        var random = SplitMix64(seed: 77)
        let broken = try Settings.schema.generator.invalidDocument(using: &random)
        #expect(Settings.schema.decode(broken.document).errors.isEmpty == broken.expected.allSatisfy { $0.severity != .error })
    }
}

@Suite("Regular expression sampler")
struct RegexSamplerTests {
    @Test func samplesMatchTheirPattern() throws {
        let patterns = [
            "abc", "a|b|c", "[a-z]+", "[^0-9]{3}", #"\d{2,4}"#, #"\w*"#, "(ab)+c?", ".{5}", #"[\w.-]+@[a-z]+\.com"#,
            "^start.*end$", "(?:x|y){2}", #"a\.b"#, "[a-c-]", "x{0}y",
        ]
        for pattern in patterns {
            guard let sampler = RegexSampler(pattern: pattern), let regex = try? Regex(pattern) else {
                fail("cannot parse \(pattern)")
                continue
            }
            var random = SplitMix64(seed: 1)
            for round in 0..<30 {
                let text = sampler.sample(using: &random, short: round % 2 == 0)
                #expect(text.firstMatch(of: regex) != nil, "\(pattern) did not match \(text)")
            }
        }
    }

    @Test func unsupportedSyntaxIsDeclined() {
        for pattern in ["(?=a)b", #"(a)\1"#, #"\p{L}+"#, "(?<n>a)", "[[:alpha:]]", "a{2,1}", "*a"] {
            #expect(RegexSampler(pattern: pattern) == nil, "\(pattern)")
        }
    }
}

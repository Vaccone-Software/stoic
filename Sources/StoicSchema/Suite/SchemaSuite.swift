internal import StoicJSON

/// A one-call self-test for a schema.
///
///     @Test func settingsSchemaHolds() throws {
///         try SchemaSuite(Settings.schema).run(seed: 1, cases: 500)
///     }
///
/// Declaring a schema is the single place a type's wire format is stated; the
/// suite checks that the declaration keeps the promises every schema makes,
/// on documents derived from the declaration itself, so there is nothing to
/// write and nothing to fall out of date:
///
/// - **round trip.** Every generated value, encoded and decoded again, is the
///   value, as JSON and as text, and `validate` accepts it.
/// - **sparse fixed point.** Sparse encoding, decoded and encoded again, is
///   unchanged, with and without secrets.
/// - **mutations.** Every minimal violation a generated document admits (see
///   ``SchemaGenerator/mutations(of:seed:)``) yields exactly the expected
///   errors, at exactly the expected paths, and every expected warning.
/// - **accumulation.** Two, three and four independent violations yield
///   exactly that many errors.
/// - **suggestions.** Every misspelt key or union tag is answered with the
///   spelling it was derived from.
/// - **JSON Schema.** The exported JSON Schema and the decoder agree, on the
///   valid documents and the mutated ones, checked by an independent small
///   validator. (Rules a JSON Schema cannot state are skipped, by name.)
/// - **defaults.** An empty document decodes to the declared defaults, which
///   are themselves valid.
/// - **documentation.** Every field and union case has a doc comment
///   (a warning, not a failure).
/// - **migrations.** A versioned schema's history passes
///   ``Schema/migrationChainCheck(cases:seed:)``.
///
/// It returns a report and does not assert, so it needs no test library: use
/// ``report(seed:cases:)`` to inspect the findings, or ``run(seed:cases:)``
/// to throw if any check failed (a thrown error fails a Swift Testing or
/// XCTest test and prints every finding). The `StoicSchemaTesting` product
/// adds an `expectSchemaSuite` helper that records each finding at the test's
/// source location.
///
/// Everything is seeded: a finding names the seed that reproduces it.
public struct SchemaSuite<Value: Sendable>: Sendable {
    public let schema: Schema<Value>
    public var configuration: GenerationConfiguration
    /// How many single mutations of each generated document are checked.
    public var mutationsPerCase = 6
    /// How many findings of each check the report keeps (the tally counts all).
    public var findingsPerCheck = 5
    private let equate: (@Sendable (Value, Value) -> Bool)?

    /// A suite for `schema`. Values are compared by their encodings; give
    /// `equating` to compare them as Swift values too.
    public init(
        _ schema: Schema<Value>,
        configuration: GenerationConfiguration = GenerationConfiguration(),
        equating equate: (@Sendable (Value, Value) -> Bool)? = nil
    ) {
        self.schema = schema
        self.configuration = configuration
        self.equate = equate
    }

    /// Runs the suite and throws every finding if a check failed.
    public func run(seed: UInt64 = 0, cases: Int = 200) throws(SchemaSuiteFailure) {
        let result = report(seed: seed, cases: cases)
        guard result.isClean else { throw SchemaSuiteFailure(report: result) }
    }

    /// Runs the suite and returns what it found.
    public func report(seed: UInt64 = 0, cases: Int = 200) -> SchemaSuiteReport {
        var recorder = Recorder(seed: seed, cases: cases, limit: findingsPerCheck)
        let generator = SchemaGenerator(schema, configuration: configuration)
        let validator = JSONSchemaValidator(schema.jsonSchema())
        let caveats = Self.agreementCaveats(schema.node)

        checkDocumentation(into: &recorder)
        checkDefaults(into: &recorder)
        for name in generator.transformsWithoutExamples {
            recorder.warn(
                .generation,
                "\(name) declares no examples, so the generator can only try values of its base and the conversion may refuse them; give `examples:`"
            )
        }

        for index in 0..<cases {
            let caseSeed = seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
            var random = SplitMix64(seed: caseSeed)
            let sample: Sample<Value>
            do throws(GenerationFailure) {
                sample = try generator.sample(using: &random)
            } catch {
                // A refusal of a value built from a transform that declares no
                // examples is the conversion's, not a defect of the schema.
                if !generator.transformsWithoutExamples.isEmpty,
                    !error.issues.isEmpty, error.issues.allSatisfy({ $0.severity != .error || $0.code == .invalidValue })
                {
                    recorder.skipped += 1
                } else {
                    recorder.fail(.generation, "\(error)", seed: caseSeed)
                }
                continue
            }

            checkRoundTrip(sample, generator: generator, seed: caseSeed, into: &recorder)
            checkSparse(sample, seed: caseSeed, into: &recorder)
            recorder.run(.jsonSchema)
            if !validator.accepts(sample.document) {
                recorder.fail(
                    .jsonSchema, "the decoder accepts this generated document but the exported JSON Schema rejects it",
                    seed: caseSeed, document: sample.document)
            }
            checkMutations(
                sample, generator: generator, validator: validator, caveats: caveats, seed: caseSeed, random: &random,
                into: &recorder)
            checkAccumulation(sample, generator: generator, seed: caseSeed, random: &random, into: &recorder)
        }

        if case .object(let node) = schema.node, node.versioning != nil {
            let chain = schema.migrationChainCheck(cases: min(max(cases, 5), 40), seed: seed)
            recorder.run(.migrations)
            for step in chain.steps {
                for failure in step.failures {
                    recorder.fail(
                        .migrations,
                        "version \(step.from) to \(step.to): \(failure.summary)"
                            + failure.issues.filter { $0.severity == .error }.prefix(2).map { "\n    \($0)" }.joined(),
                        document: failure.oldDocument.isNull ? nil : failure.oldDocument)
                }
                if let why = step.unchecked {
                    recorder.warn(.migrations, "version \(step.from) to \(step.to) was not tested: \(why)")
                }
                for gap in step.gaps { recorder.warn(.migrations, gap) }
            }
            for problem in chain.problems { recorder.fail(.migrations, problem) }
        }
        return recorder.finish()
    }

    // MARK: Round trip

    private func roundTripProblem(_ value: Value) -> String? {
        let full = schema.encode(value, style: .full)
        let decoded = schema.decode(full)
        guard let back = decoded.value else {
            return "the encoded value does not decode: \(decoded.errors.map(\.description).joined(separator: "; "))"
        }
        let again = schema.encode(back, style: .full)
        if again != full {
            return "decode then encode changed the document: \(again.encodedString(style: .compact))"
        }
        if let equate, !equate(value, back) { return "the decoded value is not equal to the original" }
        let text = full.encodedString(style: .canonical)
        let viaText = schema.decodeReporting(text)
        guard let fromText = viaText.value else {
            return "the canonical text does not decode: \(viaText.errors.map(\.description).joined(separator: "; "))"
        }
        if schema.encode(fromText, style: .full) != full { return "the canonical text decodes to a different value" }
        let pretty = schema.decodeReporting(full.encodedString(style: .pretty()))
        if pretty.value == nil { return "the pretty-printed text does not decode" }
        let invalid = schema.validate(value)
        if !invalid.isEmpty { return "validate() rejects a value that decoded: \(invalid.map(\.description).joined(separator: "; "))" }
        return nil
    }

    private func checkRoundTrip(
        _ sample: Sample<Value>,
        generator: SchemaGenerator<Value>,
        seed: UInt64,
        into recorder: inout Recorder
    ) {
        recorder.run(.roundTrip)
        guard let problem = roundTripProblem(sample.value) else { return }
        let smallest = generator.minimize(sample) { roundTripProblem($0) != nil }
        recorder.fail(.roundTrip, problem, seed: seed, document: smallest.document)
    }

    // MARK: Sparse

    private func checkSparse(_ sample: Sample<Value>, seed: UInt64, into recorder: inout Recorder) {
        for style in [EncodeStyle.sparse(includeSecrets: true), .sparse] {
            recorder.run(.sparseFixedPoint)
            let once = schema.encode(sample.value, style: style)
            let decoded = schema.decode(once)
            guard let back = decoded.value else {
                recorder.fail(
                    .sparseFixedPoint,
                    "the sparse encoding does not decode: \(decoded.errors.map(\.description).joined(separator: "; "))",
                    seed: seed, document: once)
                continue
            }
            let twice = schema.encode(back, style: style)
            if twice != once {
                recorder.fail(
                    .sparseFixedPoint,
                    "decoding then encoding the sparse form changed it to \(twice.encodedString(style: .compact))",
                    seed: seed, document: once)
            } else if style.includeSecrets {
                if schema.encode(back, style: .full) != schema.encode(sample.value, style: .full) {
                    recorder.fail(
                        .sparseFixedPoint, "the sparse form (with secrets) does not decode to the same value", seed: seed,
                        document: once)
                }
            }
        }
    }

    // MARK: Mutations

    private func checkMutations(
        _ sample: Sample<Value>,
        generator: SchemaGenerator<Value>,
        validator: JSONSchemaValidator,
        caveats: Caveats,
        seed: UInt64,
        random: inout SplitMix64,
        into recorder: inout Recorder
    ) {
        var all = generator.mutations(of: sample.document, seed: random.next())
        all.shuffle(using: &random)
        for mutation in all.prefix(mutationsPerCase) {
            let result = schema.decode(mutation.document)
            recorder.run(.mutations)
            let expectedErrors = mutation.expected.filter { $0.severity == .error }.map { "\($0.path) \($0.code)" }.sorted()
            let actualErrors = result.errors.map { "\($0.path) \($0.code)" }.sorted()
            if expectedErrors != actualErrors {
                recorder.fail(
                    .mutations,
                    "\(mutation.summary): expected \(expectedErrors.isEmpty ? "no errors" : expectedErrors.joined(separator: ", ")), got \(actualErrors.isEmpty ? "none" : actualErrors.joined(separator: ", "))",
                    seed: seed, document: mutation.document)
            }
            for expected in mutation.expected where expected.severity == .warning {
                if !result.warnings.contains(where: { $0.path == expected.path && $0.code == expected.code }) {
                    recorder.fail(
                        .mutations, "\(mutation.summary): expected a warning \(expected), got none", seed: seed,
                        document: mutation.document)
                }
            }
            if expectedErrors.isEmpty, result.value == nil, actualErrors.isEmpty {
                recorder.fail(.mutations, "\(mutation.summary): no value although there are no errors", seed: seed)
            }
            if let wanted = mutation.expected.first(where: { $0.suggestion != nil }), let suggestion = wanted.suggestion {
                recorder.run(.suggestions)
                let offered = result.issues.filter { $0.path == wanted.path && $0.code == wanted.code }.flatMap(\.suggestions)
                if !offered.contains(suggestion) {
                    recorder.fail(
                        .suggestions,
                        "\(mutation.summary): expected the suggestion `\(suggestion)` at \(wanted.path), got \(offered.isEmpty ? "none" : offered.map { "`\($0)`" }.joined(separator: ", "))",
                        seed: seed, document: mutation.document)
                }
            }
            if !caveats.skips(mutation.kind) && !mutation.isTolerated {
                recorder.run(.jsonSchema)
                let exported = validator.accepts(mutation.document)
                if exported != (result.value != nil) {
                    recorder.fail(
                        .jsonSchema,
                        "\(mutation.summary): the decoder \(result.value != nil ? "accepts" : "rejects") this document but the exported JSON Schema \(exported ? "accepts" : "rejects") it",
                        seed: seed, document: mutation.document)
                }
            }
        }
    }

    private func checkAccumulation(
        _ sample: Sample<Value>,
        generator: SchemaGenerator<Value>,
        seed: UInt64,
        random: inout SplitMix64,
        into recorder: inout Recorder
    ) {
        for count in 2...4 {
            guard let combined = generator.mutation(of: sample.document, combining: count, using: &random) else { continue }
            recorder.run(.accumulation)
            let result = schema.decode(combined.document)
            let expected = combined.expected.filter { $0.severity == .error }.map { "\($0.path) \($0.code)" }.sorted()
            let actual = result.errors.map { "\($0.path) \($0.code)" }.sorted()
            if expected != actual {
                recorder.fail(
                    .accumulation,
                    "\(combined.summary): expected \(expected.isEmpty ? "no errors" : expected.joined(separator: ", ")), got \(actual.isEmpty ? "none" : actual.joined(separator: ", "))",
                    seed: seed, document: combined.document)
            }
        }
    }

    // MARK: Once per schema

    private func checkDocumentation(into recorder: inout Recorder) {
        var seen: Set<String> = []
        func visit(_ node: SchemaNode, _ path: String, _ recorder: inout Recorder) {
            switch node {
            case .object(let object):
                for field in object.fields {
                    recorder.run(.documentation)
                    let here = path + "." + field.key
                    if field.doc?.isEmpty ?? true { recorder.warn(.documentation, "\(here) has no doc") }
                    visit(field.node, here, &recorder)
                }
            case .union(let union):
                for entry in union.cases {
                    visit(entry.node, path + "<" + entry.tag + ">", &recorder)
                }
            case .array(let element, _): visit(element, path + "[]", &recorder)
            case .dictionary(let element, _): visit(element, path + ".*", &recorder)
            case .optional(let wrapped, _): visit(wrapped, path, &recorder)
            case .transformed(let transform): visit(transform.base, path, &recorder)
            case .lazy(let name, let resolve):
                if seen.insert(name).inserted { visit(resolve(), path, &recorder) }
            case .boolean, .integer, .number, .string, .enumeration, .integerEnumeration, .json:
                break
            }
        }
        visit(schema.node, "$", &recorder)
    }

    private func checkDefaults(into recorder: inout Recorder) {
        guard case .object(let node) = schema.node else { return }
        var empty = JSONObject()
        if let versioning = node.versioning { empty[versioning.key] = .number(JSONNumber(versioning.current)) }
        let result = schema.decode(.object(empty))
        guard let value = result.value else {
            // A schema with required fields has no defaults to speak of.
            if node.fields.contains(where: { $0.isRequired }) { return }
            recorder.run(.defaults)
            recorder.fail(
                .defaults,
                "an empty document should decode to the defaults, but: \(result.errors.map(\.description).joined(separator: "; "))")
            return
        }
        recorder.run(.defaults)
        let invalid = schema.validate(value)
        if !invalid.isEmpty {
            recorder.fail(.defaults, "the default value is not valid: \(invalid.map(\.description).joined(separator: "; "))")
        }
        guard case .object(let written) = schema.encode(value, style: .full) else { return }
        for field in node.fields {
            guard let declared = field.defaultValue else { continue }
            recorder.run(.defaults)
            let actual = written[field.key]
            // A deprecated field equal to its default is not written.
            if actual != declared && !(actual == nil && field.deprecation != nil) {
                recorder.fail(
                    .defaults,
                    "\(field.key): the node says the default is \(declared.encodedString(style: .compact)) but an empty document decodes to \(actual?.encodedString(style: .compact) ?? "nothing")"
                )
            }
        }
    }

    // MARK: What a JSON Schema cannot say

    /// Rules the decoder enforces that no JSON Schema validator can, so that
    /// the agreement check skips the mutations that break them.
    struct Caveats {
        var nonCharacterLengths = false

        func skips(_ kind: Mutation.Kind) -> Bool {
            switch kind {
            // A Double the decoder refuses for being too exact or too large is
            // still a number to a validator.
            case .precisionLoss, .notFinite: true
            // A format is an annotation to a JSON Schema validator; only
            // the conversion knows that 2024-02-30 is no date.
            case .refusedByConversion: true
            case .tooLong, .tooShort: nonCharacterLengths
            default: false
            }
        }
    }

    static func agreementCaveats(_ node: SchemaNode) -> Caveats {
        var caveats = Caveats()
        var seen: Set<String> = []
        SchemaGenerator<Value>.walk(node, path: "$", seen: &seen) { visited, _ in
            for constraint in visited.constraints {
                if case .length(_, let unit) = constraint.kind, unit != .characters { caveats.nonCharacterLengths = true }
            }
        }
        return caveats
    }
}

extension SchemaSuite where Value: Equatable {
    /// A suite that also compares decoded values with `==`.
    public init(_ schema: Schema<Value>, configuration: GenerationConfiguration = GenerationConfiguration()) {
        self.init(schema, configuration: configuration, equating: { $0 == $1 })
    }
}

/// Collects the suite's findings and counts.
private struct Recorder {
    var report: SchemaSuiteReport
    let limit: Int
    var skipped = 0
    private var kept: [SchemaSuiteReport.Check: Int] = [:]

    init(seed: UInt64, cases: Int, limit: Int) {
        report = SchemaSuiteReport(seed: seed, cases: cases, findings: [], tally: [:], skipped: 0)
        self.limit = limit
    }

    mutating func run(_ check: SchemaSuiteReport.Check) {
        report.tally[check, default: SchemaSuiteReport.Tally()].runs += 1
    }

    mutating func fail(_ check: SchemaSuiteReport.Check, _ message: String, seed: UInt64? = nil, document: JSONValue? = nil) {
        report.tally[check, default: SchemaSuiteReport.Tally()].failures += 1
        if kept[check, default: 0] < limit {
            kept[check, default: 0] += 1
            report.findings.append(
                SchemaSuiteReport.Finding(check: check, severity: .failure, message: message, seed: seed, document: document))
        }
    }

    mutating func warn(_ check: SchemaSuiteReport.Check, _ message: String) {
        report.findings.append(
            SchemaSuiteReport.Finding(check: check, severity: .warning, message: message, seed: nil, document: nil))
    }

    mutating func finish() -> SchemaSuiteReport {
        report.skipped = skipped
        return report
    }
}

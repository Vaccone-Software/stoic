public import StoicSchema
public import Testing

/// Runs a schema's self-test and records every finding as a Swift Testing
/// issue at the caller's line.
///
///     @Test func settingsSchemaHolds() {
///         expectSchemaSuite(Settings.schema, seed: 1, cases: 500)
///     }
///
/// This is `SchemaSuite(schema).run(...)` for a test that wants each problem
/// reported separately, with its reproducing seed and its (shrunk) document,
/// instead of one thrown error. Warnings (a field with no doc comment, a
/// transform without examples) are recorded as warnings and do not fail the
/// test; pass `warningsFail: true` for a schema that is held to a higher
/// standard.
///
/// The suite itself is in StoicSchema and asserts nothing, so code that is
/// not a Swift Testing test (a build tool, a command-line check) can use it
/// without this target.
///
/// - Returns: The report, in case the test wants to look at the tallies.
@discardableResult
public func expectSchemaSuite<Value: Sendable>(
    _ schema: Schema<Value>,
    seed: UInt64 = 0,
    cases: Int = 200,
    configuration: GenerationConfiguration = GenerationConfiguration(),
    equating: (@Sendable (Value, Value) -> Bool)? = nil,
    warningsFail: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation
) -> SchemaSuiteReport {
    let report = SchemaSuite(schema, configuration: configuration, equating: equating).report(seed: seed, cases: cases)
    for finding in report.findings {
        switch finding.severity {
        case .failure:
            Issue.record(Comment(rawValue: finding.description), sourceLocation: sourceLocation)
        case .warning:
            if warningsFail {
                Issue.record(Comment(rawValue: finding.description), sourceLocation: sourceLocation)
            } else {
                Issue.record(Comment(rawValue: finding.description), severity: .warning, sourceLocation: sourceLocation)
            }
        }
    }
    return report
}

/// ``expectSchemaSuite(_:seed:cases:configuration:equating:warningsFail:sourceLocation:)``
/// for a type that is `Equatable`, which also compares decoded values with
/// `==`.
@discardableResult
public func expectSchemaSuite<Value: Sendable & Equatable>(
    _ schema: Schema<Value>,
    seed: UInt64 = 0,
    cases: Int = 200,
    configuration: GenerationConfiguration = GenerationConfiguration(),
    warningsFail: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation
) -> SchemaSuiteReport {
    expectSchemaSuite(
        schema, seed: seed, cases: cases, configuration: configuration, equating: { $0 == $1 },
        warningsFail: warningsFail, sourceLocation: sourceLocation)
}

public import StoicJSON

/// What ``SchemaSuite`` found: every check's tally and every finding, as
/// data, so that any test harness (or none) can decide what to do with it.
public struct SchemaSuiteReport: Sendable, CustomStringConvertible {
    /// The properties the suite checks.
    public enum Check: String, Sendable, CaseIterable, Hashable {
        /// Valid values could be generated at all.
        case generation
        /// `decode(encode(value))` is the value, as JSON and in text.
        case roundTrip
        /// Sparse encoding is a fixed point of decode-then-encode.
        case sparseFixedPoint
        /// A valid document with one violation yields exactly the expected
        /// issue at the expected path.
        case mutations
        /// Several independent violations yield exactly that many issues.
        case accumulation
        /// A misspelt key or tag is answered with the right suggestion.
        case suggestions
        /// The exported JSON Schema and the decoder agree on every
        /// generated document.
        case jsonSchema
        /// The defaults are valid and are what an empty document means.
        case defaults
        /// Every field and case has documentation.
        case documentation
        /// A versioned schema's history leads somewhere valid.
        case migrations
    }

    public enum Severity: String, Sendable, Hashable {
        /// The schema has a bug, or the suite found a property it lacks.
        case failure
        /// Not wrong, but the suite could not check something or the schema
        /// is missing something it should have.
        case warning
    }

    /// One thing the suite noticed.
    public struct Finding: Sendable, CustomStringConvertible {
        public var check: Check
        public var severity: Severity
        public var message: String
        /// The seed that reproduces the case, for findings about a case.
        public var seed: UInt64?
        /// The document the finding is about; shrunk where the suite could.
        public var document: JSONValue?

        public var description: String {
            var text = "\(severity.rawValue) [\(check.rawValue)] \(message)"
            if let seed { text += "\n    reproduce with seed \(seed)" }
            if let document { text += "\n    document: \(document.encodedString(style: .compact))" }
            return text
        }
    }

    /// How often a check ran and how often it failed.
    public struct Tally: Sendable {
        public var runs = 0
        public var failures = 0
    }

    public var seed: UInt64
    public var cases: Int
    /// The first findings of each check; a check that fails everywhere does
    /// not bury the others. `tally` counts all of them.
    public var findings: [Finding]
    public var tally: [Check: Tally]
    /// How many samples could not be generated (and so were skipped).
    public var skipped: Int

    public var failures: [Finding] { findings.filter { $0.severity == .failure } }
    public var warnings: [Finding] { findings.filter { $0.severity == .warning } }

    /// Whether no check failed. Warnings do not count.
    public var isClean: Bool { tally.values.allSatisfy { $0.failures == 0 } && failures.isEmpty }

    public var description: String {
        var lines = ["SchemaSuite seed \(seed), \(cases) cases" + (skipped > 0 ? ", \(skipped) skipped" : "")]
        for check in Check.allCases {
            guard let entry = tally[check] else { continue }
            lines.append("  \(check.rawValue): \(entry.runs) runs, \(entry.failures) failed")
        }
        for finding in findings { lines.append(finding.description) }
        return lines.joined(separator: "\n")
    }
}

/// Thrown by ``SchemaSuite/run(seed:cases:)`` when a check failed.
public struct SchemaSuiteFailure: Error, Sendable, CustomStringConvertible {
    public var report: SchemaSuiteReport

    public var description: String { report.description }
}

#if STOIC_LINT

/// A file to lint: its path and its text. The command line reads the files;
/// the rules never touch the disk.
public struct SourceInput: Sendable, Equatable {
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// The result of linting a set of files against an optional baseline.
public struct LintOutcome: Sendable {
    /// Findings that fail the build.
    public var errors: [Finding]
    /// Findings the baseline accepts; reported as warnings.
    public var accepted: [Finding]
    /// Baseline entries that no finding matched: fixed since the baseline
    /// was written.
    public var stale: [Baseline.Entry]
    /// Every finding a `stoic:allow` comment suppressed, recorded or not.
    public var suppressed: [Finding] = []
    /// Recorded suppressions that no longer occur.
    public var staleSuppressions: [Baseline.Entry] = []
    public var fileCount: Int
    /// Where to attach the stale-entry warning, when a baseline was given.
    public var baselinePath: String?

    /// Non-zero when anything fails the build.
    public var exitCode: Int32 { errors.isEmpty ? 0 : 1 }

    /// The text for the build log: diagnostics sorted by file and position,
    /// then a summary line. Errors and warnings use the shared
    /// `path:line:col: severity: message` form, which both Xcode and SwiftPM
    /// turn into build issues.
    public func report() -> String {
        var diagnostics: [(Finding, Severity)] =
            errors.map { ($0, .error) } + accepted.map { ($0, .warning) }
        diagnostics.sort { lhs, rhs in
            (lhs.0.file, lhs.0.line, lhs.0.column) < (rhs.0.file, rhs.0.line, rhs.0.column)
        }
        var lines = diagnostics.map { $0.0.diagnostic(as: $0.1) }
        if !stale.isEmpty, let baselinePath {
            lines.append(
                "\(baselinePath):1:1: warning: [stoic.baseline] \(stale.count) accepted finding(s) no longer occur. "
                    + "Regenerate the baseline with `stoic-lint --write-baseline` so the ratchet turns down.")
        }
        if !staleSuppressions.isEmpty, let baselinePath {
            lines.append(
                "\(baselinePath):1:1: warning: [stoic.baseline] \(staleSuppressions.count) recorded suppression(s) no longer occur. "
                    + "Regenerate the baseline with `stoic-lint --write-baseline` so the ratchet turns down.")
        }
        lines.append(summary)
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line: counts of errors, baselined and stale findings.
    public var summary: String {
        var parts = ["\(errors.count) error(s)"]
        if !accepted.isEmpty || !stale.isEmpty { parts.append("\(accepted.count) baselined") }
        if !stale.isEmpty || !staleSuppressions.isEmpty { parts.append("\(stale.count + staleSuppressions.count) stale") }
        if !suppressed.isEmpty { parts.append("\(suppressed.count) suppressed") }
        return "stoic-lint: " + parts.joined(separator: ", ") + " in \(fileCount) file(s)"
    }
}

extension Linter {
    /// Lints `files`, then sets aside whatever `baseline` accepts.
    /// `baselineRoot` is the directory baseline paths are relative to: the
    /// baseline file's own directory.
    public func lint(
        _ files: [SourceInput],
        baseline: Baseline? = nil,
        baselineRoot: String = "",
        baselinePath: String? = nil
    ) -> LintOutcome {
        let reports = files.map { analyze(source: $0.text, path: $0.path) }
        let all = reports.flatMap(\.findings)
        let suppressed = reports.flatMap(\.suppressed)
        guard let baseline else {
            return LintOutcome(
                errors: all, accepted: [], stale: [], suppressed: suppressed, fileCount: files.count, baselinePath: nil)
        }
        let split = baseline.partition(all, relativeTo: baselineRoot)
        // A baseline lists a whole project's findings, but a run may cover
        // only some files (an Xcode target, a SwiftPM module). Entries for
        // files outside this run are not stale; they are somebody else's.
        let linted = Set(files.map { Baseline.relativePath($0.path, to: baselineRoot) })
        let stale = split.stale.filter { linted.contains($0.file) }
        var errors = split.new
        var staleSuppressions: [Baseline.Entry] = []
        if let escapes = baseline.partitionSuppressions(suppressed, relativeTo: baselineRoot) {
            errors += escapes.new.map(Self.unrecorded)
            staleSuppressions = escapes.stale.filter { linted.contains($0.file) }
        }
        errors.sort { ($0.file, $0.line, $0.column) < ($1.file, $1.line, $1.column) }
        return LintOutcome(
            errors: errors, accepted: split.accepted, stale: stale, suppressed: suppressed,
            staleSuppressions: staleSuppressions, fileCount: files.count, baselinePath: baselinePath)
    }

    /// The error for a suppression the baseline has not recorded, at the
    /// place of the finding it suppresses.
    private static func unrecorded(_ suppressed: Finding) -> Finding {
        Finding(
            rule: .unrecordedSuppression,
            file: suppressed.file,
            line: suppressed.line,
            column: suppressed.column,
            message:
                "`stoic:allow(\(suppressed.rule.shortName))` suppresses a finding the baseline has not recorded: an escape added since the baseline was written.",
            fixIt:
                "fix the code instead; if the suppression is right, record it with `stoic-lint --write-baseline`, in a change a reviewer sees",
            sourceLine: suppressed.sourceLine)
    }
}

#endif

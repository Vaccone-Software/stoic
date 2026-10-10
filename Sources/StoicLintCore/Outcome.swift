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
        lines.append(summary)
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line: counts of errors, baselined and stale findings.
    public var summary: String {
        var parts = ["\(errors.count) error(s)"]
        if !accepted.isEmpty || !stale.isEmpty { parts.append("\(accepted.count) baselined") }
        if !stale.isEmpty { parts.append("\(stale.count) stale") }
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
        let all = files.flatMap { lint(source: $0.text, path: $0.path) }
        guard let baseline else {
            return LintOutcome(errors: all, accepted: [], stale: [], fileCount: files.count, baselinePath: nil)
        }
        let split = baseline.partition(all, relativeTo: baselineRoot)
        // A baseline lists a whole project's findings, but a run may cover
        // only some files (an Xcode target, a SwiftPM module). Entries for
        // files outside this run are not stale; they are somebody else's.
        let linted = Set(files.map { Baseline.relativePath($0.path, to: baselineRoot) })
        let stale = split.stale.filter { linted.contains($0.file) }
        return LintOutcome(
            errors: split.new, accepted: split.accepted, stale: stale, fileCount: files.count,
            baselinePath: baselinePath)
    }
}

#endif

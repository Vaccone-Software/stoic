#if STOIC_LINT

/// The identifier of a lint rule, as it appears in diagnostics, in
/// `// stoic:allow(…)` comments and in baselines.
///
/// Identifiers are API: a baseline file and every suppression comment in an
/// app name them, so a rule is never renamed, only retired.
public enum RuleID: String, CaseIterable, Sendable, Codable {
    case blockingInAsync = "stoic.blocking-in-async"
    case uncheckedSendable = "stoic.unchecked-sendable"
    case nonisolatedUnsafe = "stoic.nonisolated-unsafe"
    case unboundedStream = "stoic.unbounded-stream"
    case discardedTry = "stoic.discarded-try"
    case forceTry = "stoic.force-try"
    case taskDetached = "stoic.task-detached"
    case sleepForTimeout = "stoic.sleep-for-timeout"
    /// A suppression comment that does not say why. Never itself suppressible:
    /// a reason is the whole point of allowing something.
    case allowWithoutReason = "stoic.allow-without-reason"

    /// The identifier without its `stoic.` prefix, the form comments use.
    public var shortName: String { String(rawValue.dropFirst(Self.prefix.count)) }

    /// The namespace shared by every rule.
    public static let prefix = "stoic."

    /// Resolves either spelling, `stoic.force-try` or `force-try`.
    public init?(named name: String) {
        let trimmed = name.trimmingSpaces()
        if let rule = RuleID(rawValue: trimmed) {
            self = rule
        } else if let rule = RuleID(rawValue: Self.prefix + trimmed) {
            self = rule
        } else {
            return nil
        }
    }
}

/// One thing a rule objects to.
///
/// A finding is a value: the rules produce them from source text alone, and
/// the command line decides what to do with them (fail, or report as
/// baselined).
public struct Finding: Sendable, Hashable {
    public var rule: RuleID
    /// The path exactly as it was given to the linter.
    public var file: String
    /// One-based.
    public var line: Int
    /// One-based, in UTF-8 bytes, which is what Xcode expects.
    public var column: Int
    public var message: String
    /// What to write instead, in words. Never a mechanical rewrite: the
    /// right replacement depends on code the linter does not read.
    public var fixIt: String?
    /// The offending line, trimmed. Together with the file and the rule it is
    /// the finding's identity in a baseline, so it survives edits elsewhere.
    public var sourceLine: String

    public init(
        rule: RuleID,
        file: String,
        line: Int,
        column: Int,
        message: String,
        fixIt: String? = nil,
        sourceLine: String = ""
    ) {
        self.rule = rule
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.fixIt = fixIt
        self.sourceLine = sourceLine
    }
}

/// How a finding is reported.
public enum Severity: String, Sendable {
    case error
    case warning
}

extension Finding {
    /// The diagnostic in the format Xcode and SwiftPM both parse:
    /// `/abs/File.swift:12:5: error: [stoic.rule] message`, followed by the
    /// suggestion as a `note:` on the same position when there is one. A
    /// baselined warning omits the note: it is already accepted, and a
    /// hundred of them should not bury the one new error.
    public func diagnostic(as severity: Severity = .error) -> String {
        var text = "\(file):\(line):\(column): \(severity.rawValue): [\(rule.rawValue)] \(message)"
        if severity == .error, let fixIt {
            text += "\n\(file):\(line):\(column): note: \(fixIt)"
        }
        return text
    }
}

extension String {
    /// Trims spaces and tabs only. `trimmingCharacters` would pull in
    /// Foundation for something this small.
    func trimmingSpaces() -> String {
        var slice = self[...]
        while let first = slice.first, first == " " || first == "\t" { slice = slice.dropFirst() }
        while let last = slice.last, last == " " || last == "\t" || last == "\r" { slice = slice.dropLast() }
        return String(slice)
    }
}

#endif

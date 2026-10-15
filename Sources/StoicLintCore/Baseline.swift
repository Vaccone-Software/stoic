#if STOIC_LINT
public import Foundation

/// The findings a codebase has agreed to live with, for now.
///
/// Adopting a strict rule in an existing app means hundreds of findings on
/// day one. Failing the build on all of them is a rule nobody can turn on;
/// ignoring them is a rule that means nothing. A baseline is the third
/// option, a ratchet: today's findings are recorded and reported as
/// warnings, and any finding _not_ recorded fails the build. The count may
/// only fall. Fix one and its entry goes stale; regenerate the baseline and
/// the ratchet turns down a notch. Add one and it is new, so it fails.
///
/// An entry is the file's path relative to the baseline, the rule, and a
/// hash of the offending line's trimmed text. No line numbers: edits
/// elsewhere in the file move a finding without changing its identity, so a
/// baseline does not churn on every unrelated commit. Change the offending
/// line itself and the entry no longer matches, which is the right moment to
/// look at it again.
///
/// Two identical lines in one file are two entries, and each entry accepts
/// one finding: a third copy is new.
///
/// A baseline also records the findings a `stoic:allow` comment suppressed,
/// the escapes, identified the same way. With them recorded, a suppression
/// added later is `stoic.unrecorded-suppression` and fails the build: an
/// escape cannot appear without a baseline change a reviewer sees. That
/// matters most when an agent writes the code, since a reason-shaped comment
/// is the cheapest way past any rule. A baseline written before suppressions
/// were recorded has no list, and the budget is not enforced until it is
/// regenerated.
public struct Baseline: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Hashable, Comparable {
        public var file: String
        public var rule: String
        public var hash: String

        public init(file: String, rule: String, hash: String) {
            self.file = file
            self.rule = rule
            self.hash = hash
        }

        public static func < (lhs: Entry, rhs: Entry) -> Bool {
            (lhs.file, lhs.rule, lhs.hash) < (rhs.file, rhs.rule, rhs.hash)
        }
    }

    public var version: Int
    public var entries: [Entry]
    /// The suppressions accepted, or nil in a baseline written before they
    /// were recorded (no budget is enforced then).
    public var suppressions: [Entry]?

    public init(entries: [Entry] = [], suppressions: [Entry]? = nil) {
        self.version = 1
        self.entries = entries.sorted()
        self.suppressions = suppressions?.sorted()
    }

    /// Records `findings` and the `suppressed` ones, with file paths made
    /// relative to `root`.
    public init(recording findings: [Finding], suppressed: [Finding] = [], relativeTo root: String) {
        self.init(
            entries: findings.map { Self.entry(for: $0, relativeTo: root) },
            suppressions: suppressed.map { Self.entry(for: $0, relativeTo: root) })
    }

    /// Splits `findings` into those the baseline accepts and those it does
    /// not, and lists the entries nothing matched any more.
    public func partition(
        _ findings: [Finding], relativeTo root: String
    ) -> (new: [Finding], accepted: [Finding], stale: [Entry]) {
        Self.match(findings, against: entries, relativeTo: root)
    }

    /// Splits suppressed findings into those recorded and those added since,
    /// and lists the recorded suppressions that no longer occur. Nil when the
    /// baseline records no suppressions.
    public func partitionSuppressions(
        _ suppressed: [Finding], relativeTo root: String
    ) -> (new: [Finding], stale: [Entry])? {
        guard let suppressions else { return nil }
        let split = Self.match(suppressed, against: suppressions, relativeTo: root)
        return (split.new, split.stale)
    }

    private static func match(
        _ findings: [Finding], against entries: [Entry], relativeTo root: String
    ) -> (new: [Finding], accepted: [Finding], stale: [Entry]) {
        var remaining: [Entry: Int] = [:]
        for entry in entries { remaining[entry, default: 0] += 1 }
        var new: [Finding] = []
        var accepted: [Finding] = []
        for finding in findings {
            let entry = Self.entry(for: finding, relativeTo: root)
            if let count = remaining[entry], count > 0 {
                remaining[entry] = count - 1
                accepted.append(finding)
            } else {
                new.append(finding)
            }
        }
        let stale = remaining.flatMap { entry, count in Array(repeating: entry, count: count) }.sorted()
        return (new, accepted, stale)
    }

    static func entry(for finding: Finding, relativeTo root: String) -> Entry {
        Entry(
            file: Self.relativePath(finding.file, to: root),
            rule: finding.rule.rawValue,
            hash: Self.hash(ofLine: finding.sourceLine)
        )
    }

    /// `path` relative to the directory `root`, or unchanged if it is
    /// elsewhere. Forward slashes, so a baseline is the same on every machine.
    public static func relativePath(_ path: String, to root: String) -> String {
        var prefix = root
        while prefix.count > 1, prefix.hasSuffix("/") { prefix.removeLast() }
        if prefix.isEmpty { return path }
        if prefix == "/" { return String(path.dropFirst()) }
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : path
    }

    /// FNV-1a over the trimmed line, as 16 hex digits. Not `Hasher`, which is
    /// seeded per process and would make a baseline unreadable tomorrow.
    public static func hash(ofLine line: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in line.trimmingSpaces().utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    // MARK: JSON

    /// Stable output (sorted keys, sorted entries) so a baseline diffs
    /// cleanly in review.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    public static func decode(_ data: Data) throws -> Baseline {
        let baseline = try JSONDecoder().decode(Baseline.self, from: data)
        guard baseline.version == 1 else { throw BaselineError.unsupportedVersion(baseline.version) }
        return baseline
    }
}

public enum BaselineError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "baseline version \(version) is not supported by this stoic-lint (it reads version 1)"
        }
    }
}

#endif

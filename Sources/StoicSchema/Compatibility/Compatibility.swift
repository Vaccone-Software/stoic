public import StoicJSON

/// One payload a release wrote, as bytes (design/32).
public struct CompatibilityFixture: Sendable, Hashable {
    public let release: ReleaseVersion
    /// The file's name without `.json`.
    public let name: String
    /// What the release wrote, exactly: not re-encoded, not wrapped.
    public let bytes: [UInt8]

    public init(release: ReleaseVersion, name: String, bytes: [UInt8]) {
        self.release = release
        self.name = name
        self.bytes = bytes
    }
}

/// Every fixture of one format, and each release's reader where it was kept.
public struct CompatibilitySet: Sendable {
    public let format: String
    public let fixtures: [CompatibilityFixture]
    /// Each release's reader: its exported JSON Schema (`_schema.json`).
    public let readers: [ReleaseVersion: JSONValue]
    /// What was wrong with the fixtures themselves as they were found: a
    /// folder whose name is not a version, a file that could not be read.
    public let problems: [CompatibilityFinding]

    public init(
        format: String, fixtures: [CompatibilityFixture], readers: [ReleaseVersion: JSONValue] = [:],
        problems: [CompatibilityFinding] = []
    ) {
        self.format = format
        self.fixtures = fixtures
        self.readers = readers
        self.problems = problems
    }

    /// Every release that has a fixture or a reader, ascending.
    public var releases: [ReleaseVersion] {
        Array(Set(fixtures.map(\.release)).union(readers.keys)).sorted()
    }
}

/// One thing a compatibility check found.
public struct CompatibilityFinding: Sendable, Hashable, CustomStringConvertible {
    public enum Direction: Sendable, Hashable {
        /// A release's payload, read by today's schema.
        case olderWriter
        /// Today's document, read by a release's schema.
        case olderReader
        /// The fixtures themselves: a misnamed folder, an empty release, a
        /// stale break, a retired release.
        case fixtures
    }

    public enum Severity: Sendable, Hashable {
        case failure, warning
    }

    public let direction: Direction
    public let severity: Severity
    public let release: ReleaseVersion?
    /// The payload's name; `generated-n` for today's generated documents.
    public let sample: String?
    /// Where in the document; `nil` for the whole document.
    public let path: JSONPath?
    /// An issue code (`unknown_key`, `missing_key`, …), a JSON Schema keyword
    /// (`additionalProperties`, `required`, `const`, …), or the fixtures' own
    /// (`stale_break`, `empty_release`, `not_a_version`, `no_reader`,
    /// `retired`, `not_covered`, `no_release`, `verify`).
    public let code: String
    public let message: String
    /// Where in the payload's text, as `line:column`, when the issue knows.
    public let location: String?

    public init(
        direction: Direction, severity: Severity, release: ReleaseVersion?, sample: String?, path: JSONPath?, code: String,
        message: String, location: String? = nil
    ) {
        self.direction = direction
        self.severity = severity
        self.release = release
        self.sample = sample
        self.path = path
        self.code = code
        self.message = message
        self.location = location
    }

    /// `1:2 $.recipient: [unknown_key] …`, after what was read by what.
    public var description: String {
        var where_: [String] = []
        if let location { where_.append(location) }
        if let path { where_.append("\(path):") }
        let detail = (where_ + ["[\(code)]", message]).joined(separator: " ")
        let what: String = switch direction {
        case .olderWriter:
            "release \(release?.description ?? "?")'s sample \"\(sample ?? "?")\" (written by \(release?.description ?? "?"), read by today's schema)"
        case .olderReader:
            "today's sample \"\(sample ?? "?")\" read by release \(release?.description ?? "?")'s reader (written today, read by \(release?.description ?? "?"))"
        case .fixtures:
            release.map { "release \($0)'s fixtures" } ?? "the fixtures"
        }
        return "\(what): \(detail)"
    }
}

/// What a compatibility check found, for one format.
public struct CompatibilityReport: Sendable, CustomStringConvertible {
    public let format: String
    /// By release, then sample, then reading order.
    public let findings: [CompatibilityFinding]
    /// Released payloads read by today's schema.
    public let read: Int
    /// Today's documents offered to older readers.
    public let offered: Int

    public init(format: String, findings: [CompatibilityFinding], read: Int, offered: Int) {
        self.format = format
        self.findings = findings
        self.read = read
        self.offered = offered
    }

    /// Whether no finding is a failure.
    public var passed: Bool {
        !findings.contains { $0.severity == .failure }
    }

    public var failures: [CompatibilityFinding] { findings.filter { $0.severity == .failure } }
    public var warnings: [CompatibilityFinding] { findings.filter { $0.severity == .warning } }

    public var description: String {
        let head = "\"\(format)\": \(read) released payloads read, \(offered) of today's documents offered to older readers"
        return ([head] + findings.map { "✘ \($0)" }).joined(separator: "\n")
    }
}

/// A schema checked against what released builds wrote and read (design/32).
///
/// Two directions. Every payload a release wrote is read by today's schema,
/// with the options the real reader uses: every error a failure, every warning
/// but `migrated` a warning, and `verify` asked what each value must mean.
/// And where a release's reader was kept (its exported JSON Schema), today's
/// documents (the samples, and `generated` documents the schema's generator
/// makes, seeded by the format's name) are offered to it: each violation a
/// failure, unless the release is declared in ``olderReadersMayRefuse``.
///
/// Pure, and it asserts nothing: `expectCompatibility` (StoicSchemaTesting)
/// records the findings as test issues.
public struct CompatibilityCheck<Value: Sendable>: Sendable {
    public let schema: Schema<Value>
    public let options: DecodeOptions
    /// How the real reader reads a payload's bytes, when it is more than the
    /// schema and the options (a settings file's header, its envelope).
    public var reading: (@Sendable ([UInt8]) -> Decoded<Value>)?
    /// Today's values, offered to the older readers.
    public var samples: [(name: String, value: Value)] = []
    /// How many generated documents are offered too.
    public var generated: Int = 50
    /// Releases whose readers may refuse today's documents, with why: a break,
    /// declared. A declared release is still checked; one that accepts every
    /// document is a stale entry, and a failure.
    public var olderReadersMayRefuse: [ReleaseVersion: String] = [:]
    /// The oldest release still promised. Releases below it are retired: not
    /// checked, and reported so, never silently ignored.
    public var oldestSupported: ReleaseVersion?
    /// What a released payload's value must mean: each string is a failure.
    public var verify: (@Sendable (CompatibilityFixture, Value) -> [String])?

    public init(_ schema: Schema<Value>, options: DecodeOptions = .strict) {
        self.schema = schema
        self.options = options
    }

    public func report(_ set: CompatibilitySet) -> CompatibilityReport {
        var findings = set.problems
        var read = 0
        var offered = 0
        let releases = set.releases
        if releases.isEmpty {
            findings.append(CompatibilityFinding(
                direction: .fixtures, severity: .failure, release: nil, sample: nil, path: nil, code: "no_release",
                message: "no release of \"\(set.format)\" has been recorded"))
        }
        let documents = todaysDocuments(format: set.format)
        for release in releases {
            if let floor = oldestSupported, release < floor {
                findings.append(CompatibilityFinding(
                    direction: .fixtures, severity: .warning, release: release, sample: nil, path: nil, code: "retired",
                    message: "below the oldest supported release \(floor): retired, not checked"))
                continue
            }
            let fixtures = set.fixtures.filter { $0.release == release }.sorted { $0.name < $1.name }
            if fixtures.isEmpty {
                findings.append(CompatibilityFinding(
                    direction: .fixtures, severity: .failure, release: release, sample: nil, path: nil, code: "empty_release",
                    message: "a promise was recorded with no payload in it"))
            }
            for fixture in fixtures {
                read += 1
                findings += readOlder(fixture)
            }
            guard let reader = set.readers[release] else {
                findings.append(CompatibilityFinding(
                    direction: .olderReader, severity: .warning, release: release, sample: nil, path: nil, code: "no_reader",
                    message: "no _schema.json: what today writes is not checked against this release"))
                if olderReadersMayRefuse[release] != nil { findings.append(staleBreak(release, why: "it has no reader to refuse")) }
                continue
            }
            let validator = JSONSchemaValidator(reader)
            let uncovered = validator.uncoveredKeywords
            if !uncovered.isEmpty {
                findings.append(CompatibilityFinding(
                    direction: .olderReader, severity: .warning, release: release, sample: nil, path: nil, code: "not_covered",
                    message: "the reader states rules this check does not evaluate: \(uncovered.joined(separator: ", "))"))
            }
            if reader == .object([:]) || reader.object?.keys.allSatisfy({ $0 == "$schema" }) == true {
                findings.append(CompatibilityFinding(
                    direction: .olderReader, severity: .warning, release: release, sample: nil, path: nil, code: "not_covered",
                    message: "the reader's schema is {} (a Codable leaf): what today writes is checked against nothing"))
            }
            let declared = olderReadersMayRefuse[release] != nil
            var refused = false
            for (name, document) in documents {
                offered += 1
                for violation in validator.violations(document) {
                    refused = true
                    guard !declared else { continue }
                    findings.append(CompatibilityFinding(
                        direction: .olderReader, severity: violation.readsBestEffort ? .warning : .failure, release: release,
                        sample: name, path: violation.path, code: violation.keyword,
                        message: violation.readsBestEffort ? "\(violation.message), which this reader reads best effort" : violation.message))
                }
            }
            if declared, !refused { findings.append(staleBreak(release, why: "it now accepts every document")) }
        }
        // A break declared for a release with no fixtures, or below the floor.
        for (release, _) in olderReadersMayRefuse where !releases.contains(release) || (oldestSupported.map { release < $0 } ?? false) {
            findings.append(staleBreak(release, why: releases.contains(release) ? "it is retired" : "it has no fixtures"))
        }
        return CompatibilityReport(format: set.format, findings: findings, read: read, offered: offered)
    }

    private func staleBreak(_ release: ReleaseVersion, why: String) -> CompatibilityFinding {
        CompatibilityFinding(
            direction: .fixtures, severity: .failure, release: release, sample: nil, path: nil, code: "stale_break",
            message: "olderReadersMayRefuse declares a break for \(release), and \(why): remove the entry")
    }

    /// A release's payload, read by today's schema.
    private func readOlder(_ fixture: CompatibilityFixture) -> [CompatibilityFinding] {
        let decoded = reading?(fixture.bytes) ?? schema.decodeReporting(fixture.bytes, options: options)
        var findings: [CompatibilityFinding] = []
        for issue in decoded.issues where issue.code != .migrated {
            findings.append(CompatibilityFinding(
                direction: .olderWriter, severity: issue.severity == .error ? .failure : .warning, release: fixture.release,
                sample: fixture.name, path: issue.code == .parseError ? nil : issue.path, code: issue.code.rawValue, message: issue.message,
                location: issue.source.map { "\($0.start.line):\($0.start.column)" }))
        }
        if let value = decoded.value, let verify {
            for problem in verify(fixture, value) {
                findings.append(CompatibilityFinding(
                    direction: .olderWriter, severity: .failure, release: fixture.release, sample: fixture.name, path: nil,
                    code: "verify", message: problem))
            }
        }
        return findings
    }

    /// The samples, encoded by today's schema, then `generated` documents its
    /// generator makes, seeded by the format's name so every run offers the
    /// same ones.
    func todaysDocuments(format: String) -> [(name: String, document: JSONValue)] {
        var documents = samples.map { ($0.name, schema.encode($0.value, style: .full)) }
        guard generated > 0 else { return documents }
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in format.utf8 {
            seed ^= UInt64(byte)
            seed &*= 0x0000_0100_0000_01B3
        }
        if let samples = try? SchemaGenerator(schema).samples(count: generated, seed: seed) {
            for (index, sample) in samples.enumerated() { documents.append(("generated-\(index + 1)", sample.document)) }
        }
        return documents
    }
}

internal import Foundation
public import StoicJSON
public import StoicSchema
public import Testing

/// Holds `schema` to what released builds wrote and read (design/32).
///
/// Reads `<directory>/<format>/<release>/*.json` beside the calling test file
/// (each release's payloads, exactly as that release wrote them, and its
/// reader as `_schema.json`), checks `schema` against them with
/// ``CompatibilityCheck``, and records each failure as a Swift Testing issue at
/// the caller's line (each warning as a warning, or a failure with
/// `warningsFail`).
///
///     @Test func reportRequests() {
///         expectCompatibility(ReportRequest.schema, format: "report-request",
///                             samples: ["typical": .typical, "no-subject": .noSubject])
///     }
///
/// **Recording.** With `STOIC_RECORD_COMPATIBILITY=<release>` in the
/// environment it records that release instead: each sample encoded by
/// `schema` as `<release>/<name>.json`, in pretty text (the same values give
/// the same bytes), and `schema.jsonSchema()` (or `reader`) as
/// `<release>/_schema.json`. A file already there with the same bytes is left
/// and passes; one with other bytes is refused, since a released promise is
/// not rewritten. A run that wrote anything records an issue saying so, so a
/// recording run is never mistaken for a pass.
///
/// - Parameters:
///   - schema: Today's reader and writer.
///   - format: The format's name, and its folder's.
///   - samples: Today's values: recorded, and offered to the older readers.
///   - options: The options the real reader decodes with: `.strict` for a
///     wire body.
///   - reading: How the real reader reads bytes, when it is more than the
///     schema (a settings file: `SettingsStore.read`).
///   - reader: The reader a recording writes as `_schema.json`, when it is
///     not `schema.jsonSchema()` (a settings file's, which admits its header).
///   - olderReadersMayRefuse: Releases whose readers may refuse today's
///     documents, by version, with why.
///   - oldestSupported: The oldest release still promised; those below it are
///     reported as retired and not checked.
///   - verify: What a released payload's value must mean.
///   - warningsFail: Whether a warning fails the test.
///   - directory: The folder beside the test file that holds the formats.
///   - filePath: The calling test file.
///   - sourceLocation: Where issues are recorded.
/// - Returns: The report.
@discardableResult
public func expectCompatibility<Value: Sendable>(
    _ schema: Schema<Value>,
    format: String,
    samples: KeyValuePairs<String, Value> = [:],
    options: DecodeOptions = .strict,
    reading: (@Sendable ([UInt8]) -> Decoded<Value>)? = nil,
    reader: JSONValue? = nil,
    olderReadersMayRefuse: [String: String] = [:],
    oldestSupported: String? = nil,
    verify: (@Sendable (CompatibilityFixture, Value) -> [String])? = nil,
    warningsFail: Bool = false,
    directory: String = "Compatibility",
    filePath: String = #filePath,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) -> CompatibilityReport {
    compatibility(
        schema, format: format, samples: samples.map { ($0.key, $0.value) }, options: options, reading: reading, reader: reader,
        olderReadersMayRefuse: olderReadersMayRefuse, oldestSupported: oldestSupported, verify: verify, warningsFail: warningsFail,
        root: URL(filePath: filePath).deletingLastPathComponent().appending(path: directory).path(),
        recording: ProcessInfo.processInfo.environment["STOIC_RECORD_COMPATIBILITY"], sourceLocation: sourceLocation)
}

/// ``expectCompatibility(_:format:samples:options:reading:reader:olderReadersMayRefuse:oldestSupported:verify:warningsFail:directory:filePath:sourceLocation:)``
/// with the fixtures' folder and the release to record given, not read from
/// the test file's place and the environment: what its own tests drive.
func compatibility<Value: Sendable>(
    _ schema: Schema<Value>, format: String, samples: [(String, Value)], options: DecodeOptions,
    reading: (@Sendable ([UInt8]) -> Decoded<Value>)?, reader: JSONValue?, olderReadersMayRefuse: [String: String],
    oldestSupported: String?, verify: (@Sendable (CompatibilityFixture, Value) -> [String])?, warningsFail: Bool, root: String,
    recording: String?, sourceLocation: Testing.SourceLocation
) -> CompatibilityReport {
    if let release = recording, !release.isEmpty {
        return record(
            release, schema: schema, format: format, samples: samples, reader: reader ?? schema.jsonSchema(), root: root,
            sourceLocation: sourceLocation)
    }
    var check = CompatibilityCheck(schema, options: options)
    check.reading = reading
    check.samples = samples
    check.verify = verify
    var problems: [CompatibilityFinding] = []
    for (text, why) in olderReadersMayRefuse {
        if let release = ReleaseVersion(text) {
            check.olderReadersMayRefuse[release] = why
        } else {
            problems.append(misnamed(text, as: "olderReadersMayRefuse"))
        }
    }
    if let oldestSupported {
        if let release = ReleaseVersion(oldestSupported) { check.oldestSupported = release } else { problems.append(misnamed(oldestSupported, as: "oldestSupported")) }
    }
    let set: CompatibilitySet
    do throws(CompatibilityLoadError) {
        set = try loadCompatibilitySet(format: format, from: root)
    } catch {
        Issue.record(Comment(rawValue: error.description), sourceLocation: sourceLocation)
        return CompatibilityReport(format: format, findings: [], read: 0, offered: 0)
    }
    let found = check.report(CompatibilitySet(format: set.format, fixtures: set.fixtures, readers: set.readers, problems: set.problems + problems))
    for finding in found.findings {
        let comment = Comment(rawValue: "\"\(format)\": \(finding)")
        if finding.severity == .failure || warningsFail {
            Issue.record(comment, sourceLocation: sourceLocation)
        } else {
            Issue.record(comment, severity: .warning, sourceLocation: sourceLocation)
        }
    }
    return found
}

private func misnamed(_ text: String, as parameter: String) -> CompatibilityFinding {
    CompatibilityFinding(
        direction: .fixtures, severity: .failure, release: nil, sample: nil, path: nil, code: "not_a_version",
        message: "\(parameter) names \"\(text)\", which is not a release version")
}

/// The fixtures of `format` in `directory`: one folder per release, each
/// holding the payloads it wrote (`*.json`) and its reader (`_schema.json`),
/// for a tool that is not a test. Names beginning with `_` are reserved, and
/// files that are not `.json` are not payloads.
///
/// A release folder whose name is not a version, and a `_schema.json` that is
/// not JSON, are reported in ``CompatibilitySet/problems``; a format with no
/// folder is a set with no release, which the check reports.
///
/// - Throws: ``CompatibilityLoadError`` when the folder exists and cannot be listed or read.
public func loadCompatibilitySet(format: String, from directory: String) throws(CompatibilityLoadError) -> CompatibilitySet {
    let formatURL = URL(filePath: directory).appending(path: format)
    guard isFolder(formatURL) else { return CompatibilitySet(format: format, fixtures: []) }
    var fixtures: [CompatibilityFixture] = []
    var readers: [ReleaseVersion: JSONValue] = [:]
    var problems: [CompatibilityFinding] = []
    for folder in try contents(of: formatURL).sorted() {
        let folderURL = formatURL.appending(path: folder)
        guard isFolder(folderURL) else { continue }
        guard let release = ReleaseVersion(folder) else {
            problems.append(CompatibilityFinding(
                direction: .fixtures, severity: .failure, release: nil, sample: nil, path: nil, code: "not_a_version",
                message: "the folder \"\(folder)\" is not named for a release"))
            continue
        }
        for file in try contents(of: folderURL).sorted() where file.hasSuffix(".json") {
            let bytes = try read(folderURL.appending(path: file))
            let name = String(file.dropLast(".json".count))
            if name == "_schema" {
                do throws(JSONParseError) {
                    readers[release] = try JSONParser().parseValue(bytes)
                } catch {
                    problems.append(CompatibilityFinding(
                        direction: .fixtures, severity: .failure, release: release, sample: "_schema", path: nil, code: "parse_error",
                        message: "the reader's schema is not JSON: \(error)"))
                }
            } else if !name.hasPrefix("_") {
                fixtures.append(CompatibilityFixture(release: release, name: name, bytes: bytes))
            }
        }
    }
    return CompatibilitySet(format: format, fixtures: fixtures, readers: readers, problems: problems)
}

/// Why fixtures could not be loaded: a folder that exists and cannot be read.
public struct CompatibilityLoadError: Error, Sendable, Hashable, CustomStringConvertible {
    public let path: String
    public let reason: String

    public var description: String { "could not read the compatibility fixtures at \(path): \(reason)" }
}

private func isFolder(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
}

private func contents(of url: URL) throws(CompatibilityLoadError) -> [String] {
    do {
        return try FileManager.default.contentsOfDirectory(atPath: url.path())
    } catch {
        throw CompatibilityLoadError(path: url.path(), reason: "\(error)")
    }
}

private func read(_ url: URL) throws(CompatibilityLoadError) -> [UInt8] {
    do {
        return Array(try Data(contentsOf: url))
    } catch {
        throw CompatibilityLoadError(path: url.path(), reason: "\(error)")
    }
}

/// The recording run: writes what is not there, refuses what differs.
private func record<Value: Sendable>(
    _ text: String, schema: Schema<Value>, format: String, samples: [(String, Value)], reader: JSONValue, root: String,
    sourceLocation: Testing.SourceLocation
) -> CompatibilityReport {
    guard let release = ReleaseVersion(text) else {
        Issue.record(Comment(rawValue: "STOIC_RECORD_COMPATIBILITY=\(text) is not a release version"), sourceLocation: sourceLocation)
        return CompatibilityReport(format: format, findings: [], read: 0, offered: 0)
    }
    let folder = URL(filePath: root).appending(path: format).appending(path: release.description)
    var files = samples.map { ("\($0.0).json", pretty(schema.encode($0.1, style: .full))) }
    files.append(("_schema.json", pretty(reader)))
    var written: [String] = []
    var refused: [CompatibilityFinding] = []
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, bytes) in files {
            let url = folder.appending(path: name)
            if let existing = try? Data(contentsOf: url) {
                if Array(existing) != bytes {
                    refused.append(CompatibilityFinding(
                        direction: .fixtures, severity: .failure, release: release, sample: String(name.dropLast(5)), path: nil,
                        code: "rewritten",
                        message: "release \(release) is already recorded with other bytes; a released promise is not rewritten"))
                }
                continue
            }
            try Data(bytes).write(to: url)
            written.append(name)
        }
    } catch {
        Issue.record(Comment(rawValue: "recording \"\(format)\" \(release) failed: \(error)"), sourceLocation: sourceLocation)
    }
    for finding in refused {
        Issue.record(Comment(rawValue: "\"\(format)\": \(finding)"), sourceLocation: sourceLocation)
    }
    if !written.isEmpty {
        Issue.record(
            Comment(rawValue: "recorded \(written.count) file(s) for \"\(format)\" \(release): commit \(folder.path())"),
            sourceLocation: sourceLocation)
    }
    return CompatibilityReport(format: format, findings: refused, read: 0, offered: 0)
}

/// Pretty text and a final newline: the bytes a recording writes.
private func pretty(_ value: JSONValue) -> [UInt8] {
    value.encoded(style: .pretty(indent: 2)) + [0x0A]
}

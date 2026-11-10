import Foundation
import StoicJSON
import StoicSchema
@testable import StoicSchemaTesting
import StoicTesting
import Testing

/// A request body three releases of an app sent.
struct ReportRequest: Sendable, Equatable {
    var subject = "Attendance"
    var recipient = ""
    var copies = 1

    static func schema(unknownKeys: UnknownKeyPolicy = .reject, recipient: Bool = true, maxCopies: Int = 10) -> Schema<ReportRequest> {
        Schema.object(ReportRequest.self, default: ReportRequest(), unknownKeys: unknownKeys, doc: "A report request.") {
            Field("subject", \.subject, .string(.length(1...80)), doc: "The report's subject.")
            if recipient { Field("recipient", \.recipient, .string(), doc: "Ignored: the address comes from the account.") }
            Field("copies", \.copies, .int(.range(1...maxCopies)), doc: "Copies.")
        }
    }

    /// The same request with `copies` required: a field a release left out.
    static let copiesRequired = Schema.object(ReportRequest.self) { f in
        let subject = f.field("subject", \.subject, .string(.length(1...80)), default: "Attendance")
        let recipient = f.field("recipient", \.recipient, .string(), default: "")
        let copies = f.field("copies", \.copies, .int(.range(1...10)))
        return f.build { v in ReportRequest(subject: v[subject], recipient: v[recipient], copies: v[copies]) }
    }
}

func release(_ text: String) -> ReleaseVersion {
    guard let version = ReleaseVersion(text) else { preconditionFailure("\(text) is not a version") }
    return version
}

func fixture(_ version: String, _ name: String, _ text: String) -> CompatibilityFixture {
    CompatibilityFixture(release: release(version), name: name, bytes: Array(text.utf8))
}

/// design/32's failure modes, against sets built in memory.
@Suite("Schema compatibility")
struct CompatibilityTests {
    static let released = CompatibilitySet(format: "report-request", fixtures: [
        fixture("2.3.0", "typical", #"{"subject": "Attendance", "recipient": "ana@example.com", "copies": 2}"#),
        fixture("2.3.0", "no-subject", #"{"recipient": "ana@example.com"}"#),
    ])

    static func failures(_ report: CompatibilityReport) -> [String] {
        report.failures.map { "\($0.code) \($0.path?.description ?? "-")" }
    }

    @Test(.failureMode("design/32", "a released payload no longer decodes"))
    func aPayloadThatNoLongerDecodesSaysReleaseSamplePathCodeAndMessage() throws {
        let report = CompatibilityCheck(ReportRequest.schema(maxCopies: 1)).report(Self.released)
        let finding = try #require(report.failures.first)
        #expect(finding.release == release("2.3.0"))
        #expect(finding.sample == "typical")
        #expect(finding.path?.description == "$.copies")
        #expect(finding.code == "out_of_range")
        #expect(finding.direction == .olderWriter)
        #expect(finding.description.hasPrefix("release 2.3.0's sample \"typical\" (written by 2.3.0, read by today's schema): "))
        #expect(!report.passed)
        #expect(report.read == 2)
    }

    @Test(.failureMode("design/32", "a field that a release still sends is removed, in an object that refuses unknown keys"))
    func aRemovedFieldInAClosedObjectIsAFailure() throws {
        let report = CompatibilityCheck(ReportRequest.schema(recipient: false)).report(Self.released)
        #expect(Self.failures(report) == ["unknown_key $.recipient", "unknown_key $.recipient"])
        let finding = try #require(report.failures.first)
        #expect(finding.sample == "no-subject", "by sample, then reading order")
        #expect(finding.location == "1:2", "where in the payload's text")
        #expect(finding.description.contains("1:2 $.recipient: [unknown_key]"))
    }

    @Test(.failureMode("design/32", "a field that a release still sends is removed, in an object that ignores unknown keys"))
    func aRemovedFieldInAnOpenObjectIsAWarning() {
        let report = CompatibilityCheck(ReportRequest.schema(unknownKeys: .warn, recipient: false)).report(Self.released)
        #expect(report.passed, "it still reads")
        #expect(report.warnings.map(\.code).filter { $0 != "no_reader" } == ["unknown_key", "unknown_key"])
        #expect(report.warnings.first?.path?.description == "$.recipient")
    }

    @Test(.failureMode("design/32", "a field that a release leaves out is made required"))
    func aFieldMadeRequiredIsAFailure() {
        let report = CompatibilityCheck(ReportRequest.copiesRequired).report(Self.released)
        #expect(Self.failures(report) == ["missing_key $.copies"])
        #expect(report.failures.first?.sample == "no-subject")
    }

    @Test(.failureMode("design/32", "a field's type is narrowed"))
    func aNarrowedTypeIsAFailure() {
        let narrowed = Schema.object(ReportRequest.self, default: ReportRequest(), unknownKeys: .reject) {
            Field("subject", \.subject, .string(.length(1...80)))
            Field("recipient", \.recipient, .string())
            Field("copies", \.copies, .int(.range(1...1)))
        }
        let typed = CompatibilitySet(format: "report-request", fixtures: [fixture("2.3.0", "string", #"{"copies": "2"}"#)])
        #expect(Self.failures(CompatibilityCheck(narrowed).report(typed)) == ["type_mismatch $.copies"])
        #expect(Self.failures(CompatibilityCheck(narrowed).report(Self.released)) == ["out_of_range $.copies"], "the constraint's code")
    }

    @Test(.failureMode("design/32", "a released payload needs a migration"))
    func aMigrationIsNotAFinding() throws {
        let set = try PrefsCapsule.set()
        let report = CompatibilityCheck(Prefs.schema).report(set)
        #expect(report.failures.isEmpty, "\(report)")
        #expect(report.findings.allSatisfy { $0.code == "no_reader" }, "\(report)")
        #expect(report.read == 4)
    }

    @Test(.failureMode("design/32", "a released payload reads with a warning"))
    func aWarningIsAWarningAndFailsUnderWarningsFail() async throws {
        let schema = ReportRequest.schema(unknownKeys: .warn, recipient: false)
        let report = CompatibilityCheck(schema).report(Self.released)
        #expect(report.passed)
        #expect(!report.warnings.isEmpty)
        // expectCompatibility with warningsFail records each as a failure.
        let folder = try Fixtures.folder(["report-request/2.3.0/typical.json": #"{"subject": "A", "recipient": "x"}"#])
        withKnownIssue {
            _ = compatibility(
                schema, format: "report-request", samples: [], options: .strict, reading: nil, reader: nil, olderReadersMayRefuse: [:],
                oldestSupported: nil, verify: nil, warningsFail: true, root: folder, recording: nil, sourceLocation: #_sourceLocation)
        }
    }

    @Test(.failureMode("design/32", "a released payload reads, but means something else today"))
    func onlyVerifyCatchesAChangedMeaning() throws {
        // Release 1.0.0 left scroll_speed out, which meant 600; a schema that
        // forgot to pin the old default reads it as 1200, with no issue.
        var forgetful = Prefs.history
        forgetful[0] = .from(1, to: 2, .rename("scroll_speed", to: "scrollSpeed"))
        let schema = Schema.object(Prefs.self, default: Prefs(), unknownKeys: .reject, version: 4, migrations: forgetful) {
            Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)))
            Field("mode", \.mode, .enumeration(Mode.self))
            Field("network", \.network, Net.schema)
        }
        let set = try PrefsCapsule.set()
        #expect(CompatibilityCheck(schema).report(set).failures.isEmpty, "decoding cannot see it")
        var check = CompatibilityCheck(schema)
        check.verify = { fixture, value in
            value == PrefsCapsule.expected[fixture.release.description] ? [] : ["it read as \(value.scrollSpeed) px/s"]
        }
        let report = check.report(set)
        #expect(report.failures.map(\.code) == ["verify"])
        #expect(report.failures.first?.release == release("1.0.0"))
        #expect(report.failures.first?.message == "it read as 1200.0 px/s")
    }

    @Test(.failureMode("design/32", "a payload file is not JSON"))
    func aPayloadThatIsNotJSONFailsAsAWholeWithItsPosition() throws {
        let set = CompatibilitySet(format: "report-request", fixtures: [fixture("2.3.0", "torn", "{\"subject\": \"A\",\n  \"copies\": }")])
        let report = CompatibilityCheck(ReportRequest.schema()).report(set)
        let finding = try #require(report.failures.first)
        #expect(finding.path == nil, "the whole document")
        #expect(finding.code == "parse_error")
        #expect(finding.location == "2:13")
    }

    @Test(.failureMode("design/32", "a Codable type no longer decodes a payload"))
    func aCodableTypeThatNoLongerDecodesIsOneFailureWithItsCodingPath() throws {
        struct Receipt: Codable, Sendable, Equatable {
            var total: Int
            var lines: [Line]
            struct Line: Codable, Sendable, Equatable { var amount: Int }
        }
        let set = CompatibilitySet(format: "receipt", fixtures: [
            fixture("1.0.0", "old", #"{"total": 3, "lines": [{"amount": "3"}]}"#),
        ])
        let report = CompatibilityCheck(Schema<Receipt>.codable(Receipt.self)).report(set)
        #expect(report.failures.count == 1)
        let finding = try #require(report.failures.first)
        #expect(finding.message.contains("lines"), "the decoder's coding path: \(finding.message)")
        #expect(finding.message.contains("amount"))
    }

    // MARK: What today writes, read by older readers

    static let readers = CompatibilitySet(
        format: "report-request",
        fixtures: [fixture("2.3.0", "typical", #"{"subject": "A", "recipient": "x"}"#)],
        readers: [release("2.3.0"): ReportRequest.schema().jsonSchema()])

    @Test(.failureMode("design/32", "today's document has a key an older reader refuses"))
    func aNewKeyAnOldReaderRefusesIsAFailure() throws {
        let today = Schema.object(ReportRequest.self, default: ReportRequest(), unknownKeys: .reject) {
            Field("subject", \.subject, .string(.length(1...80)))
            Field("recipient", \.recipient, .string())
            Field("copies", \.copies, .int(.range(1...10)))
            Field("urgent", \.urgent, .bool)
        }
        var check = CompatibilityCheck(today)
        check.samples = [("typical", ReportRequest())]
        check.generated = 0
        let report = check.report(Self.readers)
        let finding = try #require(report.failures.first)
        #expect(finding.direction == .olderReader)
        #expect(finding.code == "additionalProperties")
        #expect(finding.path?.description == "$.urgent")
        #expect(finding.description.hasPrefix("today's sample \"typical\" read by release 2.3.0's reader (written today, read by 2.3.0): "))
    }

    @Test(.failureMode("design/32", "today's document leaves out a key an older reader requires"))
    func aKeyAnOldReaderRequiresLeftOutIsAFailure() {
        let old = ReportRequest.copiesRequired.jsonSchema()
        let today = Schema.object(ReportRequest.self, default: ReportRequest(), unknownKeys: .reject) {
            Field("subject", \.subject, .string(.length(1...80)))
            Field("recipient", \.recipient, .string())
        }
        var check = CompatibilityCheck(today)
        check.samples = [("typical", ReportRequest())]
        check.generated = 0
        let set = CompatibilitySet(format: "f", fixtures: [fixture("2.3.0", "a", #"{"subject": "A", "copies": 1}"#)], readers: [release("2.3.0"): old])
        let report = check.report(set)
        #expect(report.failures.map(\.code).contains("required"), "\(report)")
    }

    static func versioned(_ version: Int, preserving: Bool) -> Schema<Loose> {
        if preserving {
            Schema.object(Loose.self, default: Loose(), version: version, migrations: (1..<version).map { .from($0, to: $0 + 1) },
                          preservingUnknownKeysIn: \Loose.extra) {
                Field("name", \.name, .string(.length(1...40)))
            }
        } else {
            Schema.object(Loose.self, default: Loose(), unknownKeys: .reject, version: version,
                          migrations: (1..<version).map { .from($0, to: $0 + 1) }) {
                Field("name", \.name, .string(.length(1...40)))
            }
        }
    }

    @Test(.failureMode("design/32", "the version key is raised"))
    func aRaisedVersionIsRefusedByEveryOlderReaderUnlessDeclared() {
        let set = CompatibilitySet(
            format: "loose",
            fixtures: [fixture("1.0.0", "a", #"{"version": 1, "name": "n"}"#), fixture("2.0.0", "a", #"{"version": 2, "name": "n"}"#)],
            readers: [release("1.0.0"): Self.versioned(1, preserving: false).jsonSchema(), release("2.0.0"): Self.versioned(2, preserving: false).jsonSchema()])
        var check = CompatibilityCheck(Self.versioned(3, preserving: false))
        check.samples = [("now", Loose())]
        check.generated = 0
        let report = check.report(set)
        #expect(Set(report.failures.compactMap(\.release)) == [release("1.0.0"), release("2.0.0")])
        #expect(report.failures.allSatisfy { $0.code == "const" && $0.path?.description == "$.version" })
        check.olderReadersMayRefuse = [release("1.0.0"): "version 3 is read from 2.0 on", release("2.0.0"): "version 3 is read from 2.1 on"]
        #expect(check.report(set).passed, "a declared break is not a failure")
    }

    @Test(.failureMode("design/32", "an older reader that preserves unknown keys meets a newer version"))
    func aReaderThatPreservesUnknownKeysReadsANewerVersionBestEffort() {
        let set = CompatibilitySet(
            format: "loose", fixtures: [fixture("1.0.0", "a", #"{"version": 1, "name": "n"}"#)],
            readers: [release("1.0.0"): Self.versioned(1, preserving: true).jsonSchema()])
        var check = CompatibilityCheck(Self.versioned(2, preserving: true))
        check.samples = [("now", Loose())]
        check.generated = 0
        let report = check.report(set)
        #expect(report.passed)
        #expect(report.warnings.map(\.code) == ["const"])
        #expect(report.warnings.first?.message.contains("best effort") == true)
    }

    @Test(.failureMode("design/32", "a declared break's release now accepts every document"))
    func aStaleBreakIsAFailure() {
        var check = CompatibilityCheck(ReportRequest.schema())
        check.samples = [("typical", ReportRequest())]
        check.olderReadersMayRefuse = [release("2.3.0"): "it used to refuse copies", release("1.0.0"): "never recorded"]
        let report = check.report(Self.readers)
        #expect(report.failures.map(\.code) == ["stale_break", "stale_break"])
        #expect(report.failures.map(\.release) == [release("2.3.0"), release("1.0.0")])
    }

    @Test(.failureMode("design/32", "a release folder has no _schema.json"))
    func aReleaseWithNoReaderSkipsTheDirectionWithAWarning() {
        let report = CompatibilityCheck(ReportRequest.schema()).report(Self.released)
        #expect(report.passed)
        #expect(report.warnings.map(\.code) == ["no_reader"])
        #expect(report.offered == 0)
    }

    @Test(.failureMode("design/32", "a release folder has no payload"))
    func aReleaseWithNoPayloadIsAFailure() {
        let set = CompatibilitySet(format: "f", fixtures: [], readers: [release("2.3.0"): ReportRequest.schema().jsonSchema()])
        #expect(CompatibilityCheck(ReportRequest.schema()).report(set).failures.map(\.code) == ["empty_release"])
    }

    @Test(.failureMode("design/32", "an older reader's rule cannot be stated in JSON Schema"))
    func whatJSONSchemaCannotStateIsNotCheckedAndSaysSo() {
        // A Codable leaf exports {}: the older-reader direction checks nothing.
        struct Blob: Codable, Sendable { var n: Int }
        let set = CompatibilitySet(
            format: "blob", fixtures: [fixture("1.0.0", "a", #"{"n": 1}"#)], readers: [release("1.0.0"): Schema<Blob>.codable(Blob.self).jsonSchema()])
        var check = CompatibilityCheck(Schema<Blob>.codable(Blob.self))
        check.samples = [("now", Blob(n: 2))]
        let report = check.report(set)
        #expect(report.passed)
        #expect(report.warnings.map(\.code).contains("not_covered"))
        // A reader written by another tool, with a rule the validator does not evaluate.
        let foreign = JSONValue.object(["type": "object", "dependentRequired": .object(["a": .array(["b"])])])
        let other = CompatibilitySet(format: "f", fixtures: [fixture("1.0.0", "a", #"{"subject": "A"}"#)], readers: [release("1.0.0"): foreign])
        let found = CompatibilityCheck(ReportRequest.schema()).report(other)
        #expect(found.warnings.contains { $0.code == "not_covered" && $0.message.contains("dependentRequired") })
    }

    @Test(.failureMode("design/32", "a release is older than the oldest supported release"))
    func aReleaseBelowTheFloorIsReportedRetiredAndNotChecked() {
        let set = CompatibilitySet(format: "report-request", fixtures: [
            fixture("1.0.0", "ancient", #"{"subject": 7}"#),
            fixture("2.3.0", "typical", #"{"subject": "A"}"#),
        ])
        var check = CompatibilityCheck(ReportRequest.schema())
        check.oldestSupported = release("2.0.0")
        let report = check.report(set)
        #expect(report.passed, "1.0.0's payload is not read")
        #expect(report.findings.first { $0.code == "retired" }?.release == release("1.0.0"))
        #expect(report.read == 1)
        check.olderReadersMayRefuse = [release("1.0.0"): "it refused copies"]
        #expect(check.report(set).failures.map(\.code) == ["stale_break"], "a break for a retired release is not needed")
    }

    @Test func messagesAreGolden() {
        let findings = [
            CompatibilityFinding(direction: .olderWriter, severity: .failure, release: release("2.3.0"), sample: "typical",
                                 path: JSONPath.root.appending(key: "recipient"), code: "unknown_key", message: "not a key", location: "1:2"),
            CompatibilityFinding(direction: .olderReader, severity: .failure, release: release("2.3.0"), sample: "tuned",
                                 path: JSONPath.root.appending(key: "network").appending(key: "retries"), code: "additionalProperties",
                                 message: "not a key this reader allows"),
            CompatibilityFinding(direction: .fixtures, severity: .failure, release: release("2.2.0"), sample: nil, path: nil,
                                 code: "stale_break", message: "remove it"),
            CompatibilityFinding(direction: .fixtures, severity: .failure, release: nil, sample: nil, path: nil, code: "no_release",
                                 message: "nothing recorded"),
        ]
        #expect(findings.map(\.description) == [
            "release 2.3.0's sample \"typical\" (written by 2.3.0, read by today's schema): 1:2 $.recipient: [unknown_key] not a key",
            "today's sample \"tuned\" read by release 2.3.0's reader (written today, read by 2.3.0): $.network.retries: [additionalProperties] not a key this reader allows",
            "release 2.2.0's fixtures: [stale_break] remove it",
            "the fixtures: [no_release] nothing recorded",
        ])
    }
}

extension ReportRequest {
    var urgent: Bool {
        get { false }
        set { _ = newValue }
    }
}

/// Folders of fixtures in a temporary directory.
enum Fixtures {
    static func folder(_ files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appending(path: "stoic-compatibility-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path()
    }
}

/// The loader and record mode, against folders on disk.
@Suite("Schema compatibility fixtures")
struct CompatibilityFixtureTests {
    @Test(.failureMode("design/32", "a release folder's name is not a version"))
    func aMisnamedFolderIsAFailure() throws {
        let root = try Fixtures.folder([
            "f/2.3.0/a.json": #"{"subject": "A"}"#, "f/latest/a.json": #"{"subject": "A"}"#,
            "f/2.3.0/_notes.json": "reserved", "f/2.3.0/README.md": "not a payload",
        ])
        let set = try loadCompatibilitySet(format: "f", from: root)
        #expect(set.fixtures.map(\.name) == ["a"], "reserved and non-JSON files are not payloads")
        #expect(set.problems.map(\.code) == ["not_a_version"])
        #expect(set.problems.first?.message.contains("latest") == true)
        #expect(!CompatibilityCheck(ReportRequest.schema()).report(set).passed)
    }

    @Test(.failureMode("design/32", "a format has no folder at all"))
    func aFormatWithNoFolderIsAFailure() throws {
        let set = try loadCompatibilitySet(format: "never", from: try Fixtures.folder([:]))
        #expect(CompatibilityCheck(ReportRequest.schema()).report(set).failures.map(\.code) == ["no_release"])
    }

    @Test(.failureMode("design/32", "a payload is added to a release by hand"))
    func aCapturedPayloadIsReadLikeARecordedOne() throws {
        let root = try Fixtures.folder([
            "f/2.3.0/typical.json": #"{"subject": "A"}"#,
            "f/2.3.0/captured-ios-17.json": #"{"subject": "A", "recipient": "x", "copies": 99}"#,
        ])
        let report = CompatibilityCheck(ReportRequest.schema()).report(try loadCompatibilitySet(format: "f", from: root))
        #expect(report.read == 2)
        #expect(report.failures.map { "\($0.sample ?? "") \($0.code)" } == ["captured-ios-17 out_of_range"])
    }

    @Test(.failureMode("design/32", "recording a release not yet recorded"))
    func recordingWritesTheSamplesAndTheReaderAndFailsTheRun() async throws {
        let root = try Fixtures.folder([:])
        withKnownIssue("a recording run fails, so it is never mistaken for a pass") {
            _ = record(root, "2.4.0")
        }
        let folder = URL(filePath: root).appending(path: "report-request/2.4.0")
        let typical = try String(contentsOf: folder.appending(path: "typical.json"), encoding: .utf8)
        #expect(typical == "{\n  \"subject\": \"Attendance\",\n  \"recipient\": \"\",\n  \"copies\": 1\n}\n", "pretty, stable bytes")
        let reader = try JSONParser().parseValue(Array(try Data(contentsOf: folder.appending(path: "_schema.json"))))
        #expect(reader == ReportRequest.schema().jsonSchema())
        // What was recorded is what the next check reads.
        let report = CompatibilityCheck(ReportRequest.schema()).report(try loadCompatibilitySet(format: "report-request", from: root))
        #expect(report.passed)
        #expect(report.read == 1)
    }

    @Test(.failureMode("design/32", "recording a release already recorded, with the same bytes"))
    func reRecordingTheSameBytesWritesNothingAndPasses() async throws {
        let root = try Fixtures.folder([:])
        withKnownIssue { _ = record(root, "2.4.0") }
        let report = record(root, "2.4.0")   // no issue: nothing was written
        #expect(report.findings.isEmpty)
    }

    @Test(.failureMode("design/32", "recording a release already recorded, with other bytes"))
    func reRecordingOtherBytesIsRefused() async throws {
        let root = try Fixtures.folder(["report-request/2.4.0/typical.json": #"{"subject": "Something else"}"#])
        withKnownIssue {
            let report = record(root, "2.4.0")
            #expect(report.findings.map(\.code) == ["rewritten"])
        }
        let kept = try String(contentsOf: URL(filePath: root).appending(path: "report-request/2.4.0/typical.json"), encoding: .utf8)
        #expect(kept == #"{"subject": "Something else"}"#, "a released promise is not rewritten")
    }

    func record(_ root: String, _ release: String) -> CompatibilityReport {
        compatibility(
            ReportRequest.schema(), format: "report-request", samples: [("typical", ReportRequest())], options: .strict, reading: nil,
            reader: nil, olderReadersMayRefuse: [:], oldestSupported: nil, verify: nil, warningsFail: false, root: root,
            recording: release, sourceLocation: #_sourceLocation)
    }

    /// The capsule, moved to fixtures, passes; with one migration step's
    /// operation deleted, it fails at the release and path that step served.
    @Test func theTimeCapsuleAsFixturesCatchesAMissingMigration() throws {
        let set = try PrefsCapsule.set()
        var check = CompatibilityCheck(Prefs.schema)
        check.verify = { fixture, value in value == PrefsCapsule.expected[fixture.release.description] ? [] : ["it read as \(value)"] }
        #expect(check.report(set).failures.isEmpty)
        var broken = Prefs.history
        broken[1] = .from(2, to: 3, .mapEnum("mode", ["fast": "turbo"]), .delete("legacy", example: true), .setIfAbsent("network.timeoutSeconds", 30))   // the move is gone
        let schema = Schema.object(Prefs.self, default: Prefs(), unknownKeys: .reject, version: 4, migrations: broken) {
            Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)))
            Field("mode", \.mode, .enumeration(Mode.self))
            Field("network", \.network, Net.schema)
        }
        let report = CompatibilityCheck(schema).report(set)
        let failed = report.failures.map { "\($0.release?.description ?? "") \($0.path?.description ?? "") \($0.code)" }
        #expect(failed.contains("1.0.0 $.hosts unknown_key"), "\(failed)")
        #expect(failed.contains("1.1.0 $.hosts unknown_key"), "the releases that step served: \(failed)")
    }

    /// Every way the exporter writes a document: the drafts, closed objects,
    /// and a settings file's header beside the schema's own keys.
    static let exportOptions: [(name: String, options: JSONSchemaOptions)] = [
        ("2020-12", JSONSchemaOptions()), ("closed", JSONSchemaOptions(closesObjects: true)),
        ("draft-07", JSONSchemaOptions(draft: .draft07)), ("draft-07 closed", JSONSchemaOptions(draft: .draft07, closesObjects: true)),
        ("header", JSONSchemaOptions(extraRootProperties: ["$schema": .object(["type": "string"])])),
    ]

    /// Exported, in every way the exporter writes, for each schema of every
    /// kind the tests hold: objects (versioned, migrated, preserving, closed),
    /// nested and recursive objects, unions, decimals, transforms and custom
    /// leaves.
    static func exported() -> [(name: String, document: JSONValue)] {
        let schemas: [(String, (JSONSchemaOptions) -> JSONValue)] = [
            ("settings", { Settings.schema.jsonSchema(options: $0) }), ("network", { Network.schema.jsonSchema(options: $0) }),
            ("prefs", { Prefs.schema.jsonSchema(options: $0) }), ("net", { Net.schema.jsonSchema(options: $0) }),
            ("request", { ReportRequest.schema().jsonSchema(options: $0) }),
            ("preserving", { CompatibilityTests.versioned(3, preserving: true).jsonSchema(options: $0) }),
            ("menu", { Menu.schema.jsonSchema(options: $0) }), ("shape", { Shape.schema.jsonSchema(options: $0) }),
            ("expression", { Expression.schema.jsonSchema(options: $0) }), ("canvas", { Canvas.schema.jsonSchema(options: $0) }),
            ("prices", { Prices.schema.jsonSchema(options: $0) }), ("chain", { Chain.schema.jsonSchema(options: $0) }),
            ("graphed", { Graphed.schema.jsonSchema(options: $0) }), ("timestamp", { Timestamp.schema.jsonSchema(options: $0) }),
            ("endpoint", { Endpoint.schema.jsonSchema(options: $0) }), ("frequency", { Frequency.schema.jsonSchema(options: $0) }),
        ]
        return schemas.flatMap { name, export in exportOptions.map { ("\(name), \($0.name)", export($0.options)) } }
    }

    /// The validator covers exactly what StoicSchema exports (design/32): no
    /// exported document holds a keyword it does not evaluate.
    @Test func theValidatorEvaluatesEveryKeywordTheExporterWrites() {
        for (name, document) in Self.exported() {
            #expect(JSONSchemaValidator(document).uncoveredKeywords.isEmpty, "\(name)")
        }
    }

    /// `violations` is empty exactly when `accepts` is true, on the documents
    /// each schema's own generator makes and mutates.
    @Test func violationsAgreeWithAcceptsOnEveryGeneratedDocument() throws {
        func agree<Value: Sendable>(_ name: String, _ schema: Schema<Value>) throws {
            let generator = SchemaGenerator(schema)
            for (option, options) in Self.exportOptions {
                let validator = JSONSchemaValidator(schema.jsonSchema(options: options))
                var random = SplitMix(seed: 11)
                for index in 0..<120 {
                    let base = try generator.sample(using: &random).document
                    let candidate = index % 2 == 0 ? base : (generator.mutation(of: base, using: &random)?.document ?? base)
                    #expect(
                        validator.violations(candidate).isEmpty == validator.accepts(candidate),
                        "\(name), \(option) #\(index): \(candidate.encodedString())")
                }
            }
        }
        try agree("prefs", Prefs.schema)
        try agree("net", Net.schema)
        try agree("request", ReportRequest.schema())
        try agree("preserving", CompatibilityTests.versioned(3, preserving: true))
        try agree("settings", Settings.schema)
        try agree("shape", Shape.schema)
        try agree("canvas", Canvas.schema)
        try agree("menu", Menu.schema)
    }
}

/// SplitMix64, for the agreement check.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Release versions")
struct ReleaseVersionTests {
    @Test func theOrderIsSemanticVersioningsPrecedence() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1",
                       "1.0.0", "1.0.1", "2.9.1", "2.10", "2.10.0.1", "10.0.0"].map(release)
        for (index, left) in ordered.enumerated() {
            for (other, right) in ordered.enumerated() {
                #expect((left < right) == (index < other), "\(left) < \(right)")
            }
        }
        #expect(release("2.4") == release("2.4.0"), "a missing number is 0")
        #expect(release("2.4").description == "2.4", "it reads back as it was written")
    }

    @Test func textThatIsNotAVersionIsRefused() {
        for text in ["", "latest", "1.", ".1", "1.2.3.4.5", "v1.2", "1.2-", "1.2-be ta", "1..2", "-1"] {
            #expect(ReleaseVersion(text) == nil, "\(text)")
        }
    }

    @Test func theOrderIsTotal() {
        var random = SplitMix(seed: 3)
        let versions = (0..<200).map { _ -> ReleaseVersion in
            let numbers = (0..<Int.random(in: 1...4, using: &random)).map { _ in String(Int.random(in: 0..<4, using: &random)) }
            let pre = Bool.random(using: &random) ? "-" + ["alpha", "beta", "1", "rc.2"].randomElement(using: &random)! : ""
            return release(numbers.joined(separator: ".") + pre)
        }
        for a in versions {
            for b in versions {
                let relations = [a < b, a == b, b < a].count { $0 }
                #expect(relations == 1, "\(a) and \(b)")
            }
        }
    }
}

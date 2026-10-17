import Foundation
import Observation
import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Synchronization
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension JSONPath.Component: ExpressibleByStringLiteral {
    /// A key, so a test can write `["editor", "font"]` for a path.
    init(stringLiteral value: String) { self = .key(value) }
}

/// A schema shaped like an app's whose file a person edits: a key that was
/// renamed (`hyper` became `lode`), a nested object, an array.
struct LodePrefs: Sendable, Equatable {
    struct Editor: Sendable, Equatable {
        var font = 12
        var theme = "dark"
    }

    var lode = "alpha"
    var speed = 600
    var editor = Editor()
    var hosts: [String] = []

    static let editorSchema = Schema.object(Editor.self, default: Editor()) {
        Field("font", \.font, .int(.range(6...72)))
        Field("theme", \.theme, .string(.length(1...20)))
    }

    /// Version 2: `hyper` became `lode`; `velocity` is an old spelling of `speed`.
    static let schema = Schema.object(
        LodePrefs.self, default: LodePrefs(), version: 2, migrations: [.from(1, to: 2, .rename("hyper", to: "lode"))]
    ) {
        Field("lode", \.lode, .string(.length(1...20)))
        Field("speed", \.speed, .int(.range(100...4000)), aliases: ["velocity"])
        Field("editor", \.editor, LodePrefs.editorSchema)
        Field("hosts", \.hosts, .array(of: .string()))
    }
}

/// Everything the store does to the file a person edits, on a simulated disk.
@Suite("Settings store: a file a person edits")
struct HandEditedTests {
    static let path = "/d/lodestar.json"

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    /// Puts `text` where the person's file is, as an editor that saves by rename does.
    static func place(_ text: String, on disk: some FileSystem, at path: String = HandEditedTests.path) throws {
        try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(Array(text.utf8), to: path)
    }

    static func place(_ bytes: [UInt8], on disk: some FileSystem) throws {
        try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(bytes, to: path)
    }

    static func text(_ disk: SimulatedFileSystem, at path: String = HandEditedTests.path) -> String? {
        disk.contents(of: path).map { String(decoding: $0, as: UTF8.self) }
    }

    static func open(
        _ disk: some FileSystem, options: SettingsStore<LodePrefs>.Options = .init()
    ) throws -> SettingsStore<LodePrefs> {
        try SettingsStore.open(at: path, schema: LodePrefs.schema, format: .handEdited, fileSystem: disk, options: options)
    }

    static func header(_ header: SettingsFileHeader = ["$schema": "lodestar-schema.json"]) -> SettingsStore<LodePrefs>.Options {
        .init(handEdited: HandEditedOptions(fileHeader: header))
    }

    /// What must never happen to a hand-edited file: moved, or a copy left beside it.
    static func expectNothingBesideTheFile(_ disk: SimulatedFileSystem, sourceLocation: Testing.SourceLocation = #_sourceLocation) throws {
        let names = try disk.list(directory: "/d")
        #expect(
            names.allSatisfy { !$0.contains(".corrupt") && !$0.hasSuffix(".previous") && !$0.hasSuffix(".tmp") },
            "beside the file: \(names)", sourceLocation: sourceLocation)
    }

    // MARK: A file that cannot be read is never destroyed

    static let garbage = "{\n  \"speed\": 700,\n  \"lode\": ,\n}\n"

    @Test(.failureMode("design/18", "the hand-edited file is not JSON on the first load"))
    func anUnparsableFileOnFirstLoadGivesTheDefaultsAndAnIssueAtTheLineAndColumn() async throws {
        let disk = try Self.disk()
        try Self.place(Self.garbage, on: disk)
        let events = RecordingInstrumentation()
        let settings = try await withAmbient({ $0.instrumentation = events }) { try Self.open(disk) }

        #expect(settings.value == LodePrefs())
        #expect(settings.source == .defaults(.unusable))
        guard case .unparsable(let issues)? = settings.fileProblem else {
            Issue.record("expected an unparsable file, got \(String(describing: settings.fileProblem))")
            return
        }
        #expect(settings.issues == issues)
        let issue = try #require(issues.first)
        #expect(issue.code == .parseError)
        // `"lode": ,` is on line 3: the value that is missing is where the comma is (column 11).
        #expect(issue.source?.start.line == 3)
        #expect(issue.source?.start.column == 11)
        #expect(settings.fileProblem?.location == issue.source?.start)
        #expect(issue.description.hasPrefix("3:11 "), "the shape an editor links to: \(issue)")

        #expect(Self.text(disk) == Self.garbage, "the file is exactly what the person wrote")
        try Self.expectNothingBesideTheFile(disk)
        let unparsed = try #require(events.events(named: "settings.unparsed").first)
        #expect(unparsed["reason"]?.description == "unparsable")
        #expect(unparsed["kept"]?.description == "defaults")
        #expect(unparsed["line"]?.description == "3")
        #expect(unparsed["column"]?.description == "11")
        #expect(events.events(named: "settings.reset").isEmpty, "nothing was quarantined")
    }

    @Test(.failureMode("design/18", "the hand-edited file is not JSON on a reload"))
    func aReloadThatFindsGarbageKeepsTheLastGoodValueAndTheNextOneThatFindsItFixedClearsTheProblem() async throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            let settings = try Self.open(disk)
            #expect(settings.value.speed == 700)
            #expect(settings.fileProblem == nil)

            try Self.place(Self.garbage, on: disk)
            try settings.reload()
            #expect(settings.value.speed == 700, "the last good value stands")
            #expect(settings.source == .file)
            #expect(settings.fileProblem?.location?.line == 3)
            #expect(settings.issues.first?.code == .parseError)
            #expect(Self.text(disk) == Self.garbage)
            let unparsed = try #require(events.events(named: "settings.unparsed").first)
            #expect(unparsed["kept"]?.description == "last_good")

            // The same garbage again says nothing more.
            try settings.reload()
            #expect(events.events(named: "settings.unparsed").count == 1)

            try Self.place(#"{"version": 2, "speed": 800}"#, on: disk)
            try settings.reload()
            #expect(settings.value.speed == 800)
            #expect(settings.fileProblem == nil)
            #expect(settings.issues.isEmpty)
            try Self.expectNothingBesideTheFile(disk)
        }
    }

    @Test(.failureMode("design/18", "an update meets a hand-edited file that cannot be read"))
    func anUpdateOfAnUnparsableFileThrowsAndLeavesItByteForByte() throws {
        let disk = try Self.disk()
        try Self.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        let before = disk.contents(of: Self.path)

        let error = #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        guard case .fileUnusable(.unparsable(let issues))? = error else {
            Issue.record("expected fileUnusable, got \(String(describing: error))")
            return
        }
        #expect(issues.first?.source?.start.line == 3)
        #expect(disk.contents(of: Self.path) == before)
        try Self.expectNothingBesideTheFile(disk)
        #expect(settings.value == LodePrefs(), "and nothing was published")
    }

    @Test(.failureMode("design/18", "an update meets a hand-edited file that cannot be read"))
    func anUpdateAfterAGoodLoadThatFindsTheFileBrokenAlsoWritesNothing() async throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        // Broken behind the store's back: no reload has seen it.
        try Self.place("{ \"speed\": ", on: disk)
        let before = disk.contents(of: Self.path)
        await #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) {
            try await settings.coordinatedUpdate { $0.speed = 900 }
        }
        #expect(disk.contents(of: Self.path) == before)
        #expect(settings.fileProblem != nil, "the update's own read reported it")
        #expect(settings.value.speed == 700)
    }

    @Test(.failureMode("design/18", "the hand-edited file is not UTF-8"))
    func aFileThatIsNotUTF8IsLeftAloneToo() throws {
        let disk = try Self.disk()
        let latin1: [UInt8] = Array(#"{"lode": ""#.utf8) + [0xE9, 0xFF] + Array(#""}"#.utf8)
        try Self.place(latin1, on: disk)
        let settings = try Self.open(disk)
        #expect(settings.value == LodePrefs())
        guard case .unparsable(let issues)? = settings.fileProblem else {
            Issue.record("expected an unparsable file, got \(String(describing: settings.fileProblem))")
            return
        }
        #expect(issues.first?.source?.start.line == 1, "even for bytes that are not text, there is a place: \(issues)")
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        #expect(disk.contents(of: Self.path) == latin1)
        try Self.expectNothingBesideTheFile(disk)
    }

    @Test(.failureMode("design/18", "the hand-edited file cannot be read"))
    func aFileThatCannotBeReadIsAProblemNotAThrowAndNotAReason() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let before = disk.contents(of: Self.path)
        disk.inject(EACCES, on: .read, count: 100)
        let settings = try Self.open(disk)   // does not throw
        #expect(settings.value == LodePrefs())
        #expect(settings.source == .defaults(.unusable))
        guard case .unreadable(let readError)? = settings.fileProblem else {
            Issue.record("expected an unreadable file, got \(String(describing: settings.fileProblem))")
            return
        }
        #expect(readError.kind == .permissionDenied)
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        try settings.reload()
        #expect(settings.fileProblem != nil, "still tried again, and still unreadable")

        disk.clearFaults()
        #expect(disk.contents(of: Self.path) == before, "never touched")
        try settings.reload()
        #expect(settings.fileProblem == nil)
        #expect(settings.value.speed == 700)
        #expect(settings.source == .file)
        try Self.expectNothingBesideTheFile(disk)
    }

    @Test func aFileOfTheWrongShapeIsUnusableToo() throws {
        let disk = try Self.disk()
        try Self.place(#"["not", "settings"]"#, on: disk)
        let settings = try Self.open(disk)
        #expect(settings.source == .defaults(.unusable))
        guard case .unparsable(let issues)? = settings.fileProblem else {
            Issue.record("expected an unparsable file, got \(String(describing: settings.fileProblem))")
            return
        }
        #expect(issues.first?.code == .typeMismatch)
        #expect(issues.first?.source?.start == StoicJSON.SourceLocation(offset: 0, line: 1, column: 1))
        #expect(Self.text(disk) == #"["not", "settings"]"#)
        try Self.expectNothingBesideTheFile(disk)
    }

    @Test(.failureMode("design/18", "the document is a newer version"))
    func aNewerHandEditedFileIsReadOnlyAndLeftAsItIs() throws {
        let disk = try Self.disk()
        let newer = #"{"version": 3, "speed": 1500, "hyperdrive": true}"#
        try Self.place(newer, on: disk)
        let settings = try Self.open(disk)
        guard case .newerFormat(let version) = settings.source else {
            Issue.record("expected newerFormat, got \(settings.source)")
            return
        }
        #expect(version == 3)
        #expect(settings.fileProblem == nil, "not unusable: intact, and the newer app's")
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        #expect(Self.text(disk) == newer)
        try Self.expectNothingBesideTheFile(disk)
    }

    @Test(.failureMode("design/18", "the write fails (disk full, read-only volume)"))
    func aFailedWriteOfAHandEditedFileChangesNothing() throws {
        let disk = try Self.disk()
        let text = #"{"version": 2, "speed": 700}"#
        try Self.place(text, on: disk)
        let settings = try Self.open(disk)
        disk.inject(ENOSPC, on: .write)
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        #expect(Self.text(disk) == text)
        #expect(settings.value.speed == 700)
        try Self.expectNothingBesideTheFile(disk)
        disk.clearFaults()
        try settings.update { $0.speed = 900 }
        #expect(try Self.open(disk).value.speed == 900)
    }

    @Test func aSettingsFileThatIsDeletedGivesTheDefaultsOnReload() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        try disk.remove(Self.path)
        try settings.reload()
        #expect(settings.value == LodePrefs())
        #expect(settings.source == .defaults(.missing))
        #expect(settings.fileProblem == nil)
    }

    @Test func noEventCarriesASettingsValue() async throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "lode": "SECRET-LODE", "speed": 99999, "hosts": }"#, on: disk)
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            let settings = try Self.open(disk)
            _ = try? settings.update { $0.speed = 900 }
            try Self.place(#"{"version": 2, "lode": "SECRET-LODE", "speed": 99999}"#, on: disk)
            try settings.reload()
            _ = try settings.update { $0.speed = 900 }
        }
        #expect(!events.events.isEmpty)
        for event in events.events {
            #expect(!"\(event)".contains("SECRET"), "\(event.name) carries a value: \(event)")
        }
    }

    // MARK: Issues point into the person's text

    @Test(.failureMode("design/18", "an issue is found in a hand-edited file"))
    func issuesCarryTheRangeOfTheKeyOrValueInThePersonsText() throws {
        let disk = try Self.disk()
        let text = """
        {
          // a comment
          "version": 2,
          "speed": 99999,
          "lod": "x",
          "editor": { "font": "big" },
          "hosts": ["a", 7]
        }
        """
        try Self.place(text, on: disk)
        let settings = try Self.open(disk)
        #expect(settings.fileProblem == nil)
        func source(_ code: IssueCode, _ path: JSONPath) throws -> SourceRange {
            let issue = try #require(settings.issues.first { $0.code == code && $0.path == path }, "\(code) at \(path) in \(settings.issues)")
            return try #require(issue.source, "no range for \(issue)")
        }
        // A value out of range: the number.
        let speed = try source(.outOfRange, ["speed"])
        #expect((speed.start.line, speed.start.column, speed.end.column) == (4, 12, 17))
        // An unknown key: the key, with the name it was probably meant to be.
        let unknown = try source(.unknownKey, ["lod"])
        #expect((unknown.start.line, unknown.start.column, unknown.end.column) == (5, 3, 8))
        #expect(settings.issues.first { $0.code == .unknownKey }?.suggestion == "lode")
        // A value of the wrong type, below a nested object.
        let font = try source(.typeMismatch, ["editor", "font"])
        #expect((font.start.line, font.start.column, font.end.column) == (6, 23, 28))
        // An element of an array.
        let element = try source(.typeMismatch, ["hosts", .index(1)])
        #expect((element.start.line, element.start.column) == (7, 18))
        // The repaired field says so, and where.
        let repaired = settings.issues.filter { $0.severity == .repaired }
        #expect(repaired.allSatisfy { $0.source != nil })
        #expect(repaired.contains { $0.path == ["speed"] })
        // And the range is the text itself.
        let document = try JSONDocument(parsing: text, options: .jsonc)
        #expect(document.text(in: speed) == "99999")
        #expect(document.text(in: unknown) == "\"lod\"")
    }

    /// design/06: a migrated object has been rewritten, so its issues point at
    /// the whole object, not at a line that may now mean something else.
    @Test(.failureMode("design/18", "an issue is found in a hand-edited file"))
    func aMigratedFilesIssuesPointAtTheWholeMigratedObjectNotAtALineThatMayMeanSomethingElse() throws {
        let disk = try Self.disk()
        try Self.place("{\n  \"version\": 1,\n  \"hyper\": \"\"\n}", on: disk)   // an empty `lode`: out of its length range
        let settings = try Self.open(disk)
        #expect(settings.value.lode == "alpha", "repaired to its default")
        #expect(settings.issues.contains { $0.code == .migrated })
        let issue = try #require(settings.issues.first { $0.path == ["lode"] && $0.severity == .repaired })
        let range = try #require(issue.source)
        #expect((range.start.line, range.start.column, range.end.line) == (1, 1, 4))
    }

    // MARK: Migrations and old spellings

    @Test(.failureMode("design/18", "the hand-edited file has an old spelling or version"))
    func aRenamedKeyIsReadThroughTheMigrationAndWrittenWithItsNewNameOnTheNextUpdateNotOnLoad() throws {
        let disk = try Self.disk()
        let old = "{\n  // from before the rename\n  \"version\": 1,\n  \"hyper\": \"beta\",\n  \"velocity\": 900\n}\n"
        try Self.place(old, on: disk)
        let settings = try Self.open(disk)
        #expect(settings.value.lode == "beta", "read through the migration")
        #expect(settings.value.speed == 900, "and through the alias")
        #expect(settings.issues.contains { $0.code == .migrated })
        #expect(Self.text(disk) == old, "not written back on load")

        try settings.update { $0.hosts = ["h"] }
        let written = try #require(Self.text(disk))
        #expect(written.contains("\"lode\": \"beta\""))
        #expect(!written.contains("hyper"), "the new name only")
        #expect(!written.contains("velocity"))
        #expect(written.contains("\"speed\": 900"))
        #expect(!written.contains("comment"), "comments are not kept: the documented price of an update")
        let reopened = try Self.open(disk)
        #expect(reopened.value == LodePrefs(lode: "beta", speed: 900, hosts: ["h"]))
        #expect(reopened.issues.isEmpty)
    }

    // MARK: Sparse, canonical writes

    static let tangled = """
    {
      // written by hand, in an order of its own
      "zeta": 1.0,
      "hosts": ["b", "a"],
      "alpha": {"y": 2, "x": [1, {"d": 1, "c": 2.50}]},
      "$schema": "somewhere-else.json",
      "editor": {"ligatures": "on", "theme": "light", "font": 14},
      "speed": 900,
      "version": 2,
      "lode": "beta"
    }
    """

    /// The canonical layout of `tangled` once `speed` goes back to its default.
    static let canonicalTangled = """
    {
      "$schema": "lodestar-schema.json",
      "version": 2,
      "lode": "beta",
      "editor": {
        "font": 14,
        "theme": "light",
        "ligatures": "on"
      },
      "hosts": [
        "b",
        "a"
      ],
      "alpha": {
        "x": [
          1,
          {
            "c": 2.5,
            "d": 1
          }
        ],
        "y": 2
      },
      "zeta": 1
    }

    """

    @Test(.failureMode("design/18", "a hand-edited file is written"))
    func theFileIsWrittenSparseAndCanonicalWithItsHeaderFirstAndTheUnknownKeysAlphabetical() throws {
        let disk = try Self.disk()
        try Self.place(Self.tangled, on: disk)
        let settings = try Self.open(disk, options: Self.header())
        #expect(
            settings.issues.filter { $0.code == .unknownKey }.map(\.path) == [["zeta"], ["alpha"], ["editor", "ligatures"]],
            "the header is not an unknown key")
        try settings.update { $0.speed = 600 }   // back to the default: left out
        #expect(Self.text(disk) == Self.canonicalTangled)
    }

    @Test(.failureMode("design/18", "a hand-edited file is written"))
    func nothingThatEqualsItsDefaultIsWrittenAndNoEmptyObjectIsLeftBehind() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk, options: Self.header())
        try settings.update { $0.editor.font = 20 }
        #expect(Self.text(disk) == """
        {
          "$schema": "lodestar-schema.json",
          "version": 2,
          "editor": {
            "font": 20
          }
        }

        """)
        try settings.update { $0.editor.font = 12 }   // the object's last non-default member goes
        #expect(Self.text(disk) == """
        {
          "$schema": "lodestar-schema.json",
          "version": 2
        }

        """)
    }

    @Test(.failureMode("design/18", "two writers hold the same value"))
    func twoWritersWithTheSameValueWriteTheSameBytes() throws {
        let one = """
        {"zeta": 1, "alpha": {"b": 1.0, "a": [3, 2]}, "speed": 900, "hosts": ["x"], "lode": "beta", "version": 2,
         "editor": {"theme": "light", "other": true}}
        """
        let other = """
        // another tool's order, spacing and number spelling
        {
          "editor": { "other": true, "theme": "light" },
          "alpha": { "a": [3, 2], "b": 1 },
          "version": 2,
          "lode": "beta",
          "hosts": [ "x" ],
          "speed": 9e2,
          "zeta": 1.00
        }
        """
        var written: [[UInt8]] = []
        for text in [one, other] {
            let disk = try Self.disk()
            try Self.place(text, on: disk)
            let settings = try Self.open(disk, options: Self.header())
            try settings.update { $0.speed += 1 }   // the same change
            try settings.update { $0.speed -= 1 }
            written.append(try #require(disk.contents(of: Self.path)))
        }
        #expect(written[0] == written[1], "\(String(decoding: written[0], as: UTF8.self))\n---\n\(String(decoding: written[1], as: UTF8.self))")
    }

    @Test(.failureMode("design/18", "a hand-edited file is written"))
    func theSourceOrderLayoutKeepsTheOrderTheFileHad() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "zeta": 1.0, "alpha": {"y": 2, "x": 1}, "speed": 900}"#, on: disk)
        let options = SettingsStore<LodePrefs>.Options(
            handEdited: HandEditedOptions(fileHeader: ["$schema": "s.json"], layout: .sourceOrder))
        let settings = try Self.open(disk, options: options)
        try settings.update { $0.lode = "beta" }
        #expect(Self.text(disk) == """
        {
          "$schema": "s.json",
          "version": 2,
          "lode": "beta",
          "speed": 900,
          "zeta": 1.0,
          "alpha": {
            "y": 2,
            "x": 1
          }
        }
        """)
    }

    @Test(.failureMode("design/18", "a hand-edited file has a file header"))
    func theHeaderIsWrittenFirstEveryTimeIgnoredOnReadAndNeverCarried() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 900, "$schema": "old.json", "mine": 1}"#, on: disk)
        let options = Self.header(["$schema": "new.json", "note": ["a", "b"]])
        let settings = try Self.open(disk, options: options)
        #expect(settings.issues.map(\.path) == [["mine"]], "only `mine` is an unknown key: the header's keys are not")
        try settings.update { $0.lode = "beta" }
        let text = try #require(Self.text(disk))
        #expect(text.hasPrefix("{\n  \"$schema\": \"new.json\",\n  \"note\": [\n    \"a\",\n    \"b\"\n  ],\n  \"version\": 2,"))
        #expect(!text.contains("old.json"))
        #expect(text.components(separatedBy: "$schema").count == 2)
        #expect(try Self.open(disk, options: options).issues.map(\.path) == [["mine"]], "read back: still ignored on read")
    }

    @Test(.failureMode("design/18", "a hand-edited file has a file header"))
    func aHeaderThatNamesASettingOrMeetsASchemaThatRejectsUnknownKeysIsRefused() throws {
        let disk = try Self.disk()
        for key in ["speed", "velocity", "version"] {
            let error = #expect(throws: StoreError.self) { try Self.open(disk, options: Self.header([key: 1])) }
            #expect(error?.kind == .invalidArgument, "\(key)")
        }
        let strict = Schema.object(Prefs.self, default: Prefs(), unknownKeys: .reject) {
            Field("speed", \.speed, .int(.range(100...4000)))
        }
        let error = #expect(throws: StoreError.self) {
            try SettingsStore.open(
                at: Self.path, schema: strict, format: .handEdited, fileSystem: disk,
                options: SettingsStore<Prefs>.Options(handEdited: HandEditedOptions(fileHeader: ["$schema": "s.json"])))
        }
        #expect(error?.kind == .invalidArgument)
        // No header, no objection.
        _ = try SettingsStore.open(at: Self.path, schema: strict, format: .handEdited, fileSystem: disk)
    }

    // MARK: The file is the person's

    @Test func aHandEditedUpdateKeepsOnlyOneGeneration() throws {
        let disk = try Self.disk()
        try Self.place(#"{"speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        try settings.update { $0.speed = 800 }
        try settings.update { $0.speed = 900 }
        #expect(try disk.list(directory: "/d") == ["lodestar.json", "lodestar.json.lock"], "no .previous, no temporary")
        #expect(try disk.permissions(of: Self.path) == 0o644, "the mode the file had")
    }

    // MARK: Updates read the file again, under a lock

    @Test(.failureMode("design/18", "a hand-edited file was changed since the store read it"))
    func anUpdateAppliesItsChangeToTheFileAsItIsNowNotAsItWasRead() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        // The command-line tool edits another setting; the app has not reloaded.
        try Self.place(#"{"version": 2, "speed": 700, "lode": "from-the-cli", "mine": 1}"#, on: disk)
        let value = try settings.update { $0.hosts = ["h"] }
        #expect(value == LodePrefs(lode: "from-the-cli", speed: 700, hosts: ["h"]), "the tool's edit is in what was updated")
        let reopened = try Self.open(disk)
        #expect(reopened.value == value)
        #expect(Self.text(disk)?.contains("\"mine\": 1") == true, "and so is what it added")
    }

    @Test(.failureMode("design/18", "a hand-edited file was changed since the store read it"))
    func anUpdateThatChangesNothingStillAdoptsTheFileAsItIsNow() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        try Self.place(#"{"version": 2, "speed": 800}"#, on: disk)
        let before = disk.contents(of: Self.path)
        try settings.update { _ in }
        #expect(settings.value.speed == 800)
        #expect(disk.contents(of: Self.path) == before, "and writes nothing")
    }

    /// The tool holds the lock while it edits; the app's update waits, then
    /// applies its change to the file the tool left, so neither edit is lost.
    @Test(.failureMode("design/18", "another process holds the lock on a hand-edited file"), .timeLimit(.minutes(1)))
    func anUpdateWaitsForTheOtherWriterAndThenKeepsItsEdit() async throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try Self.open(disk)
            let update = Task { try await settings.coordinatedUpdate { $0.hosts = ["app"] } }
            await clock.waitForSleepers(count: 1)
            #expect(Self.text(disk) == #"{"version": 2, "speed": 700}"#, "nothing written while the tool holds the lock")

            try Self.place(#"{"version": 2, "speed": 700, "lode": "tool"}"#, on: disk)   // the tool's edit
            try tool.release()
            await clock.advance(by: .milliseconds(25))
            let value = try await update.value
            #expect(value == LodePrefs(lode: "tool", speed: 700, hosts: ["app"]))
            let reopened = try Self.open(disk)
            #expect(reopened.value == value, "both edits are in the file")
        }
    }

    @Test(.failureMode("design/18", "another process holds the lock on a hand-edited file"), .timeLimit(.minutes(1)))
    func anUpdateThatCannotGetTheLockInTimeIsBusyAndTouchesNothing() async throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let before = disk.contents(of: Self.path)
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let events = RecordingInstrumentation()
        let clock = TestClock()
        try await withTestAmbient(clock: clock, events: events) {
            let settings = try Self.open(disk)
            let update = Task { try await settings.coordinatedUpdate(lockTimeout: .milliseconds(500)) { $0.speed = 900 } }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(1))
            do {
                _ = try await update.value
                Issue.record("the update did not wait for the lock")
            } catch {
                guard case SettingsStore<LodePrefs>.UpdateError.busy = error else { throw error }
            }
            #expect(disk.contents(of: Self.path) == before)
            #expect(settings.value.speed == 700)
            #expect(events.events(named: "settings.busy").first?["waitMs"]?.description == "500")
        }
        try tool.release()
    }

    @Test(.timeLimit(.minutes(1))) func theDefaultWaitIsTwoSecondsAndCanBeConfigured() async throws {
        #expect(HandEditedOptions().lockTimeout == .seconds(2))
        let disk = try Self.disk()
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let options = SettingsStore<LodePrefs>.Options(handEdited: HandEditedOptions(lockTimeout: .seconds(10)))
            let settings = try Self.open(disk, options: options)
            let update = Task { try await settings.coordinatedUpdate { $0.speed = 900 } }
            for _ in 0..<3 {
                // Past the default two seconds, inside the configured ten: still waiting.
                await clock.waitForSleepers(count: 1)
                await clock.advance(by: .seconds(1))
            }
            await clock.waitForSleepers(count: 1)
            try tool.release()
            await clock.advance(by: .milliseconds(25))
            #expect(try await update.value.speed == 900)
        }
    }

    @Test(.failureMode("design/18", "another process holds the lock on a hand-edited file"))
    func aSynchronousUpdateDoesNotWaitAndIsBusy() throws {
        let disk = try Self.disk()
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let settings = try Self.open(disk)
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        #expect(disk.contents(of: Self.path) == nil)
        try tool.release()
        try settings.update { $0.speed = 900 }
        #expect(try Self.open(disk).value.speed == 900)
    }

    @Test(.timeLimit(.minutes(1)))
    func aWaitingUpdateThatIsCancelledIsCancellationNotBusy() async throws {
        let disk = try Self.disk()
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try Self.open(disk)
            let update = Task { try await settings.coordinatedUpdate { $0.speed = 900 } }
            await clock.waitForSleepers(count: 1)
            update.cancel()
            await #expect(throws: CancellationError.self) { try await update.value }
        }
    }

    @Test(.failureMode("design/18", "two processes update a hand-edited file at once"), .timeLimit(.minutes(1)))
    func updatesFromTwoStoresOnOneFileAllLand() async throws {
        let disk = try Self.disk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let one = try Self.open(disk)
            let two = try Self.open(disk)   // another process, as far as the file is concerned
            let running = Running(2)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for store in [one, two] {
                    group.addTask {
                        for _ in 0..<25 {
                            try await store.coordinatedUpdate(lockTimeout: .seconds(1_000_000)) { $0.speed += 1 }
                        }
                        running.finishOne()
                    }
                }
                // Whoever finds the lock held sleeps on the test clock: let time pass for it.
                group.addTask {
                    while running.remaining > 0 {
                        await clock.advance(by: .milliseconds(25))
                        await Task.yield()
                    }
                }
                try await group.waitForAll()
            }
            #expect(try Self.open(disk).value.speed == 650, "100 increments, none lost")
            try one.reload()
            try two.reload()
            #expect(one.value.speed == 650)
            #expect(two.value.speed == 650)
        }
    }

    @Test(.failureMode("design/18", "the app holds the lock for life and the file is hand-edited"))
    func aStoreThatHoldsTheLockForLifeUsesItForItsUpdates() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk, options: .init(crossProcessLock: true))
        try settings.update { $0.speed = 800 }   // does not take the lock it already holds
        #expect(try Self.open(disk, options: .init()).value.speed == 800)
        #expect(throws: StoreError.self) { try Self.open(disk, options: .init(crossProcessLock: true)) }
        #expect(settings.value.speed == 800, "the first store is still the one holding it")
    }

    // MARK: Reload

    @Test(.failureMode("design/18", "a hand-edited file is replaced by a rename"))
    func aReloadAfterAnEditorSavedByRenamePublishesTheNewValueAndNotifiesObservers() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        let notified = Mutex(false)
        withObservationTracking { _ = settings.value } onChange: { notified.withLock { $0 = true } }
        try Self.place("{\n  // saved by the editor, by rename\n  \"speed\": 1200\n}\n", on: disk)
        try settings.reload()
        #expect(settings.value.speed == 1200)
        #expect(notified.withLock { $0 })
    }

    @Test(.failureMode("design/18", "the store's own write is reported by the watcher"))
    func aReloadThatFindsTheFileAsTheStoreLeftItPublishesAndReportsNothing() async throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        try settings.update { $0.speed = 800 }
        let notified = Mutex(false)
        withObservationTracking { _ = settings.value; _ = settings.issues; _ = settings.fileProblem } onChange: { notified.withLock { $0 = true } }
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            try settings.reload()
            try settings.reload()
        }
        #expect(!notified.withLock { $0 })
        #expect(events.events.isEmpty, "nothing reported: \(events.names)")
    }
}

/// How many workers have yet to finish.
final class Running: Sendable {
    private let count: Mutex<Int>
    init(_ count: Int) { self.count = Mutex(count) }
    var remaining: Int { count.withLock { $0 } }
    func finishOne() { count.withLock { $0 -= 1 } }
}

/// A file system that counts the reads of one path and otherwise is the
/// simulated one, watching included.
final class CountingFileSystem: FileSystem {
    let base: SimulatedFileSystem
    let counted: String
    private let reads = Mutex(0)

    init(_ base: SimulatedFileSystem, counting path: String) {
        self.base = base
        counted = path
    }

    var readCount: Int { reads.withLock { $0 } }

    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        if path == counted, mode == .read { reads.withLock { $0 += 1 } }
        return try base.open(path, mode: mode)
    }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func syncDirectory(_ directory: String) throws(StoreError) { try base.syncDirectory(directory) }
    func rename(from source: String, to destination: String) throws(StoreError) { try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) { try base.setPermissions(file, to: permissions) }
    func readLink(_ path: String) throws(StoreError) -> String? { try base.readLink(path) }
    func tryLock(_ file: OpenFile) throws(StoreError) -> Bool { try base.tryLock(file) }
    func unlock(_ file: OpenFile) throws(StoreError) { try base.unlock(file) }
    func watchFile(at path: String, handler: @escaping @Sendable () -> Void) throws(StoreError) -> FileWatch {
        try base.watchFile(at: path, handler: handler)
    }
}

/// Waits, without sleeping, until `condition` holds of `settings`: each change
/// of the value or the problem wakes it to look again.
func waitUntil<V: Sendable & Equatable>(_ settings: SettingsStore<V>, _ condition: @Sendable () -> Bool) async {
    let (changes, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    while true {
        // Registered before the check, so a change after it is not missed.
        withObservationTracking {
            _ = settings.value
            _ = settings.fileProblem
        } onChange: {
            signal.yield()
        }
        if condition() { return }
        var iterator = changes.makeAsyncIterator()
        await iterator.next()
    }
}

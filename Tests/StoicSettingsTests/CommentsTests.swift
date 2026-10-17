import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// A file whose owner would rather be told of a comment than lose it at the next save.
@Suite("Settings store: comments refused")
struct CommentsTests {
    static let refusing = SettingsStore<LodePrefs>.Options(handEdited: HandEditedOptions(comments: .refused))

    static let withComment = "{\n  \"version\": 2,\n  \"speed\": 700, // fast\n  \"lode\": \"beta\"\n}\n"

    @Test(.failureMode("design/18", "a hand-edited file holds a comment and comments are refused"))
    func aCommentIsAProblemAtItsLineAndColumnAndTheFileIsLeftAlone() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.withComment, on: disk)
        let events = RecordingInstrumentation()
        let settings = try await withAmbient({ $0.instrumentation = events }) {
            try HandEditedTests.open(disk, options: Self.refusing)
        }
        #expect(settings.value == LodePrefs(), "the defaults, the first time")
        #expect(settings.source == .defaults(.unusable))
        guard case .unparsable(let issues)? = settings.fileProblem else {
            Issue.record("expected an unparsable file, got \(String(describing: settings.fileProblem))")
            return
        }
        let issue = try #require(issues.first)
        #expect(issue.source?.start.line == 3)
        #expect(issue.source?.start.column == 17, "at the slash that begins the comment")
        #expect(issue.description.hasPrefix("3:17 "))
        #expect(issue.description.contains("comment"), "\(issue)")
        #expect(HandEditedTests.text(disk) == Self.withComment, "the file is exactly what the person wrote")
        try HandEditedTests.expectNothingBesideTheFile(disk)
        #expect(events.events(named: "settings.unparsed").first?["line"]?.description == "3")

        let error = #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        guard case .fileUnusable? = error else {
            Issue.record("expected .fileUnusable, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk) == Self.withComment, "and an update does not rewrite it without the comment")
    }

    @Test(.failureMode("design/18", "a hand-edited file holds a comment and comments are refused"))
    func aCommentAddedWhileTheAppRunsKeepsTheLastGoodValueAndRemovingItClearsTheProblem() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place("{\n  \"version\": 2,\n  \"speed\": 700\n}\n", on: disk)
        let settings = try HandEditedTests.open(disk, options: Self.refusing)
        #expect(settings.value.speed == 700)

        try HandEditedTests.place(Self.withComment, on: disk)
        try settings.reload()
        #expect(settings.value.speed == 700, "the last good value stands, not the 700 the commented file also holds")
        #expect(settings.fileProblem != nil)
        #expect(settings.source == .file)

        try HandEditedTests.place("{\n  \"version\": 2,\n  \"speed\": 800\n}\n", on: disk)
        try settings.reload()
        #expect(settings.fileProblem == nil)
        #expect(settings.value.speed == 800)
    }

    @Test func theDefaultIsToAllowCommentsAndThenAnUpdateDropsThem() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.withComment, on: disk)
        let settings = try HandEditedTests.open(disk)
        #expect(settings.fileProblem == nil)
        #expect(settings.value.speed == 700)
        try settings.update { $0.speed = 900 }
        #expect(HandEditedTests.text(disk)?.contains("fast") == false, "the documented price of an update")
        #expect(HandEditedOptions().comments == .allowed)
    }

    @Test func trailingCommasAreStillAllowedWhenCommentsAreRefused() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place("{\n  \"version\": 2,\n  \"speed\": 700,\n}\n", on: disk)
        let settings = try HandEditedTests.open(disk, options: Self.refusing)
        #expect(settings.fileProblem == nil)
        #expect(settings.value.speed == 700)
    }

    @Test func aSlashInAStringIsNotAComment() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "hosts": ["// not", "/* a comment */"]}"#, on: disk)
        let settings = try HandEditedTests.open(disk, options: Self.refusing)
        #expect(settings.fileProblem == nil)
        #expect(settings.value.hosts == ["// not", "/* a comment */"])
    }
}

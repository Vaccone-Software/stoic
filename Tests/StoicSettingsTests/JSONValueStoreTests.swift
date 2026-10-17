import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// A settings store whose value is the whole document, as an app that
/// validates its file itself keeps it (`Schema.json()`).
@Suite("Settings store: a JSON value")
struct JSONValueStoreTests {
    static let path = HandEditedTests.path

    static func open(
        _ disk: some FileSystem, header: SettingsFileHeader = ["$schema": "lodestar-schema.json", "version": "1.2.3"],
        options: HandEditedOptions? = nil
    ) throws -> SettingsStore<JSONValue> {
        try SettingsStore.open(
            at: path, schema: Schema.json(), format: .handEdited, fileSystem: disk,
            options: .init(handEdited: options ?? HandEditedOptions(fileHeader: header)))
    }

    @Test(.failureMode("design/18", "a hand-edited file has a file header"))
    func theHeaderIsNotPartOfAJSONValueAndTheValueNeverDisagreesWithTheFile() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"$schema": "old.json", "version": "1.0.0", "a": 1}"#, on: disk)
        let settings = try Self.open(disk)
        #expect(settings.value == .object(["a": 1]), "the header is the app's, not a setting")

        try settings.update { $0 = try $0.setting(2, at: ["b"]) }
        #expect(settings.value == .object(["a": 1, "b": 2]))
        #expect(HandEditedTests.text(disk) == "{\n  \"$schema\": \"lodestar-schema.json\",\n  \"version\": \"1.2.3\",\n  \"a\": 1,\n  \"b\": 2\n}\n")
        #expect(try Self.open(disk).value == settings.value, "read back, the same value")
    }

    @Test(.failureMode("design/18", "an issue is found in a hand-edited file"))
    func positionsAreStillTheTextsWithTheHeaderLeftOut() throws {
        let disk = try HandEditedTests.disk()
        // The header takes two lines before the version; the wrong value is on line 5 and the issue says so.
        try HandEditedTests.place(
            "{\n  \"$schema\": \"x\",\n  \"banner\": \"1\",\n  \"version\": 2,\n  \"speed\": 1.5,\n  \"lode\": \"alpha\"\n}\n", on: disk)
        let settings = try SettingsStore.open(
            at: Self.path, schema: LodePrefs.schema, format: .handEdited, fileSystem: disk,
            options: .init(handEdited: HandEditedOptions(fileHeader: ["$schema": "s", "banner": "2"])))
        let issue = try #require(settings.issues.first)
        #expect(issue.path == ["speed"])
        #expect(issue.source?.start.line == 5)
        #expect(issue.source?.start.column == 12)
        #expect(settings.issues.count == 1, "the header's two keys are not unknown keys")
    }
}

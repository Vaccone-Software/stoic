import Foundation
import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// What a typed schema over a file a person edits can say about its history and
/// its forgiveness: a section written as `null`, keys that were renamed or retired.
struct Gestures: Sendable, Equatable {
    var speed = 1000.0
    var smooth = true

    static let schema = Schema.object(Gestures.self, default: Gestures()) {
        Field("speed", \.speed, .double(.range(200...4000)), doc: "Pixels per second.")
        Field("smooth", \.smooth, .bool, doc: "Whether scrolling eases.")
    }
}

struct FilePrefs: Sendable, Equatable {
    var theme = "light"
    var gestures = Gestures()

    static let schema = Schema.object(FilePrefs.self, default: FilePrefs()) {
        Field("theme", \.theme, .string(), doc: "The theme.")
        Field("gestures", \.gestures, Gestures.schema.readingNullAsEmpty(), doc: "Gestures.")
    }
}

@Suite("Settings store: a schema over a file people edit")
struct FileSchemaTests {
    static let path = "/d/prefs.json"

    static func open(
        _ disk: some FileSystem, header: SettingsFileHeader = ["$schema": "prefs-schema.json"]
    ) throws -> SettingsStore<FilePrefs> {
        try SettingsStore.open(
            at: path, schema: FilePrefs.schema, format: .handEdited, fileSystem: disk,
            options: .init(handEdited: HandEditedOptions(fileHeader: header)))
    }

    @Test(.failureMode("design/18", "a section of a hand-edited file is null"))
    func aNullSectionIsReadSilentlyAndNotWrittenBack() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"gestures": null, "theme": "dark"}"#, on: disk, at: Self.path)
        let settings = try Self.open(disk)
        #expect(settings.value == FilePrefs(theme: "dark"))
        #expect(settings.issues.isEmpty)
        try settings.update { $0.theme = "light" }
        // The section is not a value: the write omits it, and with the header is all the file holds.
        #expect(HandEditedTests.text(disk, at: Self.path) == "{\n  \"$schema\": \"prefs-schema.json\"\n}\n")
    }
}

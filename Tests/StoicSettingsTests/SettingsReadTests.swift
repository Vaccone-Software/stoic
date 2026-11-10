import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// `SettingsStore.read` is the store's read of a file's bytes, with no file
/// (design/32): for files of both formats it gives the value and the issues
/// that `open` reports.
@Suite("Settings store: reading bytes as open does")
struct SettingsReadTests {
    static let path = "/d/prefs.json"
    static let header: SettingsFileHeader = ["$schema": "prefs-schema.json", "generator": "lodestar 0.50"]

    static func handEdited() -> SettingsStore<Prefs>.Options {
        .init(handEdited: HandEditedOptions(fileHeader: header))
    }

    /// What `open` makes of `bytes`, placed as they are.
    static func opened(_ bytes: [UInt8], format: SettingsStore<Prefs>.Format, options: SettingsStore<Prefs>.Options) throws
        -> (value: Prefs, issues: [StoicSchema.Issue])
    {
        let disk = try HandEditedTests.disk()
        try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(bytes, to: path)
        let store = try SettingsStore.open(at: path, schema: Prefs.schema, format: format, fileSystem: disk, options: options)
        return (store.value, store.issues)
    }

    static let handEditedFiles: [(name: String, text: String)] = [
        ("with a header and comments", """
            {
              // written by the app, edited by a person
              "$schema": "prefs-schema.json",
              "generator": "lodestar 0.50",
              "version": 2,
              "speed": 900, /* fast */
              "name": "Ana's Mac",
            }
            """),
        ("from an older version", #"{"$schema": "prefs-schema.json", "version": 1, "scroll_speed": 700}"#),
        ("with a value clamped", #"{"version": 2, "speed": 99999, "name": "x"}"#),
        ("with a key said twice", #"{"version": 2, "speed": 800, "speed": 850}"#),
        ("that does not parse", "{\"version\": 2, \"speed\": }"),
    ]

    @Test func aHandEditedFileReadsAsOpenReadsIt() throws {
        for file in Self.handEditedFiles {
            let bytes = Array(file.text.utf8)
            let read = SettingsStore<Prefs>.read(bytes, schema: Prefs.schema, format: .handEdited, options: Self.handEdited())
            let opened = try Self.opened(bytes, format: .handEdited, options: Self.handEdited())
            if let value = read.value { #expect(value == opened.value, "\(file.name)") }
            #expect(read.issues == opened.issues, "\(file.name): \(read.issues) vs \(opened.issues)")
            let paths = read.issues.map(\.path.description)
            #expect(!paths.contains { $0.contains("generator") }, "\(file.name): the header is set aside")
        }
    }

    @Test func anAppOwnedFileReadsThroughItsEnvelopeAsOpenReadsIt() throws {
        // As the store wrote it: enveloped, with a checksum.
        let disk = try HandEditedTests.disk()
        let store = try SettingsStore.open(at: Self.path, schema: Prefs.schema, fileSystem: disk)
        try store.update { $0.speed = 1_234 }
        let written = try #require(disk.contents(of: Self.path))
        let read = SettingsStore<Prefs>.read(written, schema: Prefs.schema)
        #expect(read.value == Prefs(speed: 1_234))
        #expect(read.issues.isEmpty)
        // A plain JSON file from before the store, migrated as open migrates it.
        let legacy = Array(#"{"version": 1, "scroll_speed": 700}"#.utf8)
        let opened = try Self.opened(legacy, format: .appOwned, options: .init())
        let plain = SettingsStore<Prefs>.read(legacy, schema: Prefs.schema)
        #expect(plain.value == opened.value)
        #expect(plain.issues == opened.issues)
        // A torn envelope reads as nothing, never as defaults.
        let torn = SettingsStore<Prefs>.read(Array(written.dropLast()), schema: Prefs.schema)
        #expect(torn.value == nil)
        #expect(torn.issues.first?.code == .invalidFormat)
    }
}

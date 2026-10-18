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

/// A file whose keys were renamed over the releases, and one that is no more.
struct RenamedPrefs: Sendable, Equatable {
    var searcher = "none"
    var theme = "light"

    static let schema = Schema.object(RenamedPrefs.self, default: RenamedPrefs()) {
        Field("searcher", \.searcher, .string(), doc: "The searcher.")
        Field("theme", \.theme, .string(), doc: "The theme.")
    }
    .normalizing(.rename("hyper", to: "searcher"), retired: ["old-flag"])
}

/// Sections declared in an order that is not alphabetical, nested two deep.
struct Ordered: Sendable, Equatable {
    struct Web: Sendable, Equatable {
        struct Routes: Sendable, Equatable {
            var zone = 1
            var base = 2
            static let schema = Schema.object(Routes.self, default: Routes()) {
                Field("zone", \.zone, .int(), doc: "Zone.")
                Field("base", \.base, .int(), doc: "Base.")
            }
        }
        var timeout = 30
        var routes = Routes()
        static let schema = Schema.object(Web.self, default: Web()) {
            Field("timeout", \.timeout, .int(), doc: "Timeout.")
            Field("routes", \.routes, Routes.schema, doc: "Routes.")
        }
    }
    var zeta = 0
    var web = Web()
    var alpha = 0

    static let schema = Schema.object(Ordered.self, default: Ordered()) {
        Field("zeta", \.zeta, .int(), doc: "Zeta.")
        Field("web", \.web, Web.schema, doc: "Web.")
        Field("alpha", \.alpha, .int(), doc: "Alpha.")
    }
}

/// A table a person fills in by hand, whose bad entries the schema drops.
struct Excluded: Sendable, Equatable {
    var theme = "light"
    var excludeApps: [String: Bool] = [:]

    static let schema = Schema.object(Excluded.self, default: Excluded()) {
        Field("theme", \.theme, .string(), doc: "The theme.")
        Field("exclude-apps", \.excludeApps, .lossyDictionary(of: .bool, valueDoc: "true to exclude this app"), doc: "Excluded apps.")
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

    static func openRenamed(_ disk: some FileSystem) throws -> SettingsStore<RenamedPrefs> {
        try SettingsStore.open(
            at: path, schema: RenamedPrefs.schema, format: .handEdited, fileSystem: disk,
            options: .init(handEdited: HandEditedOptions(fileHeader: ["$schema": "prefs-schema.json"])))
    }

    @Test(.failureMode("design/18", "a hand-edited file holds a key its schema renamed or retired"))
    func aRenamedKeyIsReadAsTheNewOneAndNeverWrittenBackBesideIt() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"hyper": "ripgrep", "old-flag": true, "theme": "dark", "stray": 1}"#, on: disk, at: Self.path)
        let settings = try Self.openRenamed(disk)
        #expect(settings.value == RenamedPrefs(searcher: "ripgrep", theme: "dark"))
        // The file's keys are not unknown: one was renamed, one retired. Only `stray` is.
        #expect(settings.issues.map { "\($0.path) \($0.code)" } == ["$.stray unknown_key"])
        #expect(HandEditedTests.text(disk, at: Self.path)?.contains("hyper") == true)  // nothing is written on load
        try settings.update { $0.theme = "light" }
        #expect(HandEditedTests.text(disk, at: Self.path) == """
        {
          "$schema": "prefs-schema.json",
          "searcher": "ripgrep",
          "stray": 1
        }

        """)
    }

    @Test func resettingTheNewKeyToItsDefaultDoesNotBringTheOldOneBack() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"hyper": "ripgrep"}"#, on: disk, at: Self.path)
        let settings = try Self.openRenamed(disk)
        try settings.update { $0.searcher = "none" }
        #expect(HandEditedTests.text(disk, at: Self.path) == "{\n  \"$schema\": \"prefs-schema.json\"\n}\n")
        let reopened = try Self.openRenamed(disk)
        #expect(reopened.value == RenamedPrefs())
    }

    @Test func bothKeysTheNewOneWinsAndIssuesPointIntoTheText() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place("{\n  \"hyper\": \"old\",\n  \"searcher\": \"new\",\n  \"theme\": 5\n}", on: disk, at: Self.path)
        let settings = try Self.openRenamed(disk)
        #expect(settings.value.searcher == "new")
        let issue = try #require(settings.issues.first)
        #expect(issue.path.description == "$.theme")
        #expect(issue.source?.start.line == 4)
    }

    @Test func theHeaderMakesTheRootPropertiesOfAClosedDocument() throws {
        let header: SettingsFileHeader = ["$schema": "prefs-schema.json", "version": 3, "ratio": 0.5, "on": true, "none": .null, "list": [], "map": [:]]
        let properties = header.jsonSchemaProperties
        #expect(properties["$schema"] == ["type": "string"])
        #expect(properties["version"] == ["type": "integer"])
        #expect(properties["ratio"] == ["type": "number"])
        #expect(properties["on"] == ["type": "boolean"])
        #expect(properties["none"] == ["type": "null"])
        #expect(properties["list"] == ["type": "array"])
        #expect(properties["map"] == ["type": "object"])
        #expect(properties.map(\.key) == header.keys)

        // The file the store writes, whose header the schema does not describe, is valid against the closed document.
        var options = JSONSchemaOptions(draft: .draft07, closesObjects: true)
        options.extraRootProperties = (["$schema": "prefs-schema.json"] as SettingsFileHeader).jsonSchemaProperties
        let validator = JSONSchemaValidator(FilePrefs.schema.jsonSchema(options: options))
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        try settings.update { $0.theme = "dark" }
        let file = try JSONValue(parsing: try #require(HandEditedTests.text(disk, at: Self.path)))
        #expect(validator.accepts(file))
        #expect(!JSONSchemaValidator(FilePrefs.schema.jsonSchema(options: JSONSchemaOptions(closesObjects: true))).accepts(file))
    }

    static func openOrdered(_ disk: some FileSystem, layout: HandEditedOptions.Layout = .canonical) throws -> SettingsStore<Ordered> {
        try SettingsStore.open(
            at: path, schema: Ordered.schema, format: .handEdited, fileSystem: disk,
            options: .init(handEdited: HandEditedOptions(fileHeader: ["$schema": "s.json"], layout: layout)))
    }

    @Test(.failureMode("design/18", "a hand-edited file is written with an order the app gave"))
    func aValueEqualToItsDefaultWritesOnlyTheHeaderAndNestedObjectsFollowDeclarationOrder() throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.openOrdered(disk)
        try settings.update { $0.alpha = 1 }
        try settings.update { $0.alpha = 0 }
        #expect(HandEditedTests.text(disk, at: Self.path) == "{\n  \"$schema\": \"s.json\"\n}\n")

        try settings.update {
            $0.alpha = 9
            $0.zeta = 8
            $0.web.routes.base = 7
            $0.web.routes.zone = 6
            $0.web.timeout = 5
        }
        // Declaration order at every depth, not alphabetical: zeta, web (timeout, routes (zone, base)), alpha.
        #expect(HandEditedTests.text(disk, at: Self.path) == """
        {
          "$schema": "s.json",
          "zeta": 8,
          "web": {
            "timeout": 5,
            "routes": {
              "zone": 6,
              "base": 7
            }
          },
          "alpha": 9
        }

        """)
        // A section that goes back to its defaults is omitted whole, and an app-given order still leaves the rest in declaration order.
        let ordered = try Self.openOrdered(disk, layout: .canonical(order: KeyOrder(root: ["alpha"], nested: [["web"]: ["routes"]])))
        try ordered.update { $0.zeta = 0 }
        #expect(HandEditedTests.text(disk, at: Self.path) == """
        {
          "$schema": "s.json",
          "alpha": 9,
          "web": {
            "routes": {
              "zone": 6,
              "base": 7
            },
            "timeout": 5
          }
        }

        """)
    }

    static func openExcluded(_ disk: some FileSystem, layout: HandEditedOptions.Layout = .canonical) throws -> SettingsStore<Excluded> {
        try SettingsStore.open(
            at: path, schema: Excluded.schema, format: .handEdited, fileSystem: disk,
            options: .init(handEdited: HandEditedOptions(fileHeader: ["$schema": "s.json"], layout: layout)))
    }

    static let excluded = #"{"theme": "dark", "exclude-apps": {"com.c": true, "com.a": true, "com.b": "yes"}}"#

    @Test(.failureMode("design/18", "a hand-edited file has an entry its lossy table dropped"))
    func anEntryTheTableDroppedIsKeptThroughAnUnrelatedWriteAtItsPlace() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.excluded, on: disk, at: Self.path)
        let settings = try Self.openExcluded(disk)
        #expect(settings.value.excludeApps == ["com.a": true, "com.c": true])
        #expect(settings.issues.map { "\($0.path) \($0.code)" } == ["$[\"exclude-apps\"][\"com.b\"] dropped_entry"])
        try settings.update { $0.theme = "light" }
        // Canonical layout orders a table's entries alphabetically: the bad one is where it sorts.
        #expect(HandEditedTests.text(disk, at: Self.path) == """
        {
          "$schema": "s.json",
          "exclude-apps": {
            "com.a": true,
            "com.b": "yes",
            "com.c": true
          }
        }

        """)
        // And stays through the next write, and a reload.
        try settings.update { $0.theme = "dark" }
        #expect(HandEditedTests.text(disk, at: Self.path)?.contains(#""com.b": "yes""#) == true)
        let reopened = try Self.openExcluded(disk)
        #expect(reopened.issues.map(\.code) == [.droppedEntry])
    }

    @Test func theSourceOrderLayoutPutsItBackAfterTheEntryThatPrecededIt() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"exclude-apps": {"com.z": true, "com.b": "yes", "com.a": true}}"#, on: disk, at: Self.path)
        let settings = try Self.openExcluded(disk, layout: .sourceOrder)
        try settings.update { $0.theme = "dark" }
        let text = try #require(HandEditedTests.text(disk, at: Self.path))
        let order = ["com.a", "com.b", "com.z"].compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        // The encoder writes the kept entries sorted (a, z); the bad one follows its predecessor in the file (z).
        #expect(order.count == 3)
        #expect(text.range(of: "\"com.z\"")!.lowerBound < text.range(of: "\"com.b\"")!.lowerBound)
    }

    @Test func settingThatKeyReplacesItAndTheOtherEntriesAreStillKept() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.excluded, on: disk, at: Self.path)
        let settings = try Self.openExcluded(disk)
        try settings.update { $0.excludeApps["com.b"] = false }
        let text = try #require(HandEditedTests.text(disk, at: Self.path))
        #expect(text.contains(#""com.b": false"#))
        #expect(!text.contains("yes"))
        let reopened = try Self.openExcluded(disk)
        #expect(reopened.value.excludeApps == ["com.a": true, "com.b": false, "com.c": true])
        #expect(reopened.issues.isEmpty)
    }

    @Test func removingTheTableOrEveryEntryRemovesWhatWasDroppedFromIt() throws {
        for edit in [
            { (value: inout Excluded) in value.excludeApps = [:] },
            { (value: inout Excluded) in value.excludeApps.removeAll() },
        ] {
            let disk = try HandEditedTests.disk()
            try HandEditedTests.place(Self.excluded, on: disk, at: Self.path)
            let settings = try Self.openExcluded(disk)
            try settings.update(edit)
            #expect(HandEditedTests.text(disk, at: Self.path) == "{\n  \"$schema\": \"s.json\",\n  \"theme\": \"dark\"\n}\n")
        }
        // Removing one entry of several is an edit of the table, not the table's removal.
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.excluded, on: disk, at: Self.path)
        let settings = try Self.openExcluded(disk)
        try settings.update { $0.excludeApps["com.a"] = nil }
        let text = try #require(HandEditedTests.text(disk, at: Self.path))
        #expect(text.contains(#""com.b": "yes""#) && text.contains("com.c") && !text.contains("com.a"))
    }

    @Test func aTableWhoseEveryEntryWasBadIsMadeAgainOnAnUnrelatedWrite() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"exclude-apps": {"com.b": "yes"}}"#, on: disk, at: Self.path)
        let settings = try Self.openExcluded(disk)
        #expect(settings.value == Excluded())
        try settings.update { $0.theme = "dark" }
        #expect(HandEditedTests.text(disk, at: Self.path) == """
        {
          "$schema": "s.json",
          "theme": "dark",
          "exclude-apps": {
            "com.b": "yes"
          }
        }

        """)
        try settings.update { $0.excludeApps["com.a"] = true }
        #expect(HandEditedTests.text(disk, at: Self.path)?.contains(#""com.b": "yes""#) == true)
    }

    @Test func aCompositeEntryIsKeptVerbatimToo() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"exclude-apps": {"com.a": true, "com.b": {"x": [1, 2.50, null]}}}"#, on: disk, at: Self.path)
        let settings = try Self.openExcluded(disk)
        try settings.update { $0.theme = "dark" }
        let reopened = try Self.openExcluded(disk)
        #expect(reopened.issues.map(\.code) == [.droppedEntry])
        #expect(HandEditedTests.text(disk, at: Self.path)?.contains(#""x": ["#) == true)
    }

    @Test func anAppOwnedFileKeepsItsDroppedEntryToo() throws {
        let disk = try HandEditedTests.disk()
        try AtomicFile(fileSystem: disk).write(Array(Self.excluded.utf8), to: Self.path)
        let settings = try SettingsStore.open(at: Self.path, schema: Excluded.schema, fileSystem: disk)
        #expect(settings.value.excludeApps == ["com.a": true, "com.c": true])
        try settings.update { $0.theme = "light" }
        let reopened = try SettingsStore.open(at: Self.path, schema: Excluded.schema, fileSystem: disk)
        #expect(reopened.issues.map(\.code) == [.droppedEntry])
        #expect(reopened.value.excludeApps == ["com.a": true, "com.c": true])
    }
}

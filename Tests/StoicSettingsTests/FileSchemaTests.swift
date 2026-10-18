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
}

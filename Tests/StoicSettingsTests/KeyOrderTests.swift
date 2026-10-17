import Foundation
import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// The app's own order of the top-level sections of a file whose schema does not declare them.
@Suite("Settings store: the order of a file's keys")
struct KeyOrderTests {
    static let path = "/d/lodestar.json"

    /// Lodestar's: a fixed order for the sections people edit most, then the rest alphabetically.
    static let sections = ["lode", "app", "gestures", "web", "scroll", "select"]

    static func open(
        _ disk: some FileSystem, layout: HandEditedOptions.Layout, header: SettingsFileHeader = [:]
    ) throws -> SettingsStore<JSONValue> {
        try SettingsStore.open(
            at: path, schema: Schema.json(), format: .handEdited, fileSystem: disk,
            options: .init(handEdited: HandEditedOptions(fileHeader: header, layout: layout)))
    }

    static func json(_ text: String) throws -> JSONValue {
        try JSONValue(parsing: text, options: .jsonc)
    }

    static let document = """
    {"web": {"routes": {"b.com": "x", "a.com": "y"}}, "zeta": 1, "scroll": {"speed": 900, "smooth": true},
     "lode": "beta", "alpha": 2, "app": {"theme": "dark"}}
    """

    @Test(.failureMode("design/18", "a hand-edited file is written with an order the app gave"))
    func theListedKeysComeFirstInTheOrderGivenAndTheRestAreAlphabetical() throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk, layout: .canonical(order: KeyOrder(root: Self.sections)))
        try settings.update { $0 = try Self.json(Self.document) }
        #expect(HandEditedTests.text(disk, at: Self.path) == """
        {
          "lode": "beta",
          "app": {
            "theme": "dark"
          },
          "web": {
            "routes": {
              "a.com": "y",
              "b.com": "x"
            }
          },
          "scroll": {
            "smooth": true,
            "speed": 900
          },
          "alpha": 2,
          "zeta": 1
        }

        """)
    }

    @Test(.failureMode("design/18", "two writers hold the same value"))
    func twoWritersThatShareTheOrderWriteTheSameBytesWhateverOrderTheirFilesHad() throws {
        var written: [[UInt8]] = []
        for text in [Self.document, #"{"app": {"theme": "dark"}, "alpha": 2, "lode": "beta", "scroll": {"smooth": true, "speed": 900}, "web": {"routes": {"a.com": "y", "b.com": "x"}}, "zeta": 1.0}"#] {
            let disk = try HandEditedTests.disk()
            try HandEditedTests.place(text, on: disk, at: Self.path)
            let settings = try Self.open(disk, layout: .canonical(order: KeyOrder(root: Self.sections)), header: ["$schema": "s.json"])
            try settings.update { try $0 = $0.setting(1, at: ["zz"]) }
            try settings.update { try $0 = $0.removing(at: ["zz"]) }
            written.append(try #require(disk.contents(of: Self.path)))
        }
        #expect(written[0] == written[1])
    }

    @Test(.failureMode("design/18", "a hand-edited file is written with an order the app gave"))
    func anOrderForANestedObjectArrangesItAndTheElementsOfAnArrayShareTheArraysPath() throws {
        let disk = try HandEditedTests.disk()
        let order = KeyOrder(root: ["web"], nested: [["web"]: ["links", "routes"], ["hosts"]: ["name"], ["web", "links", "a.com"]: ["url"]])
        let settings = try Self.open(disk, layout: .canonical(order: order))
        try settings.update {
            $0 = try Self.json("""
            {"hosts": [{"port": 1, "name": "a", "id": 1}, {"id": 2, "name": "b"}],
             "web": {"routes": {"z": 1, "a": 2}, "links": {"a.com": {"title": "t", "url": "u"}}, "aaa": 0}}
            """)
        }
        #expect(HandEditedTests.text(disk, at: Self.path) == """
        {
          "web": {
            "links": {
              "a.com": {
                "url": "u",
                "title": "t"
              }
            },
            "routes": {
              "a": 2,
              "z": 1
            },
            "aaa": 0
          },
          "hosts": [
            {
              "name": "a",
              "id": 1,
              "port": 1
            },
            {
              "name": "b",
              "id": 2
            }
          ]
        }

        """)
    }

    @Test func aKeyTheObjectDoesNotHaveIsSkippedAndAKeyListedTwiceIsPlacedOnce() throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk, layout: .canonical(order: KeyOrder(root: ["missing", "b", "b", "a"])))
        try settings.update { $0 = try Self.json(#"{"a": 1, "c": 3, "b": 2}"#) }
        #expect(HandEditedTests.text(disk, at: Self.path) == "{\n  \"b\": 2,\n  \"a\": 1,\n  \"c\": 3\n}\n")
    }

    @Test func plainCanonicalIsWhatItWasAndAnEmptyOrderIsPlainCanonical() throws {
        let plain = try HandEditedTests.disk()
        let empty = try HandEditedTests.disk()
        for (disk, layout) in [(plain, HandEditedOptions.Layout.canonical), (empty, .canonical(order: KeyOrder()))] {
            let settings = try Self.open(disk, layout: layout)
            try settings.update { $0 = try Self.json(Self.document) }
        }
        #expect(plain.contents(of: Self.path) == empty.contents(of: Self.path))
        #expect(HandEditedTests.text(plain, at: Self.path)?.hasPrefix("{\n  \"alpha\": 2,\n  \"app\": {") == true, "alphabetical, as before")
    }

    @Test func aVersionKeyAndADiscriminatorStayFirstUnlessTheOrderPlacesThem() throws {
        // LodePrefs declares `version` (2) and its fields in an order of their own.
        let disk = try HandEditedTests.disk()
        let order = KeyOrder(root: ["hosts", "speed"])
        let settings = try SettingsStore.open(
            at: HandEditedTests.path, schema: LodePrefs.schema, format: .handEdited, fileSystem: disk,
            options: .init(handEdited: HandEditedOptions(layout: .canonical(order: order))))
        try settings.update { $0 = LodePrefs(lode: "beta", speed: 900, hosts: ["h"]) }
        #expect(HandEditedTests.text(disk) == """
        {
          "version": 2,
          "hosts": [
            "h"
          ],
          "speed": 900,
          "lode": "beta"
        }

        """, "the version, the order's keys, then the rest as declared")

        let placed = try HandEditedTests.disk()
        let store = try SettingsStore.open(
            at: HandEditedTests.path, schema: LodePrefs.schema, format: .handEdited, fileSystem: placed,
            options: .init(handEdited: HandEditedOptions(layout: .canonical(order: KeyOrder(root: ["speed", "version"])))))
        try store.update { $0.speed = 900 }
        #expect(HandEditedTests.text(placed) == "{\n  \"speed\": 900,\n  \"version\": 2\n}\n", "listed, the version goes where the order says")
    }
}

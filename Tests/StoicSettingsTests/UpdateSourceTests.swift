import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// The tag an app gives an update, which rides on the change it makes.
@Suite("Settings store: who made a change")
struct UpdateSourceTests {
    static let path = HandEditedTests.path

    static func change(
        _ old: LodePrefs, _ new: LodePrefs, _ cause: LodeChange.Cause = .update, source: String? = nil
    ) -> LodeChange {
        LodeChange(old: old, new: new, cause: cause, source: source)
    }

    @Test(.failureMode("design/18", "an update is given a source"), .timeLimit(.minutes(1)))
    func anUpdatesSourceRidesOnItsChangeAndOneWithoutIsNil() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try HandEditedTests.open(disk)
        let collector = collect(settings.changes(), count: 2)
        try settings.update(source: "settings window") { $0.speed = 900 }
        try settings.update { $0.speed = 800 }
        let changes = await collector.value
        #expect(changes == [
            Self.change(LodePrefs(), LodePrefs(speed: 900), source: "settings window"),
            Self.change(LodePrefs(speed: 900), LodePrefs(speed: 800), source: nil),
        ])
    }

    @Test(.failureMode("design/18", "an update is given a source"), .timeLimit(.minutes(1)))
    func everyKindOfUpdateCarriesItAsGivenAndTheStoreNeverReadsIt() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try HandEditedTests.open(disk)
        let collector = collect(settings.changes(), count: 3)
        try await settings.coordinatedUpdate(source: "cli: set speed") { $0.speed = 900 }
        try settings.blockingUpdate(waitingUpTo: .zero, source: "") { $0.speed = 800 }       // the empty tag is a tag
        try settings.blockingUpdate(source: "import \u{2028}\"quoted\"\n") { $0.speed = 700 }   // as given, whatever it holds
        let changes = await collector.value
        #expect(changes.map(\.source) == ["cli: set speed", "", "import \u{2028}\"quoted\"\n"])
        #expect(changes.map(\.cause) == [.update, .update, .update])
    }

    @Test(.failureMode("design/18", "an update is given a source"), .timeLimit(.minutes(1)))
    func theEditAnUpdateFindsIsTheFilesNotTheAppsAndCarriesNone() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try HandEditedTests.open(disk)
        let collector = collect(settings.changes(), count: 2)
        try HandEditedTests.place(#"{"version": 2, "speed": 700, "lode": "tool"}"#, on: disk)
        try settings.update(source: "menu") { $0.hosts = ["app"] }
        let tool = LodePrefs(lode: "tool", speed: 700)
        #expect(await collector.value == [
            Self.change(LodePrefs(speed: 700), tool, .reload, source: nil),
            Self.change(tool, LodePrefs(lode: "tool", speed: 700, hosts: ["app"]), .update, source: "menu"),
        ], "what the person did is not attributed to the app")
    }

    @Test(.failureMode("design/18", "an update is given a source"), .timeLimit(.minutes(1)))
    func anAppOwnedStoreCarriesItToo() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        let collector = collect(settings.changes(), count: 2)
        try settings.update(source: "a") { $0.speed = 900 }
        try settings.blockingUpdate(source: "b") { $0.speed = 800 }
        #expect(await collector.value.map(\.source) == ["a", "b"])
    }

    @Test(.failureMode("design/18", "an update is given a source"), .timeLimit(.minutes(1)))
    func aWriteThatChangesNothingIsNoChangeWhateverItsSource() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try HandEditedTests.open(disk)
        let collector = collect(settings.changes(), count: 1)
        try settings.update(source: "nothing") { $0.speed = 600 }       // the value it has
        try settings.update(source: "sentinel") { $0.speed = 900 }
        #expect(await collector.value.map(\.source) == ["sentinel"])
    }

    @Test func aChangeBuiltWithoutASourceHasNone() {
        #expect(LodeChange(old: LodePrefs(), new: LodePrefs(speed: 700), cause: .update).source == nil)
    }
}

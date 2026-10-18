import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// What a file a person edits may contain, which is written in one place
/// (`HandEditedOptions`) and checked here, row by row.
@Suite("Settings store: the dialect of a hand-edited file")
struct DialectTests {
    static let repeated = "{\n  \"version\": 2,\n  \"speed\": 700,\n  \"lode\": \"beta\",\n  \"speed\": 900\n}\n"

    static let refusing = SettingsStore<LodePrefs>.Options(handEdited: HandEditedOptions(duplicateKeys: .refused))

    // MARK: Repeated keys, accepted

    @Test(.failureMode("design/18", "a hand-edited file says a key more than once"))
    func theLastValueIsUsedAndTheRepeatIsAWarningWithBothPlacesAndWhatTheNextUpdateDoes() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.repeated, on: disk)
        let events = RecordingInstrumentation()
        let settings = try await withAmbient({ $0.instrumentation = events }) { try HandEditedTests.open(disk) }

        #expect(settings.fileProblem == nil, "a file that worked before still works")
        #expect(settings.source == .file)
        #expect(settings.value.speed == 900, "the last, as Foundation's reader took it")
        #expect(settings.value.lode == "beta")
        let issue = try #require(settings.issues.first)
        #expect(settings.issues.count == 1)
        #expect(issue.severity == .warning)
        #expect(issue.code == .repeatedKey)
        #expect(issue.path == ["speed"])
        #expect(issue.source?.start.line == 5, "at the repeat, the line that wins")
        #expect(issue.source?.start.column == 3)
        #expect(issue.parameters["firstLine"]?.number?.lexeme == "3", "and the other place")
        #expect(issue.parameters["firstColumn"]?.number?.lexeme == "3")
        #expect(
            issue.description
                == "5:3 $.speed: warning: `speed` is set more than once (first at line 3, column 3); the last one is used; "
                + "the file is not changed until the next update, which writes only that one")
        #expect(HandEditedTests.text(disk) == Self.repeated, "nothing is written on load")
        try HandEditedTests.expectNothingBesideTheFile(disk)
        let event = try #require(events.events(named: "settings.repeated_keys").first)
        #expect(event["keys"]?.description == "1")
        #expect(event["used"]?.description == "last")
    }

    @Test(.failureMode("design/18", "a hand-edited file says a key more than once"))
    func theNextUpdateWritesTheFileWithoutTheRepeatAndTheWarningIsGone() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.repeated, on: disk)
        let settings = try HandEditedTests.open(disk)
        try settings.update { $0.lode = "gamma" }
        #expect(HandEditedTests.text(disk) == "{\n  \"version\": 2,\n  \"lode\": \"gamma\",\n  \"speed\": 900\n}\n")
        #expect(settings.issues.isEmpty)
        #expect(try HandEditedTests.open(disk).issues.isEmpty)
    }

    @Test(.failureMode("design/18", "a hand-edited file says a key more than once"))
    func aRepeatInANestedObjectAndAThirdOccurrenceAreEachAWarning() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(
            "{\"version\": 2, \"editor\": {\"font\": 10, \"font\": 11}, \"speed\": 700, \"speed\": 800, \"speed\": 900}", on: disk)
        let settings = try HandEditedTests.open(disk)
        #expect(settings.value.editor.font == 11)
        #expect(settings.value.speed == 900)
        let repeats = settings.issues.filter { $0.code == .repeatedKey }
        #expect(repeats.count == 3, "one for each occurrence after the first: \(settings.issues)")
        #expect(repeats.map(\.path) == [["editor", "font"], ["speed"], ["speed"]])
        #expect(settings.issues.count == 3)
    }

    @Test(.failureMode("design/18", "a hand-edited file says a key more than once"))
    func aRepeatThatArrivesByReloadIsReportedAndOneThatIsFixedClearsIt() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place("{\"version\": 2, \"speed\": 700}", on: disk)
        let settings = try HandEditedTests.open(disk)
        #expect(settings.issues.isEmpty)

        try HandEditedTests.place(Self.repeated, on: disk)
        try settings.reload()
        #expect(settings.value.speed == 900)
        #expect(settings.issues.map(\.code) == [.repeatedKey])

        try HandEditedTests.place("{\"version\": 2, \"speed\": 900}", on: disk)
        try settings.reload()
        #expect(settings.issues.isEmpty)
    }

    @Test func aRepeatOfAHeaderKeyIsNotTheSettingsBusiness() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place("{\"$schema\": \"a\", \"$schema\": \"b\", \"version\": 2, \"speed\": 700}", on: disk)
        let settings = try HandEditedTests.open(disk, options: HandEditedTests.header())
        #expect(settings.issues.isEmpty, "the header is ignored on read, repeats included: \(settings.issues)")
        #expect(settings.value.speed == 700)
    }

    // MARK: Repeated keys, refused

    @Test(.failureMode("design/18", "a hand-edited file says a key more than once and repeats are refused"))
    func refusedARepeatIsAProblemAtTheRepeatAndTheFileIsLeftAlone() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.repeated, on: disk)
        let events = RecordingInstrumentation()
        let settings = try await withAmbient({ $0.instrumentation = events }) {
            try HandEditedTests.open(disk, options: Self.refusing)
        }
        #expect(settings.value == LodePrefs())
        guard case .unparsable(let issues)? = settings.fileProblem else {
            Issue.record("expected an unparsable file, got \(String(describing: settings.fileProblem))")
            return
        }
        let issue = try #require(issues.first)
        #expect(issue.source?.start.line == 5)
        #expect(issue.source?.start.column == 3)
        #expect(settings.fileProblem?.parseCode == .duplicateKey)
        #expect(issue.message.contains("line 3, column 3"), "both places: \(issue.message)")
        #expect(HandEditedTests.text(disk) == Self.repeated)

        let error = #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 800 } }
        guard case .fileUnusable? = error else {
            Issue.record("expected .fileUnusable, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk) == Self.repeated, "never rewritten without the line the person wrote")

        try HandEditedTests.place("{\n  \"version\": 2,\n  \"speed\": 900\n}\n", on: disk)
        try settings.reload()
        #expect(settings.fileProblem == nil)
        #expect(settings.value.speed == 900)
        #expect(events.events(named: "settings.repeated_keys").isEmpty, "a refusal is the problem's event, not this one")
    }

    // MARK: The dialect, in one place

    @Test func theDefaultsAreWrittenDownAndTheParseOptionsAreTheSameThingAsCode() {
        let defaults = HandEditedOptions()
        #expect(defaults.comments == .allowed)
        #expect(defaults.duplicateKeys == .lastWins)
        let parse = defaults.parseOptions
        #expect(parse.dialect == .jsonc, "comments and trailing commas")
        #expect(parse.allowBOM, "a byte order mark is skipped")
        #expect(parse.allowComments)
        #expect(parse.duplicateKeys == .lastWins)

        let strictest = HandEditedOptions(comments: .refused, duplicateKeys: .refused).parseOptions
        #expect(strictest.dialect == .jsonc, "trailing commas stay")
        #expect(strictest.allowBOM)
        #expect(!strictest.allowComments)
        #expect(strictest.duplicateKeys == .reject)
        #expect(parse.maxBytes == JSONParseOptions().maxBytes, "the limits are the parser's defaults")
    }

    @Test func aTrailingCommaAndAByteOrderMarkAreAcceptedAndTheNextWriteHasNeither() throws {
        let disk = try HandEditedTests.disk()
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let text = "{\n  \"version\": 2,\n  \"hosts\": [\"a\", \"b\",],\n  \"speed\": 700,\n}\n"
        try HandEditedTests.place(bom + Array(text.utf8), on: disk)
        let settings = try HandEditedTests.open(disk)
        #expect(settings.fileProblem == nil)
        #expect(settings.issues.isEmpty)
        #expect(settings.value.hosts == ["a", "b"])
        #expect(settings.value.speed == 700)

        try settings.update { $0.speed = 800 }
        let written = try #require(disk.contents(of: HandEditedTests.path))
        #expect(!written.starts(with: bom))
        #expect(!(String(decoding: written, as: UTF8.self).contains(",\n]")))
        #expect(settings.value.hosts == ["a", "b"])
    }

    @Test func aBOMIsAColumnZeroNotAPositionShift() throws {
        let disk = try HandEditedTests.disk()
        let text = "{\n  \"version\": 2,\n  \"speed\": 1.5\n}\n"
        try HandEditedTests.place([0xEF, 0xBB, 0xBF] + Array(text.utf8), on: disk)
        let settings = try HandEditedTests.open(disk)
        #expect(settings.issues.first?.source?.start.line == 3)
        #expect(settings.issues.first?.source?.start.column == 12)
    }

    @Test func textOutsideRFC8259ThatIsNotInTheDialectIsAProblemAtItsPlace() throws {
        for (text, code) in [
            ("{'speed': 700}", JSONParseError.Code.unexpectedCharacter),
            ("{speed: 700}", .unexpectedCharacter),
            ("{\"speed\": +700}", .invalidNumber),
            ("{\"speed\": NaN}", .invalidNumber),
        ] {
            let disk = try HandEditedTests.disk()
            try HandEditedTests.place(text, on: disk)
            let settings = try HandEditedTests.open(disk)
            #expect(settings.fileProblem?.parseCode == code, "\(text)")
        }
    }

    // MARK: A table at the top

    @Test(.failureMode("design/18", "a hand-edited file's top level is not what the schema reads"))
    func aTopLevelThatIsNotAnObjectIsAProblemWithAClearIssueUnderJSONObject() throws {
        let disk = try HandEditedTests.disk()
        for text in ["[1, 2]", "5", "\"x\"", "null"] {
            try HandEditedTests.place(text, on: disk)
            let settings = try SettingsStore.open(
                at: HandEditedTests.path, schema: Schema.jsonObject(), format: .handEdited, fileSystem: disk)
            guard case .unparsable(let issues)? = settings.fileProblem else {
                Issue.record("\(text): expected an unparsable file, got \(String(describing: settings.fileProblem))")
                continue
            }
            #expect(issues.first?.code == .typeMismatch, "\(text)")
            #expect(issues.first?.expected == "an object")
            #expect(issues.first?.source?.start.line == 1)
            #expect(settings.source == .defaults(.unusable))
            #expect(HandEditedTests.text(disk) == text, "left as it is")
        }
        try HandEditedTests.place("{\"a\": 1}", on: disk)
        let good = try SettingsStore.open(
            at: HandEditedTests.path, schema: Schema.jsonObject(), format: .handEdited, fileSystem: disk)
        #expect(good.fileProblem == nil)
        #expect(good.value == .object(["a": 1]))
    }

    @Test func aJSONObjectStoreWritesWhatAJSONStoreWritesInTheAppsOrder() throws {
        let order = HandEditedOptions(layout: .canonical(order: KeyOrder(root: ["lode", "app"], nested: [["web"]: ["routes"]])))
        var written: [String] = []
        for schema in [Schema.json(), Schema.jsonObject()] {
            let disk = try HandEditedTests.disk()
            try HandEditedTests.place(#"{"zeta": 1, "web": {"b": 1, "routes": {"y": 1, "x": 2}}, "app": {"q": 1}, "lode": 1}"#, on: disk)
            let settings = try SettingsStore.open(
                at: HandEditedTests.path, schema: schema, format: .handEdited, fileSystem: disk, options: .init(handEdited: order))
            try settings.update { $0 = try $0.setting(3, at: ["web", "c"]) }
            written.append(try #require(HandEditedTests.text(disk)))
        }
        #expect(written[0] == written[1])
        #expect(written[0].hasPrefix("{\n  \"lode\": 1,\n  \"app\""), "\(written[0])")
    }
}

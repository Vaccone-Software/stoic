#if STOIC_LINT
import StoicLintCore
import StoicTesting
import Testing

@Suite("wall-clock-read")
struct WallClockReadTests {
    private let rule = "wall-clock-read"

    @Test(.failureMode("design/26", "code reads Date() directly"))
    func readingTheDevicesClockIsRefusedWithTheFix() throws {
        let source = """
            func checkIn() {
                commitment.checkedInAt = Date()
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule.shortName == rule)
        #expect(found.line == 2)
        #expect(found.column == 30)
        #expect(found.message.contains("`Date()` reads the device's clock directly"))
        #expect(found.fixIt?.contains("`Moment.now`") == true)
    }

    @Test func flagsEverySpelling() {
        let source = """
            let a = Date()
            let b = Date.now
            let c = Foundation.Date()
            let d = Date.init()
            let e = NSDate()
            let f = Calendar.current
            let g = Calendar.autoupdatingCurrent
            let h = TimeZone.current.identifier
            let i = TimeZone.autoupdatingCurrent
            let j = Foundation.Calendar.current
            """
        #expect(rules(in: source) == Array(repeating: rule, count: 10))
    }

    @Test func reportsEachAtWhatItReads() throws {
        let source = """
            let start = Date.now
            let calendar = Calendar.current
                let zone = TimeZone.current
            """
        let found = findings(in: source)
        #expect(found.map(\.line) == [1, 2, 3])
        #expect(found.map(\.column) == [18, 25, 25], "at the member read, as bare-task-sleep reports")
        #expect(found[1].fixIt?.contains("PlainDate.today(in:)") == true)
        #expect(found[2].fixIt?.contains("TimeZoneID.device") == true)
    }

    @Test func datesMadeFromAValueAndOtherMembersAreFine() {
        let source = """
            let a = Date(timeIntervalSince1970: 0)
            let b = Date(timeIntervalSinceReferenceDate: seconds)
            let c = moment.date
            let d = Calendar(identifier: .gregorian)
            let e = TimeZone(identifier: "America/New_York")
            let f = Date.distantPast
            let g = Moment.now
            let h = clock.now
            let i = TimeZoneID.device
            let j = calendar.current
            let k = Date { builder }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aMentionInACommentOrStringIsIgnored() {
        let source = """
            // let now = Date()
            let text = "Date.now and Calendar.current"
            """
        #expect(rules(in: source) == [])
    }

    @Test func theZoneRulesSeamIsExemptAndNothingElseIs() {
        let source = "let zone = TimeZone.autoupdatingCurrent.identifier\n"
        #expect(rules(in: source, path: "Sources/StoicTime/Foundation/SystemZoneRules.swift") == [])
        #expect(rules(in: source, path: "/work/stoic/Sources/StoicTime/Foundation/SystemZoneRules.swift") == [])
        #expect(rules(in: source, path: "Sources/StoicTime/ZoneRules.swift") == [rule])
        #expect(rules(in: source, path: "Sources/App/Foundation/Zones.swift") == [rule])
        #expect(rules(in: source, path: "/work/Tests/AppTests/ClockTests.swift") == [rule], "tests are not exempt")
    }

    @Test func aJustificationSuppresses() {
        let source = """
            // stoic:allow(wall-clock-read): the log line's timestamp is for people, never compared
            let stamp = Date()
            let zone = TimeZone.current // stoic:allow(wall-clock-read): shown in the about box only
            """
        #expect(rules(in: source) == [])
    }
}
#endif

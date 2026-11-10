import Stoic
@testable import StoicLive
import StoicTesting
import Synchronization
import Testing

/// design/31's failure modes for `Live`: phases, loading, freshness,
/// subscriptions, combinations, joins and permissions. On the main actor,
/// on a test clock, against scripted operations; without SwiftUI.
@Suite("Live values")
@MainActor
struct LiveTests {
    // MARK: Loading

    @Test(.failureMode("design/31", "a Live is never read"))
    func aLiveNobodyReadsNeverLoads() async throws {
        try await onLiveTime { clock, _ in
            let script = Script<Int>(.value(1))
            let live = Live(API.detail) { attempt in try await script.call(attempt) }
            await clock.advance(by: .seconds(3_600))
            #expect(script.calls == 0)
            _ = live
        }
    }

    @Test(.failureMode("design/31", "a Live is read for the first time"))
    func theFirstReadStartsTheFirstLoadAtInteractiveAndStaysPending() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let script = Script<[String]>(.gated(gate, ["ana"]))
            let live = Live(API.roster) { attempt in try await script.call(attempt) }
            #expect(live.phase.isPending, "the read changes nothing a view observes")
            await script.wait(.calls, 1)
            #expect(script.urgencies == [.interactive], "a person is looking at a spinner")
            #expect(live.phase.isPending)
            gate.open()
            await until { live.phase == .fresh(["ana"]) }
            #expect(script.calls == 1, "one load, however often it was read")
        }
    }

    @Test(.failureMode("design/31", "a Live's value is read as empty while it loads"))
    func whileItLoadsThereIsNoValueToReadAsEmpty() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let script = Script<[String]>(.gated(gate, ["ana", "ben"]))
            let live = Live(API.roster) { attempt in try await script.call(attempt) }
            #expect(live.phase == .pending)
            #expect(live.phase != .fresh([]), "pending is not empty")
            #expect(live.loadedAt == nil)
            gate.open()
            await until { live.phase.value?.count == 2 }
        }
    }

    @Test(.failureMode("design/31", "a load returns an empty list"))
    func anEmptyListIsFreshAndEmptyNotPending() async throws {
        try await onLiveTime { _, _ in
            let live = Live(API.roster) { _ in [String]() }
            _ = live.phase
            await live.waitForLoad()
            #expect(live.phase == .fresh([]))
            #expect(live.loadedAt == TestClock.wallClockStart)
        }
    }

    @Test(.failureMode("design/31", "a load fails before any value"))
    func aFirstLoadThatFailsIsFailedWithNoValue() async throws {
        try await onLiveTime { _, events in
            let live = Live(API.detail) { _ async throws(Refused) -> Int in throw Refused() }
            _ = live.phase
            await live.waitForLoad()
            guard case .failed(let presented, last: nil) = live.phase else { Issue.record("\(live.phase)"); return }
            #expect(presented.message.key == "stoic.failure")
            #expect(live.loadedAt == nil)
            let event = try #require(events.events(named: "live.failed").first)
            #expect(event.label == "test.api.events.detail")
            #expect(event["reference"]?.description == presented.reference.description)
            #expect(events.count("failure.presented") == 1, "presented once")
        }
    }

    @Test(.failureMode("design/31", "a refresh fails after a value"))
    func aRefreshThatFailsKeepsTheValueBeside() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.value(1), .failure(Refused()))
            let live = Live(API.detail) { attempt in try await script.call(attempt) }
            _ = live.phase
            await live.waitForLoad()
            let failed = await live.refreshed()
            guard case .failed(_, last: 1?) = failed else { Issue.record("\(failed)"); return }
            #expect(live.loadedAt == TestClock.wallClockStart, "the value's moment, kept with it")
        }
    }

    @Test(.failureMode("design/31", "a failed Live is read again"))
    func aFailedValueIsNotLoadedAgainByReadingIt() async throws {
        try await onLiveTime { clock, _ in
            let script = Script<Int>(.failure(Refused()), .value(2))
            let live = Live(API.detail, freshFor: .seconds(60)) { attempt in try await script.call(attempt) }
            _ = live.phase
            await live.waitForLoad()
            for _ in 0..<5 { _ = live.phase }
            await clock.advance(by: .seconds(600))
            _ = live.phase
            #expect(script.calls == 1, "every redraw would hit a failing endpoint")
            // invalidate() lets the next read load again.
            live.invalidate()
            _ = live.phase
            await live.waitForLoad()
            #expect(live.phase == .fresh(2))
            #expect(script.calls == 2)
        }
    }

    @Test(.failureMode("design/31", "refresh() is called while a load runs"))
    func aRefreshSupersedesTheLoadInFlight() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.hang, .value(2))
            let live = Live(API.detail) { attempt in try await script.call(attempt) }
            _ = live.phase
            await script.wait(.calls, 1)
            live.refresh()
            await until { live.phase == .fresh(2) }
            await script.wait(.cancelled, 1)
            #expect(live.phase == .fresh(2), "the new load's result, and only it")
        }
    }

    @Test(.failureMode("design/31", "a superseded load finishes after the new one"))
    func aSupersededLoadThatFinishesLateIsDropped() async throws {
        try await onLiveTime { _, events in
            let gate = TestGate()
            let script = Script<Int>(.gated(gate, 1), .value(2))
            let live = Live(API.detail) { attempt in try await script.call(attempt) }
            _ = live.phase
            await script.wait(.calls, 1)
            live.refresh()
            await until { live.phase == .fresh(2) }
            gate.open()   // the old load answers after the new one landed
            await script.wait(.finished, 2)
            await events.wait(for: "slot.superseded_late")
            #expect(live.phase == .fresh(2), "never replaced by the older answer")
        }
    }

    @Test(.failureMode("design/31", "freshFor passes"))
    func aValuePastItsFreshnessIsStaleAndTheNextReadRefreshesIt() async throws {
        try await onLiveTime { clock, _ in
            let script = Script<Int>(.value(1), .value(2))
            let live = Live(API.detail, freshFor: .seconds(30)) { attempt in try await script.call(attempt) }
            _ = live.phase
            await live.waitForLoad()
            #expect(live.current == .fresh(1))
            await clock.advance(by: .seconds(29))
            #expect(live.current == .fresh(1))
            await clock.advance(by: .seconds(1))
            await until { live.current == .stale(1, refreshing: false) }
            #expect(script.calls == 1, "off screen, it does no work")
            _ = live.phase   // on screen again
            await until { live.current == .fresh(2) }
            #expect(script.urgencies == [.interactive, .utility], "the person already sees a value")
        }
    }

    @Test func readingAStaleValueShowsRefreshingFromTheNextTurn() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let script = Script<Int>(.value(1), .gated(gate, 2))
            let live = Live(API.detail) { attempt in try await script.call(attempt) }
            _ = live.phase
            await live.waitForLoad()
            live.invalidate()
            #expect(live.phase == .stale(1, refreshing: false), "the read starts the refresh; it shows from the next turn")
            await until { live.current == .stale(1, refreshing: true) }
            gate.open()
            await until { live.current == .fresh(2) }
        }
    }

    @Test(.failureMode("design/31", "a Live is released while loading"))
    func aReleasedLiveCancelsItsLoadAndDeliversNothing() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.hang)
            var live: Live<Int>? = Live(API.detail) { attempt in try await script.call(attempt) }
            _ = live?.phase
            await script.wait(.calls, 1)
            weak let gone = live
            live = nil
            #expect(gone == nil)
            await script.wait(.cancelled, 1)
        }
    }

    @Test(.failureMode("design/31", "a load operation is declared .keyed or .notRepeatable"))
    func aLoadThatIsNotRepeatableIsRefusedWhereItIsMade() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = Live(Backend.remote("test.exit").keyed("charge")) { _ in 1 }
            }
        }
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = Live(Backend.remote("test.exit").notRepeatable("send")) { _ in 1 }
            }
        }
    }

    // MARK: Subscriptions

    /// A subscription a test feeds element by element, and ends or fails.
    final class Feed: Sendable {
        let stream: AsyncThrowingStream<Int, any Error>
        let continuation: AsyncThrowingStream<Int, any Error>.Continuation

        init() {
            (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
        }
    }

    @Test(.failureMode("design/31", "a subscription fails and is re-established"))
    func aFailedSubscriptionIsStaleAndRefreshingUntilItIsBack() async throws {
        try await onLiveTime { clock, _ in
            let feeds = [Feed(), Feed()]
            let established = SendableCounter()
            let live = Live(subscribing: API.feed) { _ async throws(Refused) -> AsyncThrowingStream<Int, any Error> in
                let index = established.next()
                guard index < feeds.count else { throw Refused() }
                return feeds[index].stream
            }
            _ = live.phase
            feeds[0].continuation.yield(1)
            await until { live.current == .fresh(1) }
            feeds[0].continuation.yield(2)
            await until { live.current == .fresh(2) }
            feeds[0].continuation.finish(throwing: Lost())
            await until { live.current == .stale(2, refreshing: true) }
            await clock.advance(by: .seconds(1))   // re-established a second after the last began
            feeds[1].continuation.yield(3)
            await until { live.current == .fresh(3) }
            // It fails again, and establishing it fails for good.
            feeds[1].continuation.finish(throwing: Lost())
            await until { live.current == .stale(3, refreshing: true) }
            await clock.advance(by: .seconds(1))
            await until { live.current.failure != nil }
            guard case .failed(_, last: 3?) = live.current else { Issue.record("\(live.current)"); return }
        }
    }

    @Test(.failureMode("design/31", "a subscription ends without failing"))
    func anEndedSubscriptionIsStaleAndSubscribesAgainNoSoonerThanASecond() async throws {
        try await onLiveTime { clock, _ in
            let feeds = [Feed(), Feed()]
            let established = SendableCounter()
            let live = Live(subscribing: API.feed) { _ async throws(Refused) -> AsyncThrowingStream<Int, any Error> in
                feeds[min(established.next(), feeds.count - 1)].stream
            }
            _ = live.phase
            feeds[0].continuation.yield(1)
            feeds[0].continuation.finish()
            await until { live.current == .stale(1, refreshing: false) }
            _ = live.phase   // the next read subscribes again…
            await until { live.current == .stale(1, refreshing: true) }
            #expect(established.value == 1, "…no sooner than a second after the last began")
            feeds[1].continuation.yield(5)   // buffered until it is subscribed to
            await clock.advance(by: .seconds(1))
            await until { live.current == .fresh(5) }
            #expect(established.value == 2)
        }
    }

    // MARK: Combinations

    @Test(.failureMode("design/31", "one input of a combination is refreshing"))
    func aRefreshingInputKeepsTheLastSnapshotUncomputed() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let left = Script<Int>(.value(1), .gated(gate, 10))
            let a = Live(API.detail, label: "a") { attempt in try await left.call(attempt) }
            let b = Live(API.roster, label: "b") { _ in 100 }
            let computed = SendableCounter()
            let sum = Live<Int>.combining(a, b) { x, y in
                _ = computed.next()
                return x + y
            }
            #expect(sum.phase == .pending)
            await until { sum.phase == .fresh(101) }
            let before = computed.value
            a.refresh()
            await until { a.current == .stale(1, refreshing: true) }
            for _ in 0..<5 { #expect(sum.phase == .stale(101, refreshing: true)) }
            #expect(computed.value == before, "not recomputed while an input is mid-refresh")
            gate.open()
            await until { sum.phase == .fresh(110) }
        }
    }

    @Test(.failureMode("design/31", "an action refreshes two inputs of a combination"))
    func aJointRefreshShowsTheOldSnapshotUntilBothHaveLanded() async throws {
        try await onLiveTime { _, _ in
            let attendeesGate = TestGate()
            let minorsGate = TestGate()
            let attendees = Script<[String]>(.value(["ana"]), .gated(attendeesGate, ["ana", "ben"]))
            let minors = Script<[String]>(.value([]), .gated(minorsGate, ["ben"]))
            let list = Live(API.roster) { attempt in try await attendees.call(attempt) }
            let young = Live(API.minors) { attempt in try await minors.call(attempt) }
            let roster = Live<[String]>.combining(list, young) { people, minors in
                people.map { minors.contains($0) ? "\($0) (minor)" : $0 }
            }
            await until { roster.phase == .fresh(["ana"]) }
            let signUp = Action(API.rename, refreshes: [list, young]) { _ async throws(Refused) -> Int in 1 }
            _ = await signUp.run()
            #expect(roster.phase == .stale(["ana"], refreshing: false), "both stale together")
            await until { roster.phase == .stale(["ana"], refreshing: true) }
            attendeesGate.open()   // the new attendees land first
            await until { list.current == .fresh(["ana", "ben"]) }
            #expect(roster.phase == .stale(["ana"], refreshing: true), "never the new attendees beside the old minors")
            minorsGate.open()
            await until { roster.phase == .fresh(["ana", "ben (minor)"]) }
        }
    }

    @Test(.failureMode("design/31", "one input of a combination fails"))
    func aFailedInputFailsTheCombinationKeepingItsLastSnapshot() async throws {
        try await onLiveTime { _, _ in
            let right = Script<Int>(.value(2), .failure(Refused()))
            let a = Live(API.detail) { _ in 1 }
            let b = Live(API.roster) { attempt in try await right.call(attempt) }
            let pair = Live<String>.combining(a, b) { "\($0)/\($1)" }
            await until { pair.phase == .fresh("1/2") }
            b.refresh()
            await until { b.current.failure != nil }
            guard case .failed(let presented, last: "1/2"?) = pair.phase else { Issue.record("\(pair.phase)"); return }
            #expect(presented == b.current.failure, "that input's presentation")
        }
    }

    @Test func combinationsOfThreeAndFourInputsFollowTheSameRules() async throws {
        try await onLiveTime { _, _ in
            let a = Live(API.detail, label: "a") { _ in 1 }
            let b = Live(API.roster, label: "b") { _ in 2 }
            let c = Live(API.minors, label: "c") { _ in 3 }
            let d = Live(API.roles, label: "d") { _ in 4 }
            let three = Live<Int>.combining(a, b, c) { $0 + $1 + $2 }
            let four = Live<Int>.combining(a, b, c, d) { $0 * $1 * $2 * $3 }
            await until { three.phase == .fresh(6) && four.phase == .fresh(24) }
            #expect(four.label == "a+b+c+d")
            #expect(four.loadedAt == TestClock.wallClockStart)
        }
    }

    // MARK: Joins

    struct Attendee: Sendable, Equatable { let email: String; let name: String }
    struct Minor: Sendable, Equatable { let email: String; let isMinor: Bool }
    struct Row: Sendable, Equatable { let name: String; let minor: Bool? }

    @Test(.failureMode("design/31", "two lists are joined and the right list lacks a key"))
    func aJoinPairsByKeyInTheLeftOrderAndAnAbsentPartnerIsNil() async throws {
        try await onLiveTime { _, _ in
            let attendees = Live(API.roster) { _ in
                [Attendee(email: "c@x", name: "Cleo"), Attendee(email: "a@x", name: "Ana"), Attendee(email: "b@x", name: "Ben")]
            }
            let minors = Live(API.minors) { _ in [Minor(email: "b@x", isMinor: true), Minor(email: "a@x", isMinor: false)] }
            let roster = Live<[Row]>.joining(attendees, minors, on: \.email, \.email) { attendee, minor in
                Row(name: attendee.name, minor: minor?.isMinor)
            }
            #expect(roster.phase == .pending, "no rows until both lists have loaded: never \"No\" while minors load")
            await until { roster.phase.value != nil }
            #expect(roster.phase == .fresh([
                Row(name: "Cleo", minor: nil), Row(name: "Ana", minor: false), Row(name: "Ben", minor: true),
            ]), "in the left list's order, by key, never by position")
        }
    }

    @Test(.failureMode("design/31", "the right list of a join repeats a key"))
    func aRepeatedKeyOnTheRightUsesTheFirstAndIsReported() async throws {
        try await onLiveTime { _, events in
            let attendees = Live(API.roster) { _ in [Attendee(email: "a@x", name: "Ana"), Attendee(email: "a@x", name: "Ana again")] }
            let minors = Live(API.minors) { _ in
                [Minor(email: "a@x", isMinor: true), Minor(email: "a@x", isMinor: false), Minor(email: "a@x", isMinor: false)]
            }
            let roster = Live<[Row]>.joining(attendees, minors, on: \.email, \.email, label: "roster") { Row(name: $0.name, minor: $1?.isMinor) }
            await until { roster.phase.value != nil }
            #expect(roster.phase.value == [Row(name: "Ana", minor: true), Row(name: "Ana again", minor: true)], "left repeats each join")
            let event = try #require(events.events(named: "live.join_duplicate_key").first)
            #expect(event.level == .error)
            #expect(event.label == "roster")
            #expect(event["repeated"]?.description == "2")
        }
    }

    // MARK: Permissions

    enum EditEvent: Permission {
        typealias Subject = String
        typealias Principal = String
        static let name = "test.edit-event"
    }

    struct Session: PrincipalEvidence {
        struct Mint { fileprivate init() {} }
        static let proves = "a signed-in session"
    }

    struct Organisers: PermissionPolicy {
        typealias Granting = EditEvent
        typealias Authentication = Session
        let name = "organisers"
        let script: Script<PermissionDecision>
        nonisolated(nonsending) func decide(_ principal: Verified<String, Session>, _ subject: String) async throws -> PermissionDecision {
            try await script.call(nil)
        }
    }

    static let ana = Minter<Session>(Session.Mint()).verified("ana", Session())

    static func permission(
        _ script: Script<PermissionDecision>, refresh: Script<Void>? = nil, freshFor: Duration? = .seconds(60)
    ) -> Live<PermissionCheck<EditEvent>> {
        Live(API.roles, freshFor: freshFor) { attempt in
            if let refresh { try await refresh.call(attempt) }
            return try await Organisers(script: script).check(Claimed("beach-clean"), by: Self.ana)
        }
    }

    @Test(.failureMode("design/31", "a permission Live is pending"))
    func aPendingPermissionIsUnknownLoadingNeverDenied() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let decisions = Script<PermissionDecision>(.gated(gate, .allow))
            let canEdit = Self.permission(decisions)
            guard case .unknown(.loading) = canEdit.check() else { Issue.record("\(canEdit.check())"); return }
            gate.open()
            await until { if case .granted = canEdit.check() { true } else { false } }
        }
    }

    @Test(.failureMode("design/31", "a permission Live's refresh fails"))
    func aFailedRefreshDropsAHeldGrant() async throws {
        try await onLiveTime { _, _ in
            let decisions = Script<PermissionDecision>(.value(.allow))
            let refresh = Script<Void>(.value(()), .failure(Refused()))
            let canEdit = Self.permission(decisions, refresh: refresh)
            await until { if case .granted = canEdit.check() { true } else { false } }
            canEdit.refresh()
            await until { canEdit.current.failure != nil }
            guard case .unknown(.unavailable(let why)) = canEdit.check() else { Issue.record("\(canEdit.check())"); return }
            #expect(why.contains("reference"), "unknown is not an answer, even with a grant held")
        }
    }

    @Test(.failureMode("design/31", "a permission Live's refresh fails and the screen keeps its grant for a time"))
    func keepingAGrantForAStatedTimeIsADeclaredChoice() async throws {
        try await onLiveTime { clock, _ in
            let decisions = Script<PermissionDecision>(.value(.allow))
            let refresh = Script<Void>(.value(()), .failure(Refused()))
            // No freshFor: its own timer would make the failed value stale again.
            let canEdit = Self.permission(decisions, refresh: refresh, freshFor: nil)
            await until { if case .granted = canEdit.check() { true } else { false } }
            await clock.advance(by: .seconds(30))
            canEdit.refresh()
            await until { canEdit.current.failure != nil }
            guard case .granted = canEdit.check(keepingGrantFor: .seconds(120)) else { Issue.record("kept"); return }
            await clock.advance(by: .seconds(90))
            guard case .unknown(.unavailable) = canEdit.check(keepingGrantFor: .seconds(120)) else {
                Issue.record("a grant loaded two minutes ago is no longer kept")
                return
            }
            guard case .unknown(.unavailable) = canEdit.check() else { Issue.record("the default keeps nothing"); return }
        }
    }

    @Test(.failureMode("design/31", "a permission Live is stale"))
    func aStalePermissionIsTheStaleCheck() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let decisions = Script<PermissionDecision>(.value(.allow), .gated(gate, .deny("no longer an organiser")))
            let canEdit = Self.permission(decisions)
            await until { if case .granted = canEdit.check() { true } else { false } }
            canEdit.invalidate()
            _ = canEdit.check()   // on screen: the read refreshes it
            await until { canEdit.current.isRefreshing }
            guard case .granted = canEdit.check() else { Issue.record("a stale grant still grants: the server checks again"); return }
            gate.open()
            await until { if case .denied = canEdit.check() { true } else { false } }
        }
    }
}

extension Live.Phase {
    var isRefreshing: Bool {
        if case .stale(_, refreshing: true) = self { return true }
        return false
    }
}

/// A counter shared by test tasks.
final class SendableCounter: Sendable {
    private let count = Mutex(0)

    /// The value before this call, then counts it.
    func next() -> Int {
        count.withLock { value in
            defer { value += 1 }
            return value
        }
    }

    var value: Int { count.withLock { $0 } }
}

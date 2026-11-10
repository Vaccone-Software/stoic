import Foundation
import Stoic
import StoicTesting
import Testing

/// design/27 at rest: reading, applying and settling a record, as pure
/// functions of the record, the definition and a moment; and the
/// storage-agnostic rows through `update` on an in-memory store.
/// What `update` throws on an in-memory store of `L`.
typealias UpdateError<L: Lifecycle> = LifecycleUpdateError<L, InMemoryLifecycleStore<L, String>.Failure>

@Suite("Lifecycles at rest")
struct LifecycleTests {
    typealias Waiver = ParentWaiver
    let admin = Someone.staff("admin")
    let parent = "parent@example.com"

    func sentWaiver(at moment: Moment = wallStart) throws -> Waiver.Record {
        let record = Waiver.Record.make(.awaitingAddress, by: admin, at: moment)
        return try record.applying(.send(to: parent), by: admin, because: "address confirmed", at: moment).record
    }

    // MARK: Reading

    @Test(.failureMode("design/27", "a state's timeout falls due and nobody writes the record"))
    func aDueTimeoutIsAppliedOnEveryReadAndNothingIsWritten() async throws {
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            let record = try sentWaiver()
            #expect(record.state(at: wallStart + day * 7 - .seconds(1)) == .sent)
            let reading = record.read(at: wallStart + day * 8)
            #expect(reading.state == .expired)
            #expect(reading.since == wallStart + day * 7, "entered at the due moment")
            #expect(reading.pending.count == 1)
            let entry = try #require(reading.pending.first)
            #expect(entry.from == .sent && entry.event == .expire && entry.to == .expired && entry.entered)
            #expect(entry.at == wallStart + day * 7 && entry.by == .timeout && entry.because == "after 604800 s")
            #expect(entry.sequence == record.sequence)
            #expect(record.written.state == .sent, "nothing is written")
            #expect(record.written.dueAt == wallStart + day * 7)
            #expect(reading.nextDue == nil, "expired has no timeout")
            #expect(!reading.isTruncated)
        }
        #expect(events.events.isEmpty, "a read reports nothing")
    }

    @Test(.failureMode("design/27", "several timeouts fall due one after another before a read"))
    func severalDueTimeoutsAreAppliedInOrderEachAtItsOwnMoment() {
        let record = Relay.Record.make(.first, by: "test")
        let reading = record.read(at: wallStart + hour * 3)
        #expect(reading.state == .third)
        #expect(reading.pending.map(\.to) == [.second, .third])
        #expect(reading.pending.map(\.at) == [wallStart + hour, wallStart + hour * 2])
        #expect(reading.pending.map(\.sequence) == [0, 1])
        #expect(record.read(at: wallStart + hour + .seconds(1)).state == .second)
        #expect(record.read(at: wallStart + hour + .seconds(1)).nextDue == wallStart + hour * 2)
    }

    /// The event's end had already passed when the volunteer checked in (a
    /// late scan): onSite times out at once, dated the moment it was entered.
    @Test(.failureMode("design/27", "a state is entered after its own `.at` moment has passed"))
    func aStateEnteredAfterItsAtMomentTimesOutAtOnce() throws {
        let ends = wallStart + hour * 2
        let record = Attendance.Record.make(.signedUp(eventEnds: ends), by: .volunteer("v"))
        let late = wallStart + hour
        let checkedIn = try record.applying(.checkIn(closesAt: late - .seconds(60)), by: .volunteer("v"), because: "scanned", at: late)
        #expect(checkedIn.record.written.state == .onSite(closesAt: late - .seconds(60)))
        let reading = checkedIn.record.read(at: late)
        #expect(reading.state == .closedUnattended)
        #expect(reading.pending.first?.at == late, "dated the moment the state was entered, not before it")
    }

    @Test(.failureMode("design/27", "an event is applied to a record whose state timed out unread"))
    func anEventMeetsTheStateTheTimeoutLedTo() throws {
        let record = try sentWaiver()
        // A send after expiry: the timed entry first, then the event's.
        let later = wallStart + day * 9
        let change = try record.applying(.send(to: parent), by: admin, because: "sent again", at: later)
        #expect(change.entries.map(\.event) == [.expire, .send(to: parent)])
        #expect(change.entries.map(\.by) == [.timeout, .principal(admin)])
        #expect(change.entries.map(\.at) == [wallStart + day * 7, later])
        #expect(change.record.written.state == .sent && change.record.written.since == later)
        #expect(change.base == record.revision && change.record.revision == record.revision + 1)
        #expect(change.record.sequence == record.sequence + 2)
        // A refusal names the state the timeout led to.
        #expect(throws: Waiver.Refusal.ignored(state: .expired, event: .expire)) {
            try record.applying(.expire, by: admin, because: "by hand", at: later)
        }
    }

    // MARK: Refusals, through update

    @Test(.failureMode("design/27", "an expired waiver's link is used to sign"))
    func anExpiredLinkIsRefusedOnEveryPath() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let store = InMemoryLifecycleStore<Waiver, String>()
            #expect(await store.insert(try sentWaiver(), as: "w1"))
            await clock.advance(by: day * 8)
            // The page that shows the link reads the state…
            #expect(try await store.read("w1")?.state == .expired)
            // …and the action that completes it is refused with the reason.
            do throws(UpdateError<Waiver>) {
                try await store.apply(.sign, to: "w1", by: .parent("link-1"), because: "signed through the emailed link")
                Issue.record("an expired link signed")
            } catch .refused(.refused(state: .expired, event: .sign, reason: let reason)) {
                #expect(reason == "this link has expired")
            }
            #expect(await store.load("w1")?.revision == 2, "nothing changed")
        }
    }

    @Test(.failureMode("design/27", "an event means nothing in the current state"))
    func anIgnoredEventChangesNothingAndIsReportedAtInfo() async throws {
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            let store = InMemoryLifecycleStore<Waiver, String>()
            _ = await store.insert(try sentWaiver(), as: "w1")
            await #expect(throws: LifecycleUpdateError<Waiver, InMemoryLifecycleStore<Waiver, String>.Failure>.self) {
                try await store.apply(.send(to: parent), to: "w1", by: admin, because: "pressed twice")
            }
            #expect(await store.load("w1")?.revision == 2)
            #expect(await store.effects.isEmpty, "no second email")
        }
        let refused = try #require(events.events(named: "lifecycle.refused").first)
        #expect(refused.level == .info && refused.label == Waiver.name)
        #expect(refused["kind"]?.description == "ignored")
        #expect(refused.fields.first { $0.key == "state" }?.privacy == .private)
    }

    @Test(.failureMode("design/27", "an event is refused with a reason"))
    func aRefusedEventCarriesItsReasonAndChangesNothing() async throws {
        let events = RecordingInstrumentation()
        let record = Attendance.Record.make(.signedUp(eventEnds: wallStart + day), by: .volunteer("v"))
        #expect(throws: Attendance.Refusal.refused(state: .signedUp(eventEnds: wallStart + day), event: .checkOut, reason: "you have not checked in")) {
            try record.applying(.checkOut, by: .volunteer("v"), because: "tapped", at: wallStart)
        }
        try await withTestAmbient(clock: TestClock(), events: events) {
            let store = InMemoryLifecycleStore<Attendance, String>()
            _ = await store.insert(record, as: "a1")
            do throws(UpdateError<Attendance>) {
                try await store.apply(.checkOut, to: "a1", by: .volunteer("v"), because: "tapped check-out")
                Issue.record("refused check-out committed")
            } catch .refused(.refused(state: _, event: _, reason: let reason)) {
                #expect(reason == "you have not checked in")
            }
            #expect(await store.load("a1") == record)
        }
        #expect(events.events(named: "lifecycle.refused").first?.level == .info)
        #expect(events.events(named: "lifecycle.refused").first?["kind"]?.description == "refused")
    }

    @Test(.failureMode("design/27", "an event should be impossible in the current state"))
    func anInvalidEventIsReportedAtErrorLevel() async throws {
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            let store = InMemoryLifecycleStore<Attendance, String>()
            _ = await store.insert(.make(.checkedOut, by: .staff("s")), as: "a1")
            do throws(UpdateError<Attendance>) {
                try await store.apply(.vouch, to: "a1", by: .staff("s"), because: "vouched")
                Issue.record("an invalid event committed")
            } catch .refused(.invalid(state: .checkedOut, event: .vouch, reason: _)) {}
            #expect(await store.load("a1")?.revision == 1)
        }
        #expect(events.events(named: "lifecycle.invalid").map(\.level) == [.error])
    }

    // MARK: Stays and re-entry

    @Test(.failureMode("design/27", "an event is accepted with `.stay`"))
    func aStayIsHistoryAndLeavesTheTimeoutRunning() throws {
        let record = Reminder.Record.make(.waiting, by: "p")
        let change = try record.applying(.nudge, by: "p", because: "a reminder", at: wallStart + .seconds(600))
        let entry = try #require(change.entries.first)
        #expect(change.entries.count == 1)
        #expect(entry.from == .waiting && entry.to == .waiting && !entry.entered)
        #expect(change.record.revision == 2, "the revision moves")
        #expect(change.record.written.since == wallStart, "since is unchanged")
        #expect(change.record.written.updated == wallStart + .seconds(600))
        #expect(change.record.written.dueAt == wallStart + hour, "the running timeout is unchanged")
        #expect(change.effects.map(\.effect) == [.notify("nudged")])
    }

    @Test(.failureMode("design/27", "a state is re-entered"))
    func reenteringAStateRestartsItsTimeout() throws {
        let record = Reminder.Record.make(.waiting, by: "p")
        let at = wallStart + .seconds(1_800)
        let change = try record.applying(.extend, by: "p", because: "more time", at: at)
        #expect(change.entries.first?.entered == true)
        #expect(change.record.written.since == at)
        #expect(change.record.written.dueAt == at + hour)
        #expect(change.record.state(at: wallStart + hour + .seconds(1)) == .waiting, "the old timeout is gone")
    }

    // MARK: Defective definitions

    @Test(.failureMode("design/27", "a state's own timeout event does not move it"))
    func aTimeoutThatDoesNotMoveItsStateStopsTheReadAndIsReported() async throws {
        let record = Stuck.Record.make(.stuck, by: "p")
        let reading = record.read(at: wallStart + hour * 2)
        #expect(reading.state == .stuck && reading.pending.isEmpty)
        #expect(reading.nextDue == wallStart + hour, "due, and in the past: a defect")
        let graph = StateGraph<Stuck.State, Stuck.Event>.explore(Stuck.self, from: [.stuck], events: Stuck.Event.allCases)
        #expect(graph.stuckTimeouts == [.stuck])
        let events = RecordingInstrumentation()
        let clock = TestClock()
        try await withTestAmbient(clock: clock, events: events) {
            clock.jumpWallClock(by: hour * 2)
            let store = InMemoryLifecycleStore<Stuck, String>()
            _ = await store.insert(record, as: "s")
            try await store.apply(.poke, to: "s", by: "p", because: "a poke")
        }
        #expect(events.events(named: "lifecycle.timeout_refused").map(\.level) == [.error])
    }

    @Test(.failureMode("design/27", "timeouts form a cycle"))
    func timedCyclesAreFoundAndCutAtTheCap() async throws {
        let graph = StateGraph<Blinker.State, Blinker.Event>.explore(Blinker.self, from: [.on], events: [.poke])
        #expect(graph.timedCycles == [[.on, .off]])
        let record = Blinker.Record.make(.on, by: "p")
        let reading = record.read(at: wallStart + hour * 100)
        #expect(reading.isTruncated && reading.pending.count == 64)
        #expect(throws: Blinker.Refusal.chainTooLong(state: reading.state, steps: 64)) {
            try record.applying(.poke, by: "p", because: "a poke", at: wallStart + hour * 100)
        }
        let events = RecordingInstrumentation()
        let clock = TestClock()
        await withTestAmbient(clock: clock, events: events) {
            clock.jumpWallClock(by: hour * 100)
            let store = InMemoryLifecycleStore<Blinker, String>()
            _ = await store.insert(record, as: "b")
            await #expect(throws: (any Error).self) { try await store.settle("b") }
        }
        #expect(events.events(named: "lifecycle.chain_truncated").map(\.level) == [.error])
        // An hour on, settling commits the one flip.
        #expect(try record.settling(at: wallStart + hour)?.entries.count == 1)
        #expect(record.read(at: wallStart + hour * 10).isTruncated == false)
    }

    // MARK: The wall clock

    @Test(.failureMode("design/27", "the wall clock jumps forward"))
    func aForwardJumpMakesTimeoutsFallDueEarly() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let record = try sentWaiver()
            #expect(record.state() == .sent)
            clock.jumpWallClock(by: day * 8)
            #expect(record.state() == .expired)
            #expect(record.written == (try sentWaiver()).written, "nothing else changed")
        }
    }

    @Test(.failureMode("design/27", "the wall clock jumps backward"))
    func aBackwardJumpUndoesNothingCommittedAndDatesNewEntriesNoEarlier() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, events: events) {
            let store = InMemoryLifecycleStore<Reminder, String>()
            _ = await store.insert(.make(.waiting, by: "p"), as: "r")
            clock.jumpWallClock(by: hour * 2)
            try await store.settle("r")   // the lapse is committed: a fact
            #expect(await store.load("r")?.written.state == .done)
            clock.jumpWallClock(by: .zero - hour * 3)
            #expect(try await store.read("r")?.state == .done, "committed entries stand")

            // A projected, uncommitted timeout is no longer due once the
            // clock goes back.
            _ = await store.insert(.make(.waiting, by: "p", at: wallStart - hour * 3, key: "second-key-0123456789abcd"), as: "q")
            #expect(try await store.read("q")?.state == .done, "an hour and more after it was made")
            clock.jumpWallClock(by: .zero - hour - .seconds(1))
            #expect(try await store.read("q")?.state == .waiting, "projected, not committed: no longer due")
            #expect(await store.load("q")?.revision == 1)
        }
    }

    @Test(.failureMode("design/27", "a new entry is dated before the record's latest moment"))
    func anEntryIsRaisedToTheRecordsLatestMomentAndReported() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, events: events) {
            let store = InMemoryLifecycleStore<Reminder, String>()
            _ = await store.insert(.make(.waiting, by: "p"), as: "r")
            clock.jumpWallClock(by: .seconds(600))
            try await store.apply(.nudge, to: "r", by: "p", because: "first")
            clock.jumpWallClock(by: .seconds(-300))
            let record = try await store.apply(.nudge, to: "r", by: "p", because: "second")
            let history = await store.history(of: "r")
            #expect(history.map(\.at) == [wallStart + .seconds(600), wallStart + .seconds(600)])
            #expect(record.written.updated == wallStart + .seconds(600))
        }
        let behind = try #require(events.events(named: "lifecycle.clock_behind").first)
        #expect(behind.level == .notice)
        #expect(behind["behind"]?.description == Duration.seconds(300).description)
    }

    /// Records at rest read the wall clock; a live machine's timers sleep on
    /// the monotonic clock, which a jump of the wall clock alone does not move.
    @Test(.failureMode("design/27", "a test jumps the wall clock alone"))
    func aWallClockJumpMovesRecordsAtRestAndNotLiveTimers() async throws {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let record = Reminder.Record.make(.waiting, by: "p")
            let machine = StateMachine(Reminder.self, initial: .waiting, clock: AnyClock(clock), perform: { _ in })
            await clock.waitForSleepers(count: 1)
            clock.jumpWallClock(by: hour * 2)
            #expect(record.state() == .done)
            #expect(machine.state == .waiting)
            #expect(clock.pendingDeadlines.count == 1)
            await machine.shutdown()
        }
    }

    // MARK: Conflicts

    @Test(.failureMode("design/27", "two writers commit changes made from the same revision"))
    func theSecondWriterConflictsAndUpdateAppliesItsClosureAgain() async throws {
        let store = InMemoryLifecycleStore<CharityApproval, String>()
        let record = CharityApproval.Record.make(.submitted, by: .service("signup"))
        _ = await store.insert(record, as: "c")
        let approve = try record.applying(.approve, by: .staff("a"), because: "checked", at: wallStart)
        let reject = try record.applying(.reject, by: .staff("b"), because: "not checked", at: wallStart)
        guard case .committed = try await store.commit(approve, to: "c") else { Issue.record("first did not commit"); return }
        guard case .conflict(let current) = try await store.commit(reject, to: "c") else {
            Issue.record("second did not conflict")
            return
        }
        #expect(current == approve.record)
        // Through update, the closure is applied again to the current record.
        var seen: [CharityApproval.State] = []
        await #expect(throws: (any Error).self) {
            try await store.update("c") { (record) throws(CharityApproval.Refusal) in
                seen.append(record.written.state)
                return try record.applying(.reject, by: .staff("b"), because: "not checked", at: wallStart)
            }
        }
        #expect(seen == [.approved], "rejecting an approved charity is ignored")
        let conflicting = InMemoryLifecycleStore<CharityApproval, String>()
        _ = await conflicting.insert(record, as: "c")
        await conflicting.conflictNextCommit(to: "c")
        var attempts = 0
        try await conflicting.update("c") { (record) throws(CharityApproval.Refusal) in
            attempts += 1
            return try record.applying(.approve, by: .staff("a"), because: "checked", at: wallStart)
        }
        #expect(attempts == 2)
        #expect(await conflicting.effects.count == 1)
    }

    @Test(.failureMode("design/27", "conflicts continue past the attempts"))
    func conflictsPastTheAttemptsAreReportedAndThrown() async throws {
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            let store = InMemoryLifecycleStore<CharityApproval, String>()
            _ = await store.insert(.make(.submitted, by: .service("signup")), as: "c")
            await store.conflictNextCommit(to: "c", times: 3)
            do throws(UpdateError<CharityApproval>) {
                try await store.apply(.approve, to: "c", by: .staff("a"), because: "checked")
                Issue.record("committed through three conflicts")
            } catch .conflict(let attempts) {
                #expect(attempts == 3)
            }
            #expect(await store.load("c")?.revision == 1)
        }
        #expect(events.events(named: "lifecycle.conflict").map(\.level) == [.notice, .notice, .warning])
        let error = LifecycleUpdateError<CharityApproval, InMemoryLifecycleStore<CharityApproval, String>.Failure>.conflict(attempts: 3)
        #expect(error.retryDecision == .retry)
        #expect(LifecycleUpdateError<CharityApproval, InMemoryLifecycleStore<CharityApproval, String>.Failure>.notFound.retryDecision == .stop)
    }

    @Test(.failureMode("design/27", "the same event is sent twice at once"))
    func theSameEventSentTwiceAtOnceSendsOneEmail() async throws {
        let store = InMemoryLifecycleStore<Waiver, String>()
        _ = await store.insert(.make(.awaitingAddress, by: admin), as: "w")
        let parent = parent
        let admin = admin
        async let first: Bool = { () async -> Bool in
            do { try await store.apply(.send(to: parent), to: "w", by: admin, because: "pressed send"); return true } catch { return false }
        }()
        async let second: Bool = { () async -> Bool in
            do { try await store.apply(.send(to: parent), to: "w", by: admin, because: "pressed send"); return true } catch { return false }
        }()
        let outcomes = await [first, second]
        #expect(outcomes.filter { $0 }.count == 1, "one commits, the other is ignored")
        #expect(await store.effects.map(\.effect) == [.emailSigningLink(to: parent)])
    }

    @Test(.failureMode("design/27", "two writers commit the same due timeout"))
    func twoWritersOfTheSameDueTimeoutMakeTheSameEntriesAndKeys() async throws {
        let record = CharityApproval.Record.make(.submitted, by: .service("signup"))
        let now = wallStart + day * 15
        let one = try #require(try record.settling(at: now))
        let other = try #require(try record.settling(at: now))
        #expect(one.entries == other.entries)
        #expect(one.effects.map(\.key) == other.effects.map(\.key))
        let store = InMemoryLifecycleStore<CharityApproval, String>()
        _ = await store.insert(record, as: "c")
        guard case .committed = try await store.commit(one, to: "c"),
            case .conflict(let current) = try await store.commit(other, to: "c")
        else { Issue.record("expected one commit and one conflict"); return }
        #expect(current?.written.state == .lapsed)
        #expect(await store.history(of: "c") == one.entries)
        #expect(await store.effects.map(\.key) == one.effects.map(\.key), "enqueued once")
    }

    @Test(.failureMode("design/27", "a change made from one record is committed to another"))
    func aChangeFromAnotherRecordIsRefused() async throws {
        let store = InMemoryLifecycleStore<Reminder, String>()
        let first = Reminder.Record.make(.waiting, by: "p", key: "first-key-0123456789abcdef")
        let second = Reminder.Record.make(.waiting, by: "p", key: "other-key-0123456789abcdef")
        _ = await store.insert(first, as: "a")
        _ = await store.insert(second, as: "b")
        let change = try first.applying(.finish, by: "p", because: "done", at: wallStart)
        await #expect(throws: InMemoryLifecycleStore<Reminder, String>.Failure.foreignChange) {
            try await store.commit(change, to: "b")
        }
        #expect(await store.load("b") == second)
        let untouched = await store.history(of: "b")
        #expect(untouched.isEmpty)
    }

    @Test(.failureMode("design/27", "a record is inserted under an id that exists"))
    func insertingUnderATakenIdLeavesTheRecord() async throws {
        let store = InMemoryLifecycleStore<Reminder, String>()
        let first = Reminder.Record.make(.waiting, by: "p", key: "first-key-0123456789abcdef")
        #expect(await store.insert(first, as: "a"))
        #expect(await store.insert(.make(.done, by: "q", key: "other-key-0123456789abcdef"), as: "a") == false)
        #expect(await store.load("a") == first)
    }

    // MARK: Versions and evolution

    @Test(.failureMode("design/27", "an older definition applies an event to a record a newer one wrote"))
    func anOlderDefinitionDoesNotWriteOverANewerOnesRecord() async throws {
        let newer = ParentWaiverV2.Record.make(.awaitingAddress, by: admin)
        #expect(newer.version == 2)
        let bytes = try JSONEncoder().encode(newer)
        let asOlder = try JSONDecoder().decode(ParentWaiver.Record.self, from: bytes)
        #expect(asOlder.state(at: wallStart) == .awaitingAddress, "reading still works")
        #expect(throws: ParentWaiver.Refusal.newerDefinition(written: 2, current: 1)) {
            try asOlder.applying(.revoke, by: admin, because: "withdrawn", at: wallStart)
        }
        let events = RecordingInstrumentation()
        await withTestAmbient(clock: TestClock(), events: events) {
            let store = InMemoryLifecycleStore<ParentWaiver, String>()
            _ = await store.insert(asOlder, as: "w")
            await #expect(throws: (any Error).self) { try await store.apply(.revoke, to: "w", by: admin, because: "withdrawn") }
            #expect(await store.load("w") == asOlder)
        }
        #expect(events.events(named: "lifecycle.newer_definition").map(\.level) == [.warning])
    }

    @Test(.failureMode("design/27", "a timeout is changed in a new build"))
    func aChangedTimeoutAppliesToRecordsAlreadyWaiting() throws {
        let written = try sentWaiver()
        let bytes = try JSONEncoder().encode(written)
        let underNewBuild = try JSONDecoder().decode(ParentWaiverV2.Record.self, from: bytes)
        let fourDays = wallStart + day * 4
        #expect(written.state(at: fourDays) == .sent)
        #expect(underNewBuild.state(at: fourDays) == .expired, "four-day-old waivers expire at once")
        #expect(underNewBuild.read(at: fourDays).pending.first?.at == wallStart + day * 3)
        #expect(underNewBuild.sequence == written.sequence, "committed entries are unchanged")
    }

    @Test(.failureMode("design/27", "a record is in a retired state"))
    func aRetiredStateIsMigratedOnTheNextReadAndCommittedWithTheNextWrite() throws {
        let record = Ticket.Record.make(.pending, by: "import")
        let reading = record.read(at: wallStart)
        #expect(reading.state == .queued)
        #expect(reading.pending.first?.by == .timeout && reading.pending.first?.because == "after 0 s")
        let change = try record.applying(.close, by: "agent", because: "resolved", at: wallStart + hour)
        #expect(change.entries.map(\.event) == [.migrate, .close])
        let graph = StateGraph<Ticket.State, Ticket.Event>.explore(Ticket.self, from: [.pending, .queued], events: Ticket.Event.allCases)
        #expect(graph.retiredEntries.isEmpty && graph.retiredWithoutExit.isEmpty)
    }

    @Test(.failureMode("design/27", "a history entry holds an event that was retired"))
    func anEntryWithARetiredEventStillDecodes() throws {
        // Written when `hurry` meant something; read by a build that refuses it.
        let json = #"""
            {"at":"2026-01-01T00:00:00Z","because":"a customer called","by":{"principal":"agent"},"effects":[],\#
            "entered":false,"event":"hurry","from":"queued","record":"record-key-0123456789abcdef","sequence":0,"to":"queued"}
            """#
        let entry = try JSONDecoder().decode(Ticket.Entry.self, from: Data(json.utf8))
        #expect(entry.event == .hurry && entry.by == .principal("agent"))
        #expect(throws: Ticket.Refusal.refused(state: .queued, event: .hurry, reason: "retired: hurrying is no longer offered")) {
            try Ticket.Record.make(.queued, by: "agent").applying(.hurry, by: "agent", because: "again", at: wallStart)
        }
    }

    // MARK: Effects and their keys

    @Test(.failureMode("design/27", "a transition carries effects"))
    func effectKeysDeriveFromTheRecordTheEntryAndThePosition() throws {
        let record = Waiver.Record.make(.awaitingAddress, by: admin)
        let change = try record.applying(.send(to: parent), by: admin, because: "sent", at: wallStart)
        let again = try record.applying(.send(to: parent), by: admin, because: "sent", at: wallStart + .seconds(5))
        let effect = try #require(change.effects.first)
        #expect(change.effects.count == 1)
        #expect(effect.key == IdempotencyKey.lifecycle(record: record.key, entry: 0, position: 0))
        #expect(effect.record == record.key && effect.entry == 0)
        #expect(change.entries.first?.effects == [effect.key])
        #expect(again.effects.map(\.key) == change.effects.map(\.key), "making the change again gives the same keys")
        #expect(effect.key.rawValue.count == 32)
    }

    /// The key is frozen: these values are what every build must make.
    @Test func effectKeysAreFrozen() {
        let record = IdempotencyKey(rawValue: "0123456789abcdef0123456789abcdef")
        #expect(IdempotencyKey.lifecycle(record: record, entry: 0, position: 0).rawValue == Self.frozen00)
        #expect(IdempotencyKey.lifecycle(record: record, entry: 7, position: 2).rawValue == Self.frozen72)
    }

    static let frozen00 = "3b4f2e06c773d1aa32aa827e7e3ce12b"
    static let frozen72 = "2563adbc28426d4393d2ea64d201d658"

    @Test func effectKeysAreDistinctAcrossRecordsEntriesAndPositions() {
        var generator = RandomSource.seeded(27).generator()
        var keys = Set<IdempotencyKey>()
        var records: [IdempotencyKey] = []
        for _ in 0..<1_000 {
            records.append(IdempotencyKey(rawValue: String(generator.next(), radix: 16) + String(generator.next(), radix: 16)))
        }
        for record in records {
            for entry in 0..<50 as Range<UInt64> {
                for position in 0..<20 { keys.insert(.lifecycle(record: record, entry: entry, position: position)) }
            }
        }
        #expect(keys.count == 1_000 * 50 * 20, "10⁶ draws, no collision")
    }

    // MARK: History

    @Test(.failureMode("design/27", "a record's history is checked"))
    func historyVerificationFindsEachFault() throws {
        let record = try sentWaiver()
        let change = try record.applying(.revoke, by: admin, because: "withdrawn", at: wallStart + day)
        var history: [Waiver.Entry] = []
        let first = try Waiver.Record.make(.awaitingAddress, by: admin)
            .applying(.send(to: parent), by: admin, because: "address confirmed", at: wallStart)
        history = first.entries + change.entries
        let final = change.record
        try LifecycleHistory.verify(history, of: final)
        #expect(throws: HistoryGap(.missing(1))) { try LifecycleHistory.verify(Array(history.prefix(1)), of: final) }
        #expect(throws: HistoryGap(.missing(0))) { try LifecycleHistory.verify(Array(history.suffix(1)), of: final) }
        let stranger = try Waiver.Record.make(.awaitingAddress, by: admin, key: "stranger-key-0123456789ab")
            .applying(.send(to: parent), by: admin, because: "x", at: wallStart).entries
        #expect(throws: HistoryGap(.foreign(0))) { try LifecycleHistory.verify(stranger + change.entries, of: final) }
        let otherEnd = try record.applying(.sign, by: .parent("p"), because: "signed", at: wallStart + day).entries
        #expect(throws: HistoryGap(.endsElsewhere(1))) { try LifecycleHistory.verify(first.entries + otherEnd, of: final) }
        let fromElsewhere = try Waiver.Record.make(.expired, by: admin).applying(.revoke, by: admin, because: "x", at: wallStart)
        #expect(throws: HistoryGap(.broken(1))) {
            try LifecycleHistory.verify(first.entries + fromElsewhere.entries.map { Waiver.Entry.reNumbered($0, 1) }, of: final)
        }
    }

    // MARK: Queries and coding

    @Test(.failureMode("design/27", "a database query selects by the written state"))
    func aQueryByWrittenStateNeedsTheReadAndTheDueMoment() async throws {
        let store = InMemoryLifecycleStore<Waiver, String>()
        _ = await store.insert(try sentWaiver(), as: "old")
        _ = await store.insert(try sentWaiver(at: wallStart + day * 6).with(key: "fresh"), as: "fresh")
        let now = wallStart + day * 8
        var bySent: [String] = []
        for id in ["old", "fresh"] where await store.load(id)?.written.state == .sent { bySent.append(id) }
        #expect(bySent == ["old", "fresh"], "the written state includes a waiver that expired unread")
        var reallySent: [String] = []
        for id in bySent where await store.load(id)?.read(at: now).state == .sent { reallySent.append(id) }
        #expect(reallySent == ["fresh"])
        var notDue: [String] = []
        for id in bySent where (await store.load(id)?.written.dueAt).map({ $0 > now }) ?? true { notDue.append(id) }
        #expect(notDue == ["fresh"], "a query that filters on dueAt too")
    }

    @Test func theEncodedFormIsFixed() throws {
        let record = try sentWaiver()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(record), as: UTF8.self)
        #expect(text == #"{"created":{"at":"2026-01-01T00:00:00Z","because":"made by a test","by":{"principal":{"staff":{"_0":"admin"}}}},"dueAt":"2026-01-08T00:00:00Z","key":"record-key-0123456789abcdef","lifecycle":"kindora.parent-waiver","revision":2,"sequence":1,"since":"2026-01-01T00:00:00Z","state":"sent","updated":"2026-01-01T00:00:00Z","version":1}"#)
        let entry = try record.applying(.revoke, by: admin, because: "withdrawn", at: wallStart).entries[0]
        let entryText = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(entryText.contains(#""by":{"principal":{"staff":{"_0":"admin"}}}"#))
        let timed = try #require(record.read(at: wallStart + day * 8).pending.first)
        #expect(String(decoding: try encoder.encode(timed), as: UTF8.self).contains(#""by":"timeout""#))
        // A record of another lifecycle does not decode as this one.
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CharityApproval.Record.self, from: encoder.encode(record)) }
        #expect(try JSONDecoder().decode(Waiver.Record.self, from: encoder.encode(record)) == record)
    }

    // MARK: Properties

    @Test func readingThenApplyingAgreeAndSettlingThenReadingIsReading() throws {
        let record = try sentWaiver()
        for offset in stride(from: 0, through: 10, by: 1) {
            let now = wallStart + .seconds(offset * 86_400)
            let reading = record.read(at: now)
            let settled = try record.settling(at: now)?.record ?? record
            #expect(settled.read(at: now).state == reading.state)
            #expect(settled.read(at: now).since == reading.since)
            if let change = try? record.applying(.revoke, by: admin, because: "x", at: now) {
                #expect(change.entries.first?.from == reading.state || !reading.pending.isEmpty)
                #expect(change.entries.dropLast() == reading.pending[...])
            }
        }
        // Without timeouts, reading is the identity.
        let plain = Attendance.Record.make(.checkedOut, by: .staff("s"))
        #expect(plain.read(at: wallStart + day * 1_000).state == .checkedOut)
        #expect(try plain.settling(at: wallStart + day * 1_000) == nil)
    }
}

extension LifecycleEntry {
    /// `entry` with another sequence: for a test that builds a broken history.
    static func reNumbered(_ entry: Self, _ sequence: UInt64) -> Self {
        let encoder = JSONEncoder()
        var object = (try? JSONSerialization.jsonObject(with: encoder.encode(entry))) as? [String: Any] ?? [:]
        object["sequence"] = sequence
        object["record"] = "record-key-0123456789abcdef"
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        do { return try JSONDecoder().decode(Self.self, from: data) } catch { preconditionFailure("\(error)") }
    }
}

extension LifecycleRecord {
    /// This record under another key, as another record made the same way.
    func with(key: String) -> Self {
        var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
        object["key"] = key
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        do { return try JSONDecoder().decode(Self.self, from: data) } catch { preconditionFailure("\(error)") }
    }
}

import Stoic
import StoicTesting
import Testing

/// design/27's first ideal scenario: a volunteering service whose records
/// live in a server database (here, its in-memory stand-in), and the checks
/// a test makes of each definition.
@Suite("Lifecycles: the volunteering service")
struct LifecycleScenarioTests {
    let me = Someone.volunteer("u-1")
    let admin = Someone.staff("admin")
    let parent = "parent@example.com"

    @Test func theVolunteeringServiceReadsOneStateEverywhere() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, events: events) {
            let attendance = InMemoryLifecycleStore<Attendance, String>()
            let waivers = InMemoryLifecycleStore<ParentWaiver, String>()
            let approvals = InMemoryLifecycleStore<CharityApproval, String>()
            let eventEnd = Moment.now + hour * 6

            // Sign-up creates the record. The event's end is known now.
            #expect(await attendance.insert(.new(in: .signedUp(eventEnds: eventEnd), by: me, because: "signed up in the app"), as: "c-1"))

            // Check-in from the geofence, the QR scan or a coordinator's list: one path, one rule.
            await clock.advance(by: hour * 5)
            try await attendance.apply(.checkIn(closesAt: eventEnd + hour), to: "c-1", by: me, because: "scanned the event's code 40 m from the site")
            #expect(try await attendance.read("c-1")?.state == .onSite(closesAt: eventEnd + hour))

            // Nobody checks out. After `closesAt` the state is `.closedUnattended`, though nobody wrote it.
            await clock.advance(by: hour * 3)
            #expect(try await attendance.read("c-1")?.state == .closedUnattended)
            #expect(await attendance.load("c-1")?.written.state == .onSite(closesAt: eventEnd + hour))
            // A late check-out meets the closed attendance; a coordinator vouches.
            await #expect(throws: UpdateError<Attendance>.self) {
                try await attendance.apply(.checkOut, to: "c-1", by: me, because: "tapped check-out at home")
            }
            let vouched = try await attendance.apply(.vouch, to: "c-1", by: admin, because: "seen on site by the coordinator")
            #expect(vouched.written.state == .checkedOut)
            let trail = await attendance.history(of: "c-1")
            #expect(trail.map(\.to) == [.onSite(closesAt: eventEnd + hour), .closedUnattended, .checkedOut])
            #expect(trail[1].by == .timeout && trail[1].at == eventEnd + hour)
            try LifecycleHistory.verify(trail, of: vouched)

            // The parent's link: the page and the action read the same state.
            _ = await waivers.insert(.new(in: .awaitingAddress, by: admin, because: "a minor signed up"), as: "w-1")
            try await waivers.apply(.send(to: parent), to: "w-1", by: admin, because: "the parent's address was confirmed")
            // A second send while one is out is ignored: one email.
            await #expect(throws: UpdateError<ParentWaiver>.self) {
                try await waivers.apply(.send(to: parent), to: "w-1", by: admin, because: "pressed again")
            }
            await clock.advance(by: day * 8)
            do throws(UpdateError<ParentWaiver>) {
                try await waivers.apply(.sign, to: "w-1", by: .parent("link-1"), because: "signed through the emailed link")
                Issue.record("an expired link signed")
            } catch .refused(.refused(state: .expired, event: _, reason: let reason)) {
                #expect(reason == "this link has expired")
            }
            let emails = await waivers.effects
            #expect(emails.map(\.effect) == [.emailSigningLink(to: parent)])

            // An approval names who and why, and the owner is told once.
            _ = await approvals.insert(.new(in: .submitted, by: .service("registration"), because: "registered"), as: "ch-1")
            try await approvals.apply(.approve, to: "ch-1", by: admin, because: "registration 1187421 checked with the regulator")
            let approver = await approvals.history(of: "ch-1").last { $0.to == .approved }?.by
            #expect(approver == .principal(admin))

            // An approval nobody gives is noticed in two weeks, not never.
            _ = await approvals.insert(.new(in: .submitted, by: .service("registration"), because: "registered"), as: "ch-2")
            await clock.advance(by: day * 15)
            let lapsed = try await approvals.settle("ch-2")
            #expect(lapsed.written.state == .lapsed)
            let told = await approvals.effects.map(\.effect)
            #expect(told == [.tellOwner(.approved), .tellOwner(.lapsed)])

            // The email goes out under the effect's key; a retry repeats it.
            let key = try #require(emails.first?.key)
            #expect(key == IdempotencyKey.lifecycle(record: try #require(await waivers.load("w-1")).key, entry: 0, position: 0))
        }
        #expect(events.events(named: "lifecycle.timed_out").count == 2)
        #expect(events.events(named: "lifecycle.applied").count == 5)
        // Events carry no principal and no reason.
        for event in events.events where event.name.rawValue.hasPrefix("lifecycle.") {
            #expect(!event.description.contains("admin") && !event.description.contains("regulator"))
        }
    }

    // MARK: Checking the definitions

    @Test(.failureMode("design/27", "a declared state waits forever"))
    func eachDefinitionsWaitsAreAWrittenList() {
        let waiver = StateGraph<ParentWaiver.State, ParentWaiver.Event>.explore(
            ParentWaiver.self, from: [.awaitingAddress], events: ParentWaiver.events)
        #expect(waiver.isComplete)
        #expect(Set(waiver.waitingForever) == [.awaitingAddress, .expired])
        #expect(waiver.unreachable(of: ParentWaiver.State.allCases).isEmpty)

        let approval = StateGraph<CharityApproval.State, CharityApproval.Event>.explore(
            CharityApproval.self, from: [.submitted], events: CharityApproval.Event.allCases)
        #expect(approval.isComplete)
        #expect(Set(approval.waitingForever) == [.approved, .suspended, .rejected, .lapsed], "submitted is not in it")

        let end = wallStart + hour
        let attendance = StateGraph<Attendance.State, Attendance.Event>.explore(
            Attendance.self, from: [.signedUp(eventEnds: end), .checkedOut],
            events: [.checkIn(closesAt: end + hour), .checkOut, .close, .withdraw, .vouch])
        #expect(attendance.isComplete)
        #expect(attendance.waitingForever == [.closedUnattended])
        for graph in [waiver.timedCycles.isEmpty, approval.timedCycles.isEmpty, attendance.timedCycles.isEmpty] { #expect(graph) }
        #expect(waiver.stuckTimeouts.isEmpty && approval.stuckTimeouts.isEmpty && attendance.stuckTimeouts.isEmpty)
        #expect(waiver.finalWithExits.isEmpty && attendance.finalWithExits.isEmpty)
        #expect(attendance.invalid.map(\.state) == [.checkedOut])
        // The edges a timeout took, and the effects edges carry, are drawn.
        #expect(waiver.edges.contains { $0.from == .sent && $0.to == .expired && $0.byTimeout })
        #expect(waiver.mermaid.contains("sent --> expired: expire (timeout)"))
        #expect(waiver.mermaid.contains("awaitingAddress --> sent: send(to: \"parent@example.com\") / emailSigningLink"))
    }

    @Test(.failureMode("design/27", "a dead end is not declared final"))
    func aDeadEndNotDeclaredFinalIsListed() {
        let graph = StateGraph<Stuck.State, Stuck.Event>.explore(Stuck.self, from: [.stuck, .moved], events: Stuck.Event.allCases)
        #expect(graph.undeclaredDeadEnds == [.stuck], "moved is declared final")
        #expect(graph.waitingForever.isEmpty)
        let reminder = StateGraph<Reminder.State, Reminder.Event>.explore(Reminder.self, from: [.waiting], events: Reminder.Event.allCases)
        #expect(reminder.undeclaredDeadEnds.isEmpty && reminder.finalWithExits.isEmpty)
    }

    /// A final state left, and a retired state entered or never migrated.
    @Test func finalExitsAndRetiredStatesAreFound() {
        enum Leaky: Lifecycle {
            static let name = "test.leaky"
            enum State: String, Hashable, Sendable, Codable, CaseIterable { case open, closed, old }
            enum Event: String, Hashable, Sendable, Codable, CaseIterable { case close, reopen, age }
            typealias Principal = String
            static func transition(from state: State, on event: Event) -> Self.Step {
                switch (state, event) {
                case (.open, .close): .to(.closed)
                case (.closed, .reopen): .to(.open)
                case (.open, .age): .to(.old)
                default: .ignore
                }
            }
            static func isFinal(_ state: State) -> Bool { state == .closed }
            static func isRetired(_ state: State) -> Bool { state == .old }
        }
        let graph = StateGraph<Leaky.State, Leaky.Event>.explore(Leaky.self, from: [.open], events: Leaky.Event.allCases)
        #expect(graph.finalWithExits == [.closed])
        #expect(graph.retiredEntries.map(\.to) == [.old])
        #expect(graph.retiredWithoutExit == [.old])
        // A graph explored from a transition function declares nothing.
        let plain = StateGraph<Leaky.State, Leaky.Event>.explore(from: .open, events: Leaky.Event.allCases) { state, event in
            switch Leaky.transition(from: state, on: event) {
            case .to(let next, _): .to(next)
            default: .ignore
            }
        }
        #expect(plain.finalWithExits.isEmpty && plain.retiredEntries.isEmpty && plain.stuckTimeouts.isEmpty)
        #expect(plain.undeclaredDeadEnds == plain.deadEnds)
    }

    // MARK: Random walks

    @Test func theWaiverSendsOneEmailPerVisitToSentAndIsNeverSignedAfterExpiring() {
        let violation = randomWalks(ParentWaiver.self, from: .awaitingAddress, by: admin, events: ParentWaiver.events, seed: 27) { _, entries in
            let visits = entries.filter { $0.to == .sent && $0.entered }.count
            if entries.flatMap(\.effects).count != visits { return "an email per visit to sent" }
            var expired = false
            for entry in entries {
                if entry.to == .expired { expired = true }
                if entry.to == .sent { expired = false }
                if expired && entry.to == .signed { return "signed after expired" }
            }
            return nil
        }
        #expect(violation == nil, "\(violation.map(String.init(describing:)) ?? "")")
    }

    @Test func aWalkFindsAndShrinksAViolationThroughTime() throws {
        // "Never expires" is false: one send and one wait expire it.
        let violation = try #require(randomWalks(ParentWaiver.self, from: .awaitingAddress, by: admin, events: ParentWaiver.events, seed: 3) { state, _ in
            state == .expired ? "expired" : nil
        })
        #expect(violation.events == [.send(to: parent), .expire], "shrunk to a send and the wait whose timeout fired")
        #expect(violation.state == .expired)
    }

    @Test func aWalkThatMeetsADefectIsAViolation() throws {
        let stuck = try #require(randomWalks(Stuck.self, from: .stuck, by: "p", events: [.poke], seed: 1) { _, _ in nil })
        #expect(stuck.message.contains("does not move it"))
        let blinking = try #require(randomWalks(Attendance.self, from: .checkedOut, by: .staff("s"), events: [.vouch], seed: 1) { _, _ in nil })
        #expect(blinking.message.contains("invalid transition"))
    }
}

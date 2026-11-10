import Stoic
import StoicTesting

// Kindora's three lifecycles, as design/27's ideal scenario declares them.

/// Who acts. Recorded in every history entry, and never in an event.
enum Someone: Hashable, Sendable, Codable {
    case volunteer(String), parent(String), staff(String), service(String)
}

let hour = Duration.seconds(3_600)
let day = Duration.seconds(86_400)

/// The test clock's wall clock at its start: 2026-01-01T00:00:00Z.
let wallStart = Moment(sinceEpoch: .seconds(1_767_225_600))

/// One volunteer at one event.
enum Attendance: Lifecycle {
    static let name = "kindora.attendance"
    typealias Principal = Someone

    enum State: Hashable, Sendable, Codable {
        case signedUp(eventEnds: Moment)
        case onSite(closesAt: Moment)
        case checkedOut
        case noShow
        case closedUnattended
        case withdrawn
    }
    enum Event: Hashable, Sendable, Codable {
        case checkIn(closesAt: Moment), checkOut, close, withdraw, vouch
    }

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.signedUp, .checkIn(let closesAt)): .to(.onSite(closesAt: closesAt))
        case (.signedUp, .withdraw): .to(.withdrawn)
        case (.signedUp, .close): .to(.noShow)
        case (.signedUp, .checkOut): .refuse("you have not checked in")
        case (.onSite, .checkOut): .to(.checkedOut)
        case (.onSite, .close): .to(.closedUnattended)
        case (.closedUnattended, .vouch): .to(.checkedOut)
        case (.checkedOut, .vouch): .invalid("a checked-out attendance has nothing to vouch for")
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? {
        switch state {
        case .signedUp(let ends): .at(ends, send: .close)
        case .onSite(let closesAt): .at(closesAt, send: .close)
        default: nil
        }
    }
    static func isFinal(_ state: State) -> Bool {
        switch state {
        case .checkedOut, .noShow, .withdrawn: true
        default: false
        }
    }
}

/// A parent's consent for a minor at one event, asked by email.
enum ParentWaiver: Lifecycle {
    static let name = "kindora.parent-waiver"
    typealias Principal = Someone

    enum State: String, Hashable, Sendable, Codable, CaseIterable { case awaitingAddress, sent, signed, expired, revoked }
    enum Event: Hashable, Sendable, Codable { case send(to: String), sign, expire, revoke }
    enum Effect: Hashable, Sendable, Codable { case emailSigningLink(to: String) }

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.awaitingAddress, .send(let parent)), (.expired, .send(let parent)):
            .to(.sent, effects: [.emailSigningLink(to: parent)])
        case (.sent, .sign): .to(.signed)
        case (.sent, .expire): .to(.expired)
        case (.awaitingAddress, .revoke), (.sent, .revoke), (.expired, .revoke): .to(.revoked)
        case (.expired, .sign): .refuse("this link has expired")
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? {
        state == .sent ? .after(day * 7, send: .expire) : nil
    }
    static func isFinal(_ state: State) -> Bool { state == .signed || state == .revoked }

    static let events: [Event] = [.send(to: "parent@example.com"), .sign, .expire, .revoke]
}

/// A charity's approval to publish events.
enum CharityApproval: Lifecycle {
    static let name = "kindora.charity-approval"
    typealias Principal = Someone

    enum State: String, Hashable, Sendable, Codable, CaseIterable { case submitted, approved, rejected, lapsed, suspended }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable { case approve, reject, lapse, suspend, reinstate, resubmit }
    enum Effect: Hashable, Sendable, Codable { case tellOwner(State) }

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.submitted, .approve): .to(.approved, effects: [.tellOwner(.approved)])
        case (.submitted, .reject): .to(.rejected, effects: [.tellOwner(.rejected)])
        case (.submitted, .lapse): .to(.lapsed, effects: [.tellOwner(.lapsed)])
        case (.approved, .suspend): .to(.suspended)
        case (.suspended, .reinstate): .to(.approved)
        case (.rejected, .resubmit), (.lapsed, .resubmit): .to(.submitted)
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { state == .submitted ? .after(day * 14, send: .lapse) : nil }
}

// Small definitions for the rows the scenario does not reach.

/// A reminder that a person may extend (re-entering) or nudge (a stay).
enum Reminder: Lifecycle {
    static let name = "test.reminder"
    enum State: String, Hashable, Sendable, Codable, CaseIterable { case waiting, done }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable { case nudge, extend, finish, lapse }
    enum Effect: Hashable, Sendable, Codable { case notify(String) }
    typealias Principal = String

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.waiting, .nudge): .stay(effects: [.notify("nudged")])
        case (.waiting, .extend): .to(.waiting)
        case (.waiting, .finish), (.waiting, .lapse): .to(.done)
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { state == .waiting ? .after(hour, send: .lapse) : nil }
    static func isFinal(_ state: State) -> Bool { state == .done }
}

/// Three steps, each an hour after the last.
enum Relay: Lifecycle {
    static let name = "test.relay"
    enum State: String, Hashable, Sendable, Codable, CaseIterable { case first, second, third }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable { case pass }
    typealias Principal = String

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch state {
        case .first: .to(.second)
        case .second: .to(.third)
        case .third: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { state == .third ? nil : .after(hour, send: .pass) }
    static func isFinal(_ state: State) -> Bool { state == .third }
}

/// A defective definition: `stuck`'s own timeout does not move it.
enum Stuck: Lifecycle {
    static let name = "test.stuck"
    enum State: String, Hashable, Sendable, Codable, CaseIterable { case stuck, moved }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable { case tick, poke }
    typealias Principal = String

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.stuck, .poke): .stay()
        case (.stuck, .tick): .ignore
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { state == .stuck ? .after(hour, send: .tick) : nil }
    static func isFinal(_ state: State) -> Bool { state == .moved }
}

/// A defective definition: its timeouts form a cycle.
enum Blinker: Lifecycle {
    static let name = "test.blinker"
    enum State: String, Hashable, Sendable, Codable, CaseIterable { case on, off }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable { case flip, poke }
    typealias Principal = String

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.on, .flip): .to(.off)
        case (.off, .flip): .to(.on)
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { .after(hour, send: .flip) }
}

/// A definition that retired a state and an event: `pending` was replaced by
/// `queued`, and `hurry` is no longer sent.
enum Ticket: Lifecycle {
    static let name = "test.ticket"
    enum State: String, Hashable, Sendable, Codable, CaseIterable { case pending, queued, closed }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable { case migrate, hurry, close }
    typealias Principal = String

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.pending, .migrate): .to(.queued)
        case (_, .hurry): .refuse("retired: hurrying is no longer offered")
        case (.queued, .close): .to(.closed)
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { state == .pending ? .after(.zero, send: .migrate) : nil }
    static func isFinal(_ state: State) -> Bool { state == .closed }
    static func isRetired(_ state: State) -> Bool { state == .pending }
}

/// ``ParentWaiver`` as a newer build declares it: version 2, and a three-day
/// expiry.
enum ParentWaiverV2: Lifecycle {
    static let name = ParentWaiver.name
    static let version = 2
    typealias Principal = Someone
    typealias State = ParentWaiver.State
    typealias Event = ParentWaiver.Event
    typealias Effect = ParentWaiver.Effect

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch ParentWaiver.transition(from: state, on: event) {
        case .to(let next, let effects): .to(next, effects: effects)
        case .stay(let effects): .stay(effects: effects)
        case .refuse(let reason): .refuse(reason)
        case .ignore: .ignore
        case .invalid(let reason): .invalid(reason)
        }
    }
    static func timeout(in state: State) -> Self.Timeout? {
        state == .sent ? .after(day * 3, send: .expire) : nil
    }
    static func isFinal(_ state: State) -> Bool { ParentWaiver.isFinal(state) }
}

extension LifecycleRecord {
    /// A record with a key the test names.
    static func make(_ state: L.State, by: L.Principal, at moment: Moment = wallStart, key: String = "record-key-0123456789abcdef") -> Self {
        .new(in: state, by: by, because: "made by a test", at: moment, key: IdempotencyKey(rawValue: key))
    }
}

/// `change`'s record, for a test that applies changes by hand.
func committed<L: Lifecycle>(_ change: LifecycleChange<L>) -> LifecycleRecord<L> {
    change.record
}

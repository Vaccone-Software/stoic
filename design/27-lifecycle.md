# 27 · Lifecycles

> Built in 0.6.0, on design/26 (`Moment`, `Ambient.wallClock`). The draft was
> reviewed and amended (names, the device's clock, crash testing, the outbox's
> format); "As built" lists every departure from it.

A record that lives for days — a volunteer's attendance, a parent's waiver, a
charity's approval, a release being installed — has a lifecycle whether or not
the code says so. When it does not, the lifecycle is spread over the code. It
lives in optional fields whose combinations mean states (`checkIn?`, `checkOut?`).
It lives in a status that every reader works out again in its own way. It lives
in an expiry that one path enforces and another forgets. And it lives in a
boolean that nothing ever sets. Nobody can say who moved the record or why. An
email that "goes out once" goes out twice when a request is retried, or never
when the process dies between the write and the send.

`StateMachine` (design/07) already says how to declare a lifecycle: a pure
transition function, with time-based transitions as data. But it lives in
memory and ends with the process. This contract lets the same declaration be
read at rest, on a stored record. The state is a value. A timeout that has
fallen due is applied on every read, so an expired state cannot be acted on.
Every transition is history with who and why. A transition's effects are
committed with it and delivered through the outbox under keys that make "once"
true.

## The ideal scenario

> A volunteering service keeps its records in a server database. A volunteer
> signs up, checks in on site and checks out. If nobody checks out by an hour
> after the event ends, the attendance closes itself, and a coordinator must
> vouch for the hours. A minor's parent is emailed a signing link, once per
> request, that expires in seven days, on every path that could use it. A
> charity's approval names the person who gave it and why, and an approval that
> nobody gives is noticed in two weeks, not never. Each rule is declared once.
> Every screen, endpoint and job reads the same state.

```swift
import Stoic

/// Who acts. Recorded in every history entry, and never in an event.
enum Someone: Hashable, Sendable, Codable {
    case volunteer(UserID), parent(WaiverLinkID), staff(UserID), service(String)
}

let hour = Duration.seconds(3_600), day = Duration.seconds(86_400)

/// One volunteer at one event.
enum Attendance: Lifecycle {
    static let name = "kindora.attendance"
    typealias Principal = Someone

    enum State: Hashable, Sendable, Codable {
        case signedUp(eventEnds: Moment)        // a no-show is closed when the event ends
        case onSite(closesAt: Moment)           // fixed at check-in: the event's end and an hour's grace
        case checkedOut
        case noShow
        case closedUnattended                   // nobody checked out: a coordinator vouches for the hours
        case withdrawn
    }
    enum Event: Hashable, Sendable, Codable {
        case checkIn(closesAt: Moment), checkOut, close, withdraw, vouch
    }

    static func transition(from state: State, on event: Event) -> Step {
        switch (state, event) {
        case (.signedUp, .checkIn(let closesAt)): .to(.onSite(closesAt: closesAt))
        case (.signedUp, .withdraw):              .to(.withdrawn)
        case (.signedUp, .close):                 .to(.noShow)
        case (.signedUp, .checkOut):              .refuse("you have not checked in")
        case (.onSite, .checkOut):                .to(.checkedOut)
        case (.onSite, .close):                   .to(.closedUnattended)
        case (.closedUnattended, .vouch):         .to(.checkedOut)
        default:                                  .ignore     // a second scan, a late tap
        }
    }
    static func timeout(in state: State) -> Timeout? {
        switch state {
        case .signedUp(let ends):    .at(ends, send: .close)
        case .onSite(let closesAt):  .at(closesAt, send: .close)
        default:                     nil
        }
    }
    static func isFinal(_ state: State) -> Bool {
        switch state { case .checkedOut, .noShow, .withdrawn: true; default: false }
    }
}

/// A parent's consent for a minor at one event, asked by email.
enum ParentWaiver: Lifecycle {
    static let name = "kindora.parent-waiver"
    typealias Principal = Someone

    enum State: String, Hashable, Sendable, Codable, CaseIterable { case awaitingAddress, sent, signed, expired, revoked }
    enum Event: Hashable, Sendable, Codable { case send(to: EmailAddress), sign, expire, revoke }
    enum Effect: Hashable, Sendable, Codable { case emailSigningLink(to: EmailAddress) }

    static func transition(from state: State, on event: Event) -> Step {
        switch (state, event) {
        case (.awaitingAddress, .send(let parent)), (.expired, .send(let parent)):
            .to(.sent, effects: [.emailSigningLink(to: parent)])
        case (.sent, .sign):                             .to(.signed)
        case (.sent, .expire):                           .to(.expired)
        case (.awaitingAddress, .revoke), (.sent, .revoke), (.expired, .revoke): .to(.revoked)
        case (.expired, .sign):                          .refuse("this link has expired")
        default:                                         .ignore     // a second "send" while one is out
        }
    }
    static func timeout(in state: State) -> Timeout? {
        state == .sent ? .after(day * 7, send: .expire) : nil
    }
    static func isFinal(_ state: State) -> Bool { state == .signed || state == .revoked }
}

/// A charity's approval to publish events.
enum CharityApproval: Lifecycle {
    static let name = "kindora.charity-approval"
    typealias Principal = Someone

    enum State: String, Hashable, Sendable, Codable, CaseIterable { case submitted, approved, rejected, lapsed, suspended }
    enum Event: Hashable, Sendable, Codable { case approve, reject, lapse, suspend, reinstate, resubmit }
    enum Effect: Hashable, Sendable, Codable { case tellOwner(State) }

    static func transition(from state: State, on event: Event) -> Step {
        switch (state, event) {
        case (.submitted, .approve):  .to(.approved, effects: [.tellOwner(.approved)])
        case (.submitted, .reject):   .to(.rejected, effects: [.tellOwner(.rejected)])
        case (.submitted, .lapse):    .to(.lapsed, effects: [.tellOwner(.lapsed)])
        case (.approved, .suspend):   .to(.suspended)
        case (.suspended, .reinstate): .to(.approved)
        case (.rejected, .resubmit), (.lapsed, .resubmit): .to(.submitted)
        default:                      .ignore
        }
    }
    // A review nobody does becomes visible: the owner is told, and a count rises.
    static func timeout(in state: State) -> Timeout? { state == .submitted ? .after(day * 14, send: .lapse) : nil }
}

// The service's storage: one transaction per commit (the app's code, a `LifecycleStore`;
// see "Effects, atomically").
let attendance = PostgresLifecycles<Attendance>(table: "attendance", db: db)
let waivers = PostgresLifecycles<ParentWaiver>(table: "parent_waivers", db: db)
let approvals = PostgresLifecycles<CharityApproval>(table: "charity_approvals", db: db)

// Sign-up creates the record. The event's end is known now.
try await attendance.insert(.new(in: .signedUp(eventEnds: event.end.moment), by: .volunteer(me),
                                 because: "signed up in the app"), as: commitmentID)

// Check-in from the geofence, the QR scan or a coordinator's list: one path, one rule.
try await attendance.apply(.checkIn(closesAt: event.end.moment + hour), to: commitmentID,
                           by: .volunteer(me), because: "scanned the event's code 40 m from the site")

// Reading, anywhere. After `closesAt` the state is `.closedUnattended`, though nobody wrote it.
let now = try await attendance.load(commitmentID)?.state()

// The parent's link. The page that shows it and the action that completes it
// read the same state, so an expired link is expired on both.
do {
    try await waivers.apply(.sign, to: waiverID, by: .parent(link.id), because: "signed through the emailed link")
} catch .refused(.refused(state: .expired, event: _, reason: let reason)) {
    return .linkExpired(reason)
}

// An approval names who and why, and the owner is told once.
try await approvals.apply(.approve, to: charityID, by: .staff(admin),
                          because: "registration 1187421 checked with the regulator")
let approver = try await approvals.history(of: charityID).last { $0.to == .approved }?.by

// The email goes out from the service's outbox under the effect's key. A retry or
// a restart repeats the key, and the provider sends nothing twice.
try await resend.send(signingEmail(to: parent), idempotencyKey: effect.key)
```

The same declaration, on a Mac, with the records kept by Stoic. This is
Lodestar's updater (Origin): one record per release, from offer to running or
refused, across launches and builds.

```swift
enum ReleaseOnThisMac: Lifecycle {
    static let name = "lodestar.release"
    enum Principal: Hashable, Sendable, Codable { case updater, successor(pid: Int32), watchdog, person }

    enum State: String, Hashable, Sendable, Codable, CaseIterable {
        case offered, downloading, staged, applying, running, rolledBack, refused
    }
    enum Event: Hashable, Sendable, Codable { case download, verified, failed, stall, apply, confirm, rollBack, unchanged }
    enum Effect: Hashable, Sendable, Codable { case announce(State) }      // said to the person once

    static func transition(from state: State, on event: Event) -> Step {
        switch (state, event) {
        case (.offered, .download):                            .to(.downloading)
        case (.downloading, .verified):                        .to(.staged)
        case (.downloading, .failed), (.downloading, .stall):  .to(.offered)
        case (.staged, .apply):                                .to(.applying)
        case (.applying, .confirm):                            .to(.running, effects: [.announce(.running)])
        case (.applying, .rollBack), (.applying, .stall):      .to(.rolledBack, effects: [.announce(.rolledBack)])
        case (.applying, .unchanged):                          .to(.refused, effects: [.announce(.refused)])
        case (.rolledBack, _), (.refused, _):                  .refuse("this release failed its handover once")
        default:                                               .ignore
        }
    }
    static func timeout(in state: State) -> Timeout? {
        switch state {
        case .downloading: .after(.seconds(30 * 60), send: .stall)   // UpdateDownload.deadline
        case .applying:    .after(.seconds(120), send: .stall)       // a successor that never confirmed
        default:           nil
        }
    }
    static func isFinal(_ state: State) -> Bool { [.running, .rolledBack, .refused].contains(state) }
}

let releases = try await JournaledLifecycleStore<ReleaseOnThisMac, String>.open(
    at: support + "/releases", fileSystem: PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700))

// A release is offered only while its record allows it. A refused release stays
// refused across launches and builds. There is no tombstone file to fail to write.
if let reading = try await releases.read(release.tag), reading.state != .offered { return }

// The successor, at boot: a newer build applying an event to a record the old build wrote.
try await releases.apply(.confirm, to: Lodestar.tag, by: .successor(pid: getpid()),
                         because: "the router answered 1.2 s after launch")

// The watchdog is a shell script. Its marker becomes an event, once, at boot.
if let tag = rolledBackMarker {
    try await releases.apply(.rollBack, to: tag, by: .watchdog, because: "the build never took the pid file")
}

// At launch and on a timer: commit what has fallen due, then say what is owed to the person.
try await releases.settleDue()
try await releases.deliverEffects { @Sendable delivery in
    await voice.say(delivery.effect, release: delivery.id)  // "Updated to 0.55", even if the
    return .delivered                                      // last process exited before saying it
}
```

## Origin

- **Kindora** (TypeScript on Convex), read for this contract:
  - Attendance is `{checkIn?, checkOut?}` on two tables. Check-in is written in
    at least five places with different guards. `commitments/mutations.ts:90`
    overwrites `checkIn` unconditionally, even after check-out. The
    volunteer's check-out (`:213`) returns `null` in five different cases, so a
    refusal looks like nothing. The admin's check-out (`:401`) checks out a
    commitment that never checked in. `getOngoingForCurrentUser`
    (`commitments/queries.ts:119`) treats a check-in with no check-out as
    ongoing, forever: nobody closes an attendance.
    The status is derived again in `events/actions.ts:57` and `:86`.
  - The parent-waiver token expires in seven days (`waivers/actions.ts:84`,
    `:183`, `:303`). `getByParentToken` enforces that, but
    `completeParentWaiverSigning` (`:245`) reads `getByParentTokenAbsolute`,
    which does not, so an expired link completes. Waiver status is inferred
    from `parentWaiverToken`, `acceptedTime` and `parentWaiverExpiresAt` in
    `commitments/queries.ts`, `guestCommitments/queries.ts` and
    `commitments/mutations.ts`. The email is sent after the write, and a
    failure is logged and dropped (`console.error`, `:141`). A second call
    mints a new token and sends again.
  - `charities.isApproved` is set `false` at creation
    (`charities/mutations.ts:13`) and read in five places. Nothing sets it
    `true`.
  - No table records who did what.
- **Lodestar**, the pilot, `Sources/lodestar/UpdateController.swift` and
  `Sources/LodestarCore/Updater.swift`, `UpdateDownload.swift`. The update's
  phase (`idle`, `checking`, `ready`, `applying`) is an in-memory enum. Across
  launches, the state of a release is a family of marker files (`updated`,
  `rolled-back`, `routes-ok`, the refusal tombstone) whose meaning is worked
  out again at boot. Three incidents are on record. A tombstone write that
  failed silently left a rolled-back release on offer, which became a relaunch
  loop. v0.32.4, a build that did not change the binary, was re-applied 194
  times in a night. A `checking` phase that could last for days "refused every
  later check", a state with no way out. The announcement that is "retired
  when the message is said, not when it is read" is an at-least-once effect
  written by hand.
- **Erlang's `gen_statem`**: state timeouts as part of the machine. Stoic
  already has these (design/07).
- **XState's delayed transitions (`after`)**: a timeout belongs to the state,
  not to the transition into it. This contract takes that choice, because a
  stored record must be able to recompute its timeout from its state alone.
- **Redis key expiry**: expired keys are removed lazily, when they are read,
  and actively, by a sweep. Reads apply what is due here, and `settleDue`
  commits it.
- **The transactional outbox** (design/15): the state change and the intent
  to send are one write. Delivery follows at least once, under a key.
- **Idempotency keys derived from the operation** (Stripe's model, and
  design/22's derived keys): a key is a function of what is being done, so a
  repeat carries the same key.
- **Audit tables**: history kept as rows that are only ever inserted, beside
  the row they describe.

## API

```swift
// MARK: Stoic (the kernel): pure, storage-agnostic

/// A lifecycle, declared once. The conforming type is the definition: a
/// caseless enum, read at rest by `LifecycleRecord` and live by `StateMachine`.
public protocol Lifecycle: Sendable {
    associatedtype State: Hashable & Sendable & Codable
    associatedtype Event: Hashable & Sendable & Codable
    associatedtype Effect: Sendable & Codable = Never
    associatedtype Principal: Hashable & Sendable & Codable

    /// Stable forever: it names the lifecycle in records, effect keys and events.
    static var name: String { get }
    /// Raised when a change must not meet a writer with the older definition. Default 1.
    static var version: Int { get }
    static func transition(from state: State, on event: Event) -> LifecycleStep<Self>
    static func timeout(in state: State) -> LifecycleTimeout<Event>?      // default: nil
    static func isFinal(_ state: State) -> Bool                             // default: false
    static func isRetired(_ state: State) -> Bool                           // default: false
}
extension Lifecycle {
    public typealias Step = LifecycleStep<Self>          // write `Self.Step` where a module type is named Step
    public typealias Timeout = LifecycleTimeout<Event>
    public typealias Record = LifecycleRecord<Self>
    public typealias Entry = LifecycleEntry<Self>
    public typealias Change = LifecycleChange<Self>
    public typealias Refusal = LifecycleRefusal<Self>
}

public enum LifecycleStep<L: Lifecycle>: Sendable {
    case to(L.State, effects: [L.Effect] = [])   // enter (or re-enter) a state
    case stay(effects: [L.Effect] = [])          // accepted; the state's visit goes on (written `.stay()`)
    case refuse(String)                          // expected, and the caller is told why
    case ignore                                  // means nothing here
    case invalid(String)                         // should be impossible: a bug, reported at error level
}

public enum LifecycleTimeout<Event: Hashable & Sendable>: Sendable, Hashable {
    case after(Duration, send: Event)            // measured from entering the state
    case at(Moment, send: Event)                 // a moment the state carries
    public var event: Event { get }
    public func due(since: Moment) -> Moment
}

public enum Initiator<Principal: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    case principal(Principal)                    // encoded {"principal": …}
    case timeout                                 // encoded "timeout"
}

public struct LifecycleRecord<L: Lifecycle>: Sendable, Hashable, Codable {
    public static func new(in state: L.State, by: L.Principal, because: String, at: Moment = .now) -> Self
    public let key: IdempotencyKey               // random at creation: the root of every effect key
    public let revision: UInt64                  // 1 at creation, +1 per commit: the compare-and-set token
    public let sequence: UInt64                  // entries ever committed: the next entry's number
    public let created: Creation                 // at, by (Initiator), because
    public let version: Int                      // the definition version that last wrote it
    public var written: Written { get }          // state, since, updated, dueAt: as stored. For indexes, never decisions.
    public static var timedStepLimit: Int { get } // 64

    public func read(at now: Moment = .now) -> LifecycleReading<L>
    public func state(at now: Moment = .now) -> L.State                      // read(at:).state
    public func applying(_ event: L.Event, by: L.Principal, because: String,
                         at now: Moment = .now) throws(L.Refusal) -> L.Change
    public func settling(at now: Moment = .now) throws(L.Refusal) -> L.Change?   // nil: nothing due
}

public struct LifecycleReading<L: Lifecycle>: Sendable {
    public let state: L.State
    public let since: Moment                     // when that state was entered
    public let pending: [L.Entry]                // timed entries due and not yet committed, oldest first
    public let nextDue: Moment?                  // when the current state's timeout falls due
    public let isTruncated: Bool                 // the chain stopped at its cap (a defective definition)
    public var isFinal: Bool { get }
}

public struct LifecycleEntry<L: Lifecycle>: Sendable, Hashable, Codable {
    public let record: IdempotencyKey            // the record's key
    public let sequence: UInt64                  // 0, 1, 2, … with no gap
    public let from: L.State
    public let event: L.Event
    public let to: L.State
    public let entered: Bool                     // false for `.stay`
    public let at: Moment
    public let by: Initiator<L.Principal>
    public let because: String
    public let effects: [IdempotencyKey]         // the keys of the effects this entry carried
}

public struct LifecycleChange<L: Lifecycle>: Sendable {
    public let base: UInt64                      // commit only over this revision
    public let record: L.Record                  // revision == base + 1
    public let entries: [L.Entry]                // timed entries first, then the event's
    public let effects: [LifecycleEffect<L>]
}

public struct LifecycleEffect<L: Lifecycle>: Sendable, Codable {
    public let key: IdempotencyKey               // derived: record key, entry sequence, position
    public let effect: L.Effect
    public let record: IdempotencyKey
    public let entry: UInt64
}
extension IdempotencyKey {
    public static func lifecycle(record: IdempotencyKey, entry: UInt64, position: Int) -> IdempotencyKey   // frozen
}

public enum LifecycleRefusal<L: Lifecycle>: Error, Sendable, Hashable, Retryable {   // .stop
    case refused(state: L.State, event: L.Event, reason: String)
    case ignored(state: L.State, event: L.Event)
    case invalid(state: L.State, event: L.Event, reason: String)
    case newerDefinition(written: Int, current: Int)
    case chainTooLong(state: L.State, steps: Int)
}

public enum LifecycleHistory {
    /// Checks that `entries` are a record's whole history: sequences 0..<sequence with no gap,
    /// each the record's, each starting where the one before ended and dated no earlier,
    /// the last ending in the written state.
    public static func verify<L>(_ entries: [LifecycleEntry<L>], of record: LifecycleRecord<L>) throws(HistoryGap)
}
public struct HistoryGap: Error, Sendable, Hashable { public let fault: Fault }  // missing, beyondSequence, foreign, broken, backwards, endsElsewhere

// Stores, any kind. The protocol is the obligation; `update` is the compliant path.
public protocol LifecycleStore<Definition, ID>: Sendable {
    associatedtype Definition: Lifecycle
    associatedtype ID: Hashable & Sendable
    associatedtype Failure: Error
    func load(_ id: ID) async throws(Failure) -> Definition.Record?
    func history(of id: ID) async throws(Failure) -> [Definition.Entry]
    func insert(_ record: Definition.Record, as id: ID) async throws(Failure) -> Bool    // false: the id is taken
    func commit(_ change: Definition.Change, to id: ID) async throws(Failure) -> LifecycleCommit<Definition>
    func moment(for now: Moment) async -> Moment       // the moment it reads and applies at; no default
}
public enum LifecycleCommit<L: Lifecycle>: Sendable { case committed, conflict(current: L.Record?) }

extension LifecycleStore {
    public func update(_ id: ID, attempts: Int = 3,
                       _ change: (Definition.Record) throws(Definition.Refusal) -> Definition.Change)
        async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record
    public func apply(_ event: Definition.Event, to id: ID, by: Definition.Principal, because: String)
        async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record
    public func settle(_ id: ID) async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record
    public func read(_ id: ID, at now: Moment = .now) async throws(Failure) -> LifecycleReading<Definition>?
}
public enum LifecycleUpdateError<L: Lifecycle, Failure: Error>: Error, Retryable {
    case refused(L.Refusal), notFound, conflict(attempts: Int), storage(Failure), cancelled
    public var isCancellation: Bool { get }
}

// The live reading: what changes in StateMachine (design/07)
extension StateMachine {
    public convenience init<L: Lifecycle>(_ lifecycle: L.Type, initial: State, label: String = L.name,
                                          historyLimit: Int = 64, clock: AnyClock? = nil)
        where L.State == State, L.Event == Event, L.Effect == Never
    public convenience init<L: Lifecycle>(_ lifecycle: L.Type, initial: State, label: String = L.name,
                                          historyLimit: Int = 64, clock: AnyClock? = nil,
                                          perform: @escaping @Sendable (L.Effect) -> Void)
        where L.State == State, L.Event == Event
}

// Checking a definition (design/07, design/12)
extension StateGraph where Event: Hashable {
    public static func explore<L: Lifecycle>(_ lifecycle: L.Type, from: [State], events: [Event],
                                             maximumStates: Int = 10_000) -> StateGraph
        where L.State == State, L.Event == Event
}
extension StateGraph {
    public var waitingForever: [State] { get }      // reachable, not final, no timeout
    public var undeclaredDeadEnds: [State] { get }  // dead ends not declared final
    public var finalWithExits: [State] { get }      // declared final, yet left
    public var timedCycles: [[State]] { get }       // cycles made of timeouts alone
    public var stuckTimeouts: [State] { get }       // a state's own timeout does not move it
    public var retiredEntries: [Edge] { get }       // edges into a retired state from a current one
    public var retiredWithoutExit: [State] { get }  // retired, with no timeout that leaves
}
// Edge gains `byTimeout: Bool` and `effects: [String]`; the Mermaid output labels both.

// MARK: StoicTesting
public func randomWalks<L: Lifecycle>(_ lifecycle: L.Type, from: L.State, by: L.Principal, events: [L.Event],
                                      walks: Int = 1_000, length: Int = 40, seed: UInt64 = 0,
                                      invariant: (L.State, [L.Entry]) -> String?) -> InvariantViolation<L.State, L.Event>?
public actor InMemoryLifecycleStore<L: Lifecycle, ID: Hashable & Sendable>: LifecycleStore {
    public enum Failure: Error { case foreignChange, malformedChange }
    public init()
    public var effects: [LifecycleEffect<L>] { get }          // every effect committed, in order
    public func conflictNextCommit(to id: ID, times: Int = 1) // for the conflict rows
}

// MARK: StoicStore: records kept durably on device

public actor JournaledLifecycleStore<L: Lifecycle, ID: Hashable & Sendable & Codable>: LifecycleStore {
    public typealias Failure = StoreError
    public static func open(at path: String, fileSystem: any FileSystem = PosixFileSystem(),
                            delivery: DeliveryPolicy = DeliveryPolicy(), rememberSettled: Int = 4_096,
                            compactionThreshold: Int = 256 * 1024,
                            journalOptions: Journal.Options = Journal.Options()) async throws(StoreError) -> JournaledLifecycleStore
    public nonisolated let openReport: LifecycleOpenReport<ID>     // journal and outbox reports, undecodable ids, hand-offs resumed
    // LifecycleStore: load, history(of:), insert, commit, moment(for:) (never earlier than the latest seen)
    public func records() -> [(id: ID, record: L.Record)]
    public func settleDue(at now: Moment = .now) async throws(StoreError) -> Int
    public var nextDue: Moment? { get }
    public func deliverEffects(using deliver: @Sendable (LifecycleDelivery<L, ID>) async throws -> DeliveryResult)
        async throws -> Outbox<LifecycleDelivery<L, ID>>.DeliveryReport
    public func purge(finishedBefore: Moment) throws(StoreError) -> Int
    public func close() async throws(StoreError)
    public static func remove(at path: String, fileSystem: any FileSystem = PosixFileSystem()) throws(StoreError) -> Int
}
public struct LifecycleDelivery<L: Lifecycle, ID: Hashable & Sendable & Codable>: Sendable, Codable {
    public let id: ID
    public let key: IdempotencyKey
    public let effect: L.Effect
}

// The one Outbox change (design/15)
extension Outbox {
    public static func open(at:codec:fileSystem:policy:compactionThreshold:journalOptions:
                            rememberSettled: Int) throws(StoreError) -> Outbox   // and the lockTimeout: form
    public func isSettled(_ key: IdempotencyKey) -> Bool
}
```

## Semantics

### The definition

A lifecycle is a type conforming to `Lifecycle`, usually a caseless enum. Its
`transition` is a `switch` over state and event: total, pure and free of side
effects, as design/07 requires. The compiler checks that it is exhaustive, and
`StateGraph` explores it. A timeout is a function of the **state alone**. It
is never set by the transition into the state, as `StateMachine`'s
`.to(_, timeout:)` is today. A stored record keeps only its state and when it
entered it. From that pair, any reader must be able to say when the state
times out, so the timeout cannot depend on how the record got there.
`.after(d)` is measured from entering. `.at(m)` is a moment the state itself
carries, for an expiry tied to something outside the record (an event's end,
computed by the app with design/26's `ZonedDateTime`).

`.refuse(reason)` is new beside design/07's four answers. At rest, a refusal
goes back to a caller who must tell a person something: "you have not checked
in", "this link has expired". That refusal is expected, so it is not
`.invalid`, which reports a bug. It carries a reason, so it is not
`.ignore`, which says nothing.

Why the type is the definition, rather than a value of closures as
`StateMachine` takes: `LifecycleRecord<L>` names its definition in its type.
So no code can hold a record without being able to read it correctly, and
there is no `record.state` property that skips the timeouts. The written
state is reachable only as `written.state`, named for what it is.

### One definition, two readings

**At rest**, `LifecycleRecord<L>` is a value: the written state, when it was
entered, a revision. Reading and applying are pure functions of that value,
the definition and a moment.

**Live**, `StateMachine(L.self, initial:)` runs the same definition in memory,
with `whileIn` work, observation and `StateGraph`, unchanged. What changes in
`StateMachine` is only this:

- **Two convenience initialisers** (API above). Each wraps the definition in
  today's `TransitionFunction`: `.to(s, effects)` becomes
  `.to(s, timeout: L.timeout(in: s))`. `.stay` stays `.stay`, and `.refuse`
  becomes `.ignore` (a live machine has no caller to tell). `.at(m)` becomes
  an `.after` of `Moment.now.duration(to: m)`, read on the wall clock at entry
  and at least zero, then slept on the machine's own clock.
- **The initial state's timeout is armed** at init. Today only a transition
  can carry one. This needs an internal parameter of the designated init,
  not public API.
- **Effects, live**, go to `perform`, once each, in transition order, outside
  the lock and after observers are published. They are not durable: a live
  machine that needs "once" across a crash is a stored record. A definition
  whose `Effect` is `Never` uses the initialiser without `perform`. Internally,
  the core takes the step's effects alongside the transition. The transition
  function's public type does not change.
- Nothing is removed. Closure-built machines keep `.to(_, timeout:)`. A
  definition cannot use it, because `LifecycleStep` has no timeout.

A live machine is not bound to a stored record: its transitions are not
committed anywhere (Not built). The two readings share the definition, and
with it every check in "Checking a definition", not a record.

### A record at rest

| Field      | Meaning                                                                                                                                                                                                     |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `key`      | 128 random bits from the ambient source at creation. Every effect key derives from it, so keys are unique across stores (test and production databases with the same ids do not collide) and unpredictable. |
| `revision` | 1 at creation; each commit adds exactly 1, however many entries it holds. Compare-and-set compares it.                                                                                                      |
| `sequence` | how many history entries have been committed; the next entry's number.                                                                                                                                      |
| `created`  | at, by (`Initiator`), because. Creation is not a transition, so it is not an entry.                                                                                                                         |
| `version`  | `L.version` of the definition that last wrote it.                                                                                                                                                           |
| `written`  | `state`, `since` (when that state was entered), `updated` (the latest entry's moment, or creation's), `dueAt` (`since + d` for `.after(d)`, `m` for `.at(m)`, else nil).                                    |

A record can be created in any state (`new(in:)`), because importing existing
data is creation too: Kindora's checked-out commitments become records in
`.checkedOut`, `because: "imported from commitments"`. The encoded form is
fixed, so other languages and database columns can rely on it. Its keys are
`lifecycle` (`L.name`, checked on decode: a record of another lifecycle fails
to decode), `version`, `key`, `revision`, `sequence`, `created`, `state`,
`since`, `updated`, and `dueAt` (written for indexes and ignored on decode,
since it is derived). Moments use design/26's text form. An entry encodes
`record`, `sequence`, `from`, `event`, `to`, `entered`, `at`, `by` (`{"principal": …}`
or `"timeout"`), `because` and `effects`.

### Reading

`read(at: now)` starts from the written state and its `since`, then applies
timeouts that have fallen due, in order:

1. If the current state has a timeout, the due moment is `since + d` (for
   `.after(d)`) or `m` (for `.at(m)`). If it is not after `now`, the
   timeout's event is applied through `transition`, as if sent at the due
   moment, by `.timeout`, `because` the timeout's description (`"after
604800 s"`, `"at 2027-03-14T22:00:00Z"`).
2. A `.to(next)` makes an entry dated at the due moment, raised to the
   previous entry's moment if it is earlier. `next` is now current, entered
   then, and step 1 repeats. A due moment earlier than `since` (an `.at` that
   had passed when the state was entered) is dated `since`.
3. If the timeout's own event does not move the state (`.stay`, `.refuse`,
   `.ignore`, `.invalid`), the definition is defective. The read stops in that
   state; committing it reports `lifecycle.timeout_refused`;
   `StateGraph.stuckTimeouts` finds it in a test.
4. The chain stops after 64 timed steps (`isTruncated`). A finite definition
   without timed cycles never comes near this (`StateGraph.timedCycles` finds
   cycles). The cap exists so that a defect costs a refusal
   (`.chainTooLong`), never a hang.

The reading's `pending` entries, and their effects, are what a commit would
add. **Nothing is written by a read, and nothing is reported.** A read is a
pure function, called from views, queries and previews, and it is repeated.
A projected transition becomes a fact, with history and effects, when it is
committed: by the next event applied to the record, by `settling`, or by a
store's `settleDue`. Until then every reader still sees the right state.

**Read-time projection is what enforces expiry.** Every path, the query that
shows a page and the action that completes it, reads the state through
`read` or `applying`. Both apply the same due timeouts with the same moment
source. So an expired waiver is `.expired` to all of them, whether or not
anything wrote it.

**The clock** is `Ambient.current.wallClock` (design/26), passed as a
parameter so tests and replays pin it. A forward jump makes timeouts fall due
early, and nothing else. A backward jump un-does nothing that was committed:
committed entries are facts, and a projected timeout simply stops being due.
New entries are dated at least at the record's `updated`, so a history's
moments never go backwards; the clamp is reported (`lifecycle.clock_behind`)
when a store commits it. As for the outbox's expiry (design/15), wall-clock
timeouts are for minutes and days, not for seconds.

**A device's wall clock belongs to its owner.** On a server, a clock set back
is an operator's mistake, and a projected timeout that stops being due is
acceptable. On a device it would let a person un-expire a state by setting
the clock back. So a store says which moment it reads and applies at
(`LifecycleStore.moment(for:)`, a requirement with no default):
`JournaledLifecycleStore` never reads or applies at a moment earlier than the
latest moment it has seen — the greatest of every `now` it was given and
every entry's moment — kept in memory and made durable with each append and
at `close()`. Within a store, time as lifecycles see it does not go
backwards; `lifecycle.clock_behind` reports the clamp. `read(_:at:)`,
`apply`, `settle` and `settleDue` all take that moment; a record loaded and
read by hand (`record.read()`) reads the wall clock it is given.

**The stated limit.** Across a relaunch with no append since the last read,
a clock set back can still un-do a projected, uncommitted expiry: the read
moved the moment only in memory. `settleDue` at launch (and on a schedule)
is what turns a due transition into a fact, and a committed fact stands. A
deadline that must hold against the device's owner belongs to a server, or
to a sealed record with a server's moment.

### Applying

`applying(event, by:, because:, at: now)`:

1. Refuses `.newerDefinition` if `version > L.version`. An older definition
   never writes over a newer one's record, whose timeouts and transitions it
   may not share. Reading such a record still works if it decodes.
2. Projects the due timeouts (Reading). Their entries come first.
3. Applies the event to the state reached:
   - `.to(next, effects)`: an entry with `entered: true`, dated `now` raised
     to `updated`. `since` becomes that moment, so the new state's timeout
     starts there. Re-entering the current state restarts its timeout.
   - `.stay(effects)`: an entry with `from == to` and `entered: false`.
     `since` is unchanged, so the timeout keeps running. Every accepted event
     is history, so a `.stay` is written and the revision moves. An
     administrator's reminder is recorded like any other act.
   - `.refuse(reason)`, `.ignore`, `.invalid(reason)`: throws `.refused`,
     `.ignored` or `.invalid`, with the state reached. Nothing is returned
     to commit. The due timeouts are still projected for every reader, and
     will be committed by whoever writes next.
4. Returns a `Change`: `base` (the revision read), the new record (`revision
   - 1`, `sequence`advanced by the number of entries,`version = L.version`),
     the entries, and the effects with their keys.

It never returns nil and never does nothing silently: it returns a change, or
throws a refusal that names the state. `settling(at:)` is steps 1, 2 and 4.
It returns nil when nothing is due.

**Who and why.** `by` is the app's `Principal`; timed entries are by
`.timeout`. `because` is required: a short sentence stored in history and
never in an event, because it may name people. An empty string is
accepted. A lint rule against empty reasons is possible, but is not proposed.

**Effect keys.** Effect number `i` of the entry with sequence `s` has the key
`IdempotencyKey.lifecycle(record: key, entry: s, position: i)`. Like
design/22's derived keys, each half of it is a SplitMix64-finalised FNV-1a
`StableHash` of the domain tag `"lifecycle"`, the half's index, one half of
the record key, `s` and `i`. Computing the same change twice, or committing
the same due timeout from two places, gives the same keys. Keys are computed
when the change is made and stored with it; they are never recomputed from a
later definition.

### Revisions and conflicts

A change commits only over its `base`. A store that finds another revision
must refuse, and returns `.conflict(current:)`. `update(id) { record in … }`
loads, calls the closure, commits, and on a conflict calls the closure again
on the current record. It does this at most `attempts` times (3) and does not
wait between attempts, because a conflict means another writer finished, not
that something is overloaded. Then it throws `.conflict(attempts:)`.
Re-applying is cheap and correct because the closure is pure: two staff
pressing "send" at once compute the same change. The first commits. The
second meets `.sent`, and the definition says `.ignore`: one email.

`update` reports what it decided: `lifecycle.applied`, `lifecycle.refused`,
`lifecycle.invalid`, `lifecycle.conflict` and `lifecycle.newer_definition`
(Events). The pure functions report nothing, so previewing "could this
volunteer check in?" is free of side effects.

`LifecycleUpdateError` is `Retryable`. `.conflict` asks for a retry, and
`.refused` and `.notFound` stop. `.storage` classifies as its `Failure` does.
A storage failure is not retried by `update`. A store performs its own I/O
through a declared operation (design/22) when it wants retries, so retrying
happens at one layer (rule 3).

### History

**Where it lives: beside the record, complete and append-only.** A commit
writes the new head, the record above, and appends its entries. The entries
are written once and never rewritten.

- **Complete.** No ring, no limit. Records are purged explicitly, final
  records only, after a retention the app states (`purge(finishedBefore:)`),
  with the record and its history together. That is the only way an entry
  ever goes away, and it is reported.
- **Unalterable by later writes.** History kept inside the record would be
  rewritten on every commit, so one buggy write could change the past.
  Entries kept beside it are only ever inserted.
- **Gapless and checkable.** Entries are numbered from 0 and the head counts
  them. `LifecycleHistory.verify` checks that the numbers run without a gap,
  that each entry starts where the one before ended, and that the last ends
  in the written state. An auditor, or a test, can run it on any store.
- **Cheap to read and write.** The head stays the same size, so loading
  state never loads history, and a compare-and-set write is small.

The cost is that a commit writes two things. Effects already require the
store to write several things at once, so history adds no new obligation.
The other cost is that "who approved this?" is a history query
(`history(of:)`). The alternative, history inside the record and bounded, was
rejected: a bounded history is a diagnostic, not an audit trail. Unbounded
history inside the record was rejected for the rewrite and size reasons
above.

### Effects, atomically

**What is promised.** A change's new head, its entries and its effects'
intents become durable **together or not at all**. Effects are then
delivered **at least once**, each under its own key, and asking to deliver
an effect whose key has already settled does nothing, within the bound
below. "Exactly once" happens at the receiver that honours the key. Nothing
here makes the commit and the delivery one act; nothing can.

**Any store** (the obligations of `LifecycleStore.commit`). In one
transaction: compare `revision` with `change.base`; write the head; insert the
entries; insert the effects (`LifecycleEffect`, key and value) where its
delivery mechanism reads them. Then commit, or none of it. A server
database's transaction is that. Delivery from there is the app's: a
scheduler that is part of the transaction, a polled table or a queue, always sending
`effect.key` as the idempotency key. `insert` must not overwrite an existing
id. A store that cannot do this atomically does not conform, and the
contract says so rather than offering a weaker mode.

**On device** (`JournaledLifecycleStore`, with the `Journal` and the `Outbox` as they
are, plus the change below). The store keeps two families of files: a journal
at `path` (heads, histories, hand-off marks) and an outbox at `path.effects`
(`Outbox<LifecycleDelivery<L, ID>>`). A commit is:

1. **One `Journal.append`** of `{id, change (head, entries, keyed effects),
handedOff}`. That framed, checksummed record is the commit point. The
   journal makes it all or nothing, so after a crash the commit either
   happened, with its effects' intents inside it, or did not.
2. Memory is updated, and `commit` returns `.committed` from here on,
   whatever follows.
3. **Hand-off**: each effect is `enqueue`d in the outbox under its key.
   `handedOff`, the journal sequence up to which every commit's effects are in
   the outbox, advances in memory. It becomes durable as the `handedOff`
   field of the next append, and in the snapshot.
4. If an `enqueue` fails, the commit stands, because its effects are durable
   in the journal. `commit` still returns `.committed`, with
   `lifecycle.handoff_deferred` at warning level. Throwing would invite a
   retry that the definition refuses, since the state has moved. The hand-off
   is retried, in order, before the next commit, by `settleDue`, by
   `deliverEffects` and at open.

**Recovery at open.** Replay the snapshot and the log. Find the durable
`handedOff`, and `enqueue` again the effects of every commit after it
(`lifecycle.handoff_resumed`, with the count). An effect that is still
pending is not added twice, because the outbox's enqueue is idempotent in a
pending key, as it always was. An effect that was already delivered or
discarded is not added again either, which is the change below.

**The one Outbox change: settled keys are remembered.** Without it,
recovery would re-send an effect that was delivered after its commit and
before the next append carried `handedOff` past it.

- `Outbox.open(…, rememberSettled: n)`. With `n > 0`, the keys of the last `n`
  entries to settle are kept, in settlement order. An entry settles when it is
  acknowledged, delivered or discarded, including `discard(_:)`; a discarded
  entry must not come back either, or an expired effect would be sent late.
- `enqueue(_:key:)` of a remembered key writes nothing, returns the key and
  reports `store.outbox_already_settled` (info). `isSettled(_:)` answers
  directly. `deliver(_:using:)` of one still answers `.notPending`, as
  `DeliveryOutcome` cannot grow a case without a break.
- **Durable without a new log record.** Settlements are already journal
  records (`0x02`), so recovery rebuilds the window from the snapshot and
  then the log. A snapshot written by an outbox that remembers carries the
  window after its entries, flagged by bit 30 of its 32-bit count (bit 31 is
  expiry's). That is a one-way door taken only by an outbox that asks, as
  expiry's is: a release before this one reads the flag as part of the
  count, finds too few bytes for that many entries, and refuses the outbox
  with `StoreError.corrupt` (`outbox snapshot`, "malformed"); it never
  misreads it. An outbox with `rememberSettled: 0`, the default, writes the
  formats every earlier release reads.
- **The bound is a count, not an age.** A count is deterministic and needs no
  clock. Forgetting is safe for the store as long as no key is evicted
  between its delivery and the hand-off mark that passes it. Hand-off is in
  commit order, and `handedOff` advances with every append. So the effects
  that recovery can re-enqueue are those of the last commit, plus those of a
  hand-off that keeps failing. For one of them to be forgotten, `n` other
  entries must settle after it before the mark passes it. The outbox
  delivers in enqueue order, so those entries would have to be ones enqueued
  before it and delivered after it: `continueWithNext`, or `deliver(_:)`,
  draining a backlog of at least `n` while a hand-off keeps failing. With
  `n = 4096` that is accepted and stated (Failure modes). The receiver's key
  is the last defence.

**Settling due timeouts on device.** `settleDue(at:)`, at the store's moment, makes the settling change
of every record whose `written.dueAt` is not after `now`, and appends all of
them as **one `append(batch:)`**: every record settled, or none, with one
`fullSync`. Then it hands off. A record the definition cannot settle (its
timeout does not move it, its chain is cut, a newer definition wrote it) is
left and reported. `nextDue` is the earliest `dueAt` of the records it can
settle, so an app or a scheduler (the planned reconciler) knows when to call
again and never spins on a defective one. A record also settles whenever an
event is applied to it.

**Compaction** writes a snapshot of every head, every history, every
undecodable record's bytes and `handedOff`, through `Journal.compact`, once
the log passes `compactionThreshold` (256 KiB). It waits until every commit
is handed off, so the snapshot never has to carry effects. **Purge** is a
journal record naming the ids. It is refused for a record whose state, as
read now, is not final.

### Schema evolution of a stored state

- **Adding** a state, an event or an effect is compatible. An older build that
  meets a record in a state it does not know fails to decode it. A
  `JournaledLifecycleStore` keeps that record's bytes untouched, lists its id in
  `openReport.undecodable`, throws `.corrupt` from `load` and `commit` for
  that id ("written by a newer build, or damaged"), and never overwrites it.
  It goes back to the newer build intact. An effect the older build cannot
  decode stays pending in the outbox (`onUndecodable: .keep`, the existing
  default).
- **Removing** a case is not allowed while stored data may hold it: old
  heads and old history entries would stop decoding, and an audit trail that
  stops decoding is lost. A state is **retired** instead. It keeps its case,
  `isRetired` says so, no current state may enter it, and it is given a
  timeout `.after(.zero, send: …)` to the state that replaces it. A record
  written in it is then migrated on its next read, by the same machinery,
  and the migration is history (`by: .timeout`, `because: "after 0 s"`). A
  retired event keeps its case, and the transition function refuses it.
  `StateGraph` checks both (Checking a definition).
- **Renaming** is removing plus adding, unless the encoded name is kept
  (`String` raw values, explicit coding keys).
- **Changing a timeout** changes it for every record on its next read,
  including records already waiting. Timeouts are the definition's, not the
  record's. Shortening the waiver's expiry from seven days to three expires
  four-day-old waivers at once. When that is wrong, the state carries its own
  moment (`.at`). Changing a transition affects future events only, because
  committed history is fact. A projected, uncommitted timeout is not fact.
  Run `settleDue`, or the server's sweep, before deploying a change to
  timeouts when the difference matters.
- **`L.version`** guards semantics during an overlap: two server versions
  live during a deploy, or the old and new build of a Mac app (the successor
  confirms a record the old build wrote). Raise it when a write by the older
  definition would be wrong. Records it wrote are then refused to older
  writers (`.newerDefinition`) and still readable by them.
- **`L.name`** never changes. It is in every record, every key and every
  event.

### Checking a definition

`StateGraph.explore(L.self, from:, events:)` explores like design/07, with
two differences. Each reached state's timeout event is tried in that state,
and the start states are a list: records can be created in several (sign-up,
import). Beyond today's `states`, `edges`, `invalid`, `deadEnds` and
`isComplete`:

| Check                                  | Finds                                                                      | Kindora's or Lodestar's bug it would have shown                                             |
| -------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `waitingForever`                       | reachable states, not final, with no timeout: a wait with no end           | `submitted` with nothing that approves, the `checking` phase that refused every later check |
| `undeclaredDeadEnds`                   | states nothing leaves, not declared final                                  | `isApproved = false` forever                                                                |
| `finalWithExits`                       | states declared final that an event or timeout leaves                      | —                                                                                           |
| `timedCycles`                          | cycles made only of timeouts: periodic work, which belongs to a `Schedule` | a daily check modelled as a lifecycle                                                       |
| `stuckTimeouts`                        | states whose own timeout event does not move them                          | —                                                                                           |
| `retiredEntries`, `retiredWithoutExit` | a retired state entered, or never migrated                                 | —                                                                                           |

A test asserts `isComplete` first, then each list against what it expects.
`waitingForever` is asserted **equal to a written list**, never empty by
fiat. For the parent waiver that is
`#expect(Set(graph.waitingForever) == [.awaitingAddress, .expired])`, and for
the charity approval `[.approved, .suspended, .rejected, .lapsed]`, with
`submitted` not in it. A state that can wait forever is then a decision
in a diff. This is principle 2 (every wait has an end) applied to data.

What no graph can find is a call site that is missing. Kindora's `approve`
would be in the definition, and nothing in the app sends it. The timeout on
`submitted` is what makes that visible at run time: lapsed approvals, the
owner told, `lifecycle.applied` counting `lapse`.

`randomWalks(L.self, …)` draws from the events and from "time passes until
the next due moment", applies them through `applying` on a virtual moment,
and checks an invariant over the state and the entries. So a property of the
path can be checked: "never signed after expired", "one `emailSigningLink`
per visit to `sent`". It shrinks a failure as today. A walk that meets
`.invalid` is a violation.

### Cancellation

The pure core has nothing to cancel. `update` checks for cancellation before
each attempt and throws `.cancelled` (a typed throw cannot carry a
`CancellationError`; `isCancellation` says so, and Stoic's classification
sees it), and `.storage` only with what the store threw. A commit
already sent to a store completes or not as that store decides, and
`JournaledLifecycleStore`'s commits are synchronous journal writes that cannot be
interrupted. `deliverEffects` is `deliverPending`, with design/15's
cancellation rules: the entry in flight stays pending. Cleanup always runs.

### Isolation

Records, readings, changes and entries are `Sendable` values. `JournaledLifecycleStore`
is an actor whose journal I/O happens on its own executor, as the `Outbox`'s
does. `deliverEffects` awaits the outbox's actor, and commits proceed while a
delivery waits on the network; its closure is `@Sendable`, because it is
handed to that actor. One hand-off runs at a time, in commit order; a caller
that finds one running waits for it. `InMemoryLifecycleStore` is an actor
too.

### Defaults

| Default                       | Value   | Why                                                                                   |
| ----------------------------- | ------- | ------------------------------------------------------------------------------------- |
| `L.version`                   | 1       | nothing to guard until a definition changes meaning                                   |
| timed steps per read          | 64      | far above any definition without timed cycles; a defect costs a refusal, not a hang   |
| `update` attempts             | 3       | a conflict means another writer finished; three in a row is contention worth a report |
| `rememberSettled` (store)     | 4 096   | the bound argument above; about 200 KB                                                |
| `rememberSettled` (`Outbox`)  | 0       | as today: formats every earlier release reads                                         |
| `compactionThreshold` (store) | 256 KiB | heads and histories are small; whole-file reads stay fast                             |

## Failure modes

| What happens if…                                                                         | Then                                                                                                                                                                      |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a state's timeout falls due and nobody writes the record                                 | every read returns the state the timeout leads to, with the pending entry dated at the due moment; nothing is written or reported                                         |
| several timeouts fall due one after another before a read                                | they are applied in order in one reading, each entry dated at its own due moment                                                                                          |
| a state is entered after its own `.at` moment has passed                                 | it times out at once; the entry is dated the moment it was entered                                                                                                        |
| an event is applied to a record whose state timed out unread                             | the event meets the state the timeout led to: the change holds the timed entries first, then the event's; a refusal names that state                                      |
| an expired waiver's link is used to sign                                                 | `.refused(state: .expired, …, "this link has expired")` on every path that reads the record; nothing changes                                                              |
| a state's own timeout event does not move it                                             | the read stops in that state; a commit reports `lifecycle.timeout_refused`; `StateGraph.stuckTimeouts` names it                                                           |
| timeouts form a cycle                                                                    | `StateGraph.timedCycles` names it; at run time the chain stops at 64 steps, the reading is truncated, and applying is refused `.chainTooLong`                             |
| the wall clock jumps forward                                                             | timeouts fall due early; nothing else                                                                                                                                     |
| the wall clock jumps backward                                                            | committed entries stand; a projected timeout is no longer due; new entries are dated no earlier than `updated`, reported `lifecycle.clock_behind`                         |
| a new entry is dated before the record's latest moment | it is dated at that moment instead; `lifecycle.clock_behind` from `update` with how far behind |
| a device's clock is set back while its store is open | `JournaledLifecycleStore` reads and applies at the latest moment it has seen: a projected expiry stays expired, new entries are dated at that moment; `lifecycle.clock_behind` |
| a device's clock is set back across a relaunch after an append | the latest moment was made durable with the append (or at `close()`): reads after the relaunch are clamped to it |
| a device's clock is set back across a relaunch with no append since the last read | the stated limit: a projected, uncommitted expiry can be un-done; `settleDue` at launch commits what is due, and a committed expiry stands |
| a test jumps the wall clock alone                                                        | records at rest follow it; a live machine's timers, on the continuous clock, do not                                                                                       |
| an event means nothing in the current state                                              | `.ignored(state:event:)`; nothing changes; `lifecycle.refused` at info from `update`                                                                                      |
| an event is refused with a reason                                                        | `.refused(state:event:reason:)`; nothing changes; `lifecycle.refused` at info                                                                                             |
| an event should be impossible in the current state                                       | `.invalid`; nothing changes; `lifecycle.invalid` at error level from `update`                                                                                             |
| an event is accepted with `.stay`                                                        | one entry with `from == to`, `entered: false`; `since` and the running timeout are unchanged; the revision moves                                                          |
| a state is re-entered                                                                    | a new entry; `since` is the entry's moment; the state's timeout restarts                                                                                                  |
| two writers commit changes made from the same revision                                   | one commits; the other gets `.conflict(current:)`, and `update` applies its closure again to the current record                                                           |
| conflicts continue past the attempts                                                     | `.conflict(attempts:)`; `lifecycle.conflict` for each conflict, and the last at warning level                                                                             |
| the same event is sent twice at once                                                     | the second is applied to the first's result, and the definition decides; the waiver's second "send" is ignored, so one email                                              |
| two writers commit the same due timeout                                                  | the same entries and the same effect keys; one commits, the other conflicts and finds them committed; the effect is enqueued once                                         |
| a change made from one record is committed to another | refused with the store's error (`StoreError.invalidArgument` on a device, `.foreignChange` in memory); nothing written |
| a record is inserted under an id that exists                                             | `insert` returns false; the existing record is untouched                                                                                                                  |
| an older definition applies an event to a record a newer one wrote                       | `.newerDefinition`; nothing written; `lifecycle.newer_definition`; reading it still works if it decodes                                                                   |
| a stored record holds a state this build does not know                                   | it does not decode; the store keeps its bytes, lists its id in `openReport.undecodable`, throws `.corrupt` for that id, and never overwrites it                           |
| a record is in a retired state                                                           | its zero timeout migrates it on the next read; the migration is an entry by `.timeout`, committed with the next write                                                     |
| a timeout is changed in a new build                                                      | records in that state follow the new timeout on their next read, those already waiting included; committed entries are unchanged                                          |
| a history entry holds an event that was retired                                          | it still decodes: retired cases are kept                                                                                                                                  |
| a transition carries effects                                                             | the change carries each with a key derived from the record key, the entry's sequence and its position; making the change again gives the same keys                        |
| the process dies at any point of a device commit                                         | after open: the old head and history with no effects from it, or the new head, entries and every effect pending or settled; never a head without its entries              |
| the process dies during recovery at open | what a crash before recovery would leave: recovery's own writes (the hand-off it resumes, a compaction) are crash-safe, and the next open resumes them again |
| the process dies during `settleDue`, compaction or purge | after open: every record settled by the batch or none; heads and histories as before or after, each history verifying; purged records gone with their histories, or both still there |
| the process dies after the commit and before its effects reach the outbox                | recovery at open enqueues them (`lifecycle.handoff_resumed`)                                                                                                              |
| the process dies after an effect was delivered and before the hand-off mark was durable  | recovery enqueues it again; the outbox remembers its key; nothing is sent                                                                                                 |
| an effect's enqueue fails after the commit                                               | the commit stands and returns `.committed`; `lifecycle.handoff_deferred`; the hand-off is retried before the next commit, by `settleDue`, by `deliverEffects` and at open |
| the journal append of a commit fails                                                     | nothing changes and nothing is enqueued; the `StoreError` is thrown; the journal rolls back (design/15)                                                                   |
| the journal's sync fails during a commit                                                 | thrown; nothing committed; the journal is poisoned until reopened (design/15)                                                                                             |
| a hand-off keeps failing while a backlog of more than 4 096 entries settles out of order | an effect delivered before the failure may be delivered again under its key; the receiver's idempotency decides                                                           |
| `settleDue` finds several records due                                                    | one batch append: every record settled or none; their effects handed off after                                                                                            |
| a record's history is checked                                                            | `LifecycleHistory.verify` finds no gap, no break between entries, and an end in the written state; it throws `HistoryGap` naming the first fault                          |
| a final record is purged                                                                 | the record and its history go together; `lifecycle.purged`; a record that is not final as read now is refused                                                             |
| a database query selects by the written state                                            | it can include records whose state timed out unread; reading each loaded record gives the truth, and a query filters on `dueAt` too                                       |
| a lifecycle runs live                                                                    | entering a state, the initial one included, arms its timeout on the machine's clock; an `.at` timeout is measured on the wall clock at entry                              |
| a live lifecycle's transition carries effects                                            | `perform` gets each once, in order, outside the lock, after observers; nothing is durable                                                                                 |
| a declared state waits forever                                                           | `StateGraph.waitingForever` lists it, for a test to accept by name                                                                                                        |
| a dead end is not declared final                                                         | `StateGraph.undeclaredDeadEnds` lists it                                                                                                                                  |

## Events

All in `EventCatalog`, labelled with `L.name`. They carry states and events
as descriptions at `.private` privacy, because payloads can name people (an
email address). They carry revisions, counts and durations publicly. They
never carry a principal, a reason or an effect. Pure functions record
nothing. These events come from `update`, `JournaledLifecycleStore` and a live
machine.

| Event                          | Level   | Meaning                                                                        |
| ------------------------------ | ------- | ------------------------------------------------------------------------------ |
| `lifecycle.applied`            | debug   | a change committed: from, event, to, entries, effects                          |
| `lifecycle.timed_out`          | info    | a commit included timed entries: how many, the first's due moment and lateness |
| `lifecycle.refused`            | info    | an event refused or ignored at rest                                            |
| `lifecycle.invalid`            | error   | an event the definition says is impossible                                     |
| `lifecycle.conflict`           | notice  | a commit lost to another writer (warning once `update` gives up)               |
| `lifecycle.newer_definition`   | warning | a record written by a newer definition was not written                         |
| `lifecycle.undecodable`        | error   | a stored record does not decode; kept                                          |
| `lifecycle.clock_behind`       | notice  | an entry's moment was raised to the record's latest                            |
| `lifecycle.timeout_refused`    | error   | a state's own timeout did not move it                                          |
| `lifecycle.chain_truncated`    | error   | timed steps stopped at the cap                                                 |
| `lifecycle.handoff_deferred`   | warning | committed effects could not yet be put in the outbox                           |
| `lifecycle.handoff_resumed`    | notice  | recovery put the effects of n commits in the outbox                            |
| `lifecycle.purged`             | info    | n final records and their histories removed                                    |
| `lifecycle.maintenance_failed` | warning | a compaction failed; nothing was lost (the log is whole)                       |
| `store.outbox_already_settled` | info    | an enqueue named a key that already settled; nothing written                   |

## Testing

- Every row above on a `TestClock` with the test wall clock (design/26).
  `InMemoryLifecycleStore` covers the storage-agnostic rows; its
  `conflictNextCommit` drives the conflict rows. `JournaledLifecycleStore` runs on
  `SimulatedFileSystem` with injected faults for the device rows.
- **Crash consistency is part of the contract, not a hope.** The device
  commit, the hand-off, recovery, `settleDue`'s batch, compaction, purge and
  the outbox's remembered keys are tested at every file operation with
  `SimulatedFileSystem`'s crash points (design/15's `exploreCrashes`), every
  disk image those points allow, and a crash during recovery itself, as
  design/15's own tests are. A row about a device commit without such a test
  is a gap. Invariants: the store opens; each record is an old or a
  new head, never a head without its entries; `LifecycleHistory.verify`
  passes for every record; every committed effect is pending or settled in
  the outbox after open; no effect whose acknowledgement returned is pending
  again; nothing is pending that no surviving commit owes; a step that
  returned survived. Tests that must fail keep the harness honest: a store that enqueues
  before it appends, one that appends the head and entries as two records,
  and an outbox that forgets settled keys. Each must fail the suite.
- **The Outbox change**: design/15's outbox invariants, run again with
  `rememberSettled` on; the window across relaunch, compaction and eviction
  order; bytes written with `rememberSettled: 0` against bytes an earlier
  release wrote.
- **Properties**: an effect key is a function of record key, sequence and
  position, and distinct across them (10⁶ draws); reading at `t` and then
  applying at `t` agree; settling and then reading gives the same state as
  reading; the projection of a definition with no timeouts is the identity.
- **The ideal scenarios** as tests: Kindora's three definitions with their
  graph checks (the `waitingForever` lists above), random walks with "one
  email per visit to `sent`" and "never signed after expired". Lodestar's
  release record runs through a relaunch with a newer build confirming, and a
  watchdog roll-back announced once across a crash.
- **The live reading**: `StateMachine(L.self, …)` against the existing
  design/07 suite for timeouts and visits, plus the initial state's timeout,
  `.at` conversion and `perform` ordering. 300 repetitions are clean.

## The settled fan-out

Decision 7 asked for one. It exists: `mapConcurrentResults`, with
`mapConcurrent`'s limit and cancellation rules. Its contract text and
failure-mode rows are in design/03, with their tests; nothing was added to
the API. Work whose completion must survive a cancellation belongs in an
outbox: send the emails as lifecycle effects.

## Not built

- **A live machine bound to a stored record**, whose transitions are
  committed through a store and whose `whileIn` work follows the record. The
  two readings share a definition, not a record.
- **Running `settleDue` at `nextDue`**: the reconciler planned for 0.8 owns
  that. Until then an app calls it at launch and on a timer, and a server runs
  its own sweep. So the effects of a timed transition ("tell the coordinator
  when an attendance closes unattended") wait for a commit: the next event
  applied to the record, `settle`, `settleDue` or the server's sweep. At rest
  nothing runs; the reconciler will run it on time.
- **A server outbox.** The core hands effects to the app's store. Delivery
  from a server database is the app's, under the effect's key.
- **Principals with provenance** (`Verified<Principal>`, 0.7): `Principal` is
  the app's type until then.
- **A native `StoicSchema` schema for records.** `StoicSchema` cannot see the
  kernel. `Schema.codable(LifecycleRecord<L>.self, examples:)` is the leaf
  meanwhile.
- **Queries in `JournaledLifecycleStore`** beyond `records()`. It is not a database. A
  thousand records with long histories belong in one, through a
  `LifecycleStore` conformance.
- **A sealed `JournaledLifecycleStore`** over `SealedJournal` (design/24).
- **`@Lifecycle`**, the table-declaring macro, with the `@StateMachine`
  macro already planned.
- **Calendar timeouts** ("at 18:00 on the event's day"): an `.at(Moment)`
  computed by the app with design/26's `ZonedDateTime`.

## Decisions

The review settled the draft's open questions:

1. The settled fan-out exists (`mapConcurrentResults`): design/03 gains its
   text and rows, with tests; no new API.
2. `.to(_, timeout:)` stays for closure-built machines.
3. History lives beside the record, complete and append-only.
4. `because:` is required.
5. A `.stay` at rest writes an entry and moves the revision.
6. `.refuse(reason)` is kept beside design/07's answers.
7. The settled-key bound is a count, and the hand-off mark rides the next
   append.
8. Effects of timed transitions wait for a commit (`settleDue`); the
   reconciler (0.8) will run it on time (Not built).
9. No TypeScript reading is promised; the stored format is fixed and
   documented.
10. The name stays `Lifecycle`.
11. `JournaledLifecycleStore` encodes JSON only.

## As built

Departures from the reviewed draft, and decisions it left open.

- **Names (amendment 1).** The protocol is `LifecycleStore`, the device's
  store `JournaledLifecycleStore`, the test one `InMemoryLifecycleStore`, as
  `FileSystem` / `PosixFileSystem` / `SimulatedFileSystem`.
- **The store's moment (amendment 2)** is a protocol requirement,
  `moment(for:) async -> Moment`, with **no default**: a default in a
  protocol extension won over an actor's synchronous override, silently,
  so the clamp never ran. Without one, the compiler makes every store say
  which it is. `read(_:at:)` joins `update`, `apply` and `settle` in the
  protocol extension, all at the store's moment.
- **`LifecycleUpdateError.cancelled`.** A typed throw cannot carry a
  `CancellationError`, so `update`'s check before each attempt throws this;
  `isCancellation` is true, and Stoic's classification sees it, as it sees
  `PolicyError.rejected(.cancelled)`.
- **The device store is asynchronous where the outbox is.** `open` hands
  owed effects to the outbox, an actor, so it is `async`; so are
  `settleDue` and `close`. `deliverEffects` takes a `@Sendable` closure (it
  is handed to the outbox's actor) and throws untyped, so a cancellation
  passes through as itself (rule 5).
- **`commit` hands off after the append, and again before**: a hand-off
  still owed goes first, in commit order; one hand-off runs at a time and a
  caller that finds one running waits for it.
- **The outbox's flag is bit 30 of a 32-bit count**, not bit 62 (the count
  is a `u32`; expiry's flag is bit 31). An older build refuses such a
  snapshot with `StoreError.corrupt` (amendment 4; design/15 has the row,
  proved against 0.5.0's decoder kept verbatim in the test).
- **`Outbox.open(…, rememberSettled:)` is an overload** whose parameter has no
  default: a defaulted parameter added to the existing `open` would have been
  an API break. `JournaledLifecycleStore` refuses `rememberSettled` below 1.
- **The stored format**, fixed and documented in `LifecycleStoreFormat`:
  journal records of length-prefixed JSON documents (insert, commit, purge,
  mark), each with the hand-off mark and the latest moment; snapshots of
  every record in insertion order. A document this build cannot decode is
  kept as its bytes and written back as it was; an effect is handed to the
  outbox as the bytes the commit carried, so a newer build's effect stays
  pending in an older build, as `onUndecodable: .keep` says. A commit whose
  insert the log lost is kept as undecodable, never guessed at.
- **`LifecycleHistory.verify`** also checks that every entry is the
  record's and that moments never go backwards; the first entry's `from` is
  not checked (creation is not an entry, and the record does not keep the
  state it was created in). `HistoryGap` names the fault and the entry.
- **Stores check that a change follows the stored record** (one revision
  on, entries numbered on, each the record's): `.malformedChange` in
  memory, `.invalidArgument` on a device.
- **Effect keys** are `IdempotencyKey.lifecycle(record:entry:position:)`,
  public and frozen: each half is the FNV-1a hash of `"lifecycle"` and
  `0xFF`, the half's index (8 bytes), the record key's half as UTF-8 and
  `0xFF`, the entry (8 bytes) and the position (8 bytes), all little-endian,
  SplitMix64-finalised, as 16 hexadecimal digits. Two values are pinned in a
  test.
- **`randomWalks` takes `by:`**, the principal that sends the walk's events:
  `applying` needs one, and the walk must not invent it. A wait appears in
  a violation as the timeout events it fired.
- **Graphs.** `.stay`, `.refuse` and `.ignore` make no edge, as for a
  transition function; a definition's edges carry no `timeout` (it belongs
  to the state); the Mermaid output draws every start state, marks
  `(timeout)` and follows effects with a slash. On a graph explored from a
  transition function, which declares nothing, `waitingForever` lists states
  no transition arms a timeout for, `undeclaredDeadEnds` is `deadEnds`, and
  the other checks are empty.
- **`LifecycleReading.nextDue`** is the state's due moment even when it is
  past (a defect: a refused timeout, a truncated chain);
  `JournaledLifecycleStore.nextDue` leaves out records it cannot settle.
- **`purge(finishedBefore:)`** removes the records that are final as read
  at the store's moment and whose final state was entered before the cutoff;
  a record that is not final, or does not decode, is never selected. Effects
  a purged record's commits already handed to the outbox stay there and are
  delivered: the purge removes history, not what was owed.
- **The crash tests that must fail** build their defects into the store
  through an internal switch (enqueue before the append, head and entries
  as two appends, an outbox that does not remember), so the harness is
  shown to catch the real store's code going wrong, not a copy of it.
- **A live machine's effects** are performed by one caller at a time, which
  drains the effects of every transition queued meanwhile: transition order
  holds across senders, and an effect that sends the machine an event queues
  that event's effects behind its own instead of deadlocking.
- **`Self.Step` in a conforming type.** A module-level type named `Step` or
  `Timeout` shadows the protocol's aliases in a requirement's signature;
  `Self.Step` and `Self.Timeout` always work.
- **`lifecycle.maintenance_failed`** is new: a compaction that fails loses
  nothing, so it is reported, not thrown, as the outbox's is.
- **Small additions**: `LifecycleTimeout.event` and `due(since:)`,
  `LifecycleRecord.timedStepLimit`, `LifecycleRefusal: Hashable, Retryable`
  (`.stop`), `LifecycleDelivery`'s and `LifecycleOpenReport`'s fields,
  `InMemoryLifecycleStore.conflictNextCommit(to:times:)`.

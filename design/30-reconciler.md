# 30 · Reconcilers

> Stoic 0.8.0. Builds on design/22 (declared operations), design/03
> (`mapConcurrentResults`), design/09 (supervision), design/26 (`Moment`, zoned
> values), design/27 (`settleDue`, `nextDue`) and design/28 (verified
> principals), whose "Not built" sections promised this contract. It uses
> design/31's `SupportReference` for failures a person may ask about. The
> review's amendments are folded in; "As built" records what implementing it
> changed.

An app often holds the same facts in two places. A calendar lists the people
committed to an event. A search index holds a copy of every event. A table of
devices mirrors the push tokens a phone registered. A user row mirrors an
identity provider's account. Each pair is kept in agreement the same way: every
code path that changes one side is meant to change the other. That rule holds
until a path forgets. Then a cancelled commitment stays on the calendar, an edit
drops a field from the index, and a deleted event leaves its children behind.
Nobody notices, because nothing compares the two sides. When something finally
does, it is often a script that read an empty source and deleted the
destination.

A reconciler replaces that rule with a loop. One side is the truth. The other is
derived from it. The reconciler reads what the truth says the derived side
should be and what the derived side is, and applies the difference as
corrections that are safe to repeat. It is level-triggered: a full pass is what
makes the result correct, and a trigger after a change only makes it prompt. A
pass is safe to run at any time, twice, or only partly. A failed read never
deletes anything. A pass that would remove an unusual share of the derived side
waits for a person to confirm it. Whether the two sides agree is a value that a
screen or a health check can read, and it is reported as events.

## The ideal scenario

> A volunteering service keeps three derived systems: the calendar's attendee
> lists (a remote calendar service), the map's index of events (in the service's
> own database), and the lifecycle records whose timeouts have fallen due
> (design/27). Nothing writes to both sides of a pair. A commitment written to
> the database is the whole change. The calendar follows within a second when the
> trigger fires, and within fifteen minutes when it does not. If the commitments
> query comes back empty because a deploy pointed it at the wrong table, the
> calendar keeps its 1,204 attendee lists, and someone is told. The health page
> says which pairs agree, since when, and which keys are stuck and why.

```swift
import Stoic

extension Backend {
    static let database = Backend.remote("convex")
    static let calendar = Backend.remote("cronofy", capacity: 4)
}

/// The calendar's attendee lists follow the commitments. The commitments are the truth.
/// Nothing else writes an attendee list: the app's screens write commitments.
struct CalendarAttendees: Reconciliation {
    static let name = "kindora.calendar-attendees"
    static let readsTruth = Backend.database.readOnly("calendar.desired")
    static let readsDerived = Backend.calendar.readOnly("events.list")
    static let corrects = Backend.calendar.idempotent("events.put")     // addressed by our event's id

    struct Listing: Hashable, Sendable {
        var title: String                     // "Beach clean - Surfers Against Sewage"
        var attendees: Set<EmailAddress>
    }
    let db: Database, calendar: CalendarClient

    /// Every published event and who is committed to it: complete, or thrown.
    func desired(_ scope: ReconcileScope<EventID>, attempt: Attempt) async throws(KindoraError) -> [EventID: Listing] {
        try await db.publishedEvents(scope).mapValues { event in
            Listing(title: "\(event.name) - \(event.charityName)", attendees: event.committedEmails)
        }
    }
    /// Every event the calendar holds under our tag: complete, or thrown.
    func actual(_ scope: ReconcileScope<EventID>, attempt: Attempt) async throws(KindoraError) -> [EventID: Listing] {
        try await calendar.events(tagged: "kindora", scope).mapValues { Listing(title: $0.summary, attendees: $0.attendees) }
    }
    /// Each correction makes one calendar event match, whatever state it was in.
    func correct(_ correction: Correction<EventID, Listing, Listing>, attempt: Attempt) async throws(KindoraError) {
        switch correction {
        case .create(let id, let listing), .update(let id, let listing, was: _):
            try await calendar.put(eventID: id.calendarID, listing)        // a PUT by our id: twice is once
        case .remove(let id, was: _):
            try await calendar.delete(eventID: id.calendarID)              // already absent is success
        }
    }
}

/// The map's index follows the events: coordinates and category, both of them.
struct EventIndex: Reconciliation {
    static let name = "kindora.event-index"
    static let readsTruth = Backend.database.readOnly("events.located")
    static let readsDerived = Backend.database.readOnly("geospatial.entries")
    static let corrects = Backend.database.idempotent("geospatial.put")
    struct Entry: Hashable, Sendable { var point: Coordinates; var category: Category }
    // desired, actual and correct as above. `matches` is `==` because both sides are `Entry`.
}

let attendees = Reconciler(CalendarAttendees(db: db, calendar: cronofy))    // every 15 min, guarded, bounded
let eventIndex = Reconciler(EventIndex(db: db))
let dueAttendance = Reconciler.settling(attendance, due: Attendance.due) { now, limit, _ in
    try await db.attendance(dueBefore: now, limit: limit)                    // a query on the record's `dueAt`
}

let derived = Supervisor(label: "kindora.derived") {
    Child("calendar-attendees") { _ in try await attendees.run() }
    Child("event-index") { _ in try await eventIndex.run() }
    Child("attendance-due") { _ in try await dueAttendance.run() }
}

// A commitment was written. This makes the calendar follow at once. Correctness does
// not depend on it: if this line is missing, the next full pass corrects the
// difference and reports it as drift.
attendees.changed(commitment.eventID)

// The health page: one row per reconciler.
func health<Key>(_ status: ReconcilerStatus<Key>) -> String {
    if status.isOverdue() { return "no full pass since \(status.lastFullPass?.description ?? "start")" }
    switch status.phase {
    case .converged:                    return "in agreement"                       // and since: status.lastConverged
    case .converging(let differences):  return "\(differences) being corrected"
    case .stuck(let differences):       return "\(status.stuck.count) stuck of \(differences)"   // each with reason and reference
    case .held(let differences):        return "removals wait for a person (\(differences) differences)"   // status.hold
    case .unreadable(let side):         return "cannot read the \(side)"           // nothing corrected, nothing removed
    case .starting:                     return "first pass running"
    }
}
rows = [health(attendees.status), health(eventIndex.status), health(dueAttendance.status)]

// The empty truth. The pass removes nothing, holds the removals and reports them.
// A person who has checked lets them through, and the record says who.
if let hold = attendees.status.hold {
    try attendees.confirm(hold, by: coordinator, because: "the test calendar was retired on purpose")
}
```

The same type on a device, with the records Stoic keeps (design/27) and the
zoned values an app holds (design/26). It runs while the app runs, and from a
background job:

```swift
let releasesDue = Reconciler.settling(releases)         // JournaledLifecycleStore: wakes at its nextDue
let starts = Reconciler.zonedValues(
    name: "kindora.event-starts", reads: Events.starts, writes: Events.restart,
    values: { scope, _ in try await local.upcomingStarts(scope) },        // [EventID: ZonedDateTime]
    write: { moved, _ in try await local.update(starts: moved) })

let upkeep = Supervisor(label: "kindora.upkeep") {
    Child("releases-due") { _ in try await releasesDue.run() }
    Child("event-starts") { _ in try await starts.run() }
}

let refresh = BackgroundJob(identifier: "org.kindora.upkeep", every: .seconds(3_600),
                            scheduler: SystemBackgroundTaskScheduler()) {
    try await starts.pass()                  // one full pass, under the job's deadline
}
```

## Origin

- **Kindora** (TypeScript on Convex), read for this contract. There are six
  pairs, each kept by dual writes. Kindora has no cron and no repair job, and
  nothing caps how many rows a delete may remove.
  - _Calendar attendees and commitments._ The app inserts a commitment, pushes
    the user's email onto its own copy of the attendee list, and sends the whole
    list to the calendar (`apps/mobile/app/(main)/event/[eventId]/details.tsx:155-173`;
    `calendar/actions.ts:333` replaces the list). So the last client to write
    wins. Editing an event resends a list that may be stale
    (`basic-information.tsx:160-172`). Cancelling a commitment
    (`commitments/mutations.ts:282-299`) and deleting an event
    (`events/mutations.ts:59-73`) never touch the calendar. The title is written
    as `name - charityName` on create (`calendar/actions.ts:210`) and as `name`
    on edit (`:329`), so editing loses the suffix.
  - _Identity-provider users and profiles._ There are no webhooks. The client
    creates the profile after sign-up, before the email is verified
    (`(auth)/sign-up.tsx:74-89`). It deletes the account as a client-side chain
    of four calls (`account/security.tsx:113-122`), so a failure partway leaves
    rows behind. Profiles are keyed by email and the provider's users by
    subject, so a changed email never arrives.
  - _The geospatial index and events._ Insert writes the category
    (`events/mutations.ts:50-53`). Patch removes and re-inserts without it
    (`:90-94`): that is the site that drops the field. Delete removes the row and
    the index entry in two steps (`:64-67`).
  - _Push tokens and devices._ There is one token per profile, so a second
    device overwrites the first. Opting out writes `""`
    (`account/security.tsx:197-200`), and `getExpoTokensByEmails` filters only
    `null` (`profiles/queries.ts:164-166`), so the empty token is still sent to.
    The hook that re-uploads the token on every foreground undoes the opt-out
    (`hooks/usePushTokenSync.ts:41-46`).
  - _Denormalised names._ Commitments and permissions copy the person's names
    at insert (`commitments/mutations.ts:31-33`, `permissions/mutations.ts:21-23`).
    Nothing ever updates them.
  - _Events and their children._ Deleting an event leaves its commitments, guest
    commitments and feedback (`events/mutations.ts:59-73`; all indexed
    `by_event`, `schema.ts:21-42`). Deleting a charity leaves its events and
    waivers (`charities/mutations.ts:69-83`).
- **Lodestar**, the pilot, has two reconcilers written by hand:
  - `reconcileLoginItem` (`Sources/lodestar/main.swift:2772-2840`) makes the
    launch agent and the CLI link match `config.startAtLogin`. It rewrites only
    when the bytes differ, removes the plist when the setting is off, and skips a
    translocated bundle.
  - The sealed clipboard deletes blobs its index does not name only `if
!degraded` (`Sources/LodestarCore/SealedClipboard.swift:139-142`). That is
    the removal guard below, written by hand.
- **Kubernetes controllers** (from prior knowledge, not re-checked): level-triggered
  reconciliation. They use a work queue of keys that deduplicates them, never
  process one key in two workers at once, resync everything periodically, and
  back off per key. This contract takes all four.
- **Terraform's plan** (from prior knowledge): the difference is a value, computed
  before anything is applied and shown before a destructive change. Here the
  plan is a pure function, and its removals pass a guard.
- **`rsync --max-delete`** (from prior knowledge): a sync refuses to delete more
  than a stated number of files. The guard here is that idea, stated as a
  share. The incident it prevents is the usual one: a source that read as empty,
  and a destination emptied to match it.
- **Stoic itself.** design/27's `settleDue` and `nextDue` say what is due and
  when, and nothing runs them on time. design/26's `ZoneRulesSweep` runs once
  per change of the rules' version. That is a trigger with no level pass behind
  it, so a value that another device wrote under older rules is never refreshed.

## API

```swift
// MARK: Stoic (the kernel), Sources/Stoic/Reconcile

/// Two systems, one of them the truth, and how to bring the other into line.
/// A conforming type is the declaration. An instance holds the clients it reads
/// and writes through.
public protocol Reconciliation: Sendable {
    associatedtype Key: Hashable & Comparable & Sendable
    associatedtype Desired: Sendable
    associatedtype Actual: Sendable
    associatedtype Failure: Error

    /// Stable forever: it names the reconciliation in events and keys.
    static var name: String { get }
    /// How the truth is read. Must be `.readOnly`.
    static var readsTruth: Backend.Operation { get }
    /// How the derived side is read. Must be `.readOnly`.
    static var readsDerived: Backend.Operation { get }
    /// How a correction is applied. Must be `.idempotent` or `.keyed`.
    static var corrects: Backend.Operation { get }

    /// What the truth says the derived side should hold within `scope`:
    /// complete, or thrown. A key absent from the result must not exist there.
    func desired(_ scope: ReconcileScope<Key>, attempt: Attempt) async throws(Failure) -> [Key: Desired]
    /// What the derived side holds within `scope`: complete, or thrown.
    func actual(_ scope: ReconcileScope<Key>, attempt: Attempt) async throws(Failure) -> [Key: Actual]
    /// Whether the derived side's value is what the truth asks for. Default: `==`
    /// when `Desired == Actual` and both are `Equatable`.
    func matches(_ desired: Desired, _ actual: Actual) -> Bool
    /// Makes one key of the derived side match. Must leave the same result
    /// whether run once or more, and whatever the key's state was.
    func correct(_ correction: Correction<Key, Desired, Actual>, attempt: Attempt) async throws(Failure)
    /// When the truth will next change by itself (an event ends, a record falls due).
    /// Default: nil.
    func nextChange() async -> Moment?
}

public enum ReconcileScope<Key: Hashable & Sendable>: Sendable, Hashable {
    case all                     // every key either side holds
    case keys(Set<Key>)          // these keys only
    public func contains(_ key: Key) -> Bool
}

public enum Correction<Key: Sendable, Desired: Sendable, Actual: Sendable>: Sendable {
    case create(Key, Desired)                 // the truth has it, the derived side does not
    case update(Key, Desired, was: Actual)    // both have it, and it does not match
    case remove(Key, was: Actual)             // the derived side has it, the truth does not
    public var key: Key { get }
    public var kind: CorrectionKind { get }
}
public enum CorrectionKind: String, Sendable, Hashable, Comparable { case create, update, remove }

/// The difference between two complete readings, as data. Pure.
public struct ReconcilePlan<R: Reconciliation>: Sendable {
    public init(desired: [R.Key: R.Desired], actual: [R.Key: R.Actual], using reconciliation: R)
    public let corrections: [Correction<R.Key, R.Desired, R.Actual>]   // creates and updates by key, then removes by key
    public let unchanged: Int
    public var removals: Int { get }
}

/// How much of the derived side one pass may remove without a person.
public struct RemovalGuard: Sendable, Hashable {
    /// A pass may remove at most `max(count, ⌊share × derived keys read⌋)` keys.
    public static func atMost(share: Double, orCount count: Int) -> RemovalGuard
    /// Removals are never held: a derived side that is a cache of nothing anyone needs.
    public static let unguarded: RemovalGuard
}

/// Removals a pass did not make, waiting for a person.
public struct RemovalHold<Key: Hashable & Sendable & Comparable>: Sendable, Hashable {
    public let keys: [Key]               // every key the pass would have removed, in key order
    public var removals: Int { get }     // keys.count
    public let derivedCount: Int         // derived keys the pass read
    public let truthWasEmpty: Bool       // a full pass read an empty truth
    public let since: Moment             // when it was first held
}

public struct ReconcilePolicy: Sendable, Hashable {
    public var removals: RemovalGuard = .atMost(share: 0.10, orCount: 5)
    public var correctionsPerPass: Int = 1_000
    public var concurrency: Int = 4
    public var passDeadline: Duration = .seconds(600)
    public var coalesce: Duration = .seconds(1)         // quiet time before a triggered pass
    public var verifyAfter: Duration = .seconds(2)      // a scoped pass over what was just corrected
    public var stuckAfter: Int = 3                       // passes in a row
    public var keyBackoff: Schedule = .exponential(base: .seconds(5)).capped(at: .seconds(3_600))
    public var failedPassBackoff: Schedule = .exponential(base: .seconds(30)).capped(at: .seconds(900))
    public var pendingKeys: Int = 10_000                 // triggered keys held before a full pass replaces them
    public var overdueAfter: Duration = .seconds(1_800)
    public var urgency: Urgency = .utility
    public init()
}

/// Runs a reconciliation: passes on a schedule and on demand, guarded, bounded, observed.
public final class Reconciler<Key: Hashable & Comparable & Sendable>: Sendable, Observable {
    public convenience init<R: Reconciliation>(
        _ reconciliation: R,
        every schedule: Schedule = .fixed(.seconds(900)).jittered(.equal),
        policy: ReconcilePolicy = ReconcilePolicy(),
        clock: AnyClock? = nil
    ) where R.Key == Key

    /// A job that converges in one call of its own (Jobs that converge by themselves).
    public init(
        name: String,
        every schedule: Schedule = .fixed(.seconds(900)).jittered(.equal),
        policy: ReconcilePolicy = ReconcilePolicy(),
        clock: AnyClock? = nil,
        nextDue: (@Sendable () async -> Moment?)? = nil,
        pass: @escaping @Sendable (ReconcileRequest<Key>) async throws -> ReconcileOutcome<Key>
    )

    public let name: String
    /// Observable: a view or a health check that reads it is updated after every pass.
    public var status: ReconcilerStatus<Key> { get }

    /// Passes until cancelled: one full pass at once, then on the schedule, on
    /// triggers, for verification and at `nextDue`. A failing pass is a status,
    /// never a throw.
    public func run() async throws(CancellationError)
    /// One pass now, after any pass in progress. Returns what it did.
    @discardableResult
    public func pass(_ scope: ReconcileScope<Key> = .all) async throws(ReconcileError) -> ReconcilePassReport<Key>
    /// These keys may have changed: a scoped pass follows after `coalesce`.
    public func changed(_ keys: some Sequence<Key>)
    public func changed(_ key: Key)
    /// A full pass follows after `coalesce`, whatever the schedule says.
    public func requestFullPass()
    /// Lets the next full pass make the removals `hold` names, on a verified principal's word.
    /// Refused if it is not the current hold.
    public func confirm<Principal, E: PrincipalEvidence>(
        _ hold: RemovalHold<Key>, by principal: Verified<Principal, E>, because: String
    ) throws(ReconcileError)
}

public struct ReconcilerStatus<Key: Hashable & Sendable & Comparable>: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case starting                       // no full pass has read both sides yet
        case converged                      // no difference is known
        case converging(differences: Int)   // differences known, being corrected or verified
        case stuck(differences: Int)        // some keys stopped converging (`stuck`)
        case held(differences: Int)         // removals wait for a person (`hold`)
        case unreadable(ReconcileSide)      // the last pass could not read a side
    }
    public let phase: Phase
    public let lastConverged: Moment?       // when a reading last found no difference left
    public let lastFullPass: Moment?        // when a full pass last read both sides
    public let stuck: [ReconcileStuck<Key>] // in key order
    public let hold: RemovalHold<Key>?
    public let unreadable: ReconcileFailure?
    public let overdueAt: Moment            // lastFullPass (or start) + overdueAfter
    public func isOverdue(at now: Moment = .now) -> Bool
}
public enum ReconcileSide: String, Sendable, Hashable { case truth, derived }

public struct ReconcileStuck<Key: Hashable & Sendable>: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        case failing(ReconcileFailure)      // its correction keeps failing
        case doesNotTake                    // its correction succeeds; the next read still differs
        case refused(String)                // a job said it cannot converge it, and why
    }
    public let key: Key
    public let kind: CorrectionKind?
    public let reason: Reason
    public let passes: Int                  // in a row
    public let since: Moment
}
public struct ReconcileFailure: Sendable, Hashable {
    public let errorType: String            // as events record it; never its description
    public let reference: SupportReference  // matches the event that reported it (design/31)
    public let isDefect: Bool
}

public struct ReconcilePassReport<Key: Hashable & Sendable>: Sendable {
    public enum Outcome: Sendable, Hashable { case clean, corrected, partial, held, cutShort, cancelled }
    public let scope: ReconcileScope<Key>
    public let started: Moment, ended: Moment
    public let outcome: Outcome
    public let differences: Int             // found by this pass's reading
    public let applied: Int, failed: Int, deferred: Int, waiting: Int, held: Int
    public let confirmation: String?        // the reason given to the confirmation this pass used
}
public enum ReconcileError: Error, Sendable, Hashable {
    case unreadable(ReconcileSide, ReconcileFailure)
    case cancelled                          // isCancellation
    case holdChanged                        // confirm: that hold is no longer the current one
    public var isCancellation: Bool { get }
}

extension IdempotencyKey {
    /// A correction's key: the pass's random key and the correction's position in the plan,
    /// hashed as `lifecycle(record:entry:position:)` is (design/27). Frozen once built.
    public static func reconciliation(pass: IdempotencyKey, position: Int) -> IdempotencyKey
}

// A job's own pass (Jobs that converge by themselves)
public struct ReconcileRequest<Key: Hashable & Sendable>: Sendable {
    public let scope: ReconcileScope<Key>
    public let limit: Int                   // correctionsPerPass
    public let waiting: Set<Key>            // refused keys on their backoff: skip them
}
public struct ReconcileOutcome<Key: Hashable & Sendable>: Sendable {
    public init(differences: Int, corrected: Int, deferred: Int = 0, refused: [Key: String] = [:])
}

// Adapters
extension Reconciler {
    /// Commits what has fallen due in any lifecycle store, at the store's moment (design/27).
    public static func settling<S: LifecycleStore>(
        _ store: S, due: Backend.Operation,
        every: Schedule = .fixed(.seconds(300)).jittered(.equal), policy: ReconcilePolicy = ReconcilePolicy(),
        nextDue: (@Sendable () async -> Moment?)? = nil,
        query: @escaping @Sendable (_ dueBefore: Moment, _ limit: Int, Attempt) async throws -> [S.ID]
    ) -> Reconciler<S.ID> where Key == S.ID
}
// StoicStore
extension Reconciler where Key: Codable {
    /// Commits what has fallen due in a device's store, in one batch, waking at its `nextDue`.
    public static func settling<L: Lifecycle>(
        _ store: JournaledLifecycleStore<L, Key>,
        every: Schedule = .fixed(.seconds(900)).jittered(.equal), policy: ReconcilePolicy = ReconcilePolicy()
    ) -> Reconciler<Key>
}
// StoicTime
extension Reconciler {
    /// Keeps future zoned values' instants right under the zone rules in force.
    public static func zonedValues(
        name: String, reads: Backend.Operation, writes: Backend.Operation,
        every: Schedule = .fixed(.seconds(86_400)).jittered(.equal), policy: ReconcilePolicy = ReconcilePolicy(),
        values: @escaping @Sendable (ReconcileScope<Key>, Attempt) async throws -> [Key: ZonedDateTime],
        write: @escaping @Sendable ([Key: ZonedDateTime], Attempt) async throws -> Void
    ) -> Reconciler<Key>
}
// StoicTime: deprecated, its message naming Reconciler.zonedValues
@available(*, deprecated, message: "use Reconciler.zonedValues(name:reads:writes:values:write:)…")
public struct ZoneRulesSweep { … }

// MARK: StoicTesting

/// One side of a reconciliation, in memory, with faults a test scripts.
public actor SimulatedSide<Key: Hashable & Comparable & Sendable, Value: Hashable & Sendable> {
    public init(_ entries: [Key: Value] = [:], label: String)
    public var entries: [Key: Value] { get }
    public func set(_ key: Key, _ value: Value?)               // an outside writer, for drift
    public func inject(_ fault: SideFault<Key>, times: Int = 1)
    public func clearFaults()                                  // the faults stop
    public var scriptedFaults: Int { get }
    public func intercept(_ interceptor: (@Sendable (SideCall<Key>) async -> Void)?)   // where a test plays a crash
    public var writes: [(key: Key, value: Value?)] { get }     // every applied write, in order
    public var reads: [(scope: ReconcileScope<Key>, result: [Key: Value]?)] { get }   // nil: the read failed
    public var calls: Int { get }
    public var concurrentWrites: Int { get }                   // writes to one key that overlapped
    public func read(_ scope: ReconcileScope<Key>) async throws -> [Key: Value]
    public func write(_ key: Key, _ value: Value?) async throws
}
public enum SideCall<Key: Hashable & Sendable>: Sendable, Hashable { case read(ReconcileScope<Key>), write(Key) }
public struct SimulatedSideError: Error, Retryable { … }      // permanent: an operation never retries it
public enum SideFault<Key: Hashable & Sendable>: Sendable, Hashable {
    case failRead                         // the next read throws
    case readEmpty                        // the next read returns [:] (a broken query)
    case failWrite(Key?)                  // the next write (to this key) throws before applying
    case applyThenFail(Key?)              // the next write applies, then throws (an unknown outcome)
    case dropWrite(Key?)                  // the next write is acknowledged and not applied
    case slow(Duration)                   // the next call takes this long on the test clock
}
/// A reconciliation between two simulated sides. `Desired == Actual == Value`, on the remote
/// backend `stoic.simulated`.
public struct SimulatedReconciliation<Key, Value>: Reconciliation { public init(truth:, derived:) }
```

## Semantics

### The truth and the derived side

A reconciliation names two sides. The **truth** says what should be. The
**derived** side is made to match it. There is no dual write. The code that
changes the facts writes only the truth (a commitment, an event, a setting). The
reconciler is the only writer of the derived side's keys that it manages.

A write that anyone else makes to the derived side is a difference, and the
truth wins. A person who edits the calendar's attendee list by hand sees the
next pass put it back. When a field of the derived side belongs to someone
else (a note a coordinator types on the calendar event), it is either brought
into the truth or left out of `matches` and of the correction. The contract
does not merge two writers: that would be the dual write again.

The unit is a **key**: an event's id, a device's id, a record's id. Each key's
desired value is compared with its actual value, and each is corrected on its
own. The value of one key can be a whole list (an event's attendees). Stoic
works out which keys differ. Working out what differs inside a key is the
app's job, in `correct`, from the `was:` value.

`Key` is `Comparable` so that a pass is deterministic. Keys are compared,
corrected, deferred and reported in key order, and a test can predict all of
it.

### Reading

Each read is complete or it throws. That is the rule that keeps a failed read
from deleting anything.

- **`desired(.all)`** returns every key the truth says the derived side should
  hold. A key absent from the result must not exist there. **`desired(.keys(s))`**
  returns the entries for the keys of `s` that the truth holds. A key of `s`
  that is absent from a result that did not throw is absent from the truth.
- **`actual`** has the same rules for the derived side.
- **A failed read is never an empty read.** A read that throws ends the pass
  before any correction (`.unreadable(side)`). A paged read whose third page
  fails must throw. It must not return the first two pages.
- **A key outside the scope** in a scoped read is ignored, and
  `reconciler.scope_exceeded` is reported at error level: the reconciliation is
  wrong, and it is not trusted to say which keys are removable.
- **The truth is read first.** If the truth cannot be read, the derived side is
  never asked. Because the reconciler is the only writer of the derived side,
  the order of the two reads cannot make a stale removal: between them, only an
  outside writer could change the derived side, and its change is a difference
  either way.
- **Each read is a declared operation.** It is run through
  `R.readsTruth.perform` or `R.readsDerived.perform` at the pass's urgency, so
  its deadline, retries, breaker and admission are derived (design/22). The
  reconciler, not the app, calls `perform`: an undeclared read cannot happen.
- **Each read runs under** the earlier of its operation's default total deadline
  (design/22's table, at the pass's urgency) and what remains of the pass's
  deadline. A pass's deadline must not stretch one read: under a caller's
  deadline, `perform` would otherwise use that deadline instead of its own
  default.

### The plan

`ReconcilePlan(desired:actual:using:)` is a pure function. For each key in
either reading:

| truth  | derived | `matches` | correction                           |
| ------ | ------- | --------- | ------------------------------------ |
| has it | lacks   | —         | `.create(key, desired)`              |
| has it | has it  | false     | `.update(key, desired, was: actual)` |
| has it | has it  | true      | none (`unchanged`)                   |
| lacks  | has it  | —         | `.remove(key, was: actual)`          |

The order is creates and updates by key, then removes by key. The work that
adds is done first. Removals come last because the guard judges them, and
because a pass cut short should have done the safe work.

### Corrections

- **Each correction is a declared operation**: `R.corrects.perform`, at the
  pass's urgency, under the earlier of the operation's default deadline and the
  time left in the pass.
- **Only repeatable operations can correct.** `Reconciler.init` checks
  `R.corrects.safety`, and refuses `.notRepeatable` and `.readOnly` with a
  precondition failure where the reconciler is made. Operations are static
  declarations, so this is code, not input. It is the same rule as a migration
  declared impossible (design/06).
- **Idempotent by construction.** A correction must leave the key matching
  whatever its state was. A `PUT` or delete addressed by the truth's key does
  this. So does a patch that adds what is missing and removes what is extra.
  A toggle does not. When the derived side assigns its own ids (a `POST`), the
  operation is `.keyed`, and the app also stores the truth's key on the derived
  object, so that `actual` can find it again. Otherwise every pass creates it
  again.
- **Keys.** Each correction's `perform` is given an `idempotencyKey`:
  `IdempotencyKey.reconciliation(pass:position:)`, derived from the pass's own
  random key and the correction's position in the plan. It is therefore the
  same on every attempt of that correction, and new in the next pass. Every
  correction gets one explicitly, because corrections run in child tasks, where
  design/22 refuses a derived key (`operation.key_ambiguous`). A later pass
  reads again and decides again; it never resends an earlier pass's request.
  Keys are per pass, as decided: corrections are idempotent by contract, so
  safety across passes rests on their being addressed by the truth's key.
- **Bounded.** At most `concurrency` corrections run at once
  (`mapConcurrentResults`, in plan order), and the backend's admission also
  applies. At most `correctionsPerPass` start in one pass. The rest are
  **deferred**: they stay differences, and a full pass follows after
  `coalesce` instead of waiting for the schedule. It is a full pass, not one
  scoped to the deferred keys, so the guard judges their removals against the
  whole derived side, as the pass that deferred them did.
- **A failed correction** does not stop the pass. Its key's failure count rises,
  and the key **waits** `keyBackoff`'s next delay before it is corrected again.
  A waiting key still counts as a difference; a pass skips it and counts it in
  `waiting`. A key that has failed `stuckAfter` passes in a row is **stuck**
  (`.failing`, with the last error's type and reference). It is still retried,
  on its backoff, and it is reported once when it becomes stuck. A `Defect`
  makes the key stuck at once, at error level. When a key matches, or leaves
  both readings, its count and backoff are forgotten.

### Verification and "does not take"

A pass that applied corrections cannot tell, from its own readings, whether they
worked. So after `verifyAfter` a **verification pass** runs, scoped to the keys
it corrected. That pass is an ordinary scoped pass. A key it finds matching is
done. A key it finds still differing, after a correction that returned success,
**did not take**. The usual cause is a `matches` that disagrees with the
derived side, which normalises an email address, rounds a coordinate or drops
a field. Without this check, such a key is rewritten in every pass, forever. A
key that does not take is corrected again, on its backoff. After `stuckAfter`
passes in a row it is stuck (`.doesNotTake`). Against a derived side that is
eventually consistent, the backoff (5 s, 10 s, 20 s) gives it time to catch up
before the third verdict.

### The removal guard

A pass's removals are judged before any removal is applied, over the derived
keys that the pass read (`derived`):

1. A full pass (`.all`) that read an **empty truth** while the derived side is
   not empty is always held, unless the guard is `.unguarded`. An empty full
   read is the signature of a broken one: the wrong table, an expired
   credential answered with nothing, or a filter that matches nothing.
2. Otherwise, removals are allowed when there are at most `max(count, ⌊share ×
derived⌋)` of them. The default is 10% or 5, whichever is more. So deleting
   one event's index entry passes, and so does removing 90 of 1,000. Removing
   101 of 1,000 is held.

A **hold** means the pass applies its creates and updates, makes none of its
removals, and records the hold in `status.hold`, with every key it would have
removed. It reports `reconciler.removals_held` at warning level. The phase is
`.held`. Each later pass recomputes its removals and compares them with the
hold. If they are the same set, the hold stands, and nothing new is reported. If
they are a different set, the old hold is replaced and reported again. If the
removals fall within the guard again, because the truth's read was mended, the
hold is released and reported (`reconciler.hold_released`).

`confirm(hold, by: principal, because:)` lets the next full pass remove the
hold's keys. **A confirmation names who gave it**: removing a share of a derived
system is an act someone authorised, so `confirm` takes a verified principal
(design/28), `Verified<P, E>` for any `PrincipalEvidence`, and
`reconciler.removals_confirmed` records that a principal confirmed, with the
evidence's type public and the principal's description private. An app with no
accounts declares its own evidence ("the person at this device confirmed").
A pass with a confirmation may remove any key in the confirmed set, plus as many
others as the guard allows. Beyond that it holds again. A confirmation is used
by the next full pass that runs, whether or not that pass needs it, and that
pass follows after `coalesce`. `confirm` refuses a hold that is no longer the
current one (`.holdChanged`), so a person never confirms a list they did not
see. `because` is required, and is kept in the pass's report. It is never put
in an event (as design/27's reasons are not). Holds and confirmations live in
memory, as decided: a relaunch recomputes the hold, and a person confirms again.

Scoped passes are judged the same way, over the keys they read, measured
against the larger of those and the derived keys the last full pass read: a
verification pass reading back ninety removals that a full pass of a thousand
allowed is not held. A scoped pass for one deleted event removes its one entry,
which is within the count. A scoped pass never removes a key of a standing
hold: that is the person's to lift. A scoped read that comes back empty is
indistinguishable from a deletion of its keys, so its removals are bounded by
the count alone; the next full pass reads the whole truth again.

### Passes never overlap

A reconciler runs one pass at a time. `run`'s passes, a background job's
`pass()` and a test's `pass()` queue on one `AsyncMutex`, so a key is never
corrected by two passes at once. A caller of `pass()` that finds a pass in
progress waits for it, then runs its own: the pass in progress started before
whatever made the caller ask. The caller waits no longer than its own deadline,
and if that ends the wait it throws `.cancelled` with the cause.

**Two reconcilers over one derived side**, in one process or in two (several
server instances), are not prevented (Not built: leases). What running two does
is plain: wasted work, since each reads both sides and makes the same
corrections, which are idempotent; corrections that verification settles, since
each reads the other's writes back as matching or as differences it corrects
again; and stuck accounting that may count one runner's write as another's
"did not take". Neither removes past its guard: each judges its own reading.

### Triggers, the schedule, and when a pass runs

`run()` decides when to pass. It starts with a full pass. Then it waits for the
earliest of:

- **the schedule**: `every`'s next delay after the last full pass ended (15
  minutes by default, with equal jitter, so between 7.5 and 15 minutes);
- **a trigger**: `changed(keys)` adds keys to a pending set, and a scoped pass
  over them runs once no new keys have arrived for `coalesce`. Several triggers
  during a pass are folded into the next one. `requestFullPass()` asks for a
  full pass the same way. A full pass clears the pending set, because it covers
  it. A pending set that would exceed `pendingKeys` becomes a full pass request
  instead (`reconciler.pending_overflow`);
- **verification**: `verifyAfter` after a pass that applied corrections;
- **deferred work**: a full pass, `coalesce` after a pass that deferred corrections;
- **a failed pass**: `failedPassBackoff`'s next delay after a pass that could
  not read a side, so an outage is not retried every second. The delay is never
  longer than the schedule's. A pass that can read both sides resets it;
- **a key's backoff**: when the earliest waiting key may be corrected again, a
  scoped pass over the keys whose backoff has ended;
- **`nextChange()`**, or a job's `nextDue`: the moment is converted to a wait
  on the reconciler's clock (`Moment.now.duration(to:)`, at least zero) each
  time the loop goes to sleep. After a wall-clock jump, the error is bounded by
  the next scheduled pass. A due moment that is still not in the future after
  the pass it caused is ignored until the next scheduled pass, with
  `reconciler.due_ignored` at warning level, so a defective `nextDue` cannot
  make the loop spin.

**Urgency.** `run()`'s passes run at `policy.urgency` (`.utility`), so their
reads and corrections get the patient policy and never the last half of a
backend's capacity (design/22). `pass()` runs at its caller's
`Urgency.current`, so a person's "sync now" under `withUrgency(.userInitiated)`
is that, and a background job's is `.background`.

`changed` and `requestFullPass` only record when `run()` is not running, as on
a device that is suspended in the background. The next `run()` begins with a
full pass, which covers them. Pending keys live in memory, and a crash loses
them, which is safe: a full pass at the next launch corrects whatever they
would have corrected. That is what level-triggered means.

`run()` never throws for a pass that failed. A truth that cannot be read is a
status (`.unreadable`), and a supervisor restart would only read it again. So
`run()` ends only when it is cancelled, and then it throws
`CancellationError`. The pass in progress is cancelled at that point (see
Cancellation).

### Convergence, observed

The reconciler keeps a set of **known differences**: keys whose latest reading
differed, together with keys corrected and not yet verified. A full pass
replaces the whole set. A scoped pass replaces it for its keys. A key that a
reading finds matching leaves the set. `status.phase` is the most severe that
applies:

1. `.unreadable(side)`: the latest pass could not read that side. It clears when
   a pass reads it.
2. `.held(differences:)`: a hold stands.
3. `.stuck(differences:)`: some key is stuck.
4. `.converging(differences:)`: the set is not empty.
5. `.converged`: the set is empty, and a full pass has read both sides.

`.starting` comes before the first full pass reads both sides. Until then the
reconciler knows nothing about the keys it has not read.

`lastConverged` is the moment of the reading that emptied the set. A
verification read counts too: "converged" means a read found the sides equal,
not that every correction returned. `lastFullPass` is when a full pass last read
both sides. `overdueAt` is that moment plus `overdueAfter` (30 minutes), or the
reconciler's start plus `overdueAfter` before any full pass. A health check
asks `isOverdue()`. A reconciler that stopped running is overdue, not
converged.

**Drift is reported.** A full pass that finds differences while the phase was
`.converged` reports `reconciler.drift_found` (notice) with the count.
Something changed one side without a trigger: a missing `changed` call, or an
outside writer. Kindora's six pairs would have shown up here on the first day.

The status is `Observable`. It changes once per pass, at the end, and never in
the middle, so a reader never sees half a pass. An observer that is not a view
uses `Observations { reconciler.status }` (SE-0475).

### Jobs that converge by themselves

Some derived state is not a second system. It is the same records, behind
where they should be. design/27's due timeouts and design/26's stale instants
are both like that: the truth and the derived side are two readings of one
record. A keyed plan would read the same store twice, and it could mistake a
record written between the two reads for something to create or remove. So a
`Reconciler` can also run a job that does its own pass:

```swift
Reconciler(name:, every:, policy:, nextDue:, pass: { request in … return ReconcileOutcome(…) })
```

The runner gives such a job everything except the plan. That means the
schedule, triggers, the pass deadline, non-overlap, the status, events, keys
that are refused becoming stuck, and `nextDue`. The job must keep the
contract's promises itself: every read and write a declared operation, every
write repeatable, no removals. A job that removes needs a keyed reconciliation
and its guard. `ReconcileOutcome.refused` names keys the job cannot converge,
with the reason in words. Each is stuck at once, `.refused(reason)`, and leaves
`stuck` when a later outcome no longer names it. A refused key waits its
backoff: the runner passes the keys still waiting in `ReconcileRequest.waiting`,
the job skips them, and the runner keeps them as they were. A job that throws
is a pass that could not read: `.unreadable(.truth)`, tried again after the
failed-pass backoff.

**A lifecycle store's due records (design/27).** `Reconciler.settling(store,
due:query:)` works for any `LifecycleStore`, a server's included. Its pass:

1. reads the moment with `store.moment(for: .now)`, then the due ids with
   `query` (through the `due` operation, `.readOnly`; it returns at most
   `limit`, and an app query selects on the record's `dueAt`);
2. calls `store.settle(id)` on each, in key order, `concurrency` at a time.
   Settling is repeatable: a second settle finds nothing due, or loses a
   conflict and recomputes the same entries and effect keys (design/27);
3. lists as refused each id whose settle leaves it still due at the moment it
   settled at: its timeout does not move it (`lifecycle.timeout_refused`). An
   id whose definition refuses to settle it (its chain is cut, a newer
   definition wrote it), or whose settle fails in the store, is refused with
   that reason. Its key backoff stops the loop from spinning on it. A query
   that returns its limit may have left some, so the job reports one deferred
   and another pass follows after `coalesce`.

`Reconciler.settling(journaledStore)` is the device's form. Its pass is one
`settleDue()` call: every due record settled in one batch append, or none.
Its `nextDue` is the store's `nextDue`. The refused records are those whose
`written.dueAt` is still not after the moment once `settleDue` returns, read
from `records()`.

**What changes in design/27: nothing.** `LifecycleStore`,
`JournaledLifecycleStore`, `settleDue` and `nextDue` stay as they are. The two
adapters are new: about 40 lines in the kernel and 30 in `StoicStore`. design/27's
Not built row "Running `settleDue` at `nextDue`" becomes built, and so does the
server's sweep: that sweep is the first adapter, given the app's query.

**Zoned values (design/26).** `Reconciler.zonedValues(name:reads:writes:values:write:)`
in `StoicTime`. Its pass:

1. reads every future value (`values`, through `reads`);
2. refreshes each stale one (`isStale()`, then `refreshed()`, by the value's own
   policy, as design/26 requires);
3. writes the moved ones in one call (`write`, through `writes`, which must be
   `.idempotent`: refreshing a refreshed value changes nothing). A value that
   the rules in force cannot resolve (an unknown zone) is refused with the
   reason, and the others are written.

The job has no version gate. A full pass checks every future value, at
microseconds each. That catches the values design/26's sweep can never reach:
values written by a device or a server whose rules were older or newer than
this one's. The rules' version moving is just one cause of staleness, and the
daily pass, plus the full pass every `run()` starts with, covers it.

**What changes in design/26: `ZoneRulesSweep` is deprecated** in favour of
`Reconciler.zonedValues`: one way to keep zoned values right, and the
level-triggered one. Its deprecation message names the replacement, design/26
says so, and the type stays, working as before, for this release. The job does
not call it, because the sweep's version check is exactly the edge trigger that
a level-triggered job does without. design/26's Not built row "The sweep as a
`Reconciler` job" becomes built.

### Running it

- **On a server**, each reconciler is a child of a `Supervisor`: `Child(name) {
_ in try await reconciler.run() }`. `run()` throws only cancellation, so the
  supervisor restarts it only after a defect it did not expect, and its
  intensity rules still apply. One instance of the service should run each
  reconciler (Not built: leases; what two do is stated under Passes never
  overlap). A single worker, the leader of a pair, or a cron calling `pass()`
  all do.
- **On a device**, while the app runs: the same, under the app's
  `ServiceGraph` or a supervisor. When the app comes back to the foreground,
  call `requestFullPass()`: the suspended loop's schedule did not run.
  **Through a background job** (design/21): `BackgroundJob(...) { try await
reconciler.pass() }`. The job's `Deadline.current` bounds the pass, together
  with `passDeadline`. When the system expires the task, the pass is cancelled
  with cause `.systemExpiring`. Its finished corrections stand, and the next pass
  finishes the rest. `pass()` throws `.unreadable` when a side cannot be read, so
  the job reports failure to the system.

### Cancellation

A cancelled pass starts no further correction and no further read. The
corrections in flight are cancelled and awaited. A `.brief` `.keyed` correction
finishes shielded, within its attempt timeout, because `perform` does this
(design/22). The pass's report says `.cancelled`. What it finished stands and is
reflected in the status. What it did not finish stays a difference. Cleanup
always runs. `run()` throws `CancellationError`. `pass()` throws `.cancelled`
(`isCancellation`), as a typed throw cannot carry a `CancellationError`
(design/27's `LifecycleUpdateError.cancelled` precedent).

### Isolation

`Reconciler` is a `Sendable` class, so that it can be `Observable` as
`StateMachine` is. Its state sits behind a `Mutex` that is never held across an
`await`, and its passes queue on an `AsyncMutex`. A reconciliation's methods run
on the generic executor, in the reconciler's tasks. Corrections run
concurrently, so a reconciliation is `Sendable`, and so is everything it
captures. The status is a value. Events are recorded outside every lock.

### Defaults

| Default               | Value                                    | Why                                                                                               |
| --------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------- |
| schedule              | 15 min, equal jitter (7.5–15)            | drift found within a quarter hour; replicas and devices do not pass in step                       |
| removal guard         | 10% of what was read, or 5               | normal deletions pass; an emptied source does not                                                 |
| corrections per pass  | 1 000                                    | a pass's work is bounded; the rest follows after `coalesce`                                       |
| concurrency           | 4                                        | a remote backend's default capacity is 6; admission bounds it too                                 |
| pass deadline         | 10 min                                   | twice a background read's default total (design/22); a hung pass ends                             |
| coalesce              | 1 s                                      | a group sign-up of five people is one pass                                                        |
| verify after          | 2 s                                      | read-after-write on most services; backoff covers slower ones                                     |
| stuck after           | 3 passes in a row                        | one failure is weather, three are a fault worth a person's look                                   |
| key backoff           | 5 s doubling, capped at 1 h              | a broken key costs at most one correction an hour                                                 |
| failed-pass backoff   | 30 s doubling, capped at 15 min          | an outage is not hammered; never later than the schedule                                          |
| pending keys          | 10 000                                   | beyond that a full pass is cheaper than a set                                                     |
| overdue after         | 30 min                                   | two scheduled passes missed                                                                       |
| urgency               | `.utility` (`pass()` keeps its caller's) | nobody is waiting on a scheduled pass; a person's "sync now" is `.userInitiated` by `withUrgency` |
| settling schedule     | 5 min on a server, 15 on a device        | `nextDue` makes it prompt; the schedule is the level                                              |
| zoned values schedule | 1 day                                    | rules change a few times a year; displays are right meanwhile (design/26)                         |

## Failure modes

| What happens if…                                                         | Then                                                                                                                                                                                    |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the truth cannot be read                                                 | the pass ends before reading the derived side; nothing is corrected or removed; `.unreadable(.truth)`; `reconciler.unreadable`; the next pass after the failed-pass backoff             |
| the derived side cannot be read                                          | the pass ends; nothing is corrected; `.unreadable(.derived)`                                                                                                                            |
| a paged truth read fails partway                                         | the read throws (the reconciliation's contract), and the pass is the unreadable one above; a read that returns the pages it got is a defect in the reconciliation that the guard limits |
| a full pass reads an empty truth and a non-empty derived side            | creates and updates are applied, no removal is; `.held`, with every key; `reconciler.removals_held`                                                                                     |
| a pass would remove more than the guard allows                           | the same hold                                                                                                                                                                           |
| a pass removes within the guard                                          | the removals are applied after every create and update                                                                                                                                  |
| a hold stands and the next pass computes the same removals               | the hold stands; nothing new is reported                                                                                                                                                |
| a hold stands and the truth read is mended                               | the removals fall within the guard; the hold is released; `reconciler.hold_released`                                                                                                    |
| a person confirms the current hold                                       | the next full pass may remove the confirmed keys and as many others as the guard allows; `reconciler.removals_confirmed`, naming the principal privately                                |
| a person confirms a hold that has since changed                          | `confirm` throws `.holdChanged`; nothing is let through                                                                                                                                 |
| the process relaunches while a hold stands                               | the hold and any confirmation are gone; the next pass holds again and reports it                                                                                                        |
| a scoped read returns a key outside its scope                            | the key is ignored; `reconciler.scope_exceeded` at error level                                                                                                                          |
| a correction fails                                                       | the pass goes on; the key waits its backoff; it stays a difference                                                                                                                      |
| a correction fails in `stuckAfter` passes in a row                       | the key is stuck (`.failing`, error type and reference); `reconciler.stuck` once; still retried on its backoff                                                                          |
| a correction throws a `Defect`                                           | the key is stuck at once; reported at error level                                                                                                                                       |
| a correction applies and then fails (an unknown outcome)                 | the key waits its backoff; the next reading shows whether it applied, and the plan follows from that reading                                                                            |
| a correction succeeds and the next read still differs                    | it did not take: corrected again on its backoff; stuck (`.doesNotTake`) after `stuckAfter` passes                                                                                       |
| a stuck key's correction later takes                                     | it leaves `stuck`; `reconciler.unstuck`                                                                                                                                                 |
| a pass finds more differences than `correctionsPerPass`                  | the first by plan order are applied; the rest are deferred; a full pass follows after `coalesce`                                                                                        |
| a pass reaches its deadline                                              | no further correction starts; those in flight are cancelled (brief keyed ones finish shielded); `.cutShort`; another pass follows                                                       |
| a read or a correction hangs                                             | its own default deadline (or what is left of the pass's) ends it                                                                                                                        |
| the reconciliation declares a `.notRepeatable` or `.readOnly` correction | `Reconciler.init` fails a precondition where it is made                                                                                                                                 |
| two reconcilers run over one derived side                                | wasted work and corrections that verification settles; neither removes past its guard                                                                                                   |
| a pass is asked for while one runs                                       | it runs after it; two passes never overlap; no key is corrected twice at once                                                                                                           |
| a caller's deadline passes while it waits for a pass in progress         | `pass()` throws `.cancelled`; the pass in progress goes on                                                                                                                              |
| keys are triggered during a pass                                         | they are folded into one scoped pass after the current one, once `coalesce` is quiet                                                                                                    |
| more keys are triggered than `pendingKeys`                               | a full pass replaces them; `reconciler.pending_overflow`                                                                                                                                |
| a trigger is missed                                                      | the next full pass finds the difference and corrects it; `reconciler.drift_found` if the phase was converged                                                                            |
| something else writes to the derived side                                | the next pass corrects it back; `reconciler.drift_found`                                                                                                                                |
| the process crashes in the middle of a pass                              | the finished corrections stand; the next pass reads both sides and finishes the rest                                                                                                    |
| a correction is retried within one pass                                  | every attempt sends the same key                                                                                                                                                        |
| the same difference is corrected again in a later pass                   | under a new key, from a new reading                                                                                                                                                     |
| a full pass finds no difference                                          | `.converged`; `lastConverged` is the reading's moment; `reconciler.converged` if the phase changed                                                                                      |
| a pass applies every correction                                          | `.converging` until the verification pass reads them equal                                                                                                                              |
| no full pass has finished for `overdueAfter`                             | `isOverdue()` is true; `reconciler.overdue` once                                                                                                                                        |
| `run()` is not running when keys are triggered                           | they are recorded; the next `run()` starts with a full pass that covers them                                                                                                            |
| `nextChange()` or `nextDue` falls due                                    | a pass runs at that moment, on the reconciler's clock                                                                                                                                   |
| a due moment is still not in the future after the pass it caused         | ignored until the next scheduled pass; `reconciler.due_ignored`                                                                                                                         |
| the wall clock jumps                                                     | the wait for a due moment is recomputed when the loop next sleeps; the schedule bounds the error                                                                                        |
| the run loop is cancelled                                                | the pass in progress is cancelled as above; `run()` throws `CancellationError`                                                                                                          |
| a background job's time runs out during a pass                           | the pass is cancelled with cause `.systemExpiring`; finished corrections stand                                                                                                          |
| a lifecycle record's timeout does not move it                            | the settling job names it refused; it is stuck at once and waits its backoff                                                                                                            |
| `settleDue` settles several records                                      | one batch append, as design/27 says; the job counts them as corrected                                                                                                                   |
| a future zoned value was written under other rules                       | the next full pass finds it stale and writes the refreshed value                                                                                                                        |
| a zoned value's zone is unknown to the rules in force                    | it is refused with the reason; the others are written                                                                                                                                   |
| the zone rules change while the app runs                                 | the next scheduled pass (a day at most) refreshes the moved values; displays read local time and zone meanwhile (design/26)                                                             |

## Events

All are in `EventCatalog`, labelled with the reconciliation's `name`. Counts,
durations, sides, kinds, outcomes and references are public. Keys are
descriptions at `.private` privacy, since keys can be email addresses. No event
carries a value, a reason given to `confirm`, or an error's description. The
error's type and the reference are carried; design/31's `failure.presented`
does the same.

| Event                           | Level   | Meaning                                                                   |
| ------------------------------- | ------- | ------------------------------------------------------------------------- |
| `reconciler.pass_ended`         | debug   | scope, outcome, differences, applied, failed, deferred, waiting, duration |
| `reconciler.converged`          | info    | the phase became converged                                                |
| `reconciler.drift_found`        | notice  | a full pass found differences after convergence: how many                 |
| `reconciler.unreadable`         | warning | a side could not be read: side, error type, reference                     |
| `reconciler.correction_failed`  | notice  | key, kind, error type, outcome, reference                                 |
| `reconciler.stuck`              | warning | key, kind, reason, passes                                                 |
| `reconciler.unstuck`            | info    | key                                                                       |
| `reconciler.removals_held`      | warning | removals, derived keys read, whether the truth was empty                  |
| `reconciler.hold_released`      | info    | the held removals fell within the guard                                   |
| `reconciler.removals_confirmed` | notice  | removals confirmed; the evidence's type; the principal, private           |
| `reconciler.cut_short`          | notice  | the pass's deadline or limit ended it: deferred                           |
| `reconciler.overdue`            | warning | no full pass for `overdueAfter`                                           |
| `reconciler.pending_overflow`   | notice  | triggered keys became a full pass                                         |
| `reconciler.scope_exceeded`     | error   | a scoped read returned keys outside its scope                             |
| `reconciler.due_ignored`        | warning | a due moment that a pass did not move                                     |

The reads and corrections report under design/22's names, labelled
`<backend>.<operation>`.

## Testing

- **Every row above**, on `TestClock` with the test wall clock, against
  `SimulatedSide`s with scripted faults, and against `InMemoryLifecycleStore`
  and `JournaledLifecycleStore` on `SimulatedFileSystem` for the adapters.
- **Convergence, as a property.** It runs under `simulate`, seeds `0..<500`. Each
  seed draws a truth of 0 to 60 keys and a derived side that overlaps it,
  misses keys, has extra keys and holds wrong values. It also draws a fault
  script over the first 20 passes: failed reads, empty reads, failed writes,
  writes that apply then fail, dropped writes, slow calls, outside writes, and
  crashes. A **crash** cancels the reconciler's task at a random new fault point
  (`reconciler.read`, `reconciler.correct`) and makes a fresh `Reconciler` over
  the same two sides, keeping nothing of the old one. After the faults stop, and
  with the guard confirmed where a hold stands, the derived side must equal the
  truth within 5 passes, and the phase must be `.converged`. Convergence runs
  with timers that fire only when everything sleeps; 200 more seeds run with
  early timers (a deadline landing in the middle of a write, as on a starved
  CPU) and check the safety properties alone.
- **Safety at every step**, whatever the faults:
  - no pass removes anything after a read that failed or came back empty;
  - no pass removes more than the guard allows without a confirmation;
  - `concurrentWrites` is 0;
  - every write is one that the plan of its own pass's readings asked for;
  - a full pass reports `.converged` only from readings that agreed.
- **Tests that must fail** keep the harness honest. These reconcilers must each
  fail the suite: one that removes on a failed truth read, one that treats an
  empty truth as true, one that lets passes overlap, and one that does not
  verify. Each is built through an internal switch, as design/27's crash tests
  are.
- **The plan** as properties: applying the plan's corrections to the actual
  reading gives the desired reading; the plan of two equal readings is empty;
  the order is creates and updates by key, then removes by key.
- **Adapters**: `settling` over a store with a stuck timeout (design/27's
  `stuckTimeouts`), and over a server-shaped store whose query returns the same
  id twice. `zonedValues` with `ScriptedZoneRules` changing a zone between
  passes, and with a value written under another version's rules.
- **The ideal scenario** as a test: Kindora's calendar and index over simulated
  sides, with the empty-truth incident and its confirmation, and Lodestar's
  release records through `Reconciler.settling`.
- 300 repetitions are clean.

## Not built

- **Leases.** One reconciler per derived side is assumed, not enforced. Several
  server instances need a lease (a row, a lock in the database, a leader), and
  a protocol for one could join `Reconciliation`. Until then, two runners waste
  work and make corrections that verification settles, and neither removes
  past its guard (Passes never overlap).
- **Partitions.** A full pass holds both readings in memory. A derived side too
  large for that would read by partition (an event's attendees at a time) and
  pass over partitions. The scope enum would gain `.partition(P)`.
- **Durable status and holds.** `lastConverged`, holds and confirmations live in
  memory. A device's "last synced" display that survives relaunch would keep
  them in its settings, as `ZoneRulesSweep` is kept.
- **A foreground bridge.** `StoicUIKit` and `StoicAppKit` could call
  `requestFullPass()` on becoming active. Until then the app does.
- **Webhooks as triggers.** A derived side that notifies its own changes (a
  calendar's push channel) could call `changed`. That needs no API, only an
  example.
- **Merging two writers.** It is out of scope by design (see The truth and the
  derived side).

## Decisions

The review settled the draft's open questions:

1. **Correction keys are per pass.** Corrections are idempotent by contract,
   and safety across passes rests on that. A key stable per `(key, truth
revision)` would need a revision from the truth, and is not built.
2. **The guard's numbers stand**: 10% of what was read, or 5. A rolling window
   over scoped passes is not built.
3. **Kernel.** Reconcilers use operations, `mapConcurrentResults`, `Moment`,
   lifecycles, supervision and `SupportReference`, and bring no dependency.
4. **`ZoneRulesSweep` is deprecated** in favour of `Reconciler.zonedValues`.
5. **Holds are not persisted.** A relaunch recomputes the hold.
6. **A confirmation names who gave it**: a verified principal (design/28).
7. **`Desired` and `Actual` stay two types**, `==` by default when they are one.
8. **The names stand**: `Reconciliation` declares, `Reconciler` runs.

## As built

Departures from the reviewed draft, and decisions it left open.

- **Deferred work is a full pass.** A pass that deferred corrections (its
  limit, its deadline) asks for a full pass after `coalesce`, not a pass scoped
  to the deferred keys: a scoped pass judges removals over the keys it read,
  and the deferred keys of a pass that removed 90 of 1,000 would be held when
  read back alone.
- **A scoped pass's guard** is measured against the larger of the derived keys
  it read and those the last full pass of this reconciler read, for the same
  reason (a verification pass over corrected removals). Before any full pass
  the measure is what it read.
- **A scoped pass never removes a key of a standing hold**, and a scoped pass
  past its own guard adds its removals to the hold (reported as a new hold).
  Only a full pass releases a hold, or uses a confirmation.
- **`confirm` asks for a full pass** after `coalesce`, so the person's
  confirmation is used promptly rather than at the schedule. A confirmed pass
  that is cut short before its removals still used the confirmation, as the
  contract says; the next hold must be confirmed again.
- **An empty scoped read** is treated as the deletion it looks like, bounded by
  the guard's count. The property test asserts the empty-truth rule for full
  passes only, and the count for every pass.
- **A cancelled full pass that read both sides** counts as having read them
  (`lastFullPass`; the phase leaves `.starting`): its differences are known.
- **A key's backoff wakes the loop**: a scoped pass over the keys whose
  backoff has ended runs then, so a failed key is corrected again on its
  backoff, not at the next schedule. The count that makes a key stuck is of
  consecutive passes in which it did not converge, whether its correction
  failed or did not take. A "did not take" verdict needs a reading after a
  correction, and the key then waits its backoff, so a key whose writes are
  dropped is stuck at its third such reading (the sixth pass).
- **A job's thrown error is `.unreadable(.truth)`**; a settle that fails in the
  store, or that its definition refuses, is refused with that reason (stuck at
  once, tried again on its backoff).
- **`ReconcileRequest.waiting`** is new: the refused keys still on their
  backoff, which a job skips. **`ReconcilePassReport.confirmation`** carries
  the reason given to the confirmation the pass used.
- **The jobs' generics.** `Reconciler.settling(journaledStore)` is on
  `Reconciler where Key: Codable` and takes `JournaledLifecycleStore<L, Key>`:
  a second generic parameter made equal to `Key` is refused by the compiler.
  `ReconcilerStatus` and `RemovalHold` require `Key: Comparable`, for their key
  order.
- **`SimulatedReconciliation.init(truth:derived:)`** has no `name`: the name is
  a static requirement (`stoic.simulated`). `SimulatedSide` gained what the
  property test needs: `reads`, `calls`, `scriptedFaults`, `clearFaults()`,
  and `intercept(_:)` (where a test cancels the pass in flight, to play a
  crash). Its errors are permanent (`SimulatedSideError`, `.stop`), so the
  fault script is exactly what the reconciler sees.
- **Correction keys** are `IdempotencyKey.reconciliation(pass:position:)`,
  public and frozen: `lifecycle(record:entry:position:)`'s construction under
  the name `"reconciliation"`. Two values are pinned in a test.
- **Fault points** `reconciler.read` (before each read) and
  `reconciler.correct` (before each correction) perturb simulated runs.
- **`ZoneRulesSweep`** forwards to an internal, non-deprecated
  implementation, so its own tests compile without the deprecation warning;
  its `Codable` form is unchanged.
- **The tests that must fail** build their defects into the real reconciler
  through an internal switch (`ReconcilerFaults`): reading a failed truth read
  as empty, believing an empty truth, passes that skip the lock, and taking a
  correction that returned success as done. The harness catches each.

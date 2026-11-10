# 31 · Live values, actions and presentable errors

> Stoic 0.8.0. This is the boundary to a UI. It builds on design/03
> (`TaskSlot`), design/22 (declared operations, outcomes, keys), design/27
> (`LifecycleRefusal`), design/28 (`PermissionCheck` and its `.unknown`) and
> design/05 (`Report`), and design/05's planned "`UserFacing` hook" becomes
> `Presentable`. design/30 uses `SupportReference`. `Live` and `Action` live in
> a portable library of their own, `StoicLive` (← `Stoic`); presenting failures
> stays in the kernel, where the errors are. The review's amendments are folded
> in; "As built" records what implementing it changed.

A screen shows values that arrive over time and offers buttons that change
them. Most of the bugs at that boundary come from types that cannot tell the
phases apart:

- A value that has not loaded is `undefined`, `nil` or `false`. "Not loaded"
  then reads as "empty", as "not permitted", or as "not an owner".
- Two lists that load separately are zipped by position, so they drift as soon
  as one arrives before the other.
- A button fires its request without waiting for the answer and with no guard,
  so a double tap sends it twice. Each tap draws a new key, so the server cannot
  tell that the second tap is a repeat.
- A failure becomes "An unexpected error occurred", or the raw error text
  (which can hold an email address), or nothing at all.

This contract gives each of these a type that cannot be mistaken:

- **`Live<Value>`** is a value that arrives over time. Its phases are "nothing
  yet", "fresh", "stale or being refreshed", and "failed, with the last value
  if there was one". Several `Live`s combine only into snapshots whose parts
  belong together, joined by key.
- **`Action`** is the write side. It is idle, running, succeeded or failed. A
  second tap is refused or joined, as declared, and is never fired blindly. One
  intent carries one idempotency key across taps and retries, and its failure
  is always surfaced.
- **`Presentable`** describes a failure for a person. It says what happened and
  what they can do, and it carries a reference that support can match to an
  event. A failure nobody classified gets a generic message and the reference,
  never its raw text.

## The ideal scenario

> A volunteering app's event screen. The roster lists the people signed up and
> whether each is a minor, from two queries joined by email, never by position.
> The edit button appears only once the person's permissions say so. While they
> load, the screen shows that it is checking, not "not permitted" and not an
> enabled button. Signing up is one commitment however many times the button is
> tapped, and after a lost connection "Try again" sends the same request. When
> something fails, the person reads what happened, what to do, and a reference
> that support can find.

```swift
import Stoic
import StoicFoundation        // String(localized: Wording)
import StoicLive              // Live, Action
import SwiftUI

enum Events {
    static let detail   = Backend.api.readOnly("events.detail")
    static let roster   = Backend.api.readOnly("events.roster")
    static let minors   = Backend.api.readOnly("profiles.minors")
    static let roles    = Backend.api.readOnly("permissions.mine")
    static let signUp   = Backend.api.keyed("commitments.create")       // the server deduplicates by key
    static let remove   = Backend.api.notRepeatable("events.delete")
}

@MainActor @Observable final class EventScreen {
    let event: Live<Event>
    let roster: Live<[RosterRow]>                         // attendees joined with minors by email
    let canEdit: Live<PermissionCheck<EditEvent>>
    let signUp: Action<EventID, Commitment>
    let delete: Action<Granted<EditEvent>, Void>

    init(id: EventID, api: API, me: Verified<Someone, Session>) {
        event = Live(Events.detail) { [api] _ in try await api.event(id) }
        let attendees = Live(Events.roster, freshFor: .seconds(30)) { [api] _ in try await api.attendees(id) }
        let minors = Live(Events.minors) { [api] _ in try await api.minorStatus(event: id) }
        roster = .joining(attendees, minors, on: \.email, \.email) { attendee, minor in
            RosterRow(attendee, minor: minor?.isMinor)    // nil: not in the answer, shown as "unknown", never "No"
        }
        canEdit = Live(Events.roles) { [api] _ in try await EditPolicy(api: api).check(Claimed(id), by: me) }
        signUp = Action(Events.signUp, whileRunning: .join, refreshes: [attendees]) { [api] id, attempt in
            try await api.signUp(id, idempotencyKey: attempt.idempotencyKey)    // one key per intent
        }
        delete = Action(Events.remove) { [api] grant, _ in try await api.delete(grant) }   // .refuse while running
    }
}

struct EventView: View {
    let screen: EventScreen

    var body: some View {
        switch screen.event.phase {                    // four phases; nothing to forget
        case .pending:
            ProgressView()
        case .failed(let failure, last: nil):
            FailureView(failure) { screen.event.refresh() }
        case .fresh(let event), .stale(let event, refreshing: _), .failed(_, last: let event?):
            EventDetails(event)
            switch screen.canEdit.check() {            // a PermissionCheck: loading is .unknown(.loading)
            case .granted(let proof): Button("Delete event") { screen.delete.trigger(proof) }
            case .denied:             EmptyView()
            case .unknown:            ProgressView()   // never "not permitted", never enabled
            }
            Button("Sign up") { screen.signUp.trigger(event.id) }         // a second tap joins the first
            if case .failed(let failure) = screen.signUp.phase { FailureView(failure) { screen.signUp.trigger(event.id) } }
        }
    }
}

/// What a person reads when something fails: what happened, what to do, and a reference.
struct FailureView: View {
    let failure: Presented
    let tryAgain: () -> Void
    var body: some View {
        Text(String(localized: failure.message))      // key, table and default text (StoicFoundation)
        if case .tryAgain = failure.recovery { Button("Try again", action: tryAgain) }
        Text("Reference \(failure.reference)")         // the `failure.presented` event carries it
    }
}

/// The app's own failures say what they mean, once.
enum SignUpError: Error, Presentable {
    case full, closed
    var presentation: Presentation {
        switch self {
        case .full:   Presentation(Wording("signup.full", default: "This event is full."), recovery: .nothing)
        case .closed: Presentation(Wording("signup.closed", default: "Sign-up has closed for this event."), recovery: .nothing)
        }
    }
}
```

The person who owns a charity must not delete their account. Kindora's guard was
open while permissions loaded. Here the action takes the proof, and the proof
cannot exist while loading:

```swift
let mayDeleteAccount: Live<PermissionCheck<DeleteAccount>>      // the policy denies an owner
switch mayDeleteAccount.check() {
case .granted(let proof): Button("Delete account") { deleteAccount.trigger(proof) }
case .denied(let denial): Text(denial.reason)                  // "transfer your charities first"
case .unknown:            Button("Delete account") {}.disabled(true)
}
```

## Origin

- **Kindora** (TypeScript: `apps/mobile`, `apps/desktop`), read for this
  contract:
  - _Loading as `undefined`._ The mobile app has about 35 `=== undefined`
    checks over 64 `useQuery` calls, and desktop about 15 over 21. These checks
    are the only loading handling. `event/[eventId]/details.tsx:247-252` ORs six
    of them together.
  - _Not loaded read as "not permitted"._ `hooks/usePermissions.ts:12-13`
    returns a "not permitted" result while the permissions are still loading.
  - _A guard open while loading._ `account/security.tsx:45` computes `const
isOwner = getPermissions ? userIsOwner(getPermissions) : false`, and `:306`
    disables the destructive button only when `isOwner`. Until the permissions
    arrive, an owner can press Delete Account.
  - _Joined by position._ `utils/email.ts:19-24` writes `isMinorArray[index]`
    beside `commitments.map((c, index) => …)`. The minors come from a second
    live query that falls back to `[]` while it loads
    (`event/[eventId]/attendance.tsx:71-79`), so every attendee is reported as
    "No" (not a minor) until it lands, and the two lists can be out of step after
    it does.
  - _No await, no guard._ `charity/[charityId]/settings.tsx:140-161` does not
    await the subscribe and unsubscribe calls, and `:136` reads "loading" as
    "not subscribed". The attendance report button has no in-flight guard
    (`attendance.tsx:198-235`). Sign-up is disabled only by `commitment !==
null`, and the server inserts without deduplicating
    (`commitments/mutations.ts:28`), so a double tap creates two commitments.
  - _Errors._ There is an empty `catch {}` (`details.tsx:199-200`). Others only
    `console.error` (`delete-commitments.tsx:70-72`, `attendance.tsx:222,232`).
    Messages are generic, such as "Something went wrong. Please try again
    later." (`basic-information.tsx:178`) and "An unexpected error occurred."
    (`(auth)/sign-in.tsx:67`), and one is wrong: a failed event delete says
    "Failed to delete charity" (`event/[eventId]/settings.tsx:52`). Raw
    `error.message` reaches the person in `commitments.tsx:331-333` and in four
    desktop waiver flows (`registeredWaiverFlow.tsx:72-75` and others).
- **Lodestar**, the pilot. Its phase guards are written by hand:
  `FeedbackController.swift:157` (`guard phase == .writing`, then `.sending`)
  and `UpdateController.swift:617`. `DraftModel.swift:114-115` joins a load in
  flight instead of starting a second one. Optional and Boolean loading flags
  appear in `EarHost.swift:33` and `EditorModel.swift:307-314`. One user-facing
  string embeds `error.localizedDescription` (`main.swift:2388`).
- **Elm's `RemoteData`** (Kris Jenkins, "How Elm slays a UI antipattern", 2016;
  from prior knowledge): `NotAsked | Loading | Failure | Success` as one type,
  so the view must draw each case. `Live`'s phases are that idea, with "stale"
  added and the last value kept on failure.
- **TanStack Query's two axes** (`status` and `fetchStatus`; from prior
  knowledge): "has data" and "is fetching" are different questions. Here they
  are one enum whose cases cannot contradict each other.
- **HTTP's `stale-while-revalidate`** (RFC 5861): a stale value is served while
  it is refreshed. `.stale(value, refreshing: true)` is that phase.
- **Consistent snapshots** in Relay and Convex (from prior knowledge): a client
  sees all of its queries as of one moment. Stoic cannot see the server's
  moment, so it promises the local half: a combination never mixes an input
  that is mid-refresh with one that is not.
- **Stripe's idempotency keys** (design/22): a key made with the intent, not the
  request.
- **Foundation's `LocalizedError` and `RecoverableError`** (from prior
  knowledge): a description, a recovery suggestion and options. Stoic keeps the
  shape and drops the free text: the recovery is a case a screen can act on.
- **Support references** (a request id printed on an error page; from prior
  knowledge): the person reads a short code, and the operator finds the log
  line.

## API

```swift
// MARK: StoicLive (← Stoic), Sources/StoicLive

/// A value that arrives over time, whose phases cannot be mistaken for each other.
@MainActor
public final class Live<Value: Sendable>: Observable {
    public enum Phase {
        case pending                             // nothing yet (a first load may be running)
        case fresh(Value)                        // current
        case stale(Value, refreshing: Bool)      // no longer known to be current
        case failed(Presented, last: Value?)     // the latest load failed; the value before it, if any
    }

    /// Loaded by a declared `.readOnly` or `.idempotent` operation. The first read of
    /// `phase` starts the first load.
    public init<Failure: Error>(_ operation: Backend.Operation, freshFor: Duration? = nil, label: String? = nil,
                                load: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Value)
    /// Kept up to date by a subscription the operation establishes.
    public init<Updates: AsyncSequence & Sendable, Failure: Error>(
        subscribing operation: Backend.Operation, label: String? = nil,
        subscribe: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Updates
    ) where Updates.Element == Value

    public var phase: Phase { get }              // Observable
    public var loadedAt: Moment? { get }         // when the phase's value was loaded; nil exactly when it holds none
    public func refresh()                        // load now; a load in flight is superseded
    public func refreshed() async -> Phase       // the same, waiting for its outcome (pull to refresh)
    public func invalidate()                     // the value is stale now; the next read refreshes it

    /// One snapshot of several lives (and the 3- and 4-input forms).
    public static func combining<A, B>(_ a: Live<A>, _ b: Live<B>, label: String? = nil,
                                       _ combine: @escaping @Sendable (A, B) -> Value) -> Live<Value>
    /// Two lists joined by key, in the left list's order. Never by position.
    public static func joining<A, B, K: Hashable & Sendable, Row>(
        _ left: Live<[A]>, _ right: Live<[B]>,
        on leftKey: KeyPath<A, K> & Sendable, _ rightKey: KeyPath<B, K> & Sendable, label: String? = nil,
        _ row: @escaping @Sendable (A, B?) -> Row
    ) -> Live<[Row]> where Value == [Row]

    /// A live permission check as the check itself: loading is `.unknown(.loading)`.
    public func check<P: Permission>() -> PermissionCheck<P> where Value == PermissionCheck<P>
    /// The same, but a grant held through a failed refresh keeps granting for `duration`
    /// after it was loaded: a declared choice.
    public func check<P: Permission>(keepingGrantFor duration: Duration) -> PermissionCheck<P> where Value == PermissionCheck<P>
}
extension Live.Phase: Sendable {}
extension Live.Phase: Equatable where Value: Equatable {}
extension Live.Phase { public func map<U>(_ transform: (Value) -> U) -> Live<U>.Phase }

/// Something a person triggers: the write side of a screen.
@MainActor
public final class Action<Input: Sendable, Output: Sendable>: Observable {
    public enum Phase {
        case idle
        case running
        case succeeded(Output)
        case failed(Presented)
        public var isRunning: Bool { get }
    }
    /// What a second trigger does while one runs.
    public enum WhileRunning: Sendable, Hashable {
        case refuse                              // it is refused (the default)
        case join                                // with an equal input, it waits for the run in progress
    }
    public enum Trigger: Sendable, Hashable {
        case started, joined
        case refused(Refusal)
        public enum Refusal: Sendable, Hashable { case running, outcomeUnknown }
    }

    public init<Failure: Error>(_ operation: Backend.Operation, whileRunning: WhileRunning = .refuse,
                                urgency: Urgency = .interactive, refreshes: [any Refreshable] = [], label: String? = nil,
                                perform: @escaping @concurrent @Sendable (Input, Attempt) async throws(Failure) -> Output)
        where Input: Equatable
    public init<Failure: Error>(_ operation: Backend.Operation, whileRunning: WhileRunning = .refuse,
                                urgency: Urgency = .interactive, refreshes: [any Refreshable] = [], label: String? = nil,
                                perform: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Output)
        where Input == Void

    public var phase: Phase { get }              // Observable
    @discardableResult public func trigger(_ input: Input) -> Trigger
    public func run(_ input: Input) async -> Phase   // trigger, then wait for that run's end
    public func reset()                          // back to idle; the intent ends
}
extension Action where Input == Void {
    @discardableResult public func trigger() -> Trigger
    public func run() async -> Phase
}
@MainActor public protocol Refreshable: AnyObject { func invalidate() }
extension Live: Refreshable {}

// MARK: Stoic (the kernel), Sources/Stoic/Presentation: presenting failures

/// An error that can say, to a person, what happened and what they can do.
public protocol Presentable: Error {
    var presentation: Presentation { get }
}
public struct Presentation: Sendable, Hashable, Codable {
    public init(_ message: Wording, recovery: Recovery, reference: SupportReference? = nil)
    public let message: Wording
    public let recovery: Recovery
    public let reference: SupportReference?      // one made elsewhere (a server's), shown as it is
}
/// Words for a person: a key to translate, and the text to show when there is no translation.
public struct Wording: Sendable, Hashable, Codable, CustomStringConvertible {
    public init(_ key: String, default text: String, table: String? = nil, arguments: [String: Argument] = [:])
    public let key: String
    public let defaultText: String               // may hold `{name}` placeholders
    public let table: String?                    // nil: the app's default table
    public let arguments: [String: Argument]
    public enum Argument: Sendable, Hashable, Codable { case text(String), integer(Int), moment(Moment), duration(Duration) }
    public var description: String { get }       // the default text, arguments written plainly; never translated
}
/// What the person can do about it.
public enum Recovery: Sendable, Hashable, Codable {
    case tryAgain
    case wait(until: Moment?)                    // nil: no stated time
    case signInAgain
    case changeInput(fields: [String])           // empty when the fields are not known
    case checkFirst                              // it may have happened: look before trying again
    case updateApp
    case contactSupport
    case nothing
}
/// A short code a person can read to support, matching the event that recorded the failure.
public struct SupportReference: Sendable, Hashable, Codable, CustomStringConvertible {
    public static func make() -> SupportReference      // 50 bits from the ambient random source
    public init?(_ text: String)                       // forgiving: case, hyphens, O for 0, I and L for 1
    public var description: String { get }             // "K7Q2M-9XD4F"
}
/// A failure as a person sees it.
public struct Presented: Sendable, Hashable, Codable {
    public let message: Wording
    public let recovery: Recovery
    public let reference: SupportReference
    public let isClassified: Bool                // false: nobody classified it, and the generic words were used
}
extension Error {
    /// The failure as a person should see it, recorded once as `failure.presented`.
    /// Nil exactly for cancellation, which presents nothing.
    public func presented(fileID: String = #fileID, line: UInt = #line) -> Presented?
}
/// How errors the app does not own are presented.
public struct Presenter: Sendable {
    public static let standard: Presenter                // Stoic's kernel errors (the table below)
    public func adding<E: Error>(_ type: E.Type, wordings: [Wording] = [],
                                 _ present: @escaping @Sendable (E) -> Presentation?) -> Presenter
    public var wordings: [Wording] { get }               // every wording its rules use: for a translation catalog
}
extension Ambient { public var presenter: Presenter }   // .standard by default

// MARK: StoicFoundation

extension String {
    /// The wording in the bundle's table for `locale`, else its default text, with its arguments formatted.
    public init(localized wording: Wording, bundle: Bundle = .main, locale: Locale = .current, timeZone: TimeZone? = nil)
}
extension Presenter {
    /// Rules for `URLError`, `POSIXError` and `CocoaError`.
    public static let foundation: Presenter              // .standard plus those rules
}

// MARK: StoicHTTP
extension HTTPError: Presentable { public static let wordings: [Wording] }

// MARK: StoicLintCore: one rule, `stoic.error-text-shown` (below).
```

## Semantics

### Live: the phases

| Phase                    | Means                                                                   | Holds a value |
| ------------------------ | ----------------------------------------------------------------------- | ------------- |
| `.pending`               | nothing has loaded yet; the first load may be running                   | no            |
| `.fresh(v)`              | the latest load returned `v`, and nothing has made it old               | yes           |
| `.stale(v, refreshing:)` | `v` is no longer known to be current; `refreshing` says a load is out   | yes           |
| `.failed(p, last:)`      | the latest load failed; `last` is the value before it, if there was one | maybe         |

There is no `value` property, no `isLoading` and no `Bool` at all. A screen
switches on `phase`, so it must say what it draws for each case. A value that has
not loaded cannot be read as empty, and an empty list cannot be read as "not
loaded": `.fresh([])` is a list with nothing in it. The phase never goes back to
`.pending` once it holds a value. `loadedAt` is when the phase's value was
loaded. It is `nil` exactly when the phase holds no value. It is meant for
"updated 3 minutes ago", never for deciding.

### Live: loading

- **A load is a declared operation.** `Live(Events.detail) { … }` runs the load
  through `perform`, so its deadline, retries, breaker and admission are
  derived (design/22). The operation must be `.readOnly` or `.idempotent`,
  because a superseded load runs again. `init` refuses another safety with a
  precondition failure.
- **The first read of `phase` starts the first load.** Nothing loads until
  someone looks. A `Live` made by a SwiftUI view's `@State` initialiser that is
  thrown away (SwiftUI can evaluate that expression more than once) is never
  read, so it never loads. The read starts the load. The phase stays
  `.pending`, and the read changes nothing a view observes, so reading in `body`
  never mutates state during a view update.
- **A read of a stale value refreshes it.** A read that finds `.stale(v,
refreshing: false)` starts a refresh. The phase shows `refreshing: true` from
  the main actor's next turn, not during the read. A `Live` on screen therefore
  refreshes as soon as it goes stale, and one off screen does no work.
- **A failed value is not refreshed by reading it.** A failed `Live` stays
  failed until `refresh()`, its own `freshFor`, or an `invalidate()`. Otherwise
  every redraw would hit an endpoint that is failing. `perform` has already
  retried by its schedule.
- **The latest request wins.** Loads run in a `TaskSlot` owned by the `Live`.
  `refresh()` supersedes a load in flight: it is cancelled (cause
  `superseded`), and its result, if it arrives, is never delivered
  (design/03). The refresh is wanted _because_ something changed after the old
  load started, so joining that load would return data from before the change.
- **Freshness.** With `freshFor: d`, a value goes stale `d` after it was loaded,
  measured on the ambient continuous clock. Without it, a value stays fresh
  until `invalidate()` or `refresh()`.
- **Urgency** follows who is waiting. A load while `.pending` runs at
  `.interactive`, because a person is looking at a spinner. `refreshed()`, which
  a pull to refresh awaits, also runs at `.interactive`. Every other refresh
  (stale, `invalidate()`, `freshFor`, an action's `refreshes`) runs at
  `.utility`, because the person already sees a value.
- **A failure** is presented once (`error.presented()`, below), and the phase
  becomes `.failed(presented, last:)`, keeping the value there was. A load that
  ends in cancellation (superseded, or the `Live` released) changes nothing.

**Subscriptions.** `Live(subscribing:)` establishes its subscription through
`perform`, and each element is a fresh value. While the subscription is
re-established after a failure, the phase is `.stale(v, refreshing: true)`, or
`.pending` if nothing has arrived yet. `perform`'s schedule decides the retries.
When `perform` gives up, the phase is `.failed(p, last:)`. A subscription that
ends without failing leaves `.stale(v, refreshing: false)`. The next read
subscribes again, no sooner than 1 s after the previous subscription began, so
a sequence that ends at once cannot make reads spin.

### Live: combinations

`Live.combining(a, b) { … }` and `Live.joining(left, right, on:) { … }` make a
`Live` whose value is computed only from values that belong together. Its phase
follows its inputs. The first rule that applies wins:

1. **Any input failed**: `.failed(that input's presentation, last: the
combination's last snapshot)`. The first failed input, in argument order,
   names the failure.
2. **Any input pending**: `.pending`.
3. **Any input refreshing**: `.stale(last snapshot, refreshing: true)`. The
   combination is **not recomputed** while any of its inputs is mid-refresh. So
   when an action refreshes two inputs together, the screen keeps showing the
   old, consistent snapshot until both have landed. It never shows the new
   attendee list beside the old minors. If there is no snapshot yet, one is
   made from the inputs' current values.
4. **Any input stale**: recomputed; `.stale(new snapshot, refreshing: false)`.
5. **All inputs fresh**: recomputed; `.fresh(new snapshot)`.

A combination holds its inputs, so the inputs live as long as it does. An
action's `refreshes` holds them weakly. Reading a combination's phase reads its
inputs' phases, so the lazy loading above starts every input's load. The
combination recomputes on the main actor, synchronously, when an input's
phase changes (Observation tracks the inputs), so its snapshot and its phase
never disagree. `refresh()` and `invalidate()` on a combination act on every
input at once, which is how a screen asks for a consistent new snapshot.

**Joined by key, never by position.** `joining` pairs each element of the left
list with the element of the right list that has the same key, in the left
list's order. An element with no partner gets `nil`. Inside a combination,
`nil` means "not in the answer". It cannot mean "not loaded yet", because the
combination has no value at all until both lists have loaded. So Kindora's
`isMinorArray[index]` becomes `RosterRow(attendee, minor: minor?.isMinor)`, and
the row draws "unknown". A key that appears twice on the right is a defect in
the data: the first wins, and `live.join_duplicate_key` reports how many at
error level. Repeated keys on the left are fine, and each joins. Stoic offers no
positional `zip` of two `Live`s.

### Live: permissions

`check()` turns a `Live<PermissionCheck<P>>` into the `PermissionCheck<P>` a
screen switches on (design/28):

| Live's phase               | `check()`                                            |
| -------------------------- | ---------------------------------------------------- |
| `.pending`                 | `.unknown(.loading)`                                 |
| `.fresh(c)`                | `c`                                                  |
| `.stale(c, refreshing: _)` | `c`                                                  |
| `.failed(p, last: _)`      | `.unknown(.unavailable("reference \(p.reference)"))` |

The screen therefore has to draw the waiting state, because `.unknown` is a
case, and nothing turns it into a `Bool`. An action that needs the permission
takes a `Granted<P>`, and only `.granted` has one. A stale grant still grants:
a client's grant is advisory, and the server checks again (design/28). A failed
refresh does **not** keep the last grant by default: unknown is not an answer.
If the app cannot find out what the person may do now, the button waits, the
conservative choice for destructive actions.

**Keeping a grant through a failed refresh is a declared choice.**
`check(keepingGrantFor: d)` lets a screen keep drawing the last grant for `d`
after it was loaded, through failed refreshes: an edit button need not vanish
during a brief outage, since a client's grant is advisory and the server checks
again. Past `d`, and for a denial, it is `check()`.

### Actions

An `Action` is the write side: something a person triggers. It runs a declared
operation at `.interactive` (a person tapped), or at the `urgency` it was given.

**Phases.** `.idle` until the first trigger. `.running` while a run is out.
`.succeeded(output)` or `.failed(presented)` after it. `reset()` returns to
`.idle`. A screen switches on `phase` as it does on a `Live`'s.

**A second trigger while one runs** is never fired blindly. The declaration
says what happens:

- `.refuse` (the default): it is refused (`.refused(.running)`), and
  `action.refused` is reported at debug.
- `.join`: with an input equal to the running one, it joins (`.joined`).
  `run(_:)` callers of both wait for the one run's outcome. With a different
  input it is refused, because two different intents cannot share one request.

Disabling the button is still good manners, but correctness no longer depends
on it.

**One intent, one key.** `perform` is given the intent's `idempotencyKey`, so
every attempt of every run within one intent sends the same key (design/22). A
retried `.keyed` sign-up is therefore one commitment. The key is drawn at the
trigger that starts an intent. An intent starts at a trigger when the phase is:

- `.idle`;
- `.succeeded` (the last intent is done);
- `.failed` with an input that differs from the failed one (`!=`; a `Void`
  input never differs), because the person changed what they asked for;
- `.failed` after an `.executed` outcome: the backend answered permanently,
  and a server that stores a key's first answer would replay that answer to the
  same key.

A trigger after a failure with an `.unknown` or `.notExecuted` outcome and an
equal input **continues the intent**: the same key, so a retry after a lost
connection is recognised as the same request. `reset()` ends the intent.

**After an unknown outcome on a `.notRepeatable` operation**, `trigger` is
refused (`.refused(.outcomeUnknown)`) until `reset()`. The effect may already
have happened, and running the operation again could repeat it. The
presentation says `.checkFirst`, the person looks, and the screen calls
`reset()`. A `.keyed` operation has no such stop, because its key makes the
retry safe.

**A failure is always surfaced.** It is presented once (`error.presented()`,
with `action.failed` at notice and the reference). The phase holds it until
`reset()` or the next trigger. The phase is how a screen sees it, so the
`Action` tracks whether `phase` was read after the failure. A failure that is
replaced (by a trigger or `reset()`), or whose `Action` is released, without
ever having been read is reported as `action.failure_unseen` at warning level.
That is Kindora's empty `catch`, made visible.

**Refreshes.** `refreshes: [attendees]` invalidates those `Live`s, together and
in one main-actor turn, when a run succeeds. So a combination over them shows
its old snapshot until all of them have landed (Live: combinations, rule 3).

**Ownership.** The run belongs to the `Action`. A view that disappears does not
cancel a payment the person asked for. `run(_:)`'s caller may stop waiting, by
being cancelled, and the run goes on. Releasing the `Action` cancels its run.
A `.brief` `.keyed` or `.notRepeatable` attempt in flight still finishes,
shielded, within its timeout (design/22), and its outcome is reported, though
nobody is left to show it.

### Presenting a failure

`error.presented()` turns any error into what a person reads, or into nothing
for cancellation. It records the decision once, as `failure.presented`, with a
`SupportReference`. Live and Action call it. An app calls it at any other
boundary, and a server calls it for an error response.

The search, outermost layer first:

1. **Cancellation presents nothing.** That covers anything Stoic's
   classification reads as cancellation (`isCancellation`): `CancellationError`,
   `.rejected(.cancelled)`, and an `OperationError` that is cancellation. That
   last case excludes an `.unknown` outcome on a keyed or non-repeatable
   operation, which design/22 says is never cancellation. A `Report` of a
   cancellation, `LifecycleUpdateError.cancelled` and `ReconcileError.cancelled`
   are covered too. The result is `nil`, and nothing is recorded.
2. At each layer, in order:
   1. **`Presentable`**: its presentation. The layer nearest the person knows
      best, so an app error that wraps a Stoic error decides.
   2. **The ambient presenter's rule for its type**, if it returns one. This is
      how an app presents types it does not own, such as Foundation's.
   3. **A Stoic error whose presentation is decisive at this layer**: a
      rejection; an `.unknown` outcome on a keyed or non-repeatable operation; a
      lifecycle refusal or update error other than `.storage`; a permission
      refusal; a reconciler's unreadable side; a `Defect` (table below).
   4. Otherwise **look inside**: a `Report`'s root, `PolicyError.failed`'s
      failure, an `OperationError`'s failed stop, a `ConcurrentFailure`'s
      primary failure, a `LifecycleUpdateError.storage` failure. Then continue.
      A Stoic layer passed this way leaves its fallback (an `OperationError`'s
      outcome: "could not reach", "did not finish") for step 3.
3. **Nothing matched.** Use the innermost fallback that a Stoic layer left, or
   else the **generic presentation**: "Something went wrong.", `.contactSupport`,
   with `isClassified: false`.

The reference is the presentation's own, if it has one (a server's, passed
through), or a new `SupportReference.make()`. The presentation never contains
the error's description. Free text in an error can hold anything (an email, a
token, a path with a user name in it), so it goes only to the event, at
`.private` privacy.

**Stoic's own presentations.** Keys are in the `Stoic` table. The default text
is English. A `retryAfter` becomes `.wait(until: now + retryAfter)`.

| Error                                                                             | Key                         | Default text                                                              | Recovery            |
| --------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------- | ------------------- |
| unclassified                                                                      | `stoic.failure`             | Something went wrong.                                                     | `.contactSupport`   |
| a `Defect`, `LifecycleRefusal.invalid`, `.chainTooLong`                           | `stoic.failure.ours`        | Something went wrong on our side.                                         | `.contactSupport`   |
| `.rejected(.circuitOpen)`, `.budgetExhausted`                                     | `stoic.unavailable`         | The service isn't answering right now.                                    | `.wait(until:)`     |
| `.rejected(.rateLimited)`                                                         | `stoic.busy`                | Too many requests right now.                                              | `.wait(until:)`     |
| `.rejected(.bulkheadFull)`                                                        | `stoic.busy`                | Too many requests right now.                                              | `.tryAgain`         |
| `.rejected(.deadlineExceeded)`; `.unknown` on a read-only or idempotent operation | `stoic.slow`                | This is taking too long.                                                  | `.tryAgain`         |
| `.rejected(.shuttingDown)`                                                        | `stoic.closing`             | The app is closing.                                                       | `.nothing`          |
| `.rejected(.abandonmentLimit)`                                                    | `stoic.stuck`               | Something is stuck. Try again later.                                      | `.wait(until: nil)` |
| `OperationError`, `.unknown`, `.keyed`                                            | `stoic.outcome.unconfirmed` | We couldn't confirm this finished. Trying again is safe.                  | `.tryAgain`         |
| `OperationError`, `.unknown`, `.notRepeatable`                                    | `stoic.outcome.unknown`     | We couldn't confirm whether this went through. Check before trying again. | `.checkFirst`       |
| `OperationError`, `.notExecuted`, failure unclassified                            | `stoic.unreachable`         | Couldn't reach the service.                                               | `.tryAgain`         |
| `LifecycleRefusal.refused(reason)`                                                | the reason, table `L.name`  | the reason                                                                | `.nothing`          |
| `LifecycleRefusal.ignored`                                                        | `stoic.lifecycle.no_effect` | That has no effect now.                                                   | `.nothing`          |
| `LifecycleRefusal.newerDefinition`                                                | `stoic.lifecycle.newer`     | This was changed by a newer version of the app.                           | `.updateApp`        |
| `LifecycleUpdateError.notFound`                                                   | `stoic.lifecycle.gone`      | This no longer exists.                                                    | `.nothing`          |
| `LifecycleUpdateError.conflict`                                                   | `stoic.lifecycle.conflict`  | Someone else changed this at the same moment.                             | `.tryAgain`         |
| `PermissionRefusal.denied`                                                        | `stoic.permission.denied`   | You don't have permission to do this.                                     | `.nothing`          |
| `PermissionRefusal.unknown(.loading)`                                             | `stoic.permission.loading`  | Still checking what you can do.                                           | `.wait(until: nil)` |
| `PermissionRefusal.unknown(.unavailable)`                                         | `stoic.permission.unknown`  | We couldn't check what you can do.                                        | `.tryAgain`         |
| `ReconcileError.unreadable` (design/30)                                           | `stoic.sync`                | Couldn't sync right now.                                                  | `.tryAgain`         |

A lifecycle's refusal reason is the definition's own sentence, written for a
person ("this link has expired"; design/27). It is used as both key and default
text, in a table named for the lifecycle, the way Apple's string catalogs key
by source text. A permission denial's reason is **not** shown. design/28 lets
the caller decide, because a policy's reason can name someone, so Stoic shows
the generic denial, and an app that wants the reason makes its own presentation.

**`StoicFoundation`'s rules** (`Presenter.foundation`): offline, a lost
connection or a disallowed connection over cellular presents as `stoic.offline`,
"You're offline.", with `.wait(until: nil)`. A timeout presents as `stoic.slow`,
a host that cannot be found or connected to as `stoic.unreachable`, and a full
disk (`CocoaError.fileWriteOutOfSpace`, `ENOSPC`) as `stoic.disk_full`, "There
isn't enough space on this device.", with `.nothing`. An app installs them
with `withAmbient({ $0.presenter = .foundation }) { … }` at its entry point.

**`StoicHTTP`'s `HTTPError`**: 401 presents as `stoic.http.sign_in` ("Sign in
again to continue.", `.signInAgain`), 403 as the permission denial, 404 and 410
as `stoic.lifecycle.gone`, 409 as the conflict, 400 and 422 as
`stoic.http.invalid` ("Check what you entered.", `.changeInput(fields: [])`), 429
as `stoic.busy` with `Retry-After`, and 5xx as `stoic.unavailable`. The
transport's own failures are presented as `StoicFoundation` presents them.

### Localising

The kernel has no Foundation, so it cannot look up a translation. A `Wording`
carries everything a lookup needs: a `key`, a `table` (`nil` for the app's
default; `Stoic` for Stoic's own), the English `defaultText`, and named
`arguments` for `{name}` placeholders. Arguments are typed (text, integer,
moment, duration) so that a localiser can format them for a locale.

`String(localized: wording, bundle:, locale:)` in `StoicFoundation` asks
`bundle.localizedString(forKey:value:table:)`, with the default text as the
value, then replaces each `{name}` with its argument formatted for `locale`: a
number with `formatted()`, a moment as a date and time, a duration in units. A
placeholder with no argument is left as it is. Stoic ships English only. An app
translates Stoic's keys in its own `Stoic` table, and `Presenter.wordings` lists
every key a presenter can produce, so a test can check that the table covers
them. Plural forms are not supported, and Stoic ships English only (Not built).

### Where each piece lives

| Piece                                                                                                                                    | Library           | Why                                                                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `Live`, `Action`, combinations, `check()`                                                                                                | `StoicLive`       | a value arriving for a screen is a domain of its own, and a server never builds it; it needs only the kernel                    |
| `Presentable`, `Presentation`, `Wording`, `Recovery`, `SupportReference`, `Presented`, `Presenter`, `error.presented()`, the table above | `Stoic`           | every library's errors, a server's error responses and design/30's failures need them                                            |
| `String(localized:)`, `Presenter.foundation`                                                                                             | `StoicFoundation` | `Bundle`, `Locale` and formatters; `URLError`, `POSIXError`, `CocoaError`                                                        |
| `HTTPError: Presentable`                                                                                                                 | `StoicHTTP`       | it owns the type                                                                                                                 |
| `stoic.error-text-shown`                                                                                                                 | `StoicLintCore`   | —                                                                                                                                |

**Nothing needs SwiftUI.** `Live` and `Action` are `Observable`, so SwiftUI,
UIKit's and AppKit's observation tracking, and a test all read them the same
way. The scenario's `FailureView` and `Text(String(localized:))` are
written by the app. A `StoicSwiftUI` library is Not built. It would hold a
button bound to an `Action`, a phase switch, and `Text(wording)`.

### Lint

| Id                       | Flags                                                                    | Why                                                                           | Instead                               |
| ------------------------ | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------- |
| `stoic.error-text-shown` | `.localizedDescription`, outside test code and `StoicFoundation`'s files | it is how raw error text reaches a person, and the text can hold private data | `error.presented()`; or `stoic:allow` |

It is syntactic, as every Stoic rule is. Known false negatives: `"\(error)"` in
a view, and `String(describing: error)`.

### Cancellation

A `Live`'s load that is superseded or cancelled changes no phase. Releasing a
`Live` cancels its load. An `Action`'s run is cancelled only when the `Action`
is released (see Ownership), and a cancelled run presents nothing and leaves
`.idle`. `refreshed()` and `run(_:)` return the phase as it is when their caller
is cancelled. They do not cancel the work. `error.presented()` returns `nil` for
cancellation, and records nothing. Cleanup always runs.

### Isolation

`Live` and `Action` are `@MainActor`: they hold what a screen draws, and every
UI framework draws on the main actor. Loads and runs are `@concurrent`, so
decoding happens off the main actor. Their results are `Sendable`, and are
delivered on the main actor through the `TaskSlot`'s owner check (design/03).
`Presented`, `Presentation`, `Wording`, `Recovery` and `SupportReference` are
`Sendable` values. `error.presented()` can be called anywhere, and it records
its event outside every lock.

### Defaults

| Default                   | Value                                    | Why                                                                                                                                                                |
| ------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `freshFor`                | none                                     | most values change when something happens, not when time passes; say so when they do                                                                               |
| first load, `refreshed()` | `.interactive`                           | a person is looking at a spinner                                                                                                                                   |
| other refreshes           | `.utility`                               | the person already sees a value                                                                                                                                    |
| `Action` urgency          | `.interactive`                           | a person tapped                                                                                                                                                    |
| `whileRunning`            | `.refuse`                                | joining needs an equal input; refusing is always safe                                                                                                              |
| resubscription spacing    | 1 s                                      | a subscription that ends at once cannot spin                                                                                                                       |
| `SupportReference`        | 10 characters, 50 bits, Crockford base32 | short enough to read aloud; at a million presented failures a day, two share a reference about once in six years, and support matches on the reference and the day |

## Failure modes

| What happens if…                                                         | Then                                                                                                     |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| a `Live` is never read                                                   | it never loads                                                                                           |
| a `Live` is read for the first time                                      | its first load starts at `.interactive`; the phase stays `.pending`                                      |
| a `Live`'s value is read as empty while it loads                         | it cannot be: there is no value to read; the phase is `.pending`                                         |
| a load returns an empty list                                             | `.fresh([])`, which is not `.pending`                                                                    |
| a load fails before any value                                            | `.failed(presented, last: nil)`                                                                          |
| a refresh fails after a value                                            | `.failed(presented, last: value)`; the screen can keep the value and show the failure                    |
| a failed `Live` is read again                                            | it stays failed; nothing loads until `refresh()`, `freshFor` or `invalidate()`                           |
| `refresh()` is called while a load runs                                  | the running load is superseded and its result never delivered; the new load's result is                  |
| a superseded load finishes after the new one                             | its result is dropped (`slot.superseded_late`)                                                           |
| `freshFor` passes                                                        | `.stale(v, refreshing: false)`; the next read refreshes it                                               |
| a `Live` is released while loading                                       | its load is cancelled; nothing is delivered                                                              |
| a load operation is declared `.keyed` or `.notRepeatable`                | `Live.init` fails a precondition                                                                         |
| a subscription fails and is re-established                               | `.stale(v, refreshing: true)` meanwhile; `.failed(p, last: v)` when `perform` gives up                   |
| a subscription ends without failing                                      | `.stale(v, refreshing: false)`; the next read subscribes again, no sooner than 1 s after the last began  |
| one input of a combination is refreshing                                 | the combination keeps its last snapshot as `.stale(_, refreshing: true)` and is not recomputed           |
| an action refreshes two inputs of a combination                          | the old snapshot stays until both have landed; a new input never appears beside an old one               |
| one input of a combination fails                                         | `.failed(its presentation, last: the last snapshot)`                                                     |
| two lists are joined and the right list lacks a key                      | that row gets `nil`: absent from a loaded answer, never "not loaded"                                     |
| the right list of a join repeats a key                                   | the first is used; `live.join_duplicate_key` at error level with the count                               |
| a permission `Live` is pending                                           | `check()` is `.unknown(.loading)`                                                                        |
| a permission `Live`'s refresh fails                                      | `check()` is `.unknown(.unavailable(…))`, even if a grant was held                                       |
| a permission `Live`'s refresh fails and the screen keeps its grant for a time | `check(keepingGrantFor:)` grants until the grant is that old, then is `.unknown(.unavailable(…))` |
| a permission `Live` is stale                                             | `check()` is the stale check; the server checks again                                                    |
| an action is triggered twice and declared `.refuse`                      | the second is refused (`.refused(.running)`); one request                                                |
| an action is triggered twice with one input and declared `.join`         | the second joins; one request; both `run(_:)` callers get its outcome                                    |
| an action declared `.join` is triggered with another input while running | refused (`.refused(.running)`)                                                                           |
| a keyed action fails with an unknown outcome and is triggered again      | the same intent: every attempt sends the same key                                                        |
| an action fails with a not-executed outcome and is triggered again       | the same intent and key                                                                                  |
| an action fails with an executed outcome and is triggered again          | a new intent and a new key                                                                               |
| an action fails and is triggered again with a different input            | a new intent and a new key                                                                               |
| an action succeeds and is triggered again                                | a new intent and a new key                                                                               |
| a not-repeatable action fails with an unknown outcome                    | `.failed` with `.checkFirst`; `trigger` is refused (`.outcomeUnknown`) until `reset()`                   |
| an action's failure is never read before it is replaced or released      | `action.failure_unseen` at warning level                                                                 |
| the view that triggered an action goes away                              | the run goes on; it belongs to the `Action`                                                              |
| an `Action` is released while running                                    | the run is cancelled; a brief keyed or non-repeatable attempt finishes shielded; its outcome is reported |
| an action succeeds with `refreshes`                                      | those `Live`s are invalidated together, in one main-actor turn                                           |
| an error is a cancellation                                               | `presented()` is nil; nothing is recorded                                                                |
| a keyed operation is cancelled after reaching the backend                | it is not cancellation (design/22): presented as `stoic.outcome.unconfirmed`                             |
| an error conforms to `Presentable`                                       | its presentation, with a new reference unless it carries one                                             |
| an app error wraps a Stoic error                                         | the outer `Presentable` decides                                                                          |
| a `Report` wraps a `Presentable` error                                   | the root's presentation; the frames are not shown                                                        |
| an `OperationError` was refused by a policy                              | the rejection's row of the table                                                                         |
| an `OperationError`'s failure is `Presentable`                           | that failure's presentation, unless the outcome is unknown on a keyed or non-repeatable operation        |
| nobody classified an error                                               | the generic presentation and a reference; `isClassified` is false; `failure.presented` at warning        |
| an error is a `Defect`                                                   | "Something went wrong on our side."; `failure.presented` at error                                        |
| an error's description holds private data                                | it appears in no `Presented`; only in the event, at `.private`                                           |
| a presentation carries a server's reference                              | that reference is shown, and matches the server's event                                                  |
| a wording has no translation                                             | its default text, arguments formatted for the locale                                                     |
| a wording's text names an argument it was not given                      | the placeholder is left as it is                                                                         |
| a person reads a reference back with the wrong case or an O for a 0      | `SupportReference(text)` reads it                                                                        |
| code shows `error.localizedDescription`                                  | `stoic.error-text-shown` refuses it, with the fix                                                        |

## Events

All are in `EventCatalog`. Labels, keys, recoveries, references, error types and
counts are public. An error's description is at `.private` privacy. A
`Wording`'s text and arguments are never recorded: they are for the person, and
an argument can be their own email address.

| Event                     | Level                                                     | Meaning                                                                                 |
| ------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `failure.presented`       | info if classified; warning if generic; error if a defect | a failure reached a person: reference, key, recovery, error type, description (private) |
| `live.failed`             | notice                                                    | a load failed: label, reference                                                         |
| `live.join_duplicate_key` | error                                                     | a join's right list repeated keys: label, count                                         |
| `action.refused`          | debug                                                     | a trigger was refused: label, why                                                       |
| `action.joined`           | debug                                                     | a trigger joined a run: label                                                           |
| `action.failed`           | notice                                                    | a run failed: label, reference, outcome                                                 |
| `action.failure_unseen`   | warning                                                   | a failure nobody read was replaced or released: label, reference                        |
| `action.orphaned`         | notice                                                    | an action released mid-run: how its run ended, with nobody left to show it              |

Loads and runs report under design/22's names, and supersession under
design/03's (`slot.superseded`, `slot.superseded_late`).

## Testing

- **Every row above.** The tests are `@MainActor`, on `TestClock` with the test
  wall clock, with scripted operations. `simulate` does not drive the main actor,
  so these are not simulation tests. The `TaskSlot` underneath already has
  those.
- **Phases, as a property.** Over random sequences of reads, loads that succeed,
  fail or hang, refreshes, invalidations and clock advances:
  - the phase never returns to `.pending` after a value;
  - a value is delivered only from the newest load;
  - `loadedAt` is nil exactly when the phase holds no value.
- **Combinations, as a property.** Over random interleavings of their inputs'
  phases:
  - a combination's snapshot is never computed while an input is refreshing;
  - after a joint invalidation, no snapshot mixes a new input with an old one;
  - a join's rows equal a dictionary join of its inputs, in left order.
- **Actions, as a property.** Over random taps, joins, outcomes (each of
  `OperationError`'s three) and resets:
  - at most one run is in flight;
  - the keys sent equal the intents the rules above define;
  - every failure is either read or reported unseen.
- **Presentation, as a golden table.** Every error in the table above, nested
  in every wrapper (`Report`, `PolicyError`, `OperationError`,
  `ConcurrentFailure`), maps to its row, so a changed row is a reviewed diff.
- **Privacy.** An error whose description is a sentinel string is presented,
  and the sentinel appears in no `Presented`, no `Wording` and no public event
  field.
- **Compile-fail cases** (`scripts/compile-fail`, with a control that compiles): `if live.phase`,
  `live.value`, `if check()`, an `Action` whose input is neither `Equatable` nor
  `Void`, and a delete action given an `EventID` where it takes a
  `Granted<EditEvent>`.
- **Localisation** in `StoicFoundationTests`, with a test bundle holding a `Stoic`
  table: a translated key, a missing key, every argument kind under two
  locales, and a check that `Presenter.foundation.wordings` are all in the
  table.
- **Lint**: findings and non-findings for `stoic.error-text-shown`, including the
  false negatives, written as tests that expect nothing.
- **The ideal scenario** as a test, on scripted operations: the roster stays
  consistent across a sign-up that refreshes both lists, a double tap is one
  request with one key, and a delete cannot be triggered while the permissions
  load.

## Not built

- **`StoicSwiftUI`**: a button bound to an `Action` that disables itself while
  running and shows its failure, a view that switches over a `Live`'s phase, and
  `Text(_: Wording)`. It is small, but it adds a SwiftUI dependency and many
  design questions. The app's three lines do the job until it is built.
- **Intents that survive a relaunch.** An `Action`'s key lives in memory. A
  payment that must survive the app being killed between the tap and the answer
  belongs in the outbox (design/15), whose entry keeps its key.
- **`Live` off the main actor**: a menu-bar helper's own actor. `TaskSlot`
  already allows any actor, so this is a generic isolation parameter away.
- **Reading a server's `Presented` in `StoicHTTP`.** A server can already encode
  `Presented` (it is `Codable`) in an error body. The client turning that body
  into a `Presentation` with the server's reference is HTTP work for later.
- **A schema's `ValidationFailure` as `.changeInput(fields:)`.** `StoicSchema`
  cannot see the kernel. A rule in `StoicHTTP` or `StoicSettings`, which see
  both, could map issue paths to fields.
- **Plural forms** in `Wording`, and **Stoic-shipped translations** of its keys.
- **A lint rule against positional joins.** A syntactic rule cannot tell
  `b[index]` beside `a.enumerated()` from correct code. `joining` is the
  compliant path, and the rule is left out.

## Decisions

The review settled the draft's open questions:

1. **`Live` and `Action` are a library of their own**, `StoicLive` ← `Stoic`,
   portable. Presenting failures stays in the kernel, where the errors are.
2. **The names stand**: `Wording`, `Presented`, `error.presented()`.
3. **Plurals and Stoic-shipped translations are not built.**
4. **Loading starts lazily on first read**, as drafted.
5. **`.stale(_, refreshing:)` is one case.**
6. **A failed refresh drops a held grant by default**; keeping it for a stated
   time is `check(keepingGrantFor:)`, a declared choice.
7. **An unclassified failure's recovery is `.contactSupport`.**
8. **Stoic ships English only.**

## As built

Departures from the reviewed draft, and decisions it left open.

- **`Presenter.adding(_:wordings:_:)`** takes the wordings a rule can return,
  so `wordings` can list them for a translation catalog: a closure cannot be
  asked. The rule added last is asked first, so an app can override a rule it
  was given (StoicFoundation's). `HTTPError.wordings` lists StoicHTTP's.
- **`String(localized:bundle:locale:timeZone:)`** takes the zone a moment is
  written in, `nil` for the device's: a test, and an app showing another
  place's time, say which.
- **`HTTPError`'s cases the draft did not list**: a timeout reads as
  `stoic.slow`; a transport code StoicFoundation has no words for, as
  `stoic.unreachable`; another status, a response too large, a body that does
  not match its schema, a refused redirect and an authenticator that will not
  sign, as `stoic.failure.ours` (a disagreement between the app and its
  server); an authenticator that may sign later, as `stoic.unavailable`.
- **`ReconcileError.holdChanged`** presents as the conflict;
  `ReconcileError.cancelled` is cancellation.
- **The stable forms.** `Presented` and `Presentation` are `Codable` for a
  server's error body: a `Wording` is `{"key", "default", "table"?,
"arguments"?}`, an argument one key naming its kind (`{"integer": 3}`), a
  `Recovery` `{"kind": "wait", "until": …}`, a `SupportReference` its text,
  and `Presented`'s flag `"classified"`. `Presented` has no public initialiser:
  it is made by presenting, or decoded.
- **`failure.presented`** carries the error's debug description, privately: a
  `Report`'s plain description hides its root, and whoever reads the event is
  debugging the failure. The search stops at 64 layers; Stoic's existing
  cancellation check recurses through the same chain, so an error nested
  hundreds deep is not supported anywhere.
- **`Live`'s refresh urgency**: `refresh()` loads at `.interactive` while
  nothing has loaded, else `.utility`; `refreshed()` at `.interactive`.
- **An invalidation during a load** makes the value that load brings arrive
  stale, so the next read loads again: it predates the invalidation. This is
  what makes an action's `refreshes` correct when a refresh is already out.
- **`invalidate()` on a failed value** clears the failure, so the next read
  loads again; a value's own `freshFor`, armed when it loaded, does the same to
  a failure that came after it.
- **Subscriptions.** `perform` establishes the subscription (its schedule
  decides those retries); a stream that fails once established is
  re-established, `.stale(v, refreshing: true)` meanwhile, no sooner than a
  second after the last began.
- **Combinations**: the snapshot's `loadedAt` is its oldest part's; labels
  default to `a+b` and `left⋈right`.
- **`Action.reset()` during a run changes nothing**: the run's outcome still
  lands. A run that ends in cancellation leaves `.idle` and ends the intent.
  `run(_:)` returns the phase, which counts as reading it.
- **`action.orphaned`** is new: an action released mid-run reports how its run
  ended (a shielded keyed or non-repeatable attempt may have finished), with
  nobody left to show it.
- **An action's deinit** (an `isolated deinit`) sees no task-local values, so
  it reports an unseen failure to the instrumentation in force when the action
  was made.
- **`check(keepingGrantFor:)`** keeps only a grant, measured from when it was
  loaded on the wall clock; a denial is not kept.
- **The lint rule** does not flag a method call named `localizedDescription`
  (an app's own `model.localizedDescription(of:)`), only the property.
- **The `live.value` compile-fail case** fails because the stored value is
  private: there is no public way to read it.

# 22 · Operations and backends

An app's resilience is a set of numbers — attempts, delays, timeouts,
breaker thresholds, concurrency limits — and today each call site picks its
own. They drift from each other and from the truth: a timeout shorter than
the backend's tail, a retried `POST`, three layers each retrying three
times, an interactive tap waiting out a background backoff, a breaker that a
`static let` bound to a test's frozen clock. The numbers are not the facts.
The facts are few, and each is known by exactly one party:

- **The operation** knows what it does: whether running it twice is
  harmless, harmless only with a key the backend deduplicates, or not
  harmless at all; whether it is a brief call or a long transfer; and which
  backend it calls.
- **The backend** knows what it is (a remote service, a system service, a
  local store, on-device compute) and how much concurrent work it can take.
- **The call** knows who is waiting (a person staring at a spinner, or a
  sync nobody watches) and by when (the deadline).

Stoic takes those facts and derives the policy: the deadline when the
caller set none, the retry schedule and its classifier, the attempt
timeout, the breaker and what it counts, the bulkhead and its reservation
for urgent work, the retry budget, the idempotency key, and what is known
about the outcome when a call fails. The derivation is a pure function, so
it can be printed and asserted in a test; the state it needs (breakers,
bulkheads, budgets) belongs to the backend and lives in the ambient context,
so every test starts fresh.

## The ideal scenario

A podcast app. Its catalogue API is remote; its downloads database is a
local SQLite file; transcription runs an on-device model; its payments go
through a remote API that deduplicates by key.

```swift
extension Backend {
    static let catalogue = Backend.remote("catalogue")
    static let library = Backend.local("library.sqlite")
    static let transcriber = Backend.compute("transcriber")
    static let payments = Backend.remote("payments")
}

enum Catalogue {
    static let episode = Backend.catalogue.readOnly("episode")
    static let download = Backend.catalogue.idempotent("download", length: .long)
}
enum Payments {
    static let subscribe = Backend.payments.keyed("subscribe")
}

@MainActor final class EpisodeModel {
    let api: CatalogueAPI           // not Sendable: it doesn't have to be
    var episode: Episode?

    func open(_ id: Episode.ID) async throws {
        // A tap: someone is waiting.
        episode = try await withUrgency(.interactive) {
            try await Catalogue.episode.perform { _ in try await api.episode(id) }
        }
    }
}

// The payment: retried only with the same key, never repeated without it.
// The checkout screen made the key when it opened, so a double tap is one charge.
do {
    receipt = try await Payments.subscribe.perform(idempotencyKey: checkout.key) { attempt in
        try await api.subscribe(plan, idempotencyKey: attempt.idempotencyKey)
    }
} catch let error where error.outcome == .unknown {
    // It may have been charged: reconcile under checkout.key, never re-ask.
}
```

The tap gets two quick attempts inside ten seconds and fails at once if the
catalogue's breaker is open. The same code reached from a background refresh
(a task at background priority) gets six patient attempts over ten minutes,
waits out an open breaker, and is never let into the last half of the
catalogue's capacity, which is kept for people. The payment is retried on a
transient failure with the same key on every attempt, and when it fails
after reaching the server, the error says the outcome is unknown instead of
looking like a rejection. None of these numbers is at a call site.

## Origin

- **Finagle `MethodBuilder`.** A method declares `idempotent` or
  `nonIdempotent` and the builder derives its retries, with one budget
  shared across the methods of a client. Stoic takes the derivation and the
  shared budget, and declares facts with factories, so no later call can
  undo a declaration.
- **Smithy and the AWS SDKs.** `@readonly`, `@idempotent` and
  `@idempotencyToken` on an operation; an unsafe operation is retried only
  when the failure proves it was not executed. `readOnly`, `idempotent` and
  `keyed` are those traits, and `neverReachedBackend` is that proof.
- **gRPC service config.** Per-method retry policy; the call deadline covers
  every attempt; a client can disable retries but not loosen them.
- **Google SRE.** Criticality declared at the root of a request and
  propagated to its children; retry at one layer only; budgets per client.
- **Envoy, Linkerd, Netflix.** Retry budgets as a fraction of traffic per
  upstream; capacity partitioned by priority, so batch work cannot starve
  interactive work.
- **Apple's quality-of-service classes.** The app declares who is waiting,
  never the numbers, and the system derives scheduling from it. `Urgency`
  mirrors the classes and is inferred from the task's base priority when not
  set.
- **Stripe's idempotency keys.** A key made with the intent (when the
  checkout opens), not with the request, is what makes a double tap and a
  lost response one charge; a request whose outcome is unknown is
  reconciled under its key, never resubmitted under a new one.

Facts about the systems above are from a survey made for this contract (and
prior knowledge, not re-checked); the derivations below are Stoic's.

## API

```swift
/// Something an app depends on: a value, declared once. Its state lives in
/// the ambient context, keyed by name.
public struct Backend: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case remote    // a server, over a network
        case system    // an XPC service, a daemon, an OS framework call
        case local     // a database or file on this device
        case compute   // on-device inference or other heavy local work
    }
    public let name: String         // the identity: equality and hashing use it alone
    public let kind: Kind
    public let capacity: Int        // the most operations in flight at once

    public static func remote(_ name: String, capacity: Int = 6) -> Backend
    public static func system(_ name: String, capacity: Int = 4) -> Backend
    public static func local(_ name: String, capacity: Int = 4) -> Backend
    public static func compute(_ name: String, capacity: Int = 1) -> Backend

    // One factory per repeat safety: the declaration is the fact.
    public func readOnly(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation
    public func idempotent(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation
    public func keyed(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation
    public func notRepeatable(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation
}

/// Whether running an operation more than once is harmless.
public enum RepeatSafety: Sendable, Hashable {
    case readOnly       // changes nothing
    case idempotent     // twice leaves what once leaves
    case keyed          // repeatable because the backend deduplicates by
                        // `attempt.idempotencyKey`, sent on every attempt
    case notRepeatable  // repeating it may repeat its effect
}

/// Who is waiting for the result.
public enum Urgency: Sendable, Hashable, Comparable, CustomStringConvertible {
    case background     // nobody; minutes are fine
    case utility        // shown eventually: prefetch, sync
    case userInitiated  // someone asked and is waiting seconds
    case interactive    // someone is looking at a spinner
    public static var current: Urgency { get }
}
public nonisolated(nonsending) func withUrgency<R, E: Error>(
    _ urgency: Urgency,
    operation: nonisolated(nonsending) () async throws(E) -> R
) async throws(E) -> R

extension Backend {
    /// One operation on a backend: a value, declared once, as a `static let`.
    public struct Operation: Sendable, Hashable, CustomStringConvertible {
        public enum Length: Sendable, Hashable {
            case brief  // a request, a query: an attempt that runs long is stuck
            case long   // a transfer, a migration: slow is not stuck
        }
        public let backend: Backend
        public let name: String
        public let safety: RepeatSafety
        public let length: Length
        public let ceiling: Urgency     // the highest urgency it runs at

        /// Runs `operation` under the policy derived for this call. The
        /// operation runs on the caller's actor and may capture anything.
        public nonisolated(nonsending) func perform<R, Failure: Error>(
            idempotencyKey: IdempotencyKey? = nil,
            fileID: String = #fileID,
            line: UInt = #line,
            operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
        ) async throws(OperationError<Failure>) -> R

        /// The policy `perform` would use at `urgency`: pure, printable.
        public func policy(at urgency: Urgency) -> OperationPolicy
    }
}

/// Why `perform` gave up, and what is known about the backend's side.
public struct OperationError<Failure: Error>: Error, CustomStringConvertible {
    public enum Stop {
        case failed(Failure)        // the last attempt failed and retrying stopped on it
        case rejected(Rejection)    // a policy refused or ended the call (see Errors)
        case cancelled              // the caller was cancelled
    }
    public enum Outcome: Sendable, Hashable {
        case notExecuted   // nothing reached the backend
        case executed      // the backend gave a permanent answer
        case unknown       // an attempt reached the backend and was cut off or failed transiently
    }
    public let stop: Stop
    public let outcome: Outcome
    public let last: Failure?                   // the last attempt's own failure, if one ran and had one
    public let attempts: Int
    public let safety: RepeatSafety             // the operation's, for diagnostics
    public let idempotencyKey: IdempotencyKey?  // for a keyed operation: the key every attempt sent
}

/// The breaker an operation's backend gets: what `OperationPolicy` prints.
public struct BreakerPolicy: Sendable, Hashable, CustomStringConvertible {
    public let openDuration: CircuitBreaker.OpenDuration
    public let minimumCalls: Int
}

/// Everything derived for one call. A value: tests assert it, events print it.
public struct OperationPolicy: Sendable, Hashable, CustomStringConvertible {
    public let urgency: Urgency
    public let deadline: Duration           // the default total, when the caller set none
    public let schedule: BoundedSchedule
    public let attemptTimeout: Duration?    // nil: the attempt is bounded by the deadline alone
    public let breaker: BreakerPolicy?      // nil: no breaker
    public let admission: Int               // slots of the backend's capacity this urgency may hold
    public let writers: Int?                // for a local backend: writers admitted at once
    public let stretchesForDevice: Bool
    public let waitsForOpenBreaker: Bool
}

public protocol Retryable: Error {
    var retryDecision: RetryDecision { get }
    /// True when the failure proves the operation never reached the backend
    /// (no connection was made, nothing was written). Default `false`.
    var neverReachedBackend: Bool { get }
}
```

`Backend.Operation` is never written by an app: it declares operations with
the factories, and `perform` is called on the declaration. The name `Backend`
is chosen not to collide with the `Dependency` type of swift-dependencies,
which a TCA app imports in every feature file.

## Semantics

### Facts, and only facts

A declaration holds no number but a backend's capacity, the one number its
owner knows and nobody can observe. Attempts, delays, timeouts and
thresholds are derived, and a call site cannot set them. The call's facts
are its own: its deadline (`withTimeout`, `withDeadline`) and who is waiting
(`withUrgency`). Nothing else at a call site changes the policy.

### Urgency

`Urgency.current` is the innermost `withUrgency`. Outside one, it is
inferred from the task's _base_ priority (not its escalated one, so a
prefetch that a person later awaits keeps a deterministic policy):
`.background` is `.background`; `.utility` (= `.low`) is `.utility`;
anything higher, including `.medium`, the default of a `Task {}` started off
the main actor, is `.userInitiated`. `.interactive` is never inferred: a call
is interactive only when code says so. Urgency is inherited by child tasks
and by every task Stoic starts; a `Task.detached` starts without it, like
any task-local.

An operation runs at `min(Urgency.current, ceiling)`. A ceiling stops work
that should never compete with people (a bulk re-index) from claiming their
capacity however it is called; capping is reported
(`operation.urgency_capped`, debug).

### The derivation

`policy(at:)` is a pure function of the operation, its backend's kind and
the urgency. Every number below is a default written here, chosen once, and
tested as a table (a golden test prints `OperationPolicy` for every kind ×
urgency × length).

**Total deadline** — applied only when the caller set none
(`Deadline.current` is nil). A caller's deadline, shorter or longer, is the
call's fact and always wins. `.long` operations triple these.

| Kind      | interactive | userInitiated | utility | background |
| --------- | ----------- | ------------- | ------- | ---------- |
| `remote`  | 10 s        | 30 s          | 2 min   | 10 min     |
| `system`  | 5 s         | 15 s          | 1 min   | 5 min      |
| `local`   | 2 s         | 10 s          | 1 min   | 5 min      |
| `compute` | 30 s        | 2 min         | 10 min  | 30 min     |

Ten seconds is about as long as a person watches a spinner before giving up.
Urgency is who waits, not whether the app is in the background: a
background task's own time limit arrives as `Deadline.current` from the
lifecycle bridges (design/21), and wins.

**Schedule** — exponential, fully jittered, capped; attempts count the
first.

| Kind               | interactive        | userInitiated      | utility            | background      |
| ------------------ | ------------------ | ------------------ | ------------------ | --------------- |
| `remote`, `system` | 2 · 50 ms … 250 ms | 3 · 100 ms … 1 s   | 4 · 500 ms … 10 s  | 6 · 1 s … 60 s  |
| `local`            | 3 · 10 ms … 100 ms | 3 · 10 ms … 100 ms | 3 · 10 ms … 100 ms | 5 · 50 ms … 1 s |
| `compute`          | 2 · 500 ms … 2 s   | 2 · 500 ms … 2 s   | 2 · 500 ms … 2 s   | 3 · 5 s … 60 s  |

A local store's transient failures (busy, locked) clear in milliseconds or
not at all; on-device compute fails transiently only when a resource is
briefly unavailable, and a retry costs as much as the attempt.

**Attempt timeout** — for `.brief` operations on `remote` and `system`
backends only:

| Kind     | interactive | userInitiated | utility | background |
| -------- | ----------- | ------------- | ------- | ---------- |
| `remote` | 4 s         | 10 s          | 30 s    | 60 s       |
| `system` | 2 s         | 5 s           | 15 s    | 30 s       |

Two interactive attempts fit in the interactive deadline. `local` and
`compute` operations, and every `.long` one, have no attempt timeout: they
are bounded by the deadline alone, which a timer enforces (see Order). Cancelling a local write mid-transaction
makes its outcome unknown for nothing, a slow inference is not a stuck one,
and a transfer that is progressing must not be cut at a fixed length.

**Breaker** — for `remote` and `system` backends, one per backend; not for
`local` or `compute`, where a full disk or a corrupt file is not an outage
that heals while the breaker is open, and failing fast hides the error the
app must act on. What it counts follows classification, as design/19 does
for HTTP:

- a failure the classifier would retry for its own sake (a timeout, a
  transient error) counts against the backend;
- a permanent failure counts as a success: the backend answered;
- a failure that never reached the backend, the caller's cancellation, and
  an attempt cut off by the call's deadline (not its own attempt timeout:
  the deadline is the caller's) are not recorded.

Thresholds are `CircuitBreaker`'s defaults with at least 20 calls in the
window and no slow-call rule: an attempt timeout already counts as a
failure, and a `.long` operation is slow by nature, so a window of downloads
must not open the breaker for every quick call to the same backend. A `system` backend's breaker opens for 1 s at first, growing to
30 s: launchd relaunches a crashed service in milliseconds. A `remote` one
uses `CircuitBreaker`'s standard open duration.

At `.interactive` and `.userInitiated` an open breaker fails the call at
once. At `.utility` and `.background` the call waits for it: it sleeps the
breaker's `retryAfter`, jittered up to 10% later, at most three times per
call, never past the deadline, and the waits consume neither an attempt nor
a budget token. A call refused by a half-open breaker (whose one probe is
already out) waits for the probe's verdict the same way, bounded by the
breaker's half-open timeout.

**Admission** — one bulkhead per backend, of its `capacity`. The caps are
cumulative: calls at an urgency *or lower* together hold at most (rounded
down, at least one):

| Urgency         | slots of capacity _c_ |
| --------------- | --------------------- |
| `interactive`   | _c_                   |
| `userInitiated` | _c_ − max(1, _c_/4)   |
| `utility`       | 3*c*/4                |
| `background`    | _c_/2                 |

So a person's explicit tap always has a slot that row loads and syncs
together cannot take, and background work never holds the last half. A
freed slot goes to the most urgent waiter whose cumulative cap allows it,
first come first served within an urgency. Each urgency may have at most 4 × _c_ waiters;
past that the call is refused at once (`.rejected(.bulkheadFull)`). A wait
lasts at most until the call's deadline, and is not an attempt. With
capacity 1 (`compute`'s default) the rounding gives every urgency the one
slot: there is no reservation, only priority among waiters; a long
background holder is not preempted (see Later).

**Writers** — a `local` backend admits one operation that is not
`.readOnly` at a time, because concurrent writers to one SQLite file only
contend into "busy". A writer waits for the writer lane first (most urgent
first, bounded like the partitions) and only then takes a slot, so writers
waiting for the lane never hold slots that reads need. Reads stay
concurrent.

**Device conditions** stretch delays (design/16) only at `.utility` and
`.background`: a person waiting is not made to wait longer because the
device is warm.

**Budget** — one `RetryBudget` per backend, owned by the backend's state
and registered in the ambient registry as `RetryBudget.named(backend.name)`,
so a hand-written `retry(budget: .named("catalogue"))` shares it (and the
budget registry's eviction cannot split the two). `.utility` and `.background` calls may not spend the last half
of its reserve: a failing sync cannot leave a person's one retry without a
token.

### Classification

For a failed attempt, in this order:

1. A `Defect`: stop.
2. The caller's cancellation: stop. An attempt cancelled by its own timeout
   is a transient failure.
3. Repeat safety:
   - `.notRepeatable`: the failure is _eligible_ for another attempt only if
     it proves nothing reached the backend: a rejection before start by the
     call's own breaker, bulkhead or budget, or an error whose
     `neverReachedBackend` is true. Otherwise stop.
   - `.keyed`: as `.idempotent`, provided every attempt sends the key (see
     Keys). A keyed call whose key Stoic made (drawn or derived) and the
     operation never read is treated as `.notRepeatable`, and `operation.key_unread` is reported
     at error level (it fails a test under `withTestAmbient`): a keyed
     operation that sends no key is a bug, and repeating it is the double
     charge.
   - `.readOnly`, `.idempotent`: eligible.
4. An eligible failure's own `Retryable.retryDecision`, if it has one
   (looking through `PolicyError`, `Report` and `ConcurrentFailure`, as
   `retry` does). Eligibility does not override it: a device that refuses
   cellular data is never retried, even though nothing was sent.
5. Otherwise, by kind: `remote` and `system` retry an unclassified failure
   (as `retry`'s `.standard` does); `local` and `compute` stop on one — an
   unknown local error is far more often permanent than transient, and a
   store whose transient errors matter conforms them to `Retryable`.

`StoicFoundation` sets `neverReachedBackend` for the `URLError`s that fail
before a connection exists (`cannotFindHost`, `dnsLookupFailed`,
`cannotConnectToHost`, `notConnectedToInternet`) and the `POSIXError`s
`ECONNREFUSED`, `ENETUNREACH`, `EHOSTUNREACH`, each with a test of what it
means. design/19's stricter rule for an unkeyed HTTP `POST` stands for
`StoicHTTP`'s own client: an operation is not a request, and its adapter
decides what it can prove. `StoicHTTP`'s `HTTPError` claims it for those
`URLError` codes on a call's first request, and for a refusal before any
request was sent; after a redirect it does not (see Inside StoicHTTP).

On Apple platforms Foundation's bridged errors reach an `any Error` as their
`NSError`, even when Swift built them, and a cast to `Retryable` on that box
fails. So every classification (`retry`'s, a breaker's, `perform`'s
`neverReachedBackend`) reads an error through one view, which asks an
`NSError` in `NSURLErrorDomain`, `NSPOSIXErrorDomain` or `NSCocoaErrorDomain`
for the `URLError`, `POSIXError` or `CocoaError` it is, and an `NSError` in
any other domain for nothing, so it classifies as an unknown error does.

### Outcome

Every failure `perform` throws says what is known about the backend's side:

- `.notExecuted`: every attempt was refused before start, or failed with
  `neverReachedBackend`.
- `.executed`: the last attempt that reached the backend failed
  permanently (classification steps 4–5, setting repeat safety aside, say
  stop): the backend answered.
- `.unknown`: an attempt reached the backend and then was cut off (its
  timeout, the deadline, the caller's cancellation) or failed transiently (a
  lost connection, a 502, 503 or 504), and no later attempt under the same
  key got a permanent answer. A transient failure says nothing about whether
  the backend acted.

For a `.keyed` or `.notRepeatable` operation an `.unknown` outcome is never
reported as cancellation, even when the caller was cancelled:
`isCancellation` (and Stoic's cancellation checks) is false for it, and
`operation.outcome_unknown` is reported at warning level. A caller that
swallows cancellation therefore cannot swallow a payment that may have
happened. For `.readOnly` and `.idempotent` operations the outcome is
reported but never changes how the error classifies.

For a `.brief` `.keyed` or `.notRepeatable` operation, the caller's
cancellation does not cut the attempt in flight: it finishes, shielded,
within its attempt timeout and the deadline, so an outcome about to be known
is known; then `perform` stops without retrying. Every other attempt is
cancelled at once.

`containsCancellation`, `containsDefect` and the policy-layer unwrapping see
through `OperationError` (through a non-generic internal protocol, as they
see through `PolicyError`), including inside `PolicyError.failed`: a
`Defect` in `last` is a defect to an enclosing retry. Scopes and supervisors
therefore report a cancelled child's `.unknown` keyed or non-repeatable
failure as a failure, not as cancellation — on purpose.

### Keys

`attempt.idempotencyKey` is the same on every attempt of one `perform`. It
is, in order:

1. the `idempotencyKey:` argument, when given — the key made with the
   intent (a checkout opened, an outbox entry), so that a double tap, a lost
   response or a relaunch reuses it;
2. when it runs in the task of a live attempt of an enclosing operation
   (`retry`, `perform`, an outbox delivery), a key derived from the
   enclosing operation's key, the operation's declared names
   (`backend.name`, `name`) and its occurrence among performs of that
   operation within the enclosing attempt — the same on every enclosing
   attempt, different for the second `perform` in a loop. The derivation is
   a fixed, versioned function (a SHA-256 name-based UUID under a Stoic
   namespace; never `Hasher`, never a call site), so it survives a relaunch
   and an app update. A `perform` in a *child* task of the enclosing attempt
   (a task group, `async let`) runs in no deterministic order, so it must be
   given `idempotencyKey:`; without one it is `.notRepeatable`, and
   `operation.key_ambiguous` is reported at error level. In a loop over data
   that may change between enclosing attempts, pass a key made from the
   item;
3. otherwise, a key drawn from the ambient random source when first read.

An outbox delivery (design/15) runs its attempts with the entry's key as the
enclosing key, so a keyed `perform` inside `deliver` sends a key that is the
same on every attempt and every relaunch, without the app passing it.

### One layer retries

Retrying at several layers multiplies load: three layers of three attempts
is twenty-seven. The layer that declared the backend knows how to retry it,
so:

- `perform` retries by its own policy, even inside another retry's attempt.
- When `perform` throws for any reason other than the caller's cancellation,
  or an enclosing deadline or attempt timeout cutting it off, it marks the
  live enclosing attempt, if there is one, **settled**. An `.unknown`
  outcome on a `.notRepeatable` operation, or on a `.keyed` one whose key
  Stoic made, always settles, however it ended; the settled check runs
  before an enclosing retry's rule that a timed-out attempt is transient.
  `perform` tells an enclosing cut from its own by the deadline that
  expired: an enclosing cut is the `Deadline.current` it found on entry
  (it applies its default only when there is none, so the two never
  coincide). `retry`, `Retrying`,
  `hedge` and the outbox's delivery loop never repeat a settled attempt,
  whatever their classifier says (`retry.stopped`, reason `inner_settled`),
  and a layer that stops on one settles its own enclosing attempt in turn,
  so a layer that collapsed to one attempt in between cannot let the one
  outside it repeat the attempt. That covers giving up after retrying,
  refusing to repeat, and rejections.
  The mark can only suppress retries: a task that outlives its attempt finds
  the context stale and marks nothing.
- A `perform` inside a live attempt of a `perform` on the **same backend**
  borrows the enclosing slot, one nested call at a time (a nested call that
  overlaps another takes its own slot, bounded by the deadline:
  `operation.nested_admission`, debug), passes no breaker of its own, and
  makes one attempt — the enclosing call is that backend's retry layer. An
  attempt cut by its own timer is a transient failure of that call, not a
  cancellation: the inner call made one attempt, and the `CancellationError`
  from the cancelled body is the timer, so `retryDecision` is `.retry`. The
  caller's cancellation still stops. The inner failure settles the enclosing
  attempt only when its own safety would have
  stopped it (an `.unknown` or `.executed` outcome on a `.notRepeatable`
  inner call; `.unknown` on a keyed inner call whose key Stoic made). On a
  `local` backend an inner write under an outer write is re-entrant on the
  writer lane; under an outer read it takes the lane. Waiting for a slot of
  backend B while holding one of backend A is allowed, bounded by the
  deadline.
- A plain `retry` inside `perform`'s operation collapses to one attempt, as
  any retry nested in another does (design/02).

So retrying moves to the declared backend: undeclared layers defer, and
nested declarations each retry their own backend once. Supervisor restarts
and `recur` are separate horizons with their own backoff and are not
affected.

### Order

For one call, outermost first: the default deadline, the retry loop, the
breaker, admission (for a local writer the writer lane, then the urgency's
partition), the attempt's timer, the operation. Each attempt runs under one
timer, at the earlier of its attempt timeout and the deadline; an operation
with no attempt timeout runs its attempts under the deadline's timer when
`perform` applied the default deadline (a caller's `withDeadline` already
enforces its own), so no wait outlives the deadline. Retry outside the breaker, so every attempt is
judged and an opening breaker stops the retries; breaker outside the
bulkhead, so a dead backend is refused before it takes a slot; the bulkhead
outside the attempt timeout, so waiting for a slot uses none of an attempt's
time.

### State

A `Backend` is a value; `Ambient.current.backends` holds its state, created
on first use and keyed by name: the breaker, the bulkhead with its urgency
partitions and writer lane, and the budget (`Ambient.budgets`). The process
shares one registry; `withTestAmbient` gives each test a fresh one, so a
test can neither see nor drain another's breaker, and work a test left
running keeps that test's registry. The registry holds at most 256
backends, evicting the least recently used one with nothing in flight; when
every one has work in flight it grows rather than evict, and reports
`operation.registry_full` once. Two backends with one name and a different
kind or capacity are a bug: the factories check every name against a
process-wide declaration table (name → kind, capacity), independent of the
registry and of tests, and report `operation.backend_conflict` at error
level (which fails a test under `withTestAmbient`); the first declaration
wins. Nothing crashes.

`perform` resolves its state once per call through a cache in the
declaration and builds its labels at declaration. On the first-attempt
success path it takes the bulkhead's, the breaker's and the budget's locks
and nothing else.

## Cancellation

The caller's cancellation cancels the attempt in flight and awaits it;
`perform` throws with `stop == .cancelled`, outcome as known. It never
sleeps once cancelled; a backoff it was in ends at once, with its budget
token refunded.

## Errors

`perform` throws `OperationError<Failure>`:

- `stop: .failed(error)` — the last attempt's failure was permanent, not
  eligible to repeat, or the schedule ran out on it.
- `stop: .rejected(r)` — the call was refused or ended by policy:
  `.circuitOpen`, `.bulkheadFull`, `.budgetExhausted`, or
  `.deadlineExceeded` (the deadline passed, or the next attempt could not
  finish before it); `last` is the last attempt's failure, if one ran.
- `stop: .cancelled` — the caller was cancelled.

`isCancellation` is true for `.cancelled`, except when the outcome is
`.unknown` on a `.keyed` or `.notRepeatable` operation (see Outcome).
`OperationError` is `Retryable` for a layer that did not see the settled
mark (an error carried across tasks): its `retryDecision` is `.stop` unless
the outcome is `.notExecuted` or the call deferred to an enclosing `perform`
on the same backend. A deferred call that stopped because its own attempt
timed out is `.retry` (the `CancellationError` is that timer, not the
caller). Otherwise the decision is the rejection's or `last`'s. A
cancellation in `last`, and a call the caller cancelled, are `.stop`.
`neverReachedBackend` is `outcome == .notExecuted`. An
operation that already retried is not retried again by whoever catches it.

## Isolation

The operation is `nonisolated(nonsending)`: it runs on the caller's actor,
may capture non-`Sendable` state, and its result need not be `Sendable`.
The attempt's timer runs it in a child task on the caller's actor, through
the hand-off `retry`'s attempt timeouts use for a non-`Sendable` operation. Declarations are `Sendable` values, meant
to be `static let`s.

## Failure modes

| What happens if…                                                          | Then                                                                                                       |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| the caller set no deadline                                                | the kind's and urgency's default total applies                                                             |
| the caller set a deadline                                                 | it applies, shorter or longer than the default                                                             |
| a `.notRepeatable` operation fails after reaching the backend             | it is not repeated: `stop == .failed`, `outcome == .executed`                                              |
| a `.notRepeatable` operation fails before reaching the backend            | it is repeated by the schedule                                                                             |
| an `NSError` in `NSURLErrorDomain` fails a `.notRepeatable` attempt       | it is classified as the `URLError` it is: nothing was sent, so it is repeated                              |
| a `.keyed` operation's drawn key is never read and it fails transiently   | it is not repeated, and `operation.key_unread` is reported                                                 |
| a `.keyed` operation is repeated                                          | every attempt sends the same key                                                                           |
| a `.keyed` operation is given a key                                       | every attempt sends that key                                                                               |
| two keyed performs run at one site in a loop inside one enclosing attempt | each has its own key, the same on every enclosing attempt                                                  |
| a keyed perform without a key runs in a child task of an enclosing attempt | `operation.key_ambiguous`; it is not repeated                                                             |
| a keyed perform's derived key after an app update and relaunch            | the same key as before                                                                                     |
| a keyed perform runs inside an outbox delivery                            | its key is derived from the entry's key: the same across attempts and relaunches                           |
| a keyed attempt reaches the backend and times out, and the schedule ends  | `outcome == .unknown`; never reported as cancellation                                                      |
| the caller is cancelled during a brief keyed attempt                      | the attempt finishes, shielded, within its timeout; no retry follows; the outcome is what it answered      |
| a keyed attempt's connection is lost after sending                        | `outcome == .unknown`, not `.executed`                                                                     |
| the caller is cancelled during a backoff                                  | the backoff ends at once, its token is refunded, `stop == .cancelled`                                      |
| `userInitiated` and background calls together fill what they may          | an `.interactive` call still gets a slot (capacity ≥ 2)                                                    |
| background work fills the backend                                         | it holds at most half the capacity                                                                         |
| more than 4 × capacity calls of one urgency wait                          | the next is refused at once: `.bulkheadFull`                                                               |
| a slot frees while an interactive and a background call wait              | the interactive call gets it                                                                               |
| two writes to a local backend run at once                                 | the second waits for the lane, holding no slot; reads are not held                                         |
| the breaker is open and the call is interactive                           | it fails at once: `.rejected(.circuitOpen)`                                                                |
| the breaker is open and the call is background                            | it waits the jittered `retryAfter`, at most three times, within the deadline, spending no attempt or token |
| a remote backend answers 404 (a permanent failure)                        | the breaker records a success                                                                              |
| a window full of slow `.long` calls                                       | the breaker does not open                                                                                  |
| the device is offline (`neverReachedBackend`)                             | the breaker records nothing                                                                                |
| `perform` is called inside another retry's attempt                        | `perform` retries by its own policy                                                                        |
| `perform` throws inside another retry's attempt                           | the attempt is settled; the enclosing retry does not repeat it                                             |
| an enclosing attempt's timeout cuts a `.readOnly` `perform` off           | the attempt is not settled; the enclosing retry may try again                                              |
| an enclosing attempt's timeout cuts a `.notRepeatable` `perform` off after it reached the backend | the attempt is settled; the enclosing retry does not repeat it                   |
| `perform` runs inside a `perform` on the same backend                     | it borrows the slot, makes one attempt; the outer call retries                                             |
| a same-backend inner perform's attempt times out                          | one attempt; the outer call retries it; the caller's cancellation still stops                              |
| a `local` or `compute` operation hangs with no caller deadline            | the default deadline's timer ends it                                                                       |
| an `OperationError` is caught by a retry that missed the settled mark     | it is not retried unless nothing was executed                                                              |
| a plain `retry` runs inside `perform`'s operation                         | it makes one attempt                                                                                       |
| the operation's ceiling is below the caller's urgency                     | it runs at its ceiling                                                                                     |
| a `.long` operation is slow                                               | no attempt timeout cuts it; the deadline bounds it                                                         |
| a test opens a breaker                                                    | the next test, under a fresh ambient, sees a closed one                                                    |
| two backends share a name with different kinds, even in different tests   | `operation.backend_conflict` at error level; the first wins                                                |
| the device is under thermal pressure                                      | delays stretch for utility and background work only                                                        |

## Events

The derived stages report under their own names (design/02, design/10),
labelled `<backend>.<operation>`. New:

| Event                                  | Level   | Fields                            |
| -------------------------------------- | ------- | --------------------------------- |
| `operation.key_unread`                 | error   | `operation`                       |
| `operation.key_ambiguous`              | error   | `operation`                       |
| `operation.outcome_unknown`            | warning | `operation`, `attempts`, `stop`   |
| `operation.urgency_capped`             | debug   | `operation`, `urgency`, `ceiling` |
| `operation.backend_conflict`           | error   | `backend`, `kind`, `capacity`     |
| `operation.registry_full`              | warning | `backends`                        |
| `operation.nested_admission`           | debug   | `operation`                       |
| `retry.stopped` reason `inner_settled` | info    | (design/02's fields)              |

## Testing

- The derivation table as a golden test: `policy(at:)` printed for every
  kind × urgency × length, so a changed default is a reviewed diff.
- Every failure-mode row, on `TestClock`, with scripted operations.
- The one-layer rule as a property: random nestings of `perform`, `retry`
  and `Retrying` over a failing backend never call it more often than the
  innermost declared schedule allows, and a settled attempt is never
  repeated.
- Outcome as a property: over random scripts of failures, timeouts and
  cancellations, `.unknown` is reported exactly when an attempt that reached
  the backend was cut off and not settled later.
- Simulation: many callers at mixed urgencies over a backend that slows and
  fails, across seeds: an interactive call gets a slot within its deadline
  whenever capacity ≥ 2 and fewer than *c* interactive calls are in flight;
  nothing outlives its deadline; nothing leaks.
- An allocation benchmark for `perform`'s first-attempt-success path, for a
  `remote` and a `local` backend.
- The ideal scenario above, on virtual time (`OperationScenarioTests`), and
  as the Operations section of `Examples/Tour`.

## Inside StoicHTTP

An `HTTPClient` call inside a live `perform` attempt defers to it: it skips
its own retry, breaker, bulkhead and rate limiter, and is transport plus
classification. One host is one `Backend`. When a request carries an
`Idempotency-Key`, a `409` or `425` answer ("in progress": an earlier
attempt with this key is still being processed) is transient, retried no
sooner than 1 s, so a retry after a timeout does not report a charge that
succeeded as a failure. Both are read from the error: `HTTPError` says it is
transient (`retryDecision`, with the key it knows the request carried), and
says what it proves (`neverReachedBackend`), so the operation's classification
and the client's own retry cannot disagree.

| What happens if…                                                   | Then                                                         |
| ------------------------------------------------------------------ | ------------------------------------------------------------ |
| an `HTTPClient` call runs inside a `perform` attempt               | the client makes one attempt, through no breaker or bulkhead |
| a keyed request's retry is answered `409` or `425`                 | it is retried after at least 1 s                             |

## As built

The contract above is implemented as written; where the code had to choose,
it chose this.

- **The settled mark passes outward.** A `retry` (or `Retrying`, or `hedge`)
  that stops on a settled attempt settles the attempt it runs in, if any.
  Without it, `retry { retry { perform } }` repeated the `perform`: the middle
  layer collapsed to one attempt and threw, and the outer one saw an
  ordinary failure. The property test of the one-layer rule found nothing
  else.
- **The derived key is a version 8 UUID.** RFC 9562 gives version 5 to
  names hashed with SHA-1 and version 8 to custom ones, its own example
  being SHA-256; the derivation (`IdempotencyKey.derived(fromEnclosing:…)`,
  frozen as version 1 under the namespace
  `5e1f0c3a-7b2d-4c8e-9a61-3f4d2b8c0e17`) hashes the enclosing key, the two
  names, each length-prefixed, and the occurrence as eight big-endian bytes.
- **A same-backend inner call defers its classification.** Its
  `OperationError` is marked as made for the enclosing call, which looks
  through it to the inner failure, as if the inner layer were not there; any
  other `OperationError` stands for itself unless nothing was executed. An
  attempt the inner call's own timer cut off is not looked through: the
  `CancellationError` underneath is that timer, and the error's own decision
  is to retry it.
- **The client asks the core, through a `package` function,** whether the
  task runs inside a live attempt of a `perform` (`PerformAttempt.isLive`:
  the attempt's context is live and carries a live perform frame). A task an
  attempt left running finds the context stale and is not inside it. design/19
  (As built, Inside a `perform` attempt) says what the client then leaves out.
- **A shielded attempt runs in a task of its own.** Cancelling a task
  cancels every child task, shield or no shield, and a shield inside the
  attempt would stop its timer as well; so a brief keyed or non-repeatable
  attempt runs in a task Stoic starts and the caller awaits, shielded,
  under a timer at the earlier of its attempt timeout and the deadline. It is
  never left running.
- **"In the task of the attempt"** is decided by the task's identity
  (`withUnsafeCurrentTask`, hashed and nothing else). A deadline's single
  child task carries the attempt on, so a `perform` inside
  `retry(attemptTimeout:)` or a `withTimeout` in an attempt counts its
  occurrence; a task group or an `async let` does not.
- **A forced-open breaker** has no `retryAfter`; a `.utility` or
  `.background` call waits for its state to change, as for a half-open
  breaker's verdict, bounded by the half-open timeout, at most three times.
- **A wait for a slot that the caller's deadline ends** is that deadline
  cutting the call off: it does not settle the enclosing attempt.
- **`OperationError.idempotencyKey`** is the key every attempt sent: a given
  key, or a made one that an attempt read. A made key nobody read was never
  sent, and is `nil` (with `operation.key_unread`, also reported when such a
  call succeeds).
- **`operation.backend_conflict`** describes the refused declaration (its
  kind and capacity); the backend returned is the first declaration's.
- **The bug events fail a test** under `withTestAmbient` (a test that
  provokes one on purpose wraps it in `withKnownIssue`); `simulate` and the
  `.stoic` trait give each run a fresh registry too, but record no issue.
- **The simulation runs without early timers.** With them, virtual time
  passes while a woken task waits to run, as on a starved CPU, and a
  deadline is cooperative: "nothing outlives its deadline" would measure the
  scheduler, not `perform`.
- **The outbox's delivery loop** is `retry` with the entry's key as its
  operation's key, through a `package` overload of `retry`.
- **The first-attempt-success path allocates 25 times (the median call),** on
  `remote` and `local` alike: each attempt and its timer are two tasks of a task
  group, which is most of it. `Benchmarks/allocations.json` gates it.

## Later

- **Hedging.** For `.readOnly`, `.interactive` calls on a `remote` backend,
  off expensive and constrained paths, after an observed latency
  percentile; the copy takes a slot without waiting or does not start;
  cancelled and timed-out copies recorded as censored samples. It needs
  concurrent copies, so a `@Sendable` operation, which is why v1 does not
  have it.
- **Adaptive attempt timeouts.** Tighten the ceiling to about 3 × the
  observed p99 with at least 200 samples, a floor of 2 s for `remote`; after
  one timeout in a call, its later attempts use the ceiling; a network-path
  change or an app suspension clears the record. Earned with real
  distributions from the pilot first.
- **StoicHTTP on operations.** Each host a `Backend.remote` and each
  request's repeat safety from RFC 9110 and its key; platform knobs follow
  urgency (`networkServiceType`, expensive and constrained access,
  `waitsForConnectivity`). A server's published rate limit is then the
  second declared number.
- **Preemption for compute.** A lower-urgency holder of a `.readOnly` or
  `.idempotent` operation cancelled (cause `.preempted`, not counted against
  its schedule) when an interactive call would wait.
- **A network-path change** moves every open `remote` breaker to half-open.
- **The half-open probe prefers background calls,** so a person's request
  is not the one that tests a recovering backend.
- **Store errors classified.** `NSSQLiteErrorDomain` busy and locked as
  transient in `StoicFoundation`, with the platform error catalog (DESIGN.md,
  plan item 8).

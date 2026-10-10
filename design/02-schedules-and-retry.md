# 02 · Schedules and retry

Retries are policy, not loops. A `Schedule` is a value that decides, attempt
by attempt, whether to go again and how long to wait. `retry` and `recur`
run an operation under one. Budgets make sure that retrying can never turn an
outage into a bigger one.

## Origin

- **Effect.** `Schedule` as a composable value: exponential, spaced,
  recurs, union and intersection, jitter.
- **AWS Builders' Library.** Five layers each retrying three times multiply
  load on a failing database 243-fold. Retry at one layer; cap retries with a
  local token bucket; use capped exponential backoff with jitter; retry only
  idempotent operations; never retry caller errors; honour the server's
  `Retry-After`.
- **Finagle, gRPC, Envoy.** Retry budgets as a fraction of recent requests,
  not a per-call count.
- **In apps.** Retry loops with a fixed count and a fixed delay, no jitter,
  and no awareness of cancellation or of how much time the caller has left.
  Their numbers are written in the code, the comments and the docs, and
  drift apart.
## API

```swift
public struct Schedule: Sendable, CustomStringConvertible {
    // Bases
    public static func fixed(_ delay: Duration) -> Schedule
    public static func exponential(base: Duration, factor: Double = 2) -> Schedule
    public static func fibonacci(base: Duration) -> Schedule
    public static func delays(_ delays: [Duration]) -> Schedule   // e.g. [10 s, 60 s, 300 s]
    public static let immediate: Schedule

    // Bounds (every schedule passed to retry must have at least one; see "Bounded")
    public func upTo(attempts: Int) -> Schedule
    public func upTo(elapsed: Duration) -> Schedule
    public func capped(at maximum: Duration) -> Schedule

    // Shape
    public func jittered(_ jitter: Jitter = .full) -> Schedule    // .full, .equal, .decorrelated, .none
    public func union(_ other: Schedule) -> Schedule              // continue if either; shorter delay
    public func intersection(_ other: Schedule) -> Schedule       // continue if both; longer delay
    public func andThen(_ next: Schedule) -> Schedule
    public func resetting(after quiet: Duration) -> Schedule      // for long-lived recur/supervision

    // Pure stepping, exposed for tests and tooling
    public func makeIterator(random: RandomSource) -> Iterator
}

public struct Attempt: Sendable { public let number: Int; public let elapsed: Duration }

public enum RetryDecision: Sendable {
    case retry                    // let the schedule decide the delay
    case retry(after: Duration)   // server said Retry-After; still capped and deadline-checked
    case stop                     // permanent: rethrow now
}

public protocol Retryable: Error { var retryDecision: RetryDecision { get } }

public nonisolated(nonsending) func retry<R, Failure: Error>(
    _ schedule: Schedule,
    budget: RetryBudget? = nil,
    when classify: (Failure, Attempt) -> RetryDecision = defaultClassification,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R

public nonisolated(nonsending) func recur<Failure: Error>(
    _ schedule: Schedule,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> RecurDecision
) async throws(Failure)

public final class RetryBudget: Sendable {
    public init(ratio: Double = 0.1, minimumPerSecond: Double = 1, window: Duration = .seconds(10))
}
```

A call site with its whole budget stated once:

```swift
let start = Schedule.fixed(.milliseconds(650)).upTo(attempts: 2)
try await withTimeout(start.worstCase(attemptTimeout: .seconds(2.5))) {
    try await retry(start) { _ in try await microphone.start() }
}
```

`worstCase(attemptTimeout:)` derives the outer watchdog from the schedule, so
the numbers that drifted apart in three places cannot drift at all.

## Semantics

**Order of checks per failed attempt.** (1) The error is `CancellationError`
or the task is cancelled → rethrow, never retry. (2) The error is a `Defect`
→ rethrow. (3) Classification says `.stop` → rethrow. (4) The schedule says
stop → rethrow. (5) The budget refuses → rethrow, `retry.budget_exhausted`.
(6) `now + delay` is at or past `Deadline.current` (or leaves less than the
last attempt's duration) → rethrow, `retry.deadline_skip`. (7) Sleep on the
ambient clock — cancellable — then attempt again. Always the last error is
rethrown, unwrapped.

**Default classification.** `Retryable` errors decide for themselves.
`Defect`s and cancellation stop. Everything else retries — the common
expectation — because the schedule is always bounded and the budget, when
present, caps the blast radius. Teams that want "retry only what is known to
be transient" pass `when: .onlyRetryable`.

**Bounded.** A schedule with neither an attempt nor an elapsed bound is
rejected by `retry` at runtime with a precondition (debug) and capped at 10
attempts with an error event (release); the lint rule `stoic.unbounded-retry`
catches the literal case at build time. `recur` may be unbounded — polling
forever is legitimate — but only inside a scope or supervisor that can stop
it (lint: `stoic.unowned-recur`).

**Arithmetic.** Delays saturate instead of overflowing: `Duration`
multiplication traps on overflow, and an exponential schedule at attempt 80
would. All schedule math is done in saturating integer nanoseconds and
clamped to `capped(at:)` (default cap: 5 minutes for exponential bases).

**Jitter.** Full jitter (`random(0...delay)`) is the default, per AWS.
Decorrelated jitter (`min(cap, random(base...previous × 3))`) is offered for
long tails. Jitter never yields a negative or above-cap delay, and draws
from a per-call-site random stream (DESIGN.md, Ambient) so a seed reproduces
it under any interleaving.

**Retry-After.** `.retry(after:)` overrides the schedule's delay for that
attempt but not its bounds: capped, budget-checked and deadline-checked.

**Budgets.** A token bucket per dependency, shared by every `retry` aimed at
it. Each first attempt deposits `ratio` tokens; each retry withdraws one; a
floor of `minimumPerSecond` keeps low-traffic paths retryable. Under a full
outage at most `ratio` extra load is added, however many callers retry. The
budget is a `Mutex`-guarded struct: no actor hop on the hot path.

**Hedging is not retry.** Starting a second attempt before the first fails
lives in design/03 and draws from the same budget.

**Recur.** `recur` runs an operation on a schedule after _success_ (polling, a periodic update check): the decision type lets the operation stop
(`.done`), continue, or ask for a sooner check (`.again(after:)`). Failures
propagate unless the caller wraps the body in `retry`. `resetting(after:)`
lets a long-lived loop start its backoff over after a quiet period.

## Failure modes

| What happens if…                                   | Behaviour                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------ |
| the operation succeeds on attempt n                | Result returned; `retry.succeeded` with n (only when n > 1)                    |
| every attempt fails                                | Last error rethrown; `retry.exhausted` with attempts and elapsed               |
| the task is cancelled during the backoff sleep     | Sleep throws; `CancellationError` propagates; no further attempt               |
| the error is a `Defect`                            | Rethrown immediately; `retry.defect` at error level                            |
| the budget is empty                                | Last error rethrown; `retry.budget_exhausted`                                  |
| the next attempt cannot finish before the deadline | Last error rethrown without sleeping; `retry.deadline_skip`                    |
| the server sends Retry-After longer than the cap   | The cap wins; `retry.after_capped`                                             |
| the schedule is unbounded                          | Debug: precondition failure. Release: capped at 10 attempts, `retry.unbounded` |
| two layers both retry the same dependency          | Not detectable at runtime; the shared budget bounds the multiplication         |

## Events

`retry.attempt_failed` (attempt, error type, decision, next delay),
`retry.succeeded`, `retry.exhausted`, `retry.budget_exhausted`,
`retry.deadline_skip`, `retry.defect`, `retry.unbounded`, `retry.after_capped`.

## Testing

- Property tests over random schedules: delays are within `[0, cap]`, never
  negative, attempt bounds are exact, `union`/`intersection` obey their laws
  (commutative, `upTo` monotone), and saturating math never traps across the
  whole attempt range.
- A seed reproduces the identical delay sequence under randomly interleaved
  concurrent retries.
- Budget property: over any request sequence, retries ≤ ratio × first
  attempts + floor × window.
- Virtual-clock tests for every failure-mode row, with fault-injected
  operations (`fail(times:)`, `fail(with: Retryable(.stop))`, `hang`).

## Non-goals

Retrying non-idempotent operations safely (the caller's responsibility, with
idempotency keys); retry inside `AsyncSequence` operators (async-algorithms'
domain).

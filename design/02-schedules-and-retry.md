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
public struct Schedule: Sendable, Hashable {          // data: an inspectable tree, not closures
    public static func fixed(_:) / linear(_:) / exponential(base:factor:) / fibonacci(_:)
    public static func decorrelated(base:cap:)
    public static func delays(_ delays: [Duration]) -> BoundedSchedule
    public func capped(at:) / jittered(_:) / upTo(elapsed:) / union(_:) / intersection(_:) / andThen(_:)
    public func attempts(_ count: Int) -> BoundedSchedule      // the only way to bound a schedule
    public func maximalDelays(limit:) -> [Duration]
}

public struct BoundedSchedule: Sendable, Hashable {   // what retry accepts
    public var maximumAttempts: Int
    public var maximumTotalDelay: Duration
    public func worstCase(attemptTimeout: Duration) -> Duration
}

public enum RetryDecision { case retry, retryAfter(Duration), stop }
public protocol Retryable: Error { var retryDecision: RetryDecision { get } }
public struct RetryClassifier<Failure: Error> { static var standard, transientOnly, never; init(_:) }
public enum RetryNesting { case singleAttempt, allow }
public struct RetryBudget { static let perCallSite, unlimited; static func named(_:); init(ratio:reservePerSecond:reserveCapacity:) }

// Inline: runs on the caller's actor, may capture anything.
public nonisolated(nonsending) func retry<R, Failure: Error>(
    _ schedule: BoundedSchedule, budget: RetryBudget = .perCallSite,
    classify: RetryClassifier<Failure> = .standard, nesting: RetryNesting = .singleAttempt,
    label: String? = nil, operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R

// Each attempt bounded by its own timeout; runs as a child task, inheriting the caller's actor.
public nonisolated(nonsending) func retry<R: Sendable, Failure: Error>(
    _ schedule: BoundedSchedule, attemptTimeout: Duration, …,
    @_inheritActorContext operation: @escaping @Sendable @isolated(any) (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R
```

A call site with its whole budget stated once, and the outer watchdog
derived from it rather than written down separately:

```swift
let start = Schedule.fixed(.milliseconds(650)).attempts(2)
try await withTimeout(start.worstCase(attemptTimeout: .milliseconds(2500))) {
    try await retry(start, attemptTimeout: .milliseconds(2500)) { _ in try await microphone.start() }
}
```

## Semantics

**Bounded by type.** `retry` takes a `BoundedSchedule`, and the only ways to
make one are `attempts(_:)` and `delays(_:)`. An unbounded retry does not
compile; there is no runtime cap that behaves differently in debug and
release. `upTo(elapsed:)` is an extra stop condition, not a bound: a schedule
with no delay and only an elapsed limit could spin.

**Schedules are data.** A schedule is a tree of nodes interpreted by a
stepper, so it prints, compares, reports its worst case, and steps the same
way in a test as in production. Full and equal jitter only ever shorten a
delay, so a cap holds whichever order `capped` and `jittered` are written
in. `capped(at:)` directly after a base replaces the base's default cap
(exponential and Fibonacci default to five minutes).

**Order of checks after a failed attempt.** (1) The task running the retry
was cancelled → rethrow; a cancelled *attempt* (its own timeout fired) is not
a cancelled retry. (2) Nested inside another retry's attempt with
`.singleAttempt` → rethrow, `retry.nested`. (3) The classifier says stop (a
`Defect` always does) → rethrow. (4) The schedule is exhausted → rethrow.
(5) The next attempt could not finish before `Deadline.current`, assuming it
takes as long as the last → rethrow, `retry.deadline_skip`. (6) The budget has
no token → rethrow, `retry.budget_exhausted`. Otherwise sleep (cancellable)
and try again. The error is always the last attempt's, unwrapped; cancelled
during the backoff, retry rethrows that last real failure.

**Default classification.** `.standard` lets `Retryable` errors decide,
stops on defects, `DecodingError` and `EncodingError` (the same bytes fail
the same way), and on rejections retrying cannot help (an exhausted budget,
a shutdown, a wedged label), honours a rejection's `retryAfter`, treats a
timed-out attempt as transient, and retries anything else. Review argued for
"transient only" as the default; the counterweight is that every other
safety net is on by default — the schedule is bounded by type, the budget is
per call site, nested retries collapse — so an unknown error costs a few
bounded attempts, not an outage. `.transientOnly` is one word away.

**Nesting.** A task-local marks a running attempt. A `retry` started inside
one makes a single attempt by default (`retry.nested`), enforcing AWS's
"retry at one layer" at runtime instead of documenting it. `.allow` opts out
for layers that retry different dependencies.

**Budgets.** On by default, one per call site. Each first attempt deposits
`ratio` (0.2) earned tokens; a reserve refills at `reservePerSecond` (1) up to
`reserveCapacity` (10) so a quiet app can still retry; each retry spends one.
Under a full outage, retries add at most 20% load plus one per second per
call site. Named budgets (`.named("api.example.com")`) share one bucket
across call sites hitting one dependency. Earned tokens are capped so a long
success streak cannot bank a burst for the next outage.

**Arithmetic.** Delays saturate instead of trapping (`Duration`
multiplication traps on overflow), so an exponential at attempt 300 is just
its cap.

**Jitter and seeds.** Full jitter is opt-in per schedule (`.jittered()`).
Randomness comes from the ambient source, one stream per call site, so a seed
reproduces a run's delays; in production the source is the system generator
and concurrent callers draw independently.

**Retry-After.** `.retryAfter(d)` replaces the schedule's delay for that
retry but not its bound, its budget or the deadline, and is capped at five
minutes.

**Recur.** `recur` (next) runs an operation on a schedule after *success*
— polling, periodic refresh — and may be unbounded, but only inside a scope
or supervisor that can stop it.

## Failure modes

| What happens if…                                   | Behaviour                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------ |
| the operation succeeds on attempt n                | Result returned; `retry.succeeded` with n (only when n > 1)                    |
| every attempt fails                                | Last error rethrown; `retry.exhausted` with attempts and elapsed               |
| the task is cancelled during the backoff sleep     | The last attempt's error is rethrown (typed); no further attempt              |
| the error is a `Defect`                            | Rethrown immediately; `retry.defect` at error level                            |
| the budget is empty                                | Last error rethrown; `retry.budget_exhausted`                                  |
| the next attempt cannot finish before the deadline | Last error rethrown without sleeping; `retry.deadline_skip`                    |
| the server sends Retry-After longer than the cap   | The cap wins; `retry.after_capped`                                             |
| the schedule is unbounded                          | Does not compile: `retry` takes only a `BoundedSchedule`                       |
| a retry runs inside another retry's attempt        | One attempt only, `retry.nested`, unless `nesting: .allow`                     |
| an attempt's own timeout fires                     | Counted as transient and retried; `timed_out=true` on the event               |
| the error is a `DecodingError`                     | Not retried (`.standard`): the same bytes fail the same way                   |

## Events

`retry.attempt_failed` (attempt, error type, decision, next delay),
`retry.succeeded`, `retry.exhausted`, `retry.budget_exhausted`,
`retry.deadline_skip`, `retry.defect`, `retry.permanent`, `retry.nested`,
`retry.after_capped`.

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

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

public struct Attempt: Sendable, Hashable {           // what each attempt is handed
    public let number: Int, elapsed: Duration
    public var idempotencyKey: IdempotencyKey             // one per operation: shared by every attempt
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
with no delay and only an elapsed limit could spin. It stops rather than take
a delay that would end past the limit, so a ten-second limit never sleeps for
a minute.

**Schedules are data.** A schedule is a tree of nodes interpreted by a
stepper, so it prints, compares, reports its worst case, and steps the same
way in a test as in production. Full and equal jitter only ever shorten a
delay, so a cap holds whichever order `capped` and `jittered` are written
in. `capped(at:)` directly after a base replaces the base's default cap
(exponential and Fibonacci default to five minutes). `decorrelated` needs a
positive base (each of its delays grows from the last, so a zero base would
never back off) and raises a cap below the base to it.

**Order of checks after a failed attempt.** (0) A declared operation
inside the attempt gave up and *settled* it (design/22) → rethrow,
`retry.stopped` with reason `inner_settled`, whatever the classifier would
say; a retry that stops so settles its own enclosing attempt in turn, so a
layer that collapsed to one attempt cannot let the one outside it repeat
what the operation refused to. (1) The task running the retry
was cancelled → rethrow; a cancelled *attempt* (its own timeout fired) is not
a cancelled retry. (2) Nested inside another retry's attempt with
`.singleAttempt` → rethrow, `retry.nested`. (3) The classifier says stop (a
`Defect` always does) → rethrow. (4) The schedule is exhausted → rethrow.
(5) The next attempt could not finish before `Deadline.current`, assuming it
takes as long as the last → rethrow, `retry.deadline_skip`. (6) The budget has
no token → rethrow, `retry.budget_exhausted`. Otherwise sleep (cancellable)
and try again. Between (4) and (5), a `retryAfter` that comes from an open
circuit breaker and is longer than the schedule's next delay stops the retry
(`retry.breaker_open`), and a shorter one is jittered upward by up to a tenth
(design/10). The error is always the last attempt's, unwrapped.

**What `retry` throws when it stops.** `retry` throws its operation's error
type, so it cannot say *why* it stopped: cancelled during the backoff, it
rethrows the last attempt's real failure (never a `CancellationError`, which
`Failure` may not be able to hold), and the token it spent on the retry that
never happened goes back to the budget; stopped by the deadline or the
budget, it rethrows that same failure. The event says which. A caller that
must tell a refusal from the dependency failing checks `Task.isCancelled`,
or uses `Retrying` in a pipeline, whose `PolicyError` reports those stops as
`.rejected(.cancelled)`, `.rejected(.deadlineExceeded)` and
`.rejected(.budgetExhausted)` (design/10).

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

**Jitter and seeds.** `exponential` and `fibonacci` are fully jittered by
default (`.unjittered()` turns it off, `.jittered(_:)` changes it); `fixed`
is not. Randomness comes from the ambient source, one stream per call site,
so a seed reproduces a run's delays; in production the source is the system
generator and concurrent callers draw independently.

**A struggling device.** A hot device, one in Low Power Mode or one short of
memory stretches every delay (`SystemConditions.backoffFactor`, up to eight
times), and the schedule's cap is the last word: a schedule capped at one
second never waits longer, whatever the device, while an uncapped fixed delay
stretches. `worstCase(attemptTimeout:)` includes the stretch, so a watchdog
derived from it never cuts a retry short on a hot device; a healthy one
finishes far sooner.

**Retry-After.** `.retryAfter(d)` replaces the schedule's delay for that
retry but not its bound, its budget or the deadline. The device's conditions
stretch it as they stretch any delay, and the five-minute cap is the last
word: whatever the device is going through, the wait is never longer than it.

**Idempotency keys.** `attempt.idempotencyKey` is the key of the operation
an attempt belongs to: one `retry` call is one operation, so every attempt
sends the same key, and a key drawn afresh per attempt (the double charge it
exists to prevent) cannot happen through it. Each run of `recur` is an
operation of its own and gets its own key. The key is drawn on first read,
exactly as `IdempotencyKey.random()` would draw it at the `retry`'s call
site: an operation that never asks draws nothing, so the ambient random
sequence (and every seeded test) is unchanged by its existence. Attempts
compare by number and elapsed time; the operation is identity, not value.

**Operations inside operations.** A `retry`, `hedge` or `recur` run started
while another operation's attempt is running is a *sub-operation* of it, and
its key is derived from the enclosing operation's key, its own call site and
its ordinal there, never drawn afresh. This is what makes the rule hold
across layers: when a library's `retry` (sending its `attempt.idempotencyKey`)
is called from an app's `retry`, the inner one collapses to one attempt and
the retrying happens at the outer layer; a key drawn per inner `retry` call
would be new on every outer attempt. The ordinal is the number of
sub-operations the same line had already started in the same attempt, so a
loop's n-th call gets the same key on every attempt that reaches it the same
way, and sub-operations on other lines never shift it. Two cases need a key
from the data instead (`IdempotencyKey(rawValue: item.id)`): a loop whose
items change between attempts, and sub-operations started concurrently from
one line, which take ordinals in the order they start. The attempts of a
`hedge` count their ordinals separately, so its copies, being one
operation, give a sub-operation one key.

**Recur.** `recur` (next) runs an operation on a schedule after *success*
— polling, periodic refresh — and may be unbounded, but only inside a scope
or supervisor that can stop it.

## Failure modes

| What happens if…                                   | Behaviour                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------ |
| the operation succeeds on attempt n                | Result returned; `retry.succeeded` with n (only when n > 1)                    |
| every attempt fails                                | Last error rethrown; `retry.exhausted` with attempts and elapsed               |
| the task is cancelled during the backoff sleep     | The last attempt's error is rethrown (typed); no further attempt; the budget token is returned; `retry.cancelled` |
| the error is a `Defect`                            | Rethrown immediately; `retry.defect` at error level                            |
| the budget is empty                                | Last error rethrown; `retry.budget_exhausted`                                  |
| the next attempt cannot finish before the deadline | Last error rethrown without sleeping; `retry.deadline_skip`                    |
| the next delay would end past `upTo(elapsed:)`     | Last error rethrown without sleeping; `retry.exhausted`                        |
| the device is hot, saving power or short of memory | Delays stretched up to 8×, never past the schedule's cap; `worstCase` includes it |
| the server sends Retry-After longer than the cap   | The cap wins; `retry.after_capped`                                             |
| the schedule is unbounded                          | Does not compile: `retry` takes only a `BoundedSchedule`                       |
| `decorrelated` is given a base that is not positive | Precondition failure at construction: it could never back off                  |
| a retry runs inside another retry's attempt        | One attempt only, `retry.nested`, unless `nesting: .allow`                     |
| an attempt's own timeout fires                     | Counted as transient and retried; `timed_out=true` on the event               |
| the error is a `DecodingError`                     | Not retried (`.standard`): the same bytes fail the same way                   |
| every attempt sends `attempt.idempotencyKey`       | The same key on every attempt; drawn once, on first read                       |
| the same call site retries twice                   | Each `retry` is its own operation, with its own key                            |
| each run of `recur` sends `attempt.idempotencyKey` | A new key per run: each run is its own operation                               |
| a nested retry sends its `attempt.idempotencyKey`  | The same key on every outer attempt: derived from the outer operation's key   |
| one attempt starts several operations from one line | A different key for each, the same for the n-th on every attempt              |
| a declared operation inside the attempt settled it  | Not repeated, whatever the classifier says; `retry.stopped`, and the mark passes to the enclosing attempt |

## Events

`retry.attempt_failed` (attempt, error type, decision, next delay),
`retry.succeeded`, `retry.exhausted`, `retry.budget_exhausted`,
`retry.deadline_skip`, `retry.defect`, `retry.permanent`, `retry.nested`,
`retry.after_capped`, `retry.cancelled` (debug: the task running the retry
was cancelled), `retry.breaker_open` (an open breaker's wait was longer than
the schedule's), `retry.stopped` (reason `inner_settled`: a declared
operation inside the attempt settled it, design/22).

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

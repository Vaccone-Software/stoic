# 10 · Resilience policies

Retries (design/02) decide what to do after a failure. These policies decide
whether to call at all: a circuit breaker stops calling a dependency that is
failing, a bulkhead stops one slow dependency from consuming every task, a
rate limiter keeps a caller inside what a service will accept, and a hedge
spends a little extra load to cut the slow tail. Each is a small value you
construct once, share, and run operations through; a pipeline composes them
without nesting their errors.

## Origin

- **Polly v8.** Resilience _pipelines_: an ordered list of strategies (timeout,
  retry, circuit breaker, hedging, rate limiter), each wrapping the next, with
  the order mattering and documented. Its breaker judges a failure _ratio_
  over a _sampling duration_ once a _minimum throughput_ is reached, then
  breaks for a _break duration_. Stoic's pipeline is the same idea; its
  stages share one error type, so the order costs nothing in types.
- **resilience4j.** The richest breaker vocabulary: count-based and time-based
  sliding windows, a failure-rate threshold _and_ a slow-call-rate threshold
  with a slow-call duration, `minimumNumberOfCalls`, a limited number of
  permitted calls in the half-open state, and a configurable wait in the open
  state. Also the bulkhead (`maxConcurrentCalls`, `maxWaitDuration`) and the
  rate limiter (`limitForPeriod`, `limitRefreshPeriod`, `timeoutDuration`),
  and the decorator order Retry → CircuitBreaker → RateLimiter → TimeLimiter →
  Bulkhead → call. Stoic borrows the vocabulary and the order.
- **Envoy.** Circuit breaking as hard _limits_ (connections, pending requests,
  requests) that shed load rather than queue it; outlier detection that ejects
  a host for a time that _grows with each repeated ejection_; a local token
  bucket rate limit. Stoic's bulkhead has Envoy's "pending requests" bound,
  and the breaker's open duration grows the same way.
- **AWS Builders' Library.** "Timeouts, retries, and backoff with jitter":
  retry at one layer, cap retries with a token bucket, jitter everything that
  waits; and the warning that circuit breakers introduce _modal behaviour_
  that is hard to test and can lengthen recovery. Stoic answers the warning
  with a breaker whose every mode, transition and rejection is an event and a
  test on virtual time, whose recovery is probed gradually, and whose open
  periods are jittered so a fleet does not re-converge on a dependency at one
  instant.
- **tower (Rust).** Policies as composable layers (`ServiceBuilder`, outermost
  first), `ConcurrencyLimit`, `RateLimit`, `LoadShed` (reject instead of
  queue), `Retry` with a budget, and `Hedge`. Stoic's `Pipeline` is
  `ServiceBuilder`; its bulkhead with a zero queue is `LoadShed`.
- **"The Tail at Scale" (Dean and Barroso).** Hedged requests (design/03).
- **In apps.** A boolean `isOffline` or `failureCount` property on a client
  class, reset by a timer nobody remembers to cancel; a `DispatchSemaphore`
  around a network call; a `lastRequestDate` compared to `Date()`. Each
  breaks under concurrency, on a wake from sleep, or in a test that cannot
  move time.

Facts about the systems above are from prior knowledge, not re-checked.

## API

```swift
// Every policy runs an operation inline, on the caller's actor.
public protocol Policy: Sendable {
    nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R
}

public final class CircuitBreaker: Policy {
    public enum State: Sendable, Hashable { case closed, open, halfOpen }
    public enum Window: Sendable, Hashable { case calls(Int), time(Duration) }
    public struct OpenDuration: Sendable, Hashable {
        public var initial, maximum: Duration; public var factor, jitter: Double; public var resetAfter: Duration
        public static func fixed(_: Duration, jitter: Double = 0.2) -> OpenDuration
        public static func exponential(initial: Duration = .seconds(30), factor: Double = 2,
                                       maximum: Duration = .seconds(300), jitter: Double = 0.2,
                                       resetAfter: Duration? = nil) -> OpenDuration     // resetAfter defaults to maximum
        public static let standard: OpenDuration
    }
    public struct Configuration: Sendable {
        public var window: Window                     // default .time(.seconds(60))
        public var minimumCalls: Int                  // 10
        public var failureRateThreshold: Double       // 0.5, trips at >=
        public var slowCallDuration: Duration         // 10 s
        public var slowCallRateThreshold: Double      // 1.0, trips at >=
        public var openDuration: OpenDuration         // 30 s, ×2 per repeated trip, ≤ 5 min, 20% jitter
        public var halfOpenProbes: Int                // 1
        public var halfOpenTimeout: Duration          // 60 s
        public var recordWhen: @Sendable (any Error) -> Bool    // default CircuitBreaker.countsByDefault
    }
    public struct Snapshot: Sendable { state, calls, failures, slowCalls, failureRate, slowCallRate, trips, retryAfter }

    public init(label: String, _ configuration: Configuration = .init(), clock: AnyClock? = nil)
    // (call-site `fileID`/`line` are captured too: they key the jitter stream.)
    public let label: String
    public var state: State { get }
    public var snapshot: Snapshot { get }
    public var stateChanges: AsyncStream<State> { get }     // .bufferingNewest(16), one stream per access
    public nonisolated(nonsending) func execute<R, Failure: Error>(_:) async throws(PolicyError<Failure>) -> R
    public func forceOpen(); public func forceClosed(); public func reset()
    public static func countsByDefault(_ error: any Error) -> Bool
}

public final class RateLimiter: Policy {
    public init(rate: Int, per interval: Duration = .seconds(1), burst: Int? = nil,
                queueLimit: Int? = 100, label: String, clock: AnyClock? = nil)
    public nonisolated(nonsending) func acquire(permits: Int = 1) async throws(Rejection)
    public func tryAcquire(permits: Int = 1) -> Bool
    public nonisolated(nonsending) func execute<R, Failure: Error>(_:) async throws(PolicyError<Failure>) -> R
    public var availablePermits: Int { get }; public var waiterCount: Int { get }
}

public final class Bulkhead: Policy {
    public init(maxConcurrent: Int, queueLimit: Int = 0, label: String)
    public nonisolated(nonsending) func execute<R, Failure: Error>(_:) async throws(PolicyError<Failure>) -> R
    public var activeCount: Int { get }; public var queuedCount: Int { get }
}

public enum Idempotency: Sendable { case idempotent }
public nonisolated(nonsending) func hedge<R: Sendable, Failure: Error>(
    _ idempotency: Idempotency, after delay: Duration, maxAttempts: Int = 2,
    budget: RetryBudget = .perCallSite, label: String? = nil,
    operation: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R

public struct Retrying: Policy {                      // design/02's retry, as a pipeline stage
    public init(_ schedule: BoundedSchedule, budget: RetryBudget = .perCallSite,
                classify: RetryClassifier<any Error> = .standard,
                nesting: RetryNesting = .singleAttempt,
                attemptTimeout: Duration? = nil, label: String? = nil)
}

public struct Pipeline: Policy {                      // outermost stage first
    public init(_ stages: [any Policy])
    public init(_ stages: any Policy...)
}
```

A realistic stack for an HTTP client, outermost first:

```swift
let pipeline = Pipeline(
    Retrying(.exponential(base: .milliseconds(200)).jittered().attempts(3), attemptTimeout: .seconds(2)),
    CircuitBreaker(label: "api.example.com"),
    RateLimiter(rate: 50, per: .seconds(1), burst: 100, label: "api.example.com"),
    Bulkhead(maxConcurrent: 8, queueLimit: 16, label: "api.example.com")
)

func fetch(_ request: Request) async throws(PolicyError<HTTPError>) -> Response {
    try await withTimeout(.seconds(10)) {                  // the whole call, retries included
        try await pipeline.execute { () async throws(HTTPError) -> Response in
            try await client.send(request)                 // each attempt is bounded by Retrying
        }
    }
}
```

## Semantics

**One error type, so composition is flat.** Every policy throws
`PolicyError<Failure>`: `.failed(error)` when the operation ran and failed,
`.rejected(rejection)` when the policy refused to run it. A policy placed
around another policy would, taken literally, throw
`PolicyError<PolicyError<F>>`. `Pipeline` removes that by construction: it
runs each stage with the _rest of the pipeline_ as the stage's operation,
whose failure type is `PolicyError<F>`, and maps the stage's error back down —
`.rejected(r)` and `.failed(.rejected(r))` become `.rejected(r)`,
`.failed(.failed(f))` becomes `.failed(f)`. The caller sees one flat
`PolicyError<F>` however many stages there are. Stages see inner rejections
as the operation's error, which is what lets a breaker decline to count them
and `Retrying` honour a rejection's `retryAfter`.

**Nest through a pipeline.** Written by hand, `breaker.execute { try await
bulkhead.execute { … } }` throws `PolicyError<PolicyError<F>>`: Swift cannot
choose an overload by a closure's thrown type (an `execute` for operations that
throw `PolicyError<F>` is ambiguous with the requirement, and crashes the type
checker on an existential), so the flattening cannot happen by itself.
`Pipeline(breaker, bulkhead)` is the way to nest; `flattened()` turns a hand
nesting's error into the flat `PolicyError<F>`.

**The order is checked.** `Pipeline` checks its stages when it is built:
`Retrying` outside `CircuitBreaker` outside `RateLimiter` outside `Bulkhead`,
and one `Retrying` at most; other policies may stand anywhere, and a pipeline
used as a stage counts as its stages written in place. A `Retrying` inside a
breaker would have the breaker judge a whole retry series as one call; a
bulkhead outside a retry would hold its slot through every backoff; a limiter
outside one would let retries skip it; a second `Retrying` would only collapse
to one attempt. Each is a precondition failure naming the stages, so the
mistake is found the first time the pipeline is built, in a test.

**A timeout is not a stage.** A timeout has to run the operation in a child
task so that a deadline can cancel it without cancelling the caller
(design/01); its closure is therefore `@Sendable` and `sending`, which a
`Policy`'s inline `nonisolated(nonsending)` operation is not. Forcing one into
the protocol would either drop the actor guarantee for every policy or
quietly run operations off the caller's actor. Instead `withTimeout` composes
by nesting, and its passthrough error type makes that flat too: wrapped
around a pipeline it throws the pipeline's `PolicyError<F>` untouched; placed
inside the operation it bounds one attempt and throws `F`.

**Recommended order, outermost first** (the order of Polly's documentation and
resilience4j's decorators, adjusted for Stoic): _overall timeout → retry →
circuit breaker → rate limiter → bulkhead → operation_, the attempt timeout
being `Retrying(attemptTimeout:)`.

- The overall timeout bounds the caller's wait, retries included.
- Retry is outside the breaker so that every attempt is judged, and an open
  breaker can end the retrying at once; one retry layer only (design/02).
- The breaker is outside the limiter and bulkhead so that local load-shedding
  (which says nothing about the dependency) never reaches its window, and so
  that a call the limiter or bulkhead refuses never uses up a half-open probe.
- Bound each attempt with `Retrying(attemptTimeout:)`, not with a
  `withTimeout` inside the operation. An inner `withTimeout` cancels the
  attempt, and `Retrying` receives only what the cut-off attempt threw,
  typically a `CancellationError`, which it cannot tell from the caller having
  been cancelled on purpose; the standard classifier stops on it, so a
  timed-out attempt is never retried. `Retrying(attemptTimeout:)` knows the
  attempt ran out of time and classifies it as transient (a `Defect` still
  stops), exactly as `retry(attemptTimeout:)` does (design/02).
- That timeout sits outside the breaker, so the cut-off attempt reaches the
  breaker as a cancellation, but one a deadline caused: the breaker records it
  as a slow failure (`timed_out`), so a dependency that hangs opens the
  breaker, and a half-open probe that hangs re-opens it.

**Cancellation and deadlines, for every policy.** A policy that has not
started the operation and finds the task cancelled rejects with `.cancelled`;
one that finds `Deadline.current` already passed rejects with
`.deadlineExceeded` rather than starting work that is already late (design/01
leaves this to policies). A policy that is _waiting_ leaves when its task is
cancelled, and when the cancellation came from an enclosing deadline
(`CancellationCause.current == .deadline`) it reports `.deadlineExceeded`
instead. A waiter that leaves never consumes what it was waiting for. Once the
operation is running, the policy's job is only bookkeeping; cancellation is
the operation's to honour and its error passes through.

`.rejected(.cancelled)` is how a policy's typed error spells "the caller was
cancelled" (a `PolicyError` cannot be a `CancellationError`). Stoic treats it
as cancellation everywhere it classifies an error — retry, breakers, reports,
scopes — and `Rejection.isCancellation` / `PolicyError.isCancellation` let a
caller do the same (design/03).

### CircuitBreaker

**Admission is a synchronous check.** State lives in one `Mutex`; `execute`
takes it, decides, releases it, and only then awaits the operation. There is no
actor hop on the way in or out and no lock is held across the operation.
Nothing runs in the background: the open period is not a timer but an instant
on the breaker's clock, and the transition to half-open happens lazily, on the
first call (or read of `state`) at or after it. A breaker therefore owns no
task, needs no teardown, and costs nothing while idle.

**States.** _Closed_: calls run and are recorded in the window. _Open_: calls
are rejected with `.circuitOpen` and `retryAfter` = the time left. _Half-open_:
up to `halfOpenProbes` calls run as probes; every other call is rejected
(`retryAfter` is unknown, so `nil`). When every probe permit has returned a
success, the breaker closes with an empty window. The first probe that is
recorded as a failure re-opens it.

**The window.** `.time(T)` (default) keeps the last `T` of calls in ten
buckets of `T / 10`; `.calls(N)` keeps the last `N` calls exactly. Time-based
is the default because app traffic is bursty and idle for long stretches: a
count-based window would let a handful of failures from an hour ago, still the
last `N` calls, trip the breaker on the next unlucky request, while a
time-based one has forgotten them. The cost is coarse edges (the window is
between `T − T/10` and `T`), and a quiet period leaves too few calls to judge,
which `minimumCalls` already covers. Count-based is the right choice for a
steady, high-volume dependency, where it is exact and independent of rate.

**Judging.** After each recorded call in the closed state, if the window holds
at least `minimumCalls` calls and the failure rate is at least
`failureRateThreshold` _or_ the slow-call rate is at least
`slowCallRateThreshold`, the breaker opens. Rates are compared in exact
integers (parts per million), never with floating-point division, and a
threshold must be in (0, 1]. A call is _slow_ when it took longer than
`slowCallDuration` on the breaker's clock; a slow call that also failed counts
in both rates. For a count-based window, `minimumCalls` must not exceed `N`.

**Latency is the dependency's, not the queue's.** A call is timed from when it
left the last local queue: a bulkhead or rate limiter inside the breaker marks
the moment it lets the call through (a task-local mark the breaker installs
around its operation), and the breaker measures from there. Otherwise, in the
recommended order, the time a call spent waiting for a slot or a permit would
count as the dependency's latency, and a breaker would open on `slow_calls`
(or re-open on a slow probe) while every call the dependency served was quick.
Only the nearest enclosing breaker hears the mark.

**Probes are stricter.** A probe that is _slow_ (longer than
`slowCallDuration`) counts as a failed probe (`probe_slow`): a dependency that
still cannot answer in time has not recovered. The `halfOpenProbes` permits are
for the whole episode, not per moment: a probe that succeeds does not hand its
permit on, and one that ends without a verdict (cancelled, a defect, refused by
an inner policy) returns it.

**What counts.** A completed call has one of three verdicts:

1. _Ignored_ — not evidence about the dependency: the caller was cancelled
   for any reason but a deadline (the task is cancelled when the operation
   ends, whatever it threw: a user, a superseding request, a scope ending), the
   error is or wraps a `Defect` (a bug in our code, not the dependency's
   health; it is rethrown, reported at error level, and a half-open probe's
   permit is returned), or the call finished after the breaker had already
   changed state (a _stale_ call, found by comparing generations).
2. _Failure_ — `recordWhen` returned `true` for the error; or a deadline
   cancelled the call (`CancellationCause.deadline`: an attempt timeout, or the
   caller's own deadline), which is recorded as a failure _and_ slow, whatever
   it threw (`timed_out`). The dependency did not answer within the time the
   caller could give it, which is the failure a breaker exists to notice: a
   hung dependency is the common one, and it never throws.
3. _Success_ — a return, or an error for which `recordWhen` returned `false`.
   A `404` is the dependency answering, and a probe that gets one should close
   the breaker.

`recordWhen` receives the operation's own error: `PolicyError` layers, a
`Report` (what `withContext` wraps an error in) and a `ConcurrentFailure` (its
primary failure stands for it) are removed first, so inside a pipeline, or
around code that adds context, it sees `F` or, for an inner policy's refusal,
a `Rejection`. A `Retrying` stage's classifier sees the same error, through
the same helper, so retry and breaker never classify one error two ways. The default, `countsByDefault`, returns `false` for
`Rejection`s — an inner bulkhead being full, an inner limiter refusing or an
inner budget running dry say nothing about the dependency — and `true` for
everything else, including a `CancellationError` thrown while the caller is
_not_ cancelled, which means something inside (an attempt timeout) cut the call
short. A caller who puts an abandoning timeout innermost should also count its
`.deadlineExceeded` rejection:
`{ CircuitBreaker.countsByDefault($0) || ($0 as? Rejection)?.reason == .deadlineExceeded }`.

**Open duration and growth.** The k-th consecutive trip opens the breaker for
`initial × factor^k`, capped at `maximum`, then shortened by a random fraction
up to `jitter` (jitter only ever shortens, so the cap holds; the randomness is
ambient and seeded per breaker construction site). `factor: 1` is a fixed
duration. The trip count resets when the breaker has stayed closed for
`resetAfter` (default: the maximum), so a dependency that recovers for long
enough gets a fresh start and one that flaps keeps getting longer rests.
Closing does not reset it, only sustained health does.

**Half-open cannot wedge.** If a probe has been in flight for `halfOpenTimeout`
without finishing, the next call (or `state` read) treats the episode as a
failed probe and re-opens. The late probe, when it ends, is stale and ignored.
Without this, one hung probe would hold the permit forever.

**Manual control.** `forceOpen()` opens the breaker with no end: it is not
probed and does not half-open, until `forceClosed()` or `reset()`.
`forceClosed()` closes it now with an empty window; normal judging resumes
(it is not a latch). `reset()` is `forceClosed()` plus forgetting the trip
count. Calls in flight when state is forced finish as stale.

**Observation.** `stateChanges` yields every transition, in order, on a stream
that keeps the newest 16 and drops older ones for a consumer that falls
behind; it does not replay the current state (read `state` after subscribing).
Each access to `stateChanges` is its own stream. Because the move out of open
is lazy, `half-open` is reported when first observed by a call or a `state`
read, not at the instant the open period ends.

**Clock.** A breaker measures time on one clock for its whole life: `clock:`
if given, else the ambient clock at construction. (A policy with state that
is compared across calls cannot follow an ambient clock that changes between
them.) Events go to the ambient instrumentation at the time of the call.

### RateLimiter

**Token bucket, exact.** `rate` permits per `interval`, a bucket of `burst`
permits (default `rate`), full at creation. The bucket is kept as an integer
credit in units of `permit × interval-attoseconds`, so refill is
`elapsed-attoseconds × rate` with no division and no rounding, and the time to
afford a request is one ceiling division at the end. Refill is computed lazily
from the elapsed time on the limiter's clock; nothing ticks. The invariant
the tests check: permits granted by time `t` never exceed `burst + rate × t`.

**Waiting is FIFO and bounded.** `acquire` takes permits at once when the
bucket holds enough and nobody is queued. Otherwise it computes when it would
be served — the cost of everyone ahead plus its own, less the credit — and
decides before waiting at all: if that is later than `Deadline.current` allows,
or the queue already holds `queueLimit` waiters, it throws `.rateLimited` with
`retryAfter` set to the computed wait. Nothing is queued and nothing consumed.
Otherwise it queues. Only the head of the queue sleeps, on the limiter's clock,
until it can be afforded; when it is served the next waiter is woken to compute
its own wait. This is the semaphore's waiter queue (design/03), including its
"arriving"/"left early" bookkeeping for a cancellation that arrives before the
waiter is queued, with a timer in place of a release. Recomputing at the head
means a late wake-up or a departed waiter never leaves tokens unspent that a
later waiter could use, and never grants tokens that were not earned.

**No overtaking.** `tryAcquire` returns `false` whenever anyone is queued, even
if the bucket could afford it: a newcomer must not pass a waiter. A request for
more than `burst` can never be served and is rejected at once (`.rateLimited`,
no `retryAfter`), with a `ratelimiter.oversized` event, rather than queued
forever.

**Tokens are not leases.** A permit taken is spent; a failing operation does
not get it back. A limiter limits attempts, which is what the server counts.

**Queue default.** `queueLimit` defaults to 100, not unbounded: an unbounded
queue is a wait with no end except the caller's patience (Principle 2). `nil`
opts into unbounded, still bounded by cancellation and deadlines.

### Bulkhead

At most `maxConcurrent` operations run at once; up to `queueLimit` more wait,
first-in first-out; the next is rejected with `.bulkheadFull`. The default
`queueLimit` of `0` makes it Envoy's and tower's load-shedder: when the
dependency's capacity is spoken for, refuse at once instead of letting latency
grow. It is the semaphore's queue with the "full" decision made in the same
critical section as the "wait" decision, so the limit holds exactly under
contention rather than within the number of racing arrivals. Cancellation and
deadlines are the semaphore's: a waiter leaves and never takes a slot.

### hedge

As specified in design/03, with the shape settled by implementation. Attempt 1
starts at once. If no attempt has _succeeded_ `delay` after the latest start,
the next starts without cancelling the earlier ones, up to `maxAttempts`. The
first success wins; the others are cancelled with cause `.superseded` and
awaited before `hedge` returns. If every started attempt fails, `hedge` throws
the first failure _in completion order_ (as `race` does). Hedging is a
response to slowness only: when an attempt fails and none is still running,
`hedge` throws at once rather than starting the next on a timer, because
failure belongs to `retry`, and hedge-as-retry would double the load exactly
when the dependency is failing. Each hedge withdraws a token from `budget`
(the first attempt deposits, as in `retry`); no token, no hedge, and the
attempts already running continue. `Idempotency` has one case, `.idempotent`,
so hedging a non-idempotent call means writing a lie in the source. An
`Attempt` tells the operation which attempt it is, so it can send an
idempotency key or a `hedged` header.

No hedge starts that could not finish before `Deadline.current`, by
`retry`'s rule: no attempt has finished yet, so one takes at least as long as
the first has been running, and a hedge that would end after the deadline
only adds load.

**Retry outside, hedge inside.** Each hedged attempt runs as an attempt (the
task-local `retry` reads), so a `retry` inside one is nested and makes a
single attempt. Otherwise a retry inside a hedge turns failures into
slowness, its backoff, which the hedge answers with a second copy that
retries in full too: `maxAttempts` times the retry's load on a failing
dependency. Put the `retry` around the `hedge`. A hedge started inside a
retry's attempt is a sub-operation of it (design/02): its key is derived
from the retry's, the same on every retry attempt.

### Retrying

`Retrying` runs design/02's `retry` as a pipeline stage. Its classifier is
typed `RetryClassifier<any Error>` because a stage does not know the failure
type of the pipeline it will be placed in, and it is handed the operation's
own error with the wrappers removed (as `recordWhen` is), so a classifier
that matches `F` decides the same way alone and in a pipeline. The budget is
per call site of `Retrying(…)`.

**An open breaker under retry: one rule.** The stage sits outside the
breaker, so a `.circuitOpen` rejection reaches it as the attempt's error. An
open breaker is saying "fail fast", and waiting it out for minutes would
defeat it; but a breaker about to half-open is worth one more try. So: when
its `retryAfter` is longer than the schedule's next delay, the retry stops at
once (`retry.breaker_open`) and the caller gets the breaker's rejection;
otherwise it waits the `retryAfter`, jittered upward by up to a tenth, since
every caller turned away got the same instant and would otherwise all reach
the single probe together. The remaining deadline applies as to any wait
(design/02's check 5). A half-open rejection has no `retryAfter` and is
retried on the schedule. (StoicHTTP's own classifier stops on every
rejection, a stricter form of the same rule.)

**Stops that are refusals are rejections.** `retry` can throw only its
operation's error, so it cannot say that it stopped because nothing more
was allowed. `Retrying` can, and does: its caller cancelled during a
backoff is `.rejected(.cancelled)` (`.deadlineExceeded` when a deadline did
the cancelling), as for any waiting policy; a next attempt that could not
finish before the deadline is `.rejected(.deadlineExceeded)` with the delay
it needed as `retryAfter`; an empty budget is `.rejected(.budgetExhausted)`.
Every other stop throws the last attempt's error.

With `attemptTimeout`, each attempt runs under the engine of
`retry(attemptTimeout:)`: a timeout that cancels the attempt and awaits it. A
timeout has to run the attempt in a child task, so the stage hands its
(non-`Sendable`) inline operation to that task for the length of the attempt;
the caller is suspended meanwhile, so the operation is used by one task at a
time, and it runs on the caller's actor. This is the one place a stage moves
the operation off the caller's task, which is why a timeout is an option of
`Retrying` rather than a stage of its own.

## Failure modes

| What happens if…                                                          | Behaviour                                                                                                 |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| a breaker has fewer than `minimumCalls` calls in its window               | Stays closed whatever the rates                                                                           |
| the failure rate reaches the threshold with enough calls                  | Opens; `breaker.opened` (trigger `failure_rate`)                                                          |
| the slow-call rate reaches the threshold with enough calls                | Opens; `breaker.opened` (trigger `slow_calls`)                                                            |
| a call arrives while open                                                 | `.rejected(.circuitOpen)` with `retryAfter` = time left; `breaker.rejected`                               |
| the open duration has elapsed                                             | The next call or `state` read moves to half-open (`breaker.half_open`); the call is a probe               |
| more calls arrive than there are probe permits                            | Rejected `.circuitOpen`, `retryAfter` nil; `breaker.rejected`                                             |
| every probe succeeds                                                      | Closes with an empty window; `breaker.closed` (reason `probes_succeeded`)                                 |
| a probe fails                                                             | Re-opens for the next, longer open duration; `breaker.opened` (trigger `probe_failed`)                    |
| a probe is still running after `halfOpenTimeout`                          | The next call or read re-opens it (`probe_timeout`); the late probe is ignored as stale                   |
| the caller is cancelled while the operation runs                          | Not recorded (unless a deadline cancelled it); a probe's permit is returned; `breaker.ignored` (reason `cancelled`) |
| a deadline cancels the call while the operation runs                      | Recorded as a slow failure (`breaker.recorded` reason `timed_out`); a probe re-opens the breaker         |
| a dependency hangs under `Retrying(attemptTimeout:)`                      | Each cut-off attempt is a slow failure, so the breaker opens                                              |
| the operation throws a `Defect`                                           | Rethrown; not recorded; `breaker.defect` at error level; a probe's permit is returned                     |
| an inner policy's refusal arrives wrapped by `withContext`                | Still a refusal: not recorded; `breaker.ignored` (reason `rejection`)                                     |
| a `Retrying` stage with a custom classifier runs inside a pipeline        | The classifier is handed the operation's own error, as when the stage runs alone                          |
| an inner policy rejects (bulkhead full, limiter, budget)                  | Passed through; not recorded by default; `breaker.ignored` (reason `rejection`)                           |
| the operation throws `CancellationError` and the caller is not cancelled  | Recorded like any error (an inner timeout cut the call short)                                             |
| `recordWhen` returns `false` for an error                                 | Recorded as a success; the error still propagates                                                         |
| a call waits in an inner bulkhead's or limiter's queue                    | Timed from when it left the queue: local waiting is never counted as slow                                |
| a call finishes after the breaker changed state                           | Ignored as stale; `breaker.ignored` (reason `stale`)                                                      |
| the task is cancelled, or the deadline has passed, before admission       | `.rejected(.cancelled)` / `.rejected(.deadlineExceeded)`; no probe permit used                            |
| `forceOpen()`                                                             | Rejects every call (`retryAfter` nil) until `forceClosed()` or `reset()`; never half-opens                |
| `forceClosed()` or `reset()`                                              | Closes with an empty window; `reset()` also forgets the trip count                                        |
| a dependency stays healthy for `resetAfter` after closing                 | The next trip starts again from `initial`                                                                 |
| a `stateChanges` consumer falls behind                                    | It keeps the newest 16 states; the breaker never waits for it                                             |
| the limiter has enough tokens and no queue                                | Granted at once, no suspension                                                                            |
| the limiter is empty and the wait fits the deadline and the queue         | The task queues FIFO; the head sleeps until it can be afforded                                            |
| the wait would outlive `Deadline.current`                                 | Rejected at once: `.rateLimited` with `retryAfter` = the wait; nothing queued, nothing consumed           |
| the limiter's queue is full                                               | Rejected at once: `.rateLimited` with `retryAfter` = the wait; `ratelimiter.rejected`                     |
| a queued limiter waiter is cancelled                                      | Removed; `.rejected(.cancelled)`; consumes nothing; the next waiter recomputes its wait                   |
| a queued limiter waiter's enclosing deadline cancels it                   | Removed; `.rejected(.deadlineExceeded)`; consumes nothing                                                 |
| `permits` exceeds `burst`                                                 | Rejected at once: `.rateLimited`, no `retryAfter`; `ratelimiter.oversized`                                |
| `tryAcquire` while others wait                                            | `false`: a newcomer never passes a waiter                                                                 |
| the operation of a limiter's `execute` fails                              | `.failed`; the token stays spent                                                                          |
| the limiter's clock wakes the head late                                   | The head recomputes from the credit it actually has                                                       |
| a bulkhead has a free slot                                                | Runs at once                                                                                              |
| the bulkhead is full and the queue has room                               | Queues FIFO; runs when a slot frees                                                                       |
| the bulkhead and its queue are full (or `queueLimit` is 0 and it is full) | `.rejected(.bulkheadFull)`; `bulkhead.rejected`                                                           |
| a queued bulkhead waiter is cancelled or its deadline passes              | Removed; `.cancelled` / `.deadlineExceeded`; takes no slot                                                |
| the bulkhead's operation throws                                           | Slot returned; `.failed(error)`                                                                           |
| the first hedged attempt finishes before `delay`                          | No hedge starts; its result is returned                                                                   |
| the first attempt is slow                                                 | Attempt 2 starts after `delay`, attempt 1 keeps running; first success wins; `hedge.started`, `hedge.won` |
| the winner is found                                                       | Every other attempt cancelled (`.superseded`) and awaited before return                                   |
| the hedge budget has no token                                             | No hedge; running attempts continue; `hedge.budget_exhausted`                                             |
| an attempt fails and none is running                                      | Throws that failure now; no further hedge (failure belongs to retry)                                      |
| every attempt fails                                                       | Throws the first failure in completion order; `hedge.all_failed`                                          |
| `maxAttempts` attempts have started                                       | No more hedges                                                                                            |
| hedged attempts send `attempt.idempotencyKey`                             | The same key on every attempt of one hedge, however many ask at once                                      |
| the caller is cancelled                                                   | Every attempt cancelled and awaited; the first failure returned                                           |
| a hedge could not finish before the deadline                              | No hedge; `hedge.deadline_skip`; the attempts running carry on                                            |
| a retry runs inside a hedged attempt                                      | One attempt only (`retry.nested`): failure belongs to a retry around the hedge                            |
| a hedge runs inside a retry's attempt                                     | Its key is derived from the retry's: the same on every retry attempt                                      |
| a stage inside a pipeline rejects                                         | The caller sees one `.rejected(r)`, never a nested `PolicyError`                                          |
| a pipeline's operation fails                                              | The caller sees `.failed(error)` with the operation's own error                                           |
| a pipeline's stages are out of the recommended order                      | Precondition failure when it is built, naming the two stages and the order                                |
| a pipeline has two `Retrying` stages                                      | Precondition failure when it is built: retry at one layer                                                 |
| a policy runs an operation that is itself guarded by a policy             | `PolicyError<PolicyError<F>>`; `flattened()` makes it one flat `PolicyError<F>`, as a `Pipeline` does     |
| a pipeline has no stages                                                  | The operation runs; a failure is `.failed`                                                                |
| `Retrying` meets `.circuitOpen` with a `retryAfter` longer than its next delay | Stops at once: the breaker's `.rejected(.circuitOpen)` with its `retryAfter`; `retry.breaker_open`  |
| `Retrying` meets `.circuitOpen` with a `retryAfter` no longer than its next delay | Waits that long, jittered upward by up to 10% — stretched by the device's conditions, capped at five minutes, still bounded by the deadline |
| `Retrying`'s caller is cancelled during a backoff                         | `.rejected(.cancelled)`, or `.rejected(.deadlineExceeded)` when a deadline cancelled it; the budget token is returned |
| `Retrying`'s next attempt could not finish before the deadline            | `.rejected(.deadlineExceeded)` with the delay it needed as `retryAfter`; `retry.deadline_skip`            |
| `Retrying`'s budget is empty                                              | `.rejected(.budgetExhausted)`; `retry.budget_exhausted`                                                   |
| an attempt under `Retrying(attemptTimeout:)` runs out of time             | Cancelled and awaited; counted as transient, so retried on the schedule (a `Defect` still stops)          |

## Events

Breaker: `breaker.opened` (trigger: `failure_rate`, `slow_calls`,
`probe_failed`, `probe_slow`, `probe_timeout` or `forced`; calls, failures,
slow_calls, trips, and open_for unless forced), `breaker.half_open` (probes),
`breaker.closed` (reason: `probes_succeeded`, `forced` or `reset`),
`breaker.reset`, `breaker.rejected` (state and retry_after, or reason when the
task was cancelled or late; debug), `breaker.recorded` (outcome, slow, state;
debug), `breaker.ignored` (reason: `cancelled`, `rejection` or `stale`; debug),
`breaker.defect` (error level).
Limiter: `ratelimiter.rejected` (reason: `would_exceed_deadline`, `queue_full`,
`cancelled`, `deadline_exceeded`; permits; retry_after when known),
`ratelimiter.oversized`, `ratelimiter.waited` (permits, waited; debug).
Bulkhead: `bulkhead.rejected` (reason: `bulkhead_full`, `cancelled`,
`deadline_exceeded`; capacity; waiting when full).
Hedge: `hedge.started` (attempt, elapsed), `hedge.attempt_failed` (attempt,
running, error; debug), `hedge.won` (attempt, started, latency; only when a
hedge was started), `hedge.budget_exhausted`,
`hedge.deadline_skip`, `hedge.all_failed`.
Every event carries the policy's label. Rejections are events, never errors
the caller has to log themselves.

## Testing

- Every failure-mode row has a test on `TestClock`, with no real waiting.
- Breaker: opens at the threshold only after `minimumCalls`; a slow-call trip;
  open rejection and its exact `retryAfter`; exactly `N` concurrent probes with
  the rest rejected; probe success closes, probe failure re-opens with a longer
  duration; the growth reset; cancellation and defects never counted; stale
  completions; forced control; the transitions on `stateChanges` in order,
  including under consumers that cancel mid-transition; both window kinds
  against a reference model under random call sequences (the model counts the
  last `N` calls, or the calls within the bucketed span, directly).
- Limiter: burst then the steady rate on virtual time; FIFO among waiters;
  cancelled and deadline-cancelled waiters never consume; immediate rejection
  when the wait exceeds the deadline; property test: for any random schedule of
  advances, `tryAcquire`s and waiting `acquire`s, permits granted by `t` never
  exceed `burst + rate × t`, and with enough demand they equal it exactly.
- Bulkhead: concurrency never exceeds the limit under 300 contending tasks;
  the queue limit is exact; random cancellations never leak a slot.
- Hedge: slow first attempt, winner returned, loser cancelled with cause
  `.superseded` and awaited (an attempt log shows nothing running at return, and
  a loser that ignores cancellation delays the return), budget exhaustion
  (including a budget of one across two calls), all-fail, no hedge after a
  fast failure, and a model over random timelines: for random durations and
  outcomes the winner, the first failure, the number of attempts started and
  "nothing running at return" must match a reference simulation.
- Pipeline: flattening for every stage kind, stage order, and the HTTP stack
  of the API example end to end on virtual time.
- Stress: each concurrency suite under
  `swift test --filter <Suite> --maximum-repetitions 300 --repeat-until fail`,
  and under `--sanitize=thread`.

## Non-goals

A timeout _stage_ (see "A timeout is not a stage"); adaptive concurrency
limits (Netflix's `concurrency-limits`, TCP-Vegas-style) — a bulkhead's limit
is configured, and adaptive limiting needs latency measurements this contract
does not collect; distributed rate limiting (a limiter is per process); a
fallback policy (a `catch` at the call site is clearer than a stage that
swallows the error); automatic transition out of open by timer (it would need
an owner and a teardown for a task whose only job is to flip a flag).

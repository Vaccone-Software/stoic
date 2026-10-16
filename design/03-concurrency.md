# 03 · Structured concurrency

Swift's task groups are the right foundation and the wrong altitude. This
contract adds the shapes apps keep hand-rolling — "only the latest", "at most
n at once", "first good answer", "everyone shares one fetch" — with the
cancellation and failure semantics written down.

## Origin

- **Effect.** `race`, `Effect.all({ concurrency })`, `Semaphore`, request
  deduplication.
- **Go.** `errgroup` with a limit; `singleflight`.
- **"The Tail at Scale" (Dean and Barroso).** Hedged requests cut BigTable's
  p99.9 latency from 1,800 ms to 74 ms for 2% extra load (figure from prior
  knowledge, not re-checked).
- **In apps.** Generation counters compared in every callback to stop a
  superseded request from publishing its result — one forgotten comparison
  is a stale UI. Single-flight written by hand around a shared optional
  task. `DispatchSemaphore` used to bound async work, which blocks a thread
  of the cooperative pool.

## API

```swift
// Only the newest work delivers, on the caller's actor.
public final class TaskSlot<Success: Sendable, Failure: Error>: Sendable {
    public init(label: String)
    public func run(isolation: isolated (any Actor)? = #isolation,
                    @_inheritActorContext _ operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
                    deliver: sending @escaping (Result<Success, Failure>) -> Void)
    public func runExclusively(…)            // waits for the superseded work to finish first
    public func cancel(); public func cancelAndWait() async
    public var isRunning: Bool
}

// First success wins; losers cancelled and awaited. Fixed arities plus [Racer].
public func race<R: Sendable, Failure: Error>(label:, _ first: @escaping @concurrent @Sendable () async throws(Failure) -> R,
                                               _ second: …) async throws(Failure) -> R   // and 3, 4, [Racer<R, Failure>]

// Second attempt after a delay if the first is slow. Only for idempotent work.
// Throws the first failure, as race does; the contract is design/10.
public nonisolated(nonsending) func hedge<R: Sendable, Failure: Error>(
    _ idempotency: Idempotency,            // must be .idempotent — the argument is the acknowledgement
    after delay: Duration,
    maxAttempts: Int = 2,
    budget: RetryBudget = .perCallSite,
    operation: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R

// Bounded parallel map; results in input order.
public func mapConcurrent<C: Collection, R: Sendable, Failure: Error>(_ elements: C, limit: Int,
    transform: @escaping @concurrent @Sendable (C.Element) async throws(Failure) -> R) async throws(Failure) -> [R]
public func mapConcurrentResults<…>(…) async -> [Result<R, Failure>]

// FIFO, cancellation- and deadline-aware. Scoped use only.
public final class AsyncSemaphore: Sendable {
    public init(permits: Int, label: String)
    public func withPermit<R, Failure: Error>(_ body: nonisolated(nonsending) () async throws(Failure) -> R) async throws(PolicyError<Failure>) -> R
}
public final class AsyncMutex: Sendable { public func withLock<R, Failure>(…) async throws(PolicyError<Failure>) -> R }

// Concurrent callers for the same key share one execution.
public final class SingleFlight<Key: Hashable & Sendable, Value: Sendable, Failure: Error>: Sendable {
    public func run(_ key: Key, operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value) async throws(PolicyError<Failure>) -> Value
}
```

## Semantics

**TaskSlot.** `run` supersedes the current work — cancelled with cause
`superseded` — and starts the new work at once; `runExclusively` waits for
the superseded work to finish first, for work that must never overlap (two
uses of one microphone). `deliver` runs on the actor that called `run`, and
the is-this-still-the-newest check happens there, synchronously with the
delivery, so no newer `run` can slip between them. The work does not
inherit the caller's deadline (it outlives any `withTimeout` it was started
in; SingleFlight, StateMachine and Supervisor make the same reset). Late results from
superseded work are dropped and reported (`slot.superseded_late`). The work
holds the slot weakly, and a released slot cancels its work: a view model
that goes away takes its in-flight request with it.

**race.** Every operation runs as a child task. The first success wins; the
rest are cancelled (`superseded`) and then awaited, so `race` never returns
while a loser runs. If every operation fails, the first failure is thrown —
passthrough, not a wrapper, because `throws(Failure)` has no room for a
`ConcurrentFailure` — and every failure is reported in `race.all_failed`
(`first`, then `also_1`, `also_2`, … in completion order, at most nine). A
cancelled caller cancels every racer; what they throw then passes through
(`CancellationError` where `Failure` allows) and is not reported, since
cancellation is not a failure. The natural variadic spelling crashes the Swift 6.4 compiler at call sites (a
SILGen assertion), and array literals of closures are not inferred
`@Sendable`, hence fixed arities and `Racer`.

**hedge.** Its full contract is in design/10. Starts attempt 1; if it has not finished after `delay`, starts
attempt 2 without cancelling attempt 1, and so on up to `maxAttempts`. The
first success wins and the rest are cancelled and awaited. Each hedge draws
from the retry budget, so hedging cannot amplify load during an outage
beyond the budget's ratio. The `Idempotency` argument has a single case,
`.idempotent`: it exists so that hedging non-idempotent work requires
writing a lie in the source. A latency-percentile delay (read from a rolling histogram the caller
owns) is future work; the delay is a fixed `Duration` for now.

**mapConcurrent.** At most `limit` transforms run; elements start in
order; results return in input order. On the first failure the rest are
cancelled (`siblingFailed`) and that failure alone is thrown — failures
caused by the cancellation are not reported as failures.
`mapConcurrentResults` runs everything and returns each outcome. A cancelled
caller starts no further element: the running ones are cancelled and awaited,
and `mapConcurrent` throws `CancellationError` if any element was left
unstarted and `Failure` can hold one (`any Error`). A typed `Failure` cannot,
so the caller gets the results of the elements that started — the leading
ones, an array shorter than the input; `mapConcurrentResults` likewise returns
only the started elements' outcomes.

**Child-task closures are `@concurrent`.** They run concurrently by design;
the explicit attribute keeps that true under `NonisolatedNonsendingByDefault`.

**AsyncSemaphore and AsyncMutex.** Strict FIFO, counted from arrival: a
waiter that has found no permit but not yet queued keeps its place, so a
newcomer never takes a permit freed in that moment. A waiter that is cancelled,
or whose `Deadline.current` passes, leaves the queue and never consumes a
permit — arrivals are tracked so even a cancellation that lands before the
waiter queues is honoured. Cancellation caused by an enclosing deadline is
reported as `deadlineExceeded`. `withPermit` is the only way to hold a
permit. Re-acquiring a semaphore the task already holds is reported as
`semaphore.reentrant` — a self-deadlock in waiting. The task's child tasks
count as holding it; tasks Stoic starts on its own (a slot's work, a flight,
a fork) do not, since nothing waits for them as for a child. A hand-written
`Task {}` copies task-locals, so it counts. `AsyncMutex` is the
one-permit form: the cure for actor reentrancy's check–await–act race.

**SingleFlight.** The flight owns the operation. Callers leave with a
rejection (`cancelled` or `deadlineExceeded`) when they stop waiting; the
operation is cancelled only when the last caller leaves, and the key is
retired at once so newcomers start fresh instead of joining a flight being
cancelled. The operation's cancellation cause is why that last caller left:
`deadline` when its deadline passed, and when it was cancelled, the cause an
enclosing Stoic scope recorded for it (`userRequested` only when none did).
The operation runs without the first caller's deadline; each
caller's wait is bounded by its own. The operation runs at the most urgent
priority any waiting caller has: a caller waits on a continuation, which
escalates nothing, so the flight escalates the task itself when a
higher-priority caller joins or a waiting caller is escalated.

**Cancellation of the caller.** These primitives throw `PolicyError` (or
`Rejection`), whose type cannot hold a `CancellationError`: a typed throw has
exactly the cases it declares. So the caller's own cancellation reaches the
caller as `.rejected(.cancelled)` — the library's spelling of cancellation,
the same one every policy uses (design/10). It is cancellation in every way
that matters, and Stoic reads it so: `retry` stops on it, a breaker does not
count it, a scope whose body (or fork) ends with it is `Exit.cancelled`, not a
failure, and `Rejection.isCancellation` / `PolicyError.isCancellation` ask
the question that `error is CancellationError` asks elsewhere. It is never
`.deadlineExceeded` (the caller's own deadline) and never a failure of the
operation. Where the error type is not a policy's — `mapConcurrent` with an
`any Error` failure, `Channel.receive()` (which returns `nil`), a supervisor
— cancellation is a plain `CancellationError`, or the documented `nil`.

**Channel.** A bounded queue between any number of producers and
consumers; each element reaches exactly one consumer, in order. The
producer chooses what a full channel means: `suspend` (backpressure — FIFO,
cancellation- and deadline-aware, a rejected sender sent nothing),
`dropOldest` (latest state wins: progress, location), `dropNewest`, or
`reject` (the producer sheds load). Drops are counted and reported
(`channel.dropped`). `finish()` rejects waiting senders with `closed`, and
consumers drain what is buffered before seeing the end. It is an
`AsyncSequence`; `receive()` returns `nil` at the end or when the receiving
task is cancelled. Principle 2 says no queue is unbounded; this is the queue
that keeps the promise, and the lint rule against
`AsyncStream(bufferingPolicy: .unbounded)` points to it.

## Failure modes

| What happens if…                                         | Behaviour                                                                                                                                                                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a superseded `TaskSlot` task finishes after the new one  | Its result is dropped inside the slot; `slot.superseded_late` event                                                                                                                                              |
| a `TaskSlot` task ignores cancellation forever           | Next `run` does not wait for it (it is not structured to the slot's caller); it stays in `unfinishedCount` and the task ledger, so `stoicTasksStillRunning` names it; if it ever returns, `slot.superseded_late` |
| every racer fails                                        | The first failure is thrown; `race.all_failed` carries all of them, completion order                                                                                                                             |
| the caller of a race is cancelled                        | Every racer is cancelled and awaited; the first racer's error passes through; no `race.all_failed`                                                                                                               |
| a racer ignores cancellation after another won           | `race` waits for it (structured); give such work its own timeout                                                                                                                                                 |
| the hedge budget is empty                                | No further hedges; the attempts already running continue                                                                                                                                                         |
| `mapConcurrent` caller is cancelled                      | No further element starts; children cancelled and awaited; `CancellationError` if `Failure` allows, else the started (leading) results                                                                           |
| a semaphore waiter is cancelled while queued             | Removed from the queue; no permit consumed; `.rejected(.cancelled)` (`isCancellation`; see Cancellation of the caller)                                                                                           |
| a semaphore waiter's deadline passes while queued        | Removed; `.rejected(.deadlineExceeded)`                                                                                                                                                                          |
| a permit frees while a waiter is on its way to the queue | The waiter keeps its place: the permit is kept for it, and a newcomer queues behind it                                                                                                                           |
| a waiter on its way to the queue is cancelled            | It leaves without a permit; the waiters it held up are let through at once                                                                                                                                       |
| a body inside `withPermit` throws                        | Permit returned; error passed through as `.failed`                                                                                                                                                               |
| two single-flight waiters, the first cancels             | The operation continues for the second                                                                                                                                                                           |
| every single-flight waiter cancels                       | The operation is cancelled                                                                                                                                                                                       |
| a higher-priority caller joins a single flight           | The shared operation is escalated to that priority (SE-0462); it is never lowered when that caller leaves                                                                                                        |

## Events

`slot.superseded`, `slot.superseded_late`, `race.won` (index, latency),
`race.all_failed`, `hedge.started` (attempt), `hedge.won`, `semaphore.rejected`,
`semaphore.reentrant`, `singleflight.joined`, `singleflight.abandoned`,
`channel.dropped`.

Considered and not built: `slot.dropped` and `slot.stragglers` (a slot has
exactly one answer for late work, `slot.superseded_late`, and the task
ledger already lists a superseded task still running), `race.slow_loser` (it
needs a notion of "overrun" the API does not take; a loser that ignores
cancellation is a timeout the caller should write), and `semaphore.wait` (it
needs a caller-chosen threshold; `semaphore.rejected` and the deadline cover
the waits that matter, and `Diagnostics` shows the queue).

## Testing

- Model-based tests for `AsyncSemaphore` against a reference FIFO model
  under random arrivals, cancellations and deadlines; invariant: permits in
  use + available = capacity, at every step.
- `TaskSlot` property: across random sequences of `run`, completion and
  cancellation, `deliver` is called only with the newest task's result and
  at most once per task.
- `race` and `hedge`: no child is running when the function returns (checked
  by the test kit's task ledger), under seeded random completion orders.
- `SingleFlight` reference-counting model test.

## Non-goals

Actor-style mailboxes, channels and `AsyncSequence` operators
(swift-async-algorithms covers them); work stealing or custom executors.

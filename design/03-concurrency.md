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
delivery, so no newer `run` can slip between them. Late results from
superseded work are dropped and reported (`slot.superseded_late`). The work
holds the slot weakly, and a released slot cancels its work: a view model
that goes away takes its in-flight request with it.

**race.** Every operation runs as a child task. The first success wins; the
rest are cancelled (`superseded`) and then awaited, so `race` never returns
while a loser runs. If every operation fails, the first failure is thrown and
the rest reported (`race.all_failed`) — passthrough, not a wrapper. The
natural variadic spelling crashes the Swift 6.4 compiler at call sites (a
SILGen assertion), and array literals of closures are not inferred
`@Sendable`, hence fixed arities and `Racer`.

**hedge.** Moves to the resilience policies (design/10).

**mapConcurrent.** At most `limit` transforms run; elements start in
order; results return in input order. On the first failure the rest are
cancelled (`siblingFailed`) and that failure alone is thrown — failures
caused by the cancellation are not reported as failures.
`mapConcurrentResults` runs everything and returns each outcome.

**Child-task closures are `@concurrent`.** They run concurrently by design;
the explicit attribute keeps that true under `NonisolatedNonsendingByDefault`.

**AsyncSemaphore and AsyncMutex.** Strict FIFO. A waiter that is cancelled,
or whose `Deadline.current` passes, leaves the queue and never consumes a
permit — arrivals are tracked so even a cancellation that lands before the
waiter queues is honoured. Cancellation caused by an enclosing deadline is
reported as `deadlineExceeded`. `withPermit` is the only way to hold a
permit. Re-acquiring a semaphore the task already holds is reported as
`semaphore.reentrant` — a self-deadlock in waiting. `AsyncMutex` is the
one-permit form: the cure for actor reentrancy's check–await–act race.

**SingleFlight.** The flight owns the operation. Callers leave with a
rejection (`cancelled` or `deadlineExceeded`) when they stop waiting; the
operation is cancelled only when the last caller leaves, and the key is
retired at once so newcomers start fresh instead of joining a flight being
cancelled. The operation runs without the first caller's deadline; each
caller's wait is bounded by its own.

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

| What happens if…                                        | Behaviour                                                                                                                                             |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| a superseded `TaskSlot` task finishes after the new one | Its result is dropped inside the slot; `slot.superseded_late` event                                                                                   |
| a `TaskSlot` task ignores cancellation forever          | Next `run` does not wait for it (it is not structured to the slot's caller); it is counted in `slot.stragglers`, and the test kit fails on stragglers |
| every racer fails                                       | `ConcurrentFailure` with all errors, completion order                                                                                                 |
| a racer ignores cancellation after another won          | `race` waits for it (structured); `race.slow_loser` event after one overrun period                                                                    |
| the hedge budget is empty                               | No further hedges; the attempts already running continue                                                                                              |
| `mapConcurrent` caller is cancelled                     | All children cancelled and awaited; `CancellationError` propagates                                                                                    |
| a semaphore waiter is cancelled while queued            | Removed from the queue; no permit consumed; `CancellationError`                                                                                       |
| a semaphore waiter's deadline passes while queued       | Removed; `.rejected(.deadlineExceeded)`                                                                                                               |
| a body inside `withPermit` throws                       | Permit returned; error passed through as `.failed`                                                                                                    |
| two single-flight waiters, the first cancels            | The operation continues for the second                                                                                                                |
| every single-flight waiter cancels                      | The operation is cancelled                                                                                                                            |

## Events

`slot.superseded`, `slot.superseded_late`, `slot.dropped`, `race.won`
(index, latency), `race.slow_loser`, `hedge.started` (attempt), `hedge.won`,
`semaphore.wait` (when a wait exceeds a threshold), `singleflight.joined`.

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

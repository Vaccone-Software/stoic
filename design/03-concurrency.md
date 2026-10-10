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
// Only the latest: starting new work cancels and awaits the previous.
public final class TaskSlot<Success: Sendable, Failure: Error>: Sendable {
    public init(label: String, isolation: isolated (any Actor)? = #isolation)
    public func run(_ op: sending @escaping @isolated(any) () async throws(Failure) -> Success,
                    deliver: @escaping @isolated(any) (Result<Success, Failure>) -> Void)
    public func cancel() async
    public var isRunning: Bool { get }
}

// First success wins; losers cancelled and awaited.
public nonisolated(nonsending) func race<R: Sendable, Failure: Error>(
    _ operations: [@Sendable () async throws(Failure) -> R]
) async throws(ConcurrentFailure<Failure>) -> R

// Second attempt after a delay if the first is slow. Only for idempotent work.
public nonisolated(nonsending) func hedge<R: Sendable, Failure: Error>(
    _ idempotency: Idempotency,            // must be .idempotent — the argument is the acknowledgement
    after delay: HedgeDelay,               // .fixed(Duration) or .percentile(0.95, of: LatencyTracker)
    maxAttempts: Int = 2,
    budget: RetryBudget? = nil,
    operation: @escaping @Sendable (Attempt) async throws(Failure) -> R
) async throws(ConcurrentFailure<Failure>) -> R

// Bounded parallel map; results in input order.
public nonisolated(nonsending) func mapConcurrent<Element: Sendable, R: Sendable, Failure: Error>(
    _ elements: some Collection<Element>,
    limit: Int,
    onFailure: FailurePolicy = .cancelRemaining,   // or .collectAll
    transform: @escaping @Sendable (Element) async throws(Failure) -> R
) async throws(ConcurrentFailure<Failure>) -> [R]

// FIFO, cancellation-aware. Scoped use only: no public acquire/release pair.
public final class AsyncSemaphore: Sendable {
    public init(permits: Int, label: String)
    public nonisolated(nonsending) func withPermit<R, Failure: Error>(
        _ body: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R    // .rejected(.deadlineExceeded) if the wait outlives the deadline
}

// Concurrent callers for the same key share one execution.
public final class SingleFlight<Key: Hashable & Sendable, Value: Sendable, Failure: Error>: Sendable {
    public nonisolated(nonsending) func run(
        _ key: Key, _ op: @escaping @Sendable () async throws(Failure) -> Value
    ) async throws(Failure) -> Value
}
```

## Semantics

**TaskSlot.** The structured replacement for generation counters. `run`
cancels the slot's current task with cause `.superseded`, starts the new
one, and guarantees that only the newest task's result is ever delivered:
a superseded task that finishes late (because it ignored cancellation) has
its result dropped inside the slot, so no caller-side comparison is needed.
`deliver` runs on the slot's isolation (typically the main actor) so it can
touch UI state directly. `cancel()` cancels and awaits the current task.
When the slot's owner ends — a scope, a state (design/07), a supervisor
child — the slot is cancelled with it. A slot that is deinitialised with a
task still running cancels it and emits `slot.dropped`, which the test kit
turns into a failure.

**race.** Every operation runs as a child task. The first _success_ wins;
the rest are cancelled with cause `.superseded` and then **awaited** —
structured concurrency is kept, so race never returns while a loser is
still running. For losers that cannot be cancelled, wrap them in the
abandoning `withTimeout` (design/01); race itself never abandons. If every
operation fails, race throws all the failures in completion order. An empty
array is a precondition failure.

**hedge.** Starts attempt 1; if it has not finished after `delay`, starts
attempt 2 without cancelling attempt 1, and so on up to `maxAttempts`. The
first success wins and the rest are cancelled and awaited. Each hedge draws
from the retry budget, so hedging cannot amplify load during an outage
beyond the budget's ratio. The `Idempotency` argument has a single case,
`.idempotent`: it exists so that hedging non-idempotent work requires
writing a lie in the source. `.percentile` delays read a rolling latency
histogram the caller owns.

**mapConcurrent.** At most `limit` transforms run at once; elements are
started in order; results come back in input order regardless of completion
order. `.cancelRemaining` (default) cancels outstanding work on the first
failure and throws every failure observed before the group drained;
`.collectAll` runs everything and throws all failures at the end. `limit` ≤ 0
is a precondition failure; `limit` larger than the collection is fine.

**AsyncSemaphore.** Strict FIFO. A waiter that is cancelled, or whose
deadline passes, is removed from the queue _and never consumes a permit_ —
the classic bug in hand-written async semaphores, where a permit granted to
an already-cancelled waiter leaks. The only public use is `withPermit`, so a
permit cannot be leaked by a missing release; the permit is returned on
success, failure and cancellation. A bulkhead (design/10) is a semaphore
with a bounded queue that rejects instead of waiting.

**SingleFlight.** The first caller for a key starts the operation; later
callers for the same key await the same result. Cancellation is reference
counted: one waiter cancelling detaches only that waiter; the operation is
cancelled when the _last_ waiter has cancelled. When it finishes, the key is
cleared, so the next call starts fresh (single-flight is deduplication, not
caching).

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

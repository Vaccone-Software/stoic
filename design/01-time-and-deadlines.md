# 01 · Time and deadlines

Every wait has an end (Principle 2). This contract defines how Stoic names
that end: deadlines that propagate through the task tree, timeouts that are
deadlines with a duration, and the one sanctioned way to stop waiting for
work that will not stop.

## Origin

- **Swift.** SE-0526 `withDeadline` was accepted with modifications after
  three reviews and has not shipped. It makes the active deadline task-scoped,
  narrows nested deadlines to the tightest, passes the operation's own error
  through, and adds `CancellationError.Reason` (`.deadlineExpired`). It is
  cooperative: never a hard timeout.
- **gRPC and Go.** Deadline propagation: a callee never gets more time than
  its caller has left. Go 1.21's cancellation causes and `WithoutCancel`.
- **In apps.** The usual hand-rolled timeout is a continuation, two tasks and
  a lock-guarded "first answer" box. The timer is rarely cancelled when the
  work wins, and the losing work often cannot be cancelled at all — a
  CoreAudio start on a wedged queue, a synchronous call into a hung process.
  The task-group version gets abandoned because a group waits for every
  child, including the one that will never finish.
## API

```swift
// The deadline in force for the current task, if any. Narrowed, never widened.
public struct Deadline: Sendable, Comparable {
    public let instant: AnyClock.Instant
    public let clock: AnyClock
    public static var current: Deadline? { get }
    public var remaining: Duration { get }        // ≤ .zero once passed
    public var hasPassed: Bool { get }
}

// Cooperative: cancel the operation when the deadline passes, then wait for it.
public nonisolated(nonsending) func withDeadline<R, Failure: Error>(
    _ deadline: Deadline,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Failure) -> R

public nonisolated(nonsending) func withTimeout<R, Failure: Error>(
    _ duration: Duration,
    clock: AnyClock? = nil,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Failure) -> R

// For work that cannot be cancelled: stop waiting, keep it accountable.
public nonisolated(nonsending) func withTimeout<R: Sendable, Failure: Error>(
    _ duration: Duration,
    onUncooperative: Abandonment,           // .abandon(limit:, label:)
    operation: sending @escaping @isolated(any) () async throws(Failure) -> R
) async throws(PolicyError<Failure>) -> R

// Why the current task was cancelled, when Stoic did it.
public enum CancellationCause: Sendable { case deadline, userRequested, superseded, scopeEnded, supervisorStopped }
public var currentCancellationCause: CancellationCause? { get }
```

## Semantics

**Propagation.** `withDeadline` installs the earlier of the new deadline and
`Deadline.current`. A nested `withTimeout(.seconds(30))` inside an outer
two-second deadline gets two seconds. Every Stoic primitive consults
`Deadline.current`: `retry` will not start an attempt that cannot finish,
semaphores and rate limiters stop waiting at it, scopes bound their
finalizers by it (with their own floor, design/04).

**Cooperative timeout.** The operation runs in a child task; a timer runs in
a sibling. When the operation finishes, the timer is cancelled — the defect
hand-rolled versions share. When the timer fires first, the operation's task is
cancelled with cause `.deadline` and Stoic _waits for it to finish_. The
result is whatever the operation returns or throws: passthrough, exactly as
SE-0526. An operation that honours cancellation throws `CancellationError`,
and `currentCancellationCause` (or `Task.cancellationReason` once SE-0526
ships) says why.

**Already passed.** If the deadline has passed before `withDeadline` is
entered, the operation is still run, already cancelled, so cancellation-aware
code exits immediately and cleanup inside it still happens. This matches
SE-0526 and keeps "the operation always ran" true for callers who rely on it.
Policies that would rather not start at all check `Deadline.current` first and
throw `.rejected(.deadlineExceeded)` (design/10).

**Abandoning timeout.** For operations that ignore cancellation (a CoreAudio
start on a wedged queue), `onUncooperative: .abandon` returns at the deadline
with `PolicyError.rejected(.deadlineExceeded)` and leaves the operation
running as an unstructured task Stoic still tracks:

- The operation is cancelled first, so if it _can_ notice, it does.
- It is registered in a process-wide abandonment ledger with its label,
  start time and call site; `Abandoned.current` lists them for diagnostics.
- `limit:` caps concurrent abandoned operations per label (default 4). Past
  the cap, `withTimeout` refuses to start another: `.rejected(.abandonmentLimit)`.
  A hung subsystem therefore costs a bounded number of threads, not one per
  attempt.
- When an abandoned operation finally finishes, its result is dropped and an
  `abandoned.completed` event records how late it was; a never-finishing one
  shows up in `abandoned.outstanding` on every diagnostics snapshot.
- The closure is `sending @isolated(any)` because it outlives the caller; the
  type system makes the caller give up what it captured.

**Clocks.** Deadlines use the ambient continuous clock: if the machine
sleeps through a deadline, it has passed. A deadline remembers its clock;
comparing deadlines from different clocks converts through each clock's
remaining duration at the moment of comparison (documented as approximate;
mixing clocks is linted in tests).

**Forwarding.** When the standard library ships SE-0526, `withDeadline`
becomes a thin wrapper over it (same semantics, so callers see no change),
`currentCancellationCause` maps from `Task.cancellationReason`, and the
duplicate types are deprecated with one minor version of overlap.

## Failure modes

| What happens if…                                                  | Behaviour                                                                                  |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| the operation finishes first                                      | Timer cancelled and awaited; result returned; no event                                     |
| the deadline passes, operation honours cancellation               | Operation cancelled with cause `.deadline`; its error passes through; `deadline.expired`   |
| the deadline passes, operation ignores cancellation (cooperative) | Stoic waits — cooperative means cooperative; `deadline.overrun` event every overrun period |
| the deadline passes, operation ignores cancellation (abandoning)  | Returns `.rejected(.deadlineExceeded)` at the deadline; operation tracked in the ledger    |
| the abandonment limit for a label is reached                      | Refuses to start: `.rejected(.abandonmentLimit)`; `abandoned.limit` event                  |
| the caller is cancelled                                           | Operation cancelled with cause `.userRequested`; timer cancelled; caller's error rules     |
| an inner timeout is longer than the outer deadline                | The outer deadline wins; the inner one is a no-op                                          |
| the deadline has already passed on entry                          | Operation runs already cancelled (cooperative) / never starts (abandoning)                 |
| the clock is a test clock that never advances                     | Nothing fires; the test clock reports the pending deadline in its idle diagnostics         |
| the Mac sleeps past the deadline                                  | Continuous clock: the deadline passes on wake and fires immediately                        |

## Events

`deadline.expired` (label, budget, overrun), `deadline.overrun` (still
running after the deadline, cooperative), `abandoned.started`,
`abandoned.completed` (lateness), `abandoned.limit`.

## Testing

- Virtual-clock tests for every row above, including the timer-cancelled
  check: after the operation wins, the clock must report no pending sleeper.
- Property: for any nesting of deadlines, the effective deadline is the
  minimum, and no operation observes a later one.
- Fault injection: `hangIgnoringCancellation` models CoreAudio; the
  abandoning form must return within one scheduler tick of the deadline and
  leave exactly one ledger entry.
- Stress: ten thousand races between completion and expiry with seeded
  timing; no lost results, no double resumes (the noncopyable `Continuation`
  of SE-0528 makes a double resume a compile error, and Stoic uses it).

## Non-goals

Hard preemption of Swift tasks (impossible and unsafe), wall-clock
(`Date`-based) deadlines, and timeouts on synchronous code.

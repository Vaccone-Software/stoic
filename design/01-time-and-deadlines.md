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
public struct Deadline: Sendable {
    public let instant: AnyClock.Instant
    public let clock: AnyClock
    public static func after(_ duration: Duration, clock: AnyClock? = nil) -> Deadline
    public static var current: Deadline? { get }
    public var remaining: Duration { get }        // zero once passed
    public var hasPassed: Bool { get }
    public func earlier(_ other: Deadline) -> Deadline
}

// Cooperative: cancel the operation when the deadline passes, then wait for it.
public nonisolated(nonsending) func withDeadline<R: Sendable, Failure: Error>(
    _ deadline: Deadline, tolerance: Duration? = nil, label: String? = nil,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws(Failure) -> R
) async throws(Failure) -> R

public nonisolated(nonsending) func withTimeout<R: Sendable, Failure: Error>(
    _ duration: Duration, clock: AnyClock? = nil, tolerance: Duration? = nil, label: String? = nil,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws(Failure) -> R
) async throws(Failure) -> R

// For work that cannot be cancelled: stop waiting, keep it accountable. (Not yet built; see below.)
public nonisolated(nonsending) func abandoningAfter<R: Sendable, Failure: Error>(
    _ duration: Duration, label: String, limit: Int = 2, clock: AnyClock? = nil,
    qos: DispatchQoS.QoSClass = .userInitiated, operation: @escaping @Sendable () throws(Failure) -> R
) async throws(PolicyError<Failure>) -> R

// Why the current task was cancelled: an extensible struct, first cause wins.
public struct CancellationCause: Hashable, Sendable {
    public static let deadline, userRequested, superseded, scopeEnded, supervisorStopped
    public static var current: CancellationCause? { get }
}
```

## Semantics

**Propagation.** `withDeadline` installs the earlier of the new deadline and
`Deadline.current`. A nested `withTimeout(.seconds(30))` inside an outer
two-second deadline gets two seconds. Every Stoic primitive consults
`Deadline.current`: `retry` will not start an attempt that cannot finish,
semaphores and rate limiters stop waiting at it, scopes bound their
finalizers by it (with their own floor, design/04).

**Execution model.** The operation runs as a child task in a task group;
a timer runs as its sibling. This is the only model that lets a deadline
cancel the operation without cancelling the caller — cancellation is
irrevocable, so cancelling the caller's own task would leave it cancelled
after `withDeadline` returned. Two consequences, both deliberate:

- The closure is `sending @escaping @isolated(any)` and carries
  `@_inheritActorContext`, exactly like `Task {}`: written on the main
  actor, it runs on the main actor and may touch main-actor state, verified
  under Swift 6.4. The attribute is underscored; it is how the standard
  library spells this today, and Stoic will follow its replacement.
- The result must be `Sendable`, because it crosses from the child task.
  SE-0526, which the runtime implements without a child task, lifts this;
  Stoic forwards to it when it ships.

**Cooperative timeout.** When the operation finishes, the timer is cancelled — the defect
hand-rolled versions share — and the clock is left with no pending sleeper.
When the timer fires first, Stoic records ``CancellationCause/deadline`` and
cancels the operation's task, then _waits for it to finish_. The result is
whatever the operation returns or throws: passthrough, exactly as SE-0526.

**Causes.** Stoic records a cause before every cancellation it initiates,
in a box the cancelled task can read; nested scopes consult their enclosing
scopes' boxes. Cancellation no Stoic scope initiated reads as
`userRequested`, SE-0526's default. A first version recorded the caller's
cancellation from a cancellation handler; 300 repeated runs showed the child
can observe its cancellation before the handler runs, so the cause is now
resolved by elimination instead of by a racing write.

**Already passed.** If the deadline has passed before `withDeadline` is
entered, the operation is still run, already cancelled, so cancellation-aware
code exits immediately and cleanup inside it still happens. This matches
SE-0526 and keeps "the operation always ran" true for callers who rely on it.
Policies that would rather not start at all check `Deadline.current` first and
throw `.rejected(.deadlineExceeded)` (design/10).

**Abandoning timeout (`abandoningAfter`).** For work that ignores
cancellation — a synchronous CoreAudio call on a wedged queue, an
Accessibility call into a hung process — `abandoningAfter` returns
`.rejected(.deadlineExceeded)` at the deadline and leaves the work running,
accounted for. Review surfaced three hazards the first draft missed, and the
design answers each:

- **Thread starvation.** Blocking work holds a thread of the cooperative
  pool, which is only about as wide as the core count. Abandonable work
  therefore runs on a Dispatch queue, whose threads are not the
  cooperative pool's. The operation is synchronous by signature, so it
  cannot be mistaken for well-behaved async work. (A dedicated task
  executor was the first plan; Dispatch gives the same isolation with no
  unsafe executor code.)
- **Use after close.** Abandoned work may still hold a resource that its
  scope is about to release. Scopes count abandoned work started inside
  them and hand that count to finalizers (`Exit.abandoned`), and a resource
  may declare its release `.quarantine`: leak it deliberately and report,
  rather than close it under a zombie.
- **Threads parked without bound.** A label never occupies more than `limit`
  threads, running or abandoned: a call keeps its slot until its operation
  actually returns. Counting only abandoned work is not enough — a dozen
  concurrent callers are all admitted while running and all abandoned
  together. Callers past the cap wait for a slot, bounded by their deadline.
- **A permanent dead end.** When every slot of a label is held by abandoned
  work, `abandoningAfter` refuses at once (`.rejected(.abandonmentLimit)`)
  and emits `abandoned.wedged`, which a supervisor (design/09) can escalate
  to its terminal action: restart the process, the only cure for a wedged
  system framework.
- **Starting doomed work.** A caller that is already cancelled, or whose
  deadline has passed, is refused before anything is dispatched; otherwise
  the work would start only to be abandoned at once.

A label's slots exist only while a call or an operation under that label is
in flight (a call holds a lease, and so does an operation until it returns,
abandoned or not); the last lease retires them. A label built at runtime
(a device name, a path) therefore leaves nothing behind, and "a label's limit
is fixed by its first call" means its first call *while the label is live*.

Abandoned work is listed in a process-wide ledger (label, age, call site)
and appears in diagnostics until it finishes; a late finish is reported with
its lateness. Built: `abandoningAfter(_:label:limit:clock:qos:operation:)`, and its scope
integration: every scope counts work abandoned inside it (and inside scopes
within it) — `scope.abandonedWork` — and a release declared
`ifWorkAbandoned: .quarantine` is skipped and reported
(`scope.release_quarantined`) when that count is not zero. The count is not
a case of `Exit`, which would break every `switch` over it.

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
| the deadline passes, operation ignores cancellation (cooperative) | Stoic waits — cooperative means cooperative; `deadline.expired` reports the overrun when it ends |
| the deadline passes, operation ignores cancellation (abandoning)  | Returns `.rejected(.deadlineExceeded)` at the deadline; operation tracked in the ledger    |
| a label has `limit` operations running (abandoning)              | Later callers wait for a slot until their deadline: `.rejected(.deadlineExceeded)`         |
| every slot of a label is held by abandoned work                   | Refuses to start: `.rejected(.abandonmentLimit)`; `abandoned.wedged` event                 |
| an enclosing deadline cancels an abandoning call                  | `.rejected(.deadlineExceeded)`, not `.cancelled`                                           |
| the caller is cancelled                                           | Operation cancelled with cause `.userRequested`; timer cancelled; caller's error rules     |
| an inner timeout is longer than the outer deadline                | The outer deadline wins; the inner one is a no-op                                          |
| the deadline has already passed on entry                          | Operation runs already cancelled (cooperative) / never starts (abandoning)                 |
| the caller is already cancelled on entry (abandoning)             | Never starts: `.rejected(.cancelled)`                                                      |
| the clock is a test clock that never advances                     | Nothing fires; the test clock reports the pending deadline in its idle diagnostics         |
| the Mac sleeps past the deadline                                  | Continuous clock: the deadline passes on wake and fires immediately                        |

## Events

`deadline.expired` (label, budget, overrun, outcome), `abandoned.started`,
`abandoned.completed` (lateness), `abandoned.wedged`.

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

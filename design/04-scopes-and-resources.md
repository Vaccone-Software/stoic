# 04 · Scopes and resources

A scope is Effect's `Scope` plus `acquireRelease`, built from the parts
Swift 6.4 finally ships. Anything acquired in a scope is released when the
scope ends — on success, on failure, on cancellation — in reverse order,
shielded from cancellation, and within a bounded time. Work forked in a
scope is cancelled and awaited before any release runs.

## Origin

- **Effect / Cats Effect.** `Scope`, `acquireRelease`, `Resource`, `Exit`;
  Cats' `uncancelable` mask for the release path.
- **Rust.** RAII and `Drop`, and their weak point: async drop is still
  nightly-only in 2026. Swift is now ahead: `await` in `defer` (SE-0493)
  inside a cancellation shield (SE-0504) gives guaranteed async cleanup
  under cancellation.
- **Arrow.** `Saga` with compensations as a first-class primitive.
- **In apps.** Sockets closed by hand on each exit path, observers removed
  in `deinit` (which cannot `await`), idle-release timers that race the next
  load, and model or session handles that leak a little on every reload.
## API

```swift
public struct Scope: ~Copyable {
    // Acquire, and register the release in the same breath.
    public func acquire<R, Failure: Error>(
        _ acquire: nonisolated(nonsending) () async throws(Failure) -> R,
        release: @escaping @Sendable (R, Exit) async -> Void,
        label: String = #function
    ) async throws(Failure) -> R where R: Sendable

    public func acquire<R: Sendable, Failure: Error>(_ resource: Resource<R, Failure>) async throws(Failure) -> R

    // Register a finalizer for something already acquired.
    public func onExit(label: String, timeout: Duration? = nil,
                       _ finalizer: @escaping @Sendable (Exit) async -> Void)

    public var exitDeadlineFloor: Duration { get }   // minimum time every finalizer gets
}

// A scope that also owns child tasks. Separate, because child failures are
// heterogeneous: a TaskScope's body is typed, but the scope throws `any Error`.
public struct TaskScope: ~Copyable {
    public var resources: Scope { borrowing get }
    // Child work owned by the scope: cancelled and awaited at exit, before releases.
    public func fork(label: String, _ work: sending @escaping @isolated(any) () async throws -> Void)
}

public enum Exit: Sendable { case success, failure(any Error), cancelled }

public nonisolated(nonsending) func withScope<R, Failure: Error>(
    finalizerTimeout: Duration = .seconds(5),
    _ body: nonisolated(nonsending) (borrowing Scope) async throws(Failure) -> R
) async throws(Failure) -> R

public nonisolated(nonsending) func withTaskScope<R>(
    finalizerTimeout: Duration = .seconds(5),
    _ body: nonisolated(nonsending) (borrowing TaskScope) async throws -> R
) async throws -> R

// A reusable acquire/release description, composable.
public struct Resource<Value: Sendable, Failure: Error>: Sendable {
    public init(acquire: @escaping @Sendable () async throws(Failure) -> Value,
                release: @escaping @Sendable (Value, Exit) async -> Void)
    public func map<T>(_ f: @escaping @Sendable (Value) -> T) -> Resource<T, Failure>
    public func flatMap<T>(_ f: @escaping @Sendable (Value) -> Resource<T, Failure>) -> Resource<T, Failure>
}

// Compensations run in reverse when the body fails or is cancelled.
public nonisolated(nonsending) func withSaga<R, Failure: Error>(
    _ body: nonisolated(nonsending) (borrowing Saga) async throws(Failure) -> R
) async throws(Failure) -> R
```

```swift
try await withTaskScope { scope in
    let socket = try await scope.resources.acquire { try Socket.bind(path) }
                                           release: { socket, _ in await socket.close() }
    let model = try await scope.resources.acquire(Model.resource(config))
    scope.fork(label: "heartbeat") { try await heartbeat(socket) }
    try await serve(socket, model)
}
```

## Semantics

**The handle cannot escape.** `Scope` is `~Copyable` and the body receives it
`borrowing`. The compiler rejects capturing it in an escaping closure
("cannot be captured by an escaping closure since it is a borrowed
parameter"), so nothing can register a finalizer on a scope that has already
ended. Verified with the Swift 6.4 compiler; `~Escapable` would say the same
thing but still needs experimental lifetime features to construct.

**Acquire is atomic with registration.** Cancellation in Swift cannot
interrupt synchronous code, so the moment between `acquire` returning and its
release being registered is not a window — Stoic registers the release before
returning the value to the body. If the acquire itself throws or is
cancelled, nothing is registered (acquire is responsible for its own partial
state). Acquires that must not be interrupted halfway are wrapped by the
caller in a shield; Stoic offers `acquire(shielded: true)` to make that a
one-word decision.

**Exit order.** When the body returns, throws or is cancelled:

1. Forked children are cancelled (cause `.scopeEnded`) and awaited.
2. Finalizers run one at a time in reverse registration order.
3. Each runs inside `withTaskCancellationShield`, so cancellation-aware
   cleanup code does not skip its work, and receives the `Exit` so it can
   choose (roll back on failure, flush on success).
4. Each runs under its own timeout (`timeout:` or `finalizerTimeout`). A
   finalizer that overruns is abandoned through the bounded ledger
   (design/01), reported, and the next finalizer runs — one hung release does
   not hold every later release hostage.
5. The body's outcome is returned or rethrown, unchanged.

**Finalizers are for release, not for commit.** A finalizer that fails does
not change the body's outcome: its error is reported (`scope.finalizer_failed`,
error level) and, in debug builds, trips an assertion. Work whose failure must
change the outcome — committing a transaction, flushing a write the caller
depends on — belongs at the end of the body, where its error propagates. This
is Java's suppressed-exception rule with the suppression made loud.

**Deadline interplay.** A scope inside an expiring deadline still cleans up:
finalizers get at least `exitDeadlineFloor` (default 1 s) even when the
enclosing deadline has passed, because cleanup that never runs is worse than
cleanup that runs a second late.

**Forked children (TaskScope).** A child that throws cancels the body and
its siblings (fail-fast, like a throwing task group). After cleanup the
scope throws a `ConcurrentFailure<any Error>` holding every child failure in
completion order, followed by the body's own error if it threw something
other than the `CancellationError` the child's failure caused. A child that
returns normally is simply done; a child cancelled by the scope's exit is
not a failure. Children are for work that lives exactly as long as the
scope — heartbeats, pumps, observers. Plain `withScope` has no `fork`, so
its body's typed error passes through untouched; a function that needs
both typed errors and children nests a `withScope` inside the child.

**Saga.** `saga.step(perform:compensate:)` runs `perform`, and on success
registers `compensate` as an exit-aware finalizer that runs only when the
saga exits with failure or cancellation. Compensations run in reverse, each
shielded and time-bounded; a failed compensation is reported and the rest
still run.

**Typestate for single resources.** When a resource has states the caller
must move through (open → committed or rolled back), Stoic's guidance is a
`~Copyable` type with `consuming` transitions; `deinit` reports a resource
dropped mid-protocol (design/07 has the pattern). Scopes and typestate
compose: acquire the typestate value in a scope, so cancellation still
releases it.

## Failure modes

| What happens if…                                  | Behaviour                                                                              |
| ------------------------------------------------- | -------------------------------------------------------------------------------------- |
| the body succeeds                                 | Children awaited, finalizers run with `.success`, value returned                       |
| the body throws                                   | Finalizers run with `.failure(error)`, error rethrown unchanged                        |
| the task is cancelled mid-body                    | Finalizers run with `.cancelled`, shielded; `CancellationError` rethrown               |
| a finalizer throws (logs) / fails                 | Reported at error level; remaining finalizers run; outcome unchanged                   |
| a finalizer hangs                                 | Abandoned after its timeout via the ledger; `scope.finalizer_timeout`; next one runs   |
| the acquire throws                                | Nothing registered; error rethrown; earlier acquisitions are released                  |
| a forked child throws                             | Body and siblings cancelled; after cleanup, `ConcurrentFailure` with every child error |
| the enclosing deadline has already passed at exit | Finalizers still get `exitDeadlineFloor` each                                          |
| someone tries to keep the `Scope`                 | Compile error                                                                          |

## Events

`scope.finalizer_failed`, `scope.finalizer_timeout`, `scope.finalizer_slow`
(over half its timeout), `scope.child_failed`, `saga.compensated`,
`saga.compensation_failed`.

## Testing

- Exhaustive outcome matrix (success, throw, cancel) × (0, 1, n finalizers)
  × (finalizer ok, throws, hangs) × (0, 1, n children), on the virtual clock,
  asserting order, `Exit` value and outcome.
- Property: for any random interleaving of acquire, fork, throw and cancel,
  every acquired resource is released exactly once, in reverse order.
- A compile-fail test (a fixture target the test suite builds and expects to
  fail) proves the scope handle cannot escape.
- Leak test: thousands of scopes under random cancellation; the resource
  counter returns to zero.

## Non-goals

Reference-counted shared resources (`RcRef`) before a real use appears; async
`deinit` (no Swift proposal exists).

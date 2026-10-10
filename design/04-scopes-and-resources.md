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
    public func acquire<R: Sendable, Failure: Error>(label:, shielded: Bool = false, timeout: Duration? = nil,
        _ acquire: nonisolated(nonsending) () async throws(Failure) -> R,
        release: @escaping @Sendable (R, Exit) async throws -> Void) async throws(Failure) -> R
    public func acquire<R, Failure>(_ resource: Resource<R, Failure>) async throws(Failure) -> R
    public func onExit(label:, timeout:, _ finalizer: @escaping @Sendable (Exit) async throws -> Void)
}
public struct Resource<Value: Sendable, Failure: Error>: Sendable { init(label:shielded:timeout:acquire:release:) }
public enum Exit: Sendable { case success, failure(any Error), cancelled }

public nonisolated(nonsending) func withScope<R, Failure: Error>(
    exitBudget: Duration = .seconds(10), finalizerTimeout: Duration = .seconds(5), label: String? = nil,
    _ body: nonisolated(nonsending) (borrowing Scope) async throws(Failure) -> R) async throws(Failure) -> R

public struct TaskScope: ~Copyable { func fork(label:, _:); acquire…; onExit… }
public nonisolated(nonsending) func withTaskScope<R: Sendable>(…,
    @_inheritActorContext _ body: sending @escaping @isolated(any) (borrowing TaskScope) async throws -> R) async throws -> R

public struct Saga: ~Copyable { func step(_ action:, compensate:) }
public nonisolated(nonsending) func withSaga<R, Failure: Error>(…, _ body: (borrowing Saga) async throws(Failure) -> R) async throws(Failure) -> R
```

## Semantics

**The handle cannot escape.** `Scope`, `TaskScope` and `Saga` are
`~Copyable` and handed to the body `borrowing`; the compiler rejects
capturing them in an escaping closure. Verified against Swift 6.4.
(`~Escapable` would say the same, but constructing one still needs
experimental lifetime features.)

**Acquire is atomic with registration.** Swift cannot interrupt
synchronous code, so the release is registered before the value reaches the
body. `shielded: true` runs the acquire itself hidden from cancellation.

**Exit.** When the body returns, throws or is cancelled, finalizers run one
at a time, newest first. Waiting for them is shielded
(`withTaskCancellationShield`), so a cancelled task still cleans up. Each
finalizer runs in its own task and gets `max(250 ms, min(its timeout,
what is left of exitBudget))`: a total budget, so n finalizers cannot add up
to n × timeout, and a floor, because cleanup that never runs is worse than
cleanup that runs late. A finalizer that overruns is abandoned —
`scope.finalizer_abandoned`, error level — and the next one runs.

**Finalizers cannot change the outcome.** They may throw; the error is
reported (`scope.finalizer_failed`) and the body's result or error passes
through unchanged. Work whose failure must change the outcome — committing
a transaction — belongs at the end of the body. Review rejected asserting
in debug on a reported failure: it would crash every test of that path.

**TaskScope.** Children forked into a task scope are cancelled
(`scopeEnded`) and awaited when the body ends, *before* any finalizer runs,
so no fork can use a released resource. A failing fork cancels the body and
its siblings (`siblingFailed`); the scope then throws `ConcurrentFailure`
with every fork failure followed by the body's own error if it failed for
another reason. The body runs as a child task — the only way a fork's
failure can cancel it without cancelling the caller — so, like `Task {}`, it
inherits the caller's actor and returns a `Sendable` result. `withScope`
has no forks, so its body runs inline with any captures and a typed error.

**Saga.** A step's compensation is registered only once the step
succeeds, and runs only if the saga ends in failure or cancellation:
newest first, shielded, time-bounded, each one even if an earlier one
failed. Compensations live in memory; effects that must be undone across a
crash need a durable journal (design/15, `StoicStore`).

**Typestate.** For a single resource with states to move through, use a
`~Copyable` type with `consuming` transitions; a scope then guarantees
release even under cancellation by holding a *release token*, not the
typestate value itself (ownership is single, so the value cannot be both
returned to the body and kept by the release closure).

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

`scope.finalizer_failed`, `scope.finalizer_abandoned`, `scope.finalizer_slow`
(over half its allowance), `scope.child_failed`, `scope.fork_after_exit`.

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

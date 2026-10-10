---
name: stoic
description: Write robust Swift app code with the Stoic library — timeouts, retry, scopes, task slots, state machines, supervisors, service graphs, structured errors and schema validation — and test it on virtual time. Use when code imports Stoic, or when Swift code hand-rolls timeouts, retry loops, generation counters, cleanup in defer/deinit, semaphores in async code, unbounded AsyncStreams, or watchdogs.
---

# Using Stoic

Stoic's primitives replace patterns that are easy to write wrongly. When you
see the pattern on the left, use the primitive on the right; `llms.txt` at the
repository root lists every entry point.

| Pattern | Primitive |
|---|---|
| timeout built from a continuation and two tasks | `withTimeout(_:)` (cooperative) or `abandoningAfter(_:label:)` (blocking, uncancellable work) |
| `for attempt in 0..<n { do {…} catch { sleep } }` | `retry(.exponential(base:).attempts(n))` |
| generation counter checked in callbacks | `TaskSlot` or `StateMachine.whileIn` |
| booleans tracking a lifecycle | `StateMachine` |
| cleanup needing `await`, or in `deinit` | `withScope` + `scope.acquire(…, release:)` |
| `DispatchSemaphore` in async code | `AsyncSemaphore` / `AsyncMutex` |
| `AsyncStream` with default (unbounded) buffering | `Channel(capacity:overflow:)` |
| unbounded task group over a large collection | `mapConcurrent(_:limit:)` |
| `while true { do {…} catch { sleep } }` keeping work alive | `Supervisor` |
| startup/teardown lists in the app delegate | `ServiceGraph` |
| hand-written config validation | `StoicSchema` `Schema.object` |
| `try?` / `catch { print(error) }` | handle it, or `withContext("…") { … }` |

## Rules

1. Every retry ends in `.attempts(n)`; it will not compile otherwise.
2. Create an `IdempotencyKey` outside `retry` for non-idempotent requests.
3. Don't nest retries for the same dependency (inner ones make one attempt).
4. Never catch `CancellationError` to keep going; never wrap it.
5. Bug-shaped errors conform to `Defect`; dependency errors to `Retryable`.
6. Release resources in finalizers; commit in the body.
7. No `@unchecked Sendable`, `nonisolated(unsafe)` or `try!` without a written reason.
8. Tests: `TestClock` + `waitForSleepers(count:)` + `advance(by:)`; `ImmediateClock` only to record delays; `FaultInjector` for failures; `@Test(.stoic(seed:))` for isolation. No real sleeps. For concurrent logic (caches, sync engines, anything with shared state across tasks), add a `simulate(seeds: 0..<500) { sim in … }` test: it explores interleavings deterministically and a failure names the seed that replays it.

## Compiler gotchas

- Typed-throws closures need `{ _ throws(MyError) in … }`; Swift does not infer them.
- `withTimeout`, `retry(_:attemptTimeout:)`, `TaskSlot.run`, `withTaskScope` run work in a child task: results must be `Sendable`, captured mutable locals are rejected; on an actor, the closure runs on that actor.
- `race` takes two to four closures, or `[Racer]`.

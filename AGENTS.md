# Stoic for agents

Rules for writing app code with Stoic, and for working on Stoic itself.
Short on purpose: each rule is one you can check.

## Writing app code with Stoic

### Reach for the primitive, not the pattern

| Instead of…                                               | Use                                                   |
| --------------------------------------------------------- | ----------------------------------------------------- |
| a continuation + two tasks + a flag to time something out | `withTimeout(_:)` / `withDeadline(_:)`                |
| `for attempt in 0..<3 { do { … } catch { sleep } }`       | `retry(.exponential(base:).attempts(n))`              |
| `Task.sleep` in code tests should control                 | `Ambient.sleep(for:)`, or pass `clock:`               |
| a generation counter compared in a callback               | `TaskSlot`, or `StateMachine.whileIn`                 |
| several booleans tracking a lifecycle                     | `StateMachine`                                        |
| cleanup in `defer` that needs `await`, or in `deinit`     | `withScope` + `scope.acquire(…, release:)`            |
| `DispatchSemaphore` around async work                     | `AsyncSemaphore` / `AsyncMutex`                       |
| `AsyncStream` with an unbounded buffer                    | `Channel(capacity:overflow:)`                         |
| a task group with no limit over a big collection          | `mapConcurrent(_:limit:)`                             |
| a "while true, catch, sleep" loop keeping work alive      | `Supervisor`                                          |
| a teardown list in `applicationWillTerminate`             | `ServiceGraph`                                        |
| `try?`, or `catch { print(error) }`                       | handle it, or `withContext("what I was doing") { … }` |
| a token in a `String` property                            | `Secret<String>`                                      |

### Rules

1. **Bound every wait.** Every retry has `.attempts(n)`; long operations
   run under a deadline; queues have a capacity.
2. **Never retry what is not idempotent** unless the server deduplicates:
   create an `IdempotencyKey` _outside_ the `retry` and send it with every
   attempt.
3. **Retry at one layer.** Nested retries collapse to one attempt by
   default; do not pass `nesting: .allow` unless the layers retry different
   dependencies.
4. **Let cancellation be cancellation.** Do not catch `CancellationError`
   to continue; do not wrap it. `withContext` already passes it through.
5. **Conform bug-shaped errors to `Defect`** so they are never retried.
   Conform dependency errors to `Retryable` so every retry classifies them
   the same way.
6. **Release in finalizers; commit in the body.** A finalizer's failure
   does not change the outcome; a commit's failure must.
7. **No escape hatches without a reason in a comment:** `@unchecked
Sendable`, `nonisolated(unsafe)`, `try!`, `@preconcurrency`. With the
`StoicLint` plugin the first three fail the build unless the reason is
written as `// stoic:allow(<rule>): <why>` on that line or the one above
(`design/13`).
8. **Test on virtual time.** `TestClock` for anything that races time,
   `ImmediateClock` only for recording delays (its timers fire at once),
   `FaultInjector` for failures, `@Test(.stoic(seed:))` for isolation.
   Wait with `clock.waitForSleepers(count:)`, never with real sleeps.

### Gotchas the compiler will show you

- A closure with a typed throw needs the annotation: `{ _ throws(MyError) in … }`.
  Swift 6.4 does not infer typed throws from a closure body.
- `withTimeout`, `retry(attemptTimeout:)`, `TaskSlot.run` and
  `withTaskScope` run work in a child task, like `Task {}`: results must be
  `Sendable`, and captured mutable locals are not allowed. Written on an
  actor, the closure runs on that actor.
- `race` takes two to four closures or an array of `Racer`s.

## Working on Stoic

- **Build and test:** `swift build` and `swift test`. Warnings are errors.
  Stress a suite with
  `swift test --filter <Suite> --maximum-repetitions 300 --repeat-until fail`;
  every concurrency test must survive it.
- **Lint:** `swift run --traits Lint stoic-lint Sources Plugins Package.swift`
  must stay clean; the lint tests are `swift test --traits Lint --filter
StoicLintCoreTests`. Without the `Lint` trait, swift-syntax is never fetched.
- **Contracts first.** Each primitive has a contract in `design/`. Change the
  contract and the code together; a failure-mode table row without a test
  is a gap.
- **Events are API.** A new event goes in `EventCatalog`; the catalog test
  fails otherwise. Never rename one.
- **House style:** prose doc comments that explain _why_; typed errors
  pass through untouched; `Mutex` for synchronous state, never held across
  `await`; events recorded outside locks; no type named `Stoic`.
- **Commits:** small and focused, each building and passing tests, with a
  message that says what changed and why.

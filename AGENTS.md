# Stoic for agents

Rules for writing app code with Stoic, and for working on Stoic itself.
Short on purpose: each rule is one you can check.

## Writing app code with Stoic

### Reach for the primitive, not the pattern

| Instead of…                                                | Use                                                   |
| ---------------------------------------------------------- | ----------------------------------------------------- |
| a continuation + two tasks + a flag to time something out  | `withTimeout(_:)` / `withDeadline(_:)`                |
| `for attempt in 0..<3 { do { … } catch { sleep } }`        | `retry(.exponential(base:).attempts(n))`              |
| timeouts, retries and breakers picked at each service call | a declared `Backend` operation's `perform`            |
| `Task.sleep` in code tests should control                  | `Ambient.sleep(for:)`, or pass `clock:`               |
| a generation counter compared in a callback                | `TaskSlot`, or `StateMachine.whileIn`                 |
| several booleans tracking a lifecycle                      | `StateMachine`                                        |
| cleanup in `defer` that needs `await`, or in `deinit`      | `withScope` + `scope.acquire(…, release:)`            |
| `DispatchSemaphore` around async work                      | `AsyncSemaphore` / `AsyncMutex`                       |
| `AsyncStream` with an unbounded buffer                     | `Channel(capacity:overflow:)`                         |
| a task group with no limit over a big collection           | `mapConcurrent(_:limit:)`                             |
| a "while true, catch, sleep" loop keeping work alive       | `Supervisor`                                          |
| a teardown list in `applicationWillTerminate`              | `ServiceGraph`                                        |
| `try?`, or `catch { print(error) }`                        | handle it, or `withContext("what I was doing") { … }` |
| a token in a `String` property                             | `Secret<String>`                                      |
| ranges and defaults repeated in parser, clamp, UI and docs | `@Schema` (trait `Macros`), else `Schema.object`      |

### Rules

1. **Bound every wait.** Every retry has `.attempts(n)`; long operations
   run under a deadline; queues have a capacity.
2. **Never retry what is not idempotent** unless the server deduplicates:
   send `attempt.idempotencyKey`, which is the same on every attempt, or
   create an `IdempotencyKey` _outside_ the `retry`.
3. **Retry at one layer.** Nested retries collapse to one attempt by
   default; do not pass `nesting: .allow` unless the layers retry different
   dependencies.
4. **Declare backends and operations; never pick resilience numbers at a
   call site.** Each dependency is a `static let` `Backend`, each call to it
   a declared operation (`readOnly`, `idempotent`, `keyed`,
   `notRepeatable`); call `perform`, and say who waits with `withUrgency`.
   A `.keyed` operation sends `attempt.idempotencyKey`; an `.unknown`
   outcome is reconciled under its key, never asked again (design/22).
5. **Let cancellation be cancellation.** Do not catch `CancellationError`
   to continue; do not wrap it. `withContext` already passes it through.
6. **Conform bug-shaped errors to `Defect`** so they are never retried.
   Conform dependency errors to `Retryable` so every retry classifies them
   the same way; claim `neverReachedBackend` only on proof nothing was sent.
7. **Release in finalizers; commit in the body.** A finalizer's failure
   does not change the outcome; a commit's failure must.
8. **No escape hatches without a reason in a comment:** `@unchecked
Sendable`, `nonisolated(unsafe)`, `try!`, `@preconcurrency`. With the
   `StoicLint` plugin each fails the build unless the reason is
   written as `// stoic:allow(<rule>): <why>` on that line or the one above
   (`design/13`).
9. **Test on virtual time.** `TestClock` for anything that races time,
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
- `TaskSlot.run(for: self)` must be called on an actor, and `deliver` gets
  the owner: write `{ @MainActor model, result in model.x = … }`, and capture
  what the work needs (`[api]`), never `self`, or the owner cannot go.

## Working on Stoic

- **Check everything:** `scripts/check.sh` (the package graph, build, tests,
  Thread and Address Sanitizer, lint tests, self-lint, the examples' lint with
  no baseline, the public API check, the allocation gate, macros, adoption
  from outside, iOS, docs; `--stress` adds 100 repetitions of every suite),
  and `scripts/linux.sh --docker` for Linux. Warnings are errors.
- **The package graph:** a new dependency between Stoic's libraries must be
  allowed in `scripts/package-graph.swift`'s layering, in the same change;
  every import must be a declared, direct dependency, and every declared
  dependency used. Split a new library off only when it brings a dependency
  or a domain of its own; never subdivide the kernel (DESIGN.md,
  Architecture).
  Stress a suite with
  `swift test --filter <Suite> --maximum-repetitions 300 --repeat-until fail`;
  every concurrency test must survive it.
- **Lint:** `swift run --traits Lint stoic-lint --baseline
.stoic-lint-baseline.json Sources Plugins Package.swift` must stay clean;
  the lint tests are `swift test --traits Lint --filter StoicLintCoreTests`.
  Without the `Lint` trait, swift-syntax is never fetched. A new
  `stoic:allow` fails until the baseline records it: fix the code first, and
  re-record (`--write-baseline .stoic-lint-baseline.json Sources Plugins
Package.swift`) only for an escape a reviewer should see.
- **API and allocations:** a breaking public API change fails `check.sh`
  unless listed in `api-breakage-allowlist.txt` in the same change. A hot
  path whose median call allocates more than `Benchmarks/allocations.json`
  records fails too (the few paths that start tasks have a stated allowance
  over it, `schedulerAllowance`); one whose median is lower, re-record it
  (`--record`, on an idle machine) so the gate tightens.
- **Macros:** `swift test --traits Macros --filter StoicMacros` runs the
  expansion tests and the usage tests (macro schema against the same schema
  written by hand). The `Macros` trait is the only other way swift-syntax is
  fetched. A new diagnostic needs a test with its line and column; a new
  attribute needs a case in the hand-written comparison (`design/06`).
- **Contracts first.** Each primitive has a contract in `design/`. Change the
  contract and the code together; a failure-mode table row without a test
  is a gap. Mark the test that proves a row with `@Test(.failureMode("design/NN",
"the row's first column"))`: `FailureModeCoverageTests` fails on a row no
  test claims (unless it is in `design/failure-modes.baseline`, which may
  only shrink) and on a claim whose row no longer exists.
- **Events are API.** A new event goes in `EventCatalog`; the catalog test
  fails otherwise. Never rename one.
- **House style:** prose doc comments that explain _why_; typed errors
  pass through untouched; `Mutex` for synchronous state, never held across
  `await`; events recorded outside locks; no type named `Stoic`.
- **Commits:** small and focused, each building and passing tests, with a
  message that says what changed and why.

# Stoic design

Stoic is a robustness library for Swift apps. It gives an app the guarantees
Effect gives a TypeScript program — resources are always released, failures
are classified, retries are policy rather than loops, time and randomness are
injectable, and work never outlives the thing that started it — without
Effect's wrapper type. Stoic's primitives are ordinary `async` functions,
structs and actors over Swift's own concurrency runtime.

The name is the design. Stoicism separates what you control from what you do
not, and meets the second with composure. Stoic separates _expected failures_
(handled, typed, retried by policy) from _defects_ (reported loudly, never
retried), and stays composed under the conditions that break hand-rolled
code: cancellation, timeouts, hung dependencies, slow cleanup, and the
machine going to sleep in the middle of it all.

This document is the north star. Each primitive has its own contract in
`design/`; this file holds what is common to all of them. A feature that
cannot state its contract in the form below does not ship.

## Contents

- [Who it is for](#who-it-is-for)
- [Principles](#principles)
- [Architecture](#architecture)
- [Shared contracts](#shared-contracts)
- [The primitives](#the-primitives)
- [Quality bar](#quality-bar)
- [What apps get wrong today](#what-apps-get-wrong-today)
- [Roadmap](#roadmap)
- [Decisions on record](#decisions-on-record)
- [Open questions](#open-questions)

## Who it is for

Apps first: macOS and iOS apps whose complexity lives in long-lived
background work — audio, models, sync, system integrations, downloads — and
whose failures are hangs, leaks and races rather than 500s. Server Swift
benefits from the same primitives, and integrates through ServiceLifecycle,
but no decision is made for servers at an app's expense.

Two kinds of author write code against Stoic: people, and coding agents. The
second changes the design more than it seems. Agents are good at satisfying a
compiler and following a worked example; they are bad at global reasoning
about ownership and concurrency, and they reach for escape hatches
(`@unchecked Sendable`, `try?`, `nonisolated(unsafe)`) when stuck. So Stoic
puts its safety where a compiler or a build plugin can check it, keeps its
API shaped like plain Swift, and ships its own guidance (design/14).

## Principles

1. **Direct style.** No effect type, no monad, no combinator chains over
   wrapped values. An operation is a closure — `() async throws(E) -> T` —
   and the closure _is_ the lazy, re-runnable description Effect reifies.
   Stack traces, the debugger and Instruments keep working.

2. **Every wait has an end.** No primitive waits without a bound it can
   name: a deadline, a budget, a capacity, or the cancellation of its
   caller. Unbounded queues, retries and joins do not exist in the API.

3. **Work belongs to a scope.** Every task Stoic starts is owned by a
   scope, a slot, a supervisor or a state, and is cancelled _and awaited_
   when its owner ends. Stoic never starts work it cannot account for. The
   one sanctioned exception — abandoning an operation that ignores
   cancellation — is bounded, counted and reported (design/01).

4. **Cleanup always runs, and runs bounded.** Finalizers run on success,
   failure and cancellation, in reverse order, shielded from cancellation,
   each under its own deadline.

5. **Failures are classified, not flattened.** Stoic passes your error type
   through untouched. It distinguishes failures (expected, handled) from
   defects (bugs) and from cancellation (never an error to retry or report).

6. **Time and randomness are injected.** Every primitive reads its clock
   and its random source from the ambient context, so a test replaces both
   and a thirty-second backoff runs in microseconds, the same way every
   time.

7. **Observable by default.** Every primitive reports what it decides —
   retrying, giving up, opening, restarting, abandoning — as structured
   events. A silent decision is a bug.

8. **The compiler first, the build plugin second, the docs third.** A
   guarantee the type system can carry is carried there (noncopyable scope
   handles, typestate, exhaustive transition tables). What it cannot carry,
   the lint plugin checks. What neither can, the docs say plainly.

9. **Align with the standard library, then step aside.** Where Swift
   Evolution has an accepted design (SE-0526 deadlines), Stoic matches its
   names and semantics, and forwards to the standard library once it ships.
   Stoic's lasting value is what the standard library is unlikely to absorb:
   budgets, schedules, breakers, supervisors, scopes, schemas, test tooling.

10. **Small core, opt-in edges.** The core depends on the standard library,
    `Synchronization`, and `os` for its default log sink only. Macros, lint, logging, metrics, tracing and
    ServiceLifecycle are separate products or traits.

## Architecture

```text
                       ┌───────────────────────────────────────────┐
  apps import ───────▶ │ Stoic (core: stdlib + Synchronization)    │
                       │  Ambient · Deadline · Schedule · Retry    │
                       │  Concurrency · Scope · Supervisor · Graph │
                       │  Policies · Report · StateMachine · Schema│
                       │  runtime · Instrumentation                │
                       └───────────────────────────────────────────┘
        ▲                  ▲                  ▲                  ▲
 ┌──────┴──────┐   ┌───────┴───────┐  ┌───────┴───────┐  ┌───────┴────────┐
 │ StoicMacros │   │ StoicTesting  │  │ StoicLint     │  │ Integrations   │
 │ @Schema     │   │ TestClock     │  │ build plugin  │  │ (traits)       │
 │ @StateMach. │   │ faults, seeds │  │ + doctor      │  │ OSLog, swift-  │
 │ @Services   │   │ model tests   │  │ command       │  │ log/metrics/   │
 │ (swift-     │   │               │  │ (swift-syntax)│  │ tracing, SLC,  │
 │  syntax)    │   │               │  │               │  │ AppKit/UIKit   │
 └─────────────┘   └───────────────┘  └───────────────┘  └────────────────┘
```

| Product        | Contents                                                                        | Dependencies                    |
| -------------- | ------------------------------------------------------------------------------- | ------------------------------- |
| `Stoic`        | Every runtime primitive                                                         | stdlib, `Synchronization`       |
| `StoicTesting` | Virtual clock, seeded randomness, fault injection, model tests                  | `Stoic`, Swift Testing          |
| `StoicMacros`  | `@Schema`, `@StateMachine`, `@Services` (compile-time checking)                 | `Stoic`, swift-syntax           |
| `StoicLint`    | Build-tool plugin that fails the build on unsafe patterns                       | swift-syntax (host tool only)   |
| Traits         | `OSLog`, `Logging`, `Metrics`, `Tracing`, `ServiceLifecycle`, `AppKit`, `UIKit` | the named package, when enabled |

Platform floor: macOS, iOS, tvOS, watchOS and visionOS 27, Swift 6.4,
Swift 6 language mode. The floor is what makes the core honest:
`withTaskCancellationShield` (SE-0504) and `await` in `defer` (SE-0493) are
runtime features of the 27 releases, and Stoic's cleanup guarantee rests on
them. Linux and Windows are not targets for 1.0 (see Open questions).

There is no type named `Stoic`. A type that shares the module's name shadows
it; callers who need to disambiguate write `Stoic::retry` (module selectors,
Swift 6.3).

## Shared contracts

Every primitive's contract in `design/` is written against these.

### The ambient context

Clock, randomness and instrumentation are cross-cutting: threading them
through every signature is noise, and missing one breaks determinism. They
live in one task-local value.

```swift
public struct Ambient: Sendable {
    public var clock: AnyClock                  // default: ContinuousClock
    public var livenessClock: AnyClock          // default: SuspendingClock
    public var random: RandomSource             // default: system generator
    public var instrumentation: any Instrumentation  // default: OSLog sink

    public static var current: Ambient { get }
}

public nonisolated(nonsending) func withAmbient<R, E: Error>(
    _ transform: (inout Ambient) -> Void,
    operation: nonisolated(nonsending) () async throws(E) -> R
) async throws(E) -> R
```

- Time-based primitives accept an explicit `clock:` that overrides the
  ambient clock for that call. Randomness is always ambient: one seed for a
  whole test is what makes a run reproducible.
- **Two clocks, on purpose.** Operation deadlines and retry delays use a
  continuous clock: if the Mac sleeps through a deadline, the deadline has
  passed. Liveness checks (watchdogs, heartbeats) use a suspending clock: a
  process that was asleep was not hung. A watchdog on the wrong clock
  turns every wake from sleep into a false hang, and a false hang that
  restarts the app turns into a crash loop.
- **Deterministic randomness under concurrency.** A shared seeded generator
  is not deterministic once two tasks draw from it in an order the scheduler
  picks. Stoic derives a stream per call site (a stable FNV hash of seed,
  file and line, never `Hasher`), so a seed reproduces the same jitter
  regardless of interleaving. The cost: under one seed, concurrent callers
  at the same site draw the same jitter. Production uses the system
  generator, where every draw is independent; a test that studies herd
  behaviour runs each caller under its own seed.
- `AnyClock` erases any `Clock<Duration>`; its instants are durations from
  the clock's origin, so a deadline can be stored and compared without
  generics leaking into every signature. Every sleep is clamped to a
  century: "wait forever" means "wait for cancellation", never a trap.
- Retry budgets live in the ambient context too (`Ambient.budgets`), so a
  test's budgets start full and no other test can drain them.

### Errors

- **Passthrough.** A primitive that runs your operation throws your
  operation's error type, untouched. `retry` that gives up throws the last
  attempt's error, not a `RetryError`.
- **Rejections have one type.** When a policy refuses to run the operation
  at all — breaker open, bulkhead full, rate limited, budget exhausted,
  deadline passed before the start — it throws `PolicyError<Failure>`:

  ```swift
  public enum PolicyError<Failure: Error>: Error {
      case rejected(Rejection)   // the operation never ran (or was abandoned)
      case failed(Failure)       // the operation ran and failed
  }
  ```

  Policies flatten: a policy wrapping an operation that already throws
  `PolicyError<F>` throws `PolicyError<F>`, never `PolicyError<PolicyError<F>>`.
  Pipelines of policies therefore compose without nested unwrapping.

- **Concurrent failures are all kept.** Where several children can fail
  (race, mapConcurrent, scopes with forks), Stoic throws
  `ConcurrentFailure<Failure>`: a non-empty list in completion order, the
  first being the primary. This is Effect's parallel `Cause`, flattened the
  way Effect 4 flattened it.
- **Cancellation is not a failure.** `CancellationError` is never retried,
  never counted by a breaker, never reported as an error event, and never
  wrapped. It propagates as itself.
- **Defects.** An error type conforming to `Defect` is a programming error:
  never retried, never handled by a fallback, always reported at error
  level. Swift traps cannot be caught in-process; the defect protocol is for
  the thrown kind.

### Cancellation

Every primitive's contract has a cancellation clause that answers three
questions: what happens to work in flight, whether cleanup runs (always
yes), and what is thrown. Stoic never converts cancellation into success,
never retries after it, and never sleeps once cancelled.

### Isolation

Operation closures are `nonisolated(nonsending)`: they run on the caller's
actor. A `@MainActor` caller can capture non-`Sendable` state, exactly as in
the spike that validated this design. Stoic's own shared state lives behind
`Mutex` (from `Synchronization`) for synchronous fast paths and actors where
waiting is involved. No Stoic lock is ever held across an `await`.

### Observability

Every decision is an event (design/11). Event names are stable API: a
renamed event is a breaking change, so dashboards and log queries built on
them keep working across minor versions.

### Defaults

Every default is written down, justified and safe: retries are capped and
jittered, timeouts exist, breakers need a minimum call count before
judging, supervisors escalate. A default that would surprise someone in an
incident review is the wrong default.

## The primitives

| #   | Contract                                                          | Replaces                                                  | Status                                     |
| --- | ----------------------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------ |
| 01  | [Time and deadlines](design/01-time-and-deadlines.md)             | hand-rolled timeout races, `asyncAfter` timeouts          | Built, including `abandoningAfter`         |
| 02  | [Schedules and retry](design/02-schedules-and-retry.md)           | retry loops, fixed delays, drifting budgets               | Built                                      |
| 03  | [Structured concurrency](design/03-concurrency.md)                | generation counters, semaphores, unbounded streams        | Built                                      |
| 04  | [Scopes and resources](design/04-scopes-and-resources.md)         | `defer`/`deinit` cleanup, manual teardown order           | Built                                      |
| 05  | [Errors and reports](design/05-errors.md)                         | `try?`, errors flattened to strings                       | Built; platform catalog planned            |
| 06  | [Validation and schema](design/06-validation.md)                  | hand-written validators, ranges repeated three times      | Built: phases 1 and 2; `@Schema` in progress |
| 07  | [State machines](design/07-state-machines.md)                     | phase booleans, stale-callback guards                     | Built; macro planned                       |
| 08  | [Services and app lifecycle](design/08-services-and-lifecycle.md) | `applicationWillTerminate` teardown lists                 | Built, with AppKit and UIKit bridges       |
| 09  | [Supervision](design/09-supervision.md)                           | watchdogs, restart-on-failure loops                       | Built                                      |
| 10  | [Resilience policies](design/10-resilience-policies.md)           | nothing between the app and a failing dependency          | Built                                      |
| 11  | [Observability](design/11-observability.md)                       | silent decisions                                          | Built, with swift-log and swift-metrics adapters |
| 12  | [Testing](design/12-testing.md)                                   | wall-clock tests, hand-written fakes                      | Built: task ledger, random walks, deterministic simulation; buggify planned |
| 13  | [Build enforcement](design/13-build-enforcement.md)               | conventions nobody checks                                 | Built: `StoicLint` plugin with a baseline  |
| 14  | [Guidance](design/14-guidance.md)                                 | tribal knowledge                                          | Built: README, AGENTS.md, llms.txt, skill  |
| 15  | [Persistence](design/15-persistence.md)                           | `Data.write` without fsync, configs corrupted by crashes  | Built: `StoicStore`                        |
| 16  | System conditions                                                 | ignoring memory pressure, thermal state, background expiry| Built: conditions, `DeviceConditions`, UIKit expiry, `LaunchGuard` |
| 17  | Diagnostics                                                       | "it hung once, no idea why"                               | Built: event ring, task ledger, snapshot; flight recorder planned |

**Planned domains, in brief.**

- **Persistence (`StoicStore`).** Atomic file writes done right on Apple
  platforms (temporary file, `F_FULLFSYNC` — plain `fsync` does not flush
  the drive cache — rename, directory sync, checksum envelope, previous
  generation kept, corrupt files quarantined), a crash-consistent
  append-only journal with torn-tail detection, and an outbox for
  at-least-once delivery with idempotency keys. All behind a `FileSystem`
  protocol so tests can replay every prefix and reordering of the syscalls a
  write makes and check that recovery always finds the old file or the new
  one — crash-consistency testing no Swift library ships.
- **System conditions.** Memory pressure, thermal state, low-power mode,
  network constraints and app activity as an observable value in the
  ambient context, so policies adapt: schedules slow down when the device
  is hot, bulkheads shrink under memory pressure, hedging pauses on low
  power. Background-task expiry becomes a deadline that existing primitives
  already honour. A crash-loop marker counts unclean launches and enters a
  safe mode — skipping optional services, quarantining the last config or
  migration — after too many.
- **Diagnostics.** A bounded ring of recent events, a crash-surviving
  variant on a memory-mapped file so the next launch can say what the app
  was deciding when it died, and a ledger of every Stoic-owned task (label,
  owner, age, what it waits on) that can be dumped on demand — the
  goroutine dump Swift lacks — and asserted empty at the end of every test.

## Quality bar

A primitive ships when, and only when, all of these hold.

- **Contract.** Its `design/` file states semantics, cancellation, errors,
  isolation, defaults, a failure-mode table ("what happens if…") and the
  events it emits — and the implementation matches it.
- **Proof.** Deterministic tests on the virtual clock for every row of the
  failure-mode table. Property-based tests for every piece of arithmetic or
  state (schedule math, token buckets, breaker windows, transition tables).
  A stress suite that runs each concurrency test thousands of times.
- **Sanitizers.** Clean under Thread Sanitizer and Address Sanitizer in CI.
  `@unchecked Sendable` is forbidden in Stoic's own code; `unsafe`
  expressions (strict memory safety) need a written justification.
- **Warnings are errors.** In Stoic's own build, always (Package.swift).
- **Performance.** Hot paths (breaker admission, semaphore acquire,
  `Ambient.current`, schedule step) have benchmarks with allocation counts,
  and a regression fails CI.
- **API discipline.** Every public symbol is documented with an example
  that compiles; `swift package diagnose-api-breaking-changes` gates every
  release; deprecations get one minor version of overlap.
- **Used in anger.** It has replaced a hand-rolled version in a shipping
  app and survived a release there.

## What apps get wrong today

The same failures recur in every Swift app with long-lived background work.
Each primitive exists because one of them is common, costly, and easy to
write wrongly by hand.

| The hand-rolled pattern                                                                       | What goes wrong                                                                    | Stoic                                  |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------- |
| A timeout built from a continuation, two tasks and a "first answer" flag                       | The timer outlives the work; the losing work cannot be cancelled and leaks          | `withTimeout`, abandoning form (01)    |
| A retry loop with a fixed count and delay                                                      | No jitter, no budget, retries cancellation, and the numbers drift from the docs     | `Schedule`, `retry`, `RetryBudget` (02) |
| A generation counter compared in every callback                                                | One forgotten comparison publishes a stale result                                  | `TaskSlot`, state-scoped tasks (03, 07) |
| Cleanup in `defer` and `deinit`                                                                | Cannot `await`, skipped under cancellation, unbounded when the resource hangs       | `withScope`, `Resource` (04)           |
| `try?` and errors flattened to strings                                                        | The cause, the context and the decision to retry are all lost                      | `Report`, `Defect` (05)                |
| Ranges and defaults repeated in the parser, the clamp, the settings UI and the docs            | They drift; invalid input is silently clamped instead of reported                  | `@Schema` (06)                         |
| A handful of booleans tracking a lifecycle                                                     | Impossible combinations become reachable; work started in one phase leaks into the next | `StateMachine` (07)               |
| A teardown list in `applicationWillTerminate`                                                  | Unordered, unbounded, failures swallowed, and synchronous where cleanup is async    | `ServiceGraph`, lifecycle bridges (08) |
| A timer that pings a thread and aborts                                                         | Fires on wake from sleep and during slow launches; restarts become crash loops      | `Supervisor`, `Heartbeat` (09)         |
| Nothing at all between the app and a failing dependency                                        | Every caller hammers it; one slow endpoint exhausts every thread                   | Circuit breaker, bulkhead (10)         |
| `DispatchSemaphore.wait()` and `usleep` inside async code                                      | Starves the cooperative pool; deadlocks under load                                 | Lint rules (13)                        |
| Tests that sleep for real time                                                                 | Slow and flaky; the interesting interleavings are never reached                    | `TestClock`, seeds, fault injection (12) |

## Roadmap

| Milestone | Delivers                                                                                                              | Status       |
| --------- | --------------------------------------------------------------------------------------------------------------------- | ------------ |
| **M0**    | Repository, strict build, design contracts, guidance                                                                  | Done         |
| **M1**    | `Ambient`, `AnyClock`, deadlines, `Schedule`, `retry`, `recur`, budgets; test clocks and seeds                        | Done         |
| **M2**    | Scopes, `Resource`, `Saga`, `TaskScope`; `TaskSlot`, `race`, `mapConcurrent`, semaphores, `SingleFlight`, `Channel`   | Done         |
| **M3**    | `Report`, `Defect`, the event catalog; `Secret`, `IdempotencyKey`                                                     | Done         |
| **M4**    | `StoicJSON`, `StoicSchema` phase 1                                                                                     | Done         |
| **M4.2**  | Schema phase 2: unions, transforms, migrations, generators, SchemaSuite, Codable bridge; then `@Schema`                | Done; `@Schema` in progress |
| **M5**    | `StateMachine`, `StateGraph`                                                                                           | Done         |
| **M6**    | `ServiceGraph`, `Supervisor`; lifecycle bridges                                                                        | Done         |
| **M7**    | Circuit breaker, rate limiter, bulkhead, hedging, pipelines                                                            | Done         |
| **M8**    | `StoicLint` build plugin with a ratchet baseline                                                                       | Done         |
| **M9**    | Persistence, system conditions, diagnostics                                                                            | Done; flight recorder planned |
| **1.0**   | API freeze after every primitive has shipped in a real app; SSWG incubation application                               | —            |

## Decisions on record

- **No `Effect<A, E, R>` type.** Swift has no error unions, no higher-kinded
  types and no do-notation; result builders cannot express monadic bind.
  Bow and SwiftEffect died of this, and Point-Free's TCA 2.0 moved from
  effect values to scoped tasks. Closures are the effect value.
- **No compile-time `R` channel.** Swift cannot express an unordered,
  subtractable set of requirements. The service graph is validated at
  compile time by a macro when it is declared in one place, and at startup
  otherwise (design/08).
- **Scope handles are `~Copyable` and borrowed.** The compiler rejects any
  attempt to capture one in an escaping closure, which is the guarantee
  `~Escapable` would give, without the experimental lifetime features that
  constructing a `~Escapable` value still requires in Swift 6.4. Verified
  against the 6.4 compiler.
- **Value handles over type-keyed lookup.** Services are passed as values,
  so two databases or two HTTP clients coexist. Only cross-cutting context
  (clock, randomness, instrumentation, deadline) is ambient.
- **Cooperative deadlines by default, abandonment by request.** Matches
  SE-0526; the abandoning form exists because some work (CoreAudio, AX
  calls into a hung app) cannot be cancelled, and real apps depend on it.
- **The platform floor is 27.** Back-deploying the cleanup guarantee
  means emulating shields with unstructured tasks, and an emulation that
  is mostly right is worse than a floor.

## Open questions

1. **License.** A library that wants adoption is usually Apache-2.0 (the
   Swift ecosystem's default) or MIT. Decide before the repository goes
   public.
2. **Going public.** The repository starts private. Public at M1 (first
   usable primitives) or at M2?
3. **CI runners.** GitHub's hosted runners must offer macOS 27 with Xcode 27
   before CI can run Stoic's tests; until then, CI is a self-hosted runner
   or local `scripts/check.sh`.
4. **Linux.** Server users will ask. The core is Foundation-free, so the
   cost is CI and the Linux story for shields (which have no availability
   gate there). Decide after M2.
5. **Upstreaming.** `retry` with schedules overlaps swift-async-algorithms
   PR #364. If it merges, Stoic wraps it; Stoic's budgets, deadline
   awareness and classification are the value on top. Worth a forum post
   once M1 is real.

# Stoic design

Stoic is a robustness framework for Swift apps: a complexity management
system. The things that make long-lived, asynchronous software dependable —
resources always released, failures classified, retries as policy rather
than loops, time and randomness injectable, work that never outlives what
started it, every decision observable — are hard to get right by hand and
easy to get subtly wrong. Stoic moves them out of the app and into
primitives that are specified, tested and enforced once, so an app is built
on them instead of re-deriving them. The primitives are ordinary `async`
functions, structs and actors over Swift's own concurrency runtime: there is
no wrapper type and no new way of writing Swift to learn.

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

Two kinds of author write code against Stoic: people, and coding agents, and
Stoic is designed for the second first. Agents are good at satisfying a
compiler and following a worked example; they are bad at global reasoning
about ownership and concurrency, and they reach for escape hatches
(`@unchecked Sendable`, `try?`, `nonisolated(unsafe)`) when stuck. So Stoic
puts its safety where a compiler, a build plugin or a simulation can check
it, keeps its API shaped like plain Swift, and ships its own guidance
(design/14). Strictness is the feature: every check is feedback an agent can
act on, the way TypeScript's compiler made JavaScript tractable, and it pays
off more as agents grow more capable. Stoic prefers robustness and
performance to brevity, and one opinionated way to do a common thing to
several.

Lodestar is the pilot. It demands robustness, and it is where each primitive
meets production and where its API is refined.

## Principles

1. **Direct style.** No wrapper type, no monad, no combinator chains over
   wrapped values. An operation is a closure — `() async throws(E) -> T` —
   and the closure _is_ the lazy, re-runnable description of the work.
   Values describe policy (a `Schedule` is data; a transition function is
   pure, so `StateGraph` can explore it); closures do the work. Stack
   traces, the debugger and Instruments keep working.

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

9. **Build on the standard library, never beside it.** Where Swift
   Evolution has an accepted design (SE-0526 deadlines), Stoic matches its
   names and semantics, and uses the standard library's types once they
   ship, so an app never holds two kinds of deadline. Stoic does not step
   aside when the standard library gains a primitive: it keeps what makes the
   primitive part of one cohesive system — budgets, schedules, breakers,
   supervisors, scopes, schemas, simulation and test tooling.

10. **A framework of separable packages.** The core depends on the standard
    library, `Synchronization`, and `os` for its default log sink only.
    Everything else is a library an app adopts on its own (schemas and JSON
    need no core at all) or a trait: macros, lint, persistence, settings,
    HTTP, logging, metrics, tracing, ServiceLifecycle. The libraries are
    tested together, and their graph is checked (see Architecture), so
    adopting a second one is never an integration project.

11. **Design from the ideal.** A primitive starts from what an idealized
    robust system would do, not from the hand-rolled code it replaces: not
    only how to retry, but what the operation being retried is, and what it
    should declare so the system can decide for it. Each primitive ships with
    that scenario as a runnable example, which is also what an agent copies.

12. **The compliant path is the easy one; every escape is counted.** Where
    the API can make the right thing as easy as the wrong one, it does:
    `attempt.idempotencyKey` instead of a rule about where to create a key.
    What still needs an escape hatch takes a written reason, and every
    escape is recorded in the lint baseline, so a new one is a reviewed
    change, never a quiet one (design/13). An agent that can switch a check
    off will; one that has to justify it in a diff mostly will not.

## Architecture

Stoic is one Swift package of separately adoptable libraries. An app names
the products it uses and builds nothing else; with no traits enabled, it
fetches no other package at all.

```text
 portable ─────────────────────────────────────────────────────────────────────
   Stoic ············ the kernel: Ambient · Deadline · Schedule · Retry ·
   (stdlib, Sync.)    Operations · Concurrency · Scope · Policies ·
                      StateMachine · ServiceGraph · Supervisor · Report ·
                      Instrumentation
   StoicJSON ········ strict JSON, the trust boundary (stdlib only)
     StoicSchema ···· one declaration per type        ← StoicJSON
   StoicTesting ····· clocks, seeds, faults, simulation ← Stoic
   StoicFoundation ·· Foundation's errors classified  ← Stoic
   StoicStore ······· atomic files, journal, outbox   ← Stoic
   StoicObservability swift-log / swift-metrics       ← Stoic (+ traits)
     StoicSettings ·· settings that cannot corrupt    ← Stoic, StoicStore, StoicSchema
     StoicHTTP ······ the resilient HTTP client       ← Stoic, StoicFoundation, StoicSchema
 Apple ────────────────────────────────────────────────────────────────────────
   StoicApple ······· reachability, BGTask, Keychain  ← Stoic, StoicFoundation
   StoicAppKit, StoicUIKit · lifecycle bridges        ← Stoic
 tools ────────────────────────────────────────────────────────────────────────
   StoicMacros (Macros trait) · StoicLint + stoic-lint (Lint trait): swift-syntax
```

| Product              | Contents                                                                       | Depends on                         |
| -------------------- | ------------------------------------------------------------------------------ | ---------------------------------- |
| `Stoic`              | Every runtime primitive                                                        | stdlib, `Synchronization`, `os`    |
| `StoicTesting`       | Virtual clock, seeded randomness, fault injection, model tests, simulation     | `Stoic`, Swift Testing             |
| `StoicJSON`          | Strict JSON: duplicate keys, exact numbers, positions                          | stdlib                             |
| `StoicSchema`        | Decode, encode, validate, JSON Schema, migrations, generators                 | `StoicJSON`                        |
| `StoicFoundation`    | `URLError`, `POSIXError`, `CocoaError` classified for retry                    | `Stoic`, Foundation                |
| `StoicStore`         | Atomic files, journal, outbox, launch guard, flight recorder                   | `Stoic`                            |
| `StoicSettings`      | Schema-declared settings in an atomic file                                     | `Stoic`, `StoicStore`, `StoicSchema` |
| `StoicHTTP`          | Resilient HTTP client; scripted transport for tests                            | `Stoic`, `StoicFoundation`, `StoicSchema`, Foundation(Networking) |
| `StoicObservability` | Events to swift-log and swift-metrics                                          | `Stoic`; the packages, behind traits |
| `StoicApple`         | Reachability, background tasks, Keychain, device conditions                    | `Stoic`, `StoicFoundation`, Apple frameworks |
| `StoicAppKit`, `StoicUIKit` | Lifecycle bridges                                                       | `Stoic`, AppKit / UIKit            |
| `StoicMacros`        | `@Schema`, `@Refined`; `@StateMachine`, `@Services` planned                    | `StoicSchema`; swift-syntax, behind `Macros` |
| `StoicLint`          | Build-tool plugin that fails the build on unsafe patterns                      | swift-syntax, behind `Lint` (host only) |

**Where a line is drawn.** A library is split off when it brings a
dependency the layer below refuses (Foundation, an Apple framework,
swift-syntax, another package) or a domain of its own (JSON and schemas,
persistence, HTTP). The kernel is never subdivided: its parts are one
system — deadlines bound retries, budgets are ambient, scopes own the tasks
concurrency starts, policies read all three — and splitting it would only
move those dependencies behind `package` access while an app imported more
modules for the same thing. It depends on nothing, so adopting it costs
nothing.

**The graph is enforced, not described** (`scripts/check.sh`):

- `scripts/package-graph.swift` holds the layering above as a table. A
  dependency the table does not allow fails the check, so a new edge is an
  architecture change made in the same diff. Every import must be a
  declared, direct dependency (SwiftPM lets a target import a module another
  target happened to build, which then fails in an app adopting it alone),
  and every declared dependency must be imported.
- `scripts/adoption.sh` adopts every library from a fresh package outside
  this one, with no traits: resolution must fetch nothing, and the app must
  build. On Linux it adopts the portable ones.
- The portable libraries build and test on Linux (`scripts/linux.sh`).

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

// And for a synchronous entry point (an app's `main` running its run loop):
@_disfavoredOverload
public func withAmbient<R, E: Error>(
    _ transform: (inout Ambient) -> Void,
    operation: () throws(E) -> R
) throws(E) -> R
```

- **A synchronous entry point binds it too.** An app's `main` runs its run
  loop and never returns, and must not do that inside a task, so the
  synchronous `withAmbient` binds the context outside any task, in the
  thread's own storage. It reaches what the operation calls on that thread
  and every task those callees start (a `Task {}` from a delegate method, a
  timer or a main-queue block, also after an `await`); it does not reach
  `Task.detached` or other threads and queues. The overload is disfavoured
  so a call with `await` keeps choosing the async form.
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

  Policies flatten in a `Pipeline`: it throws one `PolicyError<F>` however
  many stages refuse, never `PolicyError<PolicyError<F>>`, so pipelines of
  policies compose without nested unwrapping. (Nested by hand, a policy
  around a policy throws the nested type; `flattened()` makes it flat. Swift
  cannot choose an overload by a closure's thrown type, so it cannot happen
  by itself.)

- **Concurrent failures are all kept.** Where several children can fail,
  none is lost. Scopes with forks throw `ConcurrentFailure<Failure>`: a
  non-empty list in completion order, the first being the primary (the
  precedent is Effect's parallel `Cause`, as Effect 4 flattened it). `race`
  and `mapConcurrent` take a typed `throws(Failure)` with room for one, so
  they throw the first and report every one in an event (`race.all_failed`,
  `map.failed`).
- **Cancellation is not a failure.** `CancellationError` is never retried,
  never counted by a breaker, never reported as an error event, and never
  wrapped. It propagates as itself. Where an error type cannot hold one — a
  policy's `PolicyError` — the caller's cancellation is `.rejected(.cancelled)`,
  and everything that classifies errors reads it as cancellation
  (`isCancellation`).
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
| 06  | [Validation and schema](design/06-validation.md)                  | hand-written validators, ranges repeated three times      | Built, with `@Schema` behind the `Macros` trait |
| 07  | [State machines](design/07-state-machines.md)                     | phase booleans, stale-callback guards                     | Built; macro planned                       |
| 08  | [Services and app lifecycle](design/08-services-and-lifecycle.md) | `applicationWillTerminate` teardown lists                 | Built, with AppKit and UIKit bridges       |
| 09  | [Supervision](design/09-supervision.md)                           | watchdogs, restart-on-failure loops                       | Built                                      |
| 10  | [Resilience policies](design/10-resilience-policies.md)           | nothing between the app and a failing dependency          | Built                                      |
| 11  | [Observability](design/11-observability.md)                       | silent decisions                                          | Built, with swift-log and swift-metrics adapters |
| 12  | [Testing](design/12-testing.md)                                   | wall-clock tests, hand-written fakes                      | Built: task ledger, random walks, deterministic simulation with fault points |
| 13  | [Build enforcement](design/13-build-enforcement.md)               | conventions nobody checks                                 | Built: `StoicLint` plugin with a baseline  |
| 14  | [Guidance](design/14-guidance.md)                                 | tribal knowledge                                          | Built: README, AGENTS.md, llms.txt, skill  |
| 15  | [Persistence](design/15-persistence.md)                           | `Data.write` without fsync, configs corrupted by crashes  | Built: `StoicStore`                        |
| 16  | System conditions                                                 | ignoring memory pressure, thermal state, background expiry| Built: conditions, `DeviceConditions`, UIKit expiry, `LaunchGuard` |
| 17  | Diagnostics                                                       | "it hung once, no idea why"                               | Built: event ring, task ledger, snapshot, flight recorder |
| 18  | [Settings](design/18-settings.md)                                 | `Codable` + `Data.write`, settings lost to crashes and old builds | Built: `StoicSettings`                     |
| 19  | [HTTP](design/19-http.md)                                         | hand-rolled retry loops around `URLSession`, a `POST` charged twice | Built: `StoicHTTP`                         |
| 20  | [Time shaping](design/20-time-shaping.md) | search-as-you-type firing per keystroke, a cache that serves nothing while it refetches | Built: `Debouncer`, `Throttler`, `ExpiringCache`, `Broadcast` |
| 21  | [Platform integration](design/21-platform-integration.md) | requests sent into a dead network, background work killed mid-write, tokens in `UserDefaults` | Built: `StoicApple` |
| 22  | [Operations and backends](design/22-operations.md) | resilience numbers picked per call site, retried `POST`s, interactive taps waiting out background backoffs | Built: `Backend`, `perform`, `withUrgency`; `StoicHTTP` on operations planned |

**The plan from here.** Every domain above is built; what follows is
ordered by how much hand-written fragility each removes from a typical
app, and each lands the way the others did: a contract in `design/`, a
review, tests for every failure-mode row, small commits.

1. **Settings that cannot corrupt (`StoicSettings`, built: design/18).** The composition the
   pieces were built for: a schema-declared settings value, persisted with
   `AtomicFile`, migrated on read, validated on write, observable, with the
   last good file kept and a corrupt one quarantined. Settings are the most
   common persistent state in an app and the most commonly lost.
2. **Smarter simulation.** Fault points, a PCT/uniform schedule portfolio
   and early timers are built; next, faults in the simulated file system,
   learned PCT horizons, and shrinking a failing seed to the fewest
   preemptions (design/12).
3. **Macros.** `@Schema` is built; next, `@StateMachine`, whose transition
   table becomes a compile-time-checked declaration with exhaustiveness; and
   `@Services`, which checks a service graph's dependencies at compile time
   (design/06, 07, 08).
4. **Abandonment meets scopes** — built. Scopes count abandoned work
   started inside them (`scope.abandonedWork`); a release declared
   `ifWorkAbandoned: .quarantine` is leaked deliberately rather than closed
   under a call that may still be using it (design/01, 04).
5. **A resilient HTTP layer (`StoicHTTP`, built: design/19).** Per-host pipelines (timeout,
   retry honouring `Retry-After`, breaker, bulkhead), idempotency keys on
   unsafe methods, responses decoded through schemas with every issue
   reported, request coalescing, and the outbox for work that must survive
   a relaunch (the client is built; the outbox composition is not). The
   network is where most app failures start.
6. **Tracing.** swift-distributed-tracing as a trait: retries, deadlines
   and breaker decisions as span events and attributes.
7. **Executable failure-mode tables and golden traces** — built: a row no
   test claims fails the suite (with a shrinking baseline), and
   `expectTrace` asserts the decisions a scenario made (design/11, 12).
   Next: prove every row in the baseline.
8. **A platform error catalog.** Every common `URLError`, `POSIXError`,
   `CocoaError` and `NSOSStatusErrorDomain` code classified for retry, with
   its meaning in words (design/05).

## Quality bar

A primitive ships when, and only when, all of these hold.

- **Contract.** Its `design/` file states semantics, cancellation, errors,
  isolation, defaults, a failure-mode table ("what happens if…") and the
  events it emits — and the implementation matches it.
- **Proof.** Deterministic tests on the virtual clock for every row of the
  failure-mode table. Property-based tests for every piece of arithmetic or
  state (schedule math, token buckets, breaker windows, transition tables).
  A stress suite that runs each concurrency test thousands of times.
- **Ideal scenario.** Its contract opens with the problem an idealized
  robust system solves with it, and that scenario exists as a runnable
  example or test.
- **Sanitizers.** Clean under Thread Sanitizer and Address Sanitizer in CI.
  `@unchecked Sendable` is forbidden in Stoic's own code; `unsafe`
  expressions (strict memory safety) need a written justification.
- **Warnings are errors.** In Stoic's own build, always (Package.swift).
- **Performance.** Hot paths (breaker admission, semaphore acquire,
  `Ambient.current`, schedule step) have benchmarks with allocation counts,
  and a rise in the median call's allocations fails CI. Time is reported, not gated: shared
  CI machines drift more than the regressions worth catching.
- **API discipline.** Every public symbol is documented with an example
  that compiles; `swift package diagnose-api-breaking-changes` against the
  last release gates every change, and an intentional break is allowed only
  by listing it in `api-breakage-allowlist.txt` in the same change;
  deprecations get one minor version of overlap.
- **Portable where it can be.** A library that needs no Apple framework
  builds on Linux in CI (`scripts/linux.sh`).
- **Enforced.** Every item above that a machine can check is checked by
  `scripts/check.sh` and CI. An item that is written here and not checked is
  a bug in the bar, not a convention.

Adoption is not a gate. A primitive can encode better architecture than any
existing app would discover by itself, so "it replaced a hand-rolled
version" is the wrong test. Lodestar, the pilot, is where primitives meet
production and their APIs are refined.

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
| **M4.2**  | Schema phase 2: unions, transforms, migrations, generators, SchemaSuite, Codable bridge                                | Done         |
| **M4.3**  | `StoicMacros`: `@Schema` and `@Refined`, behind the `Macros` trait                                                     | Done         |
| **M5**    | `StateMachine`, `StateGraph`                                                                                           | Done         |
| **M6**    | `ServiceGraph`, `Supervisor`; lifecycle bridges                                                                        | Done         |
| **M7**    | Circuit breaker, rate limiter, bulkhead, hedging, pipelines                                                            | Done         |
| **M8**    | `StoicLint` build plugin with a ratchet baseline                                                                       | Done         |
| **M9**    | Persistence, system conditions, diagnostics                                                                            | Done         |
| **M10**   | The quality bar enforced: Address Sanitizer, the public API check, the allocation gate, Linux builds, the escape budget | Done         |
| **M11**   | The package graph: `StoicFoundation` split from `StoicApple`, `StoicHTTP` portable, the layering enforced, adoption tested from outside | Done         |
| **1.0**   | API freeze once Lodestar runs on every primitive; SSWG incubation application                                          | —            |

## Decisions on record

- **Apache-2.0, and public.** The license of Swift itself and of most of the
  Swift Server Workgroup's packages: permissive, with a patent grant from
  every contributor and contributions licensed by submission. A
  source-available license (as Lodestar uses) would protect an app, but
  would keep a library out of the companies and the workgroup it is for.

- **No wrapper type for effects.** Swift has no error unions, no
  higher-kinded types and no do-notation; result builders cannot express
  monadic bind. Swift libraries built on a wrapper (Bow, SwiftEffect) died of
  this, and Point-Free's TCA 2.0 moved from effect values to scoped tasks.
  Closures are the description of the work.
- **The quality bar gates shipping; adoption does not.** A primitive ships
  when its contract, proof, sanitizers, performance and API checks hold.
  Lodestar validates and refines it in production afterwards.
- **No compile-time requirements channel.** Swift cannot express an unordered,
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

1. **Linux, all the way.** The libraries that need no Apple framework build
   on Linux in CI. Running their tests there (SwiftPM builds every test
   target, and the Apple libraries' do not build), `StoicHTTP` over
   FoundationNetworking, and the story for shields are what remain.
2. **Upstreaming.** `retry` with schedules overlaps swift-async-algorithms
   PR #364. If it merges, Stoic wraps it; Stoic's budgets, deadline
   awareness and classification are the value on top. Worth a forum post
   once M1 is real.

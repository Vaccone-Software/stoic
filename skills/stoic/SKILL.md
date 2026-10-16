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
| timeouts, retry counts, breakers chosen at each call to a service | declare it: `Backend.remote("api").readOnly("user")` as a `static let`, then `.perform { attempt in … }`; say who waits with `withUrgency` |
| generation counter checked in callbacks | `TaskSlot` or `StateMachine.whileIn` |
| booleans tracking a lifecycle | `StateMachine` |
| cleanup needing `await`, or in `deinit` | `withScope` + `scope.acquire(…, release:)` |
| `DispatchSemaphore` in async code | `AsyncSemaphore` / `AsyncMutex` |
| `AsyncStream` with default (unbounded) buffering | `Channel(capacity:overflow:)` |
| unbounded task group over a large collection | `mapConcurrent(_:limit:)` |
| `while true { do {…} catch { sleep } }` keeping work alive | `Supervisor` |
| startup/teardown lists in the app delegate | `ServiceGraph` |
| hand-written config validation | `@Schema struct` (trait `Macros`); `StoicSchema`'s `Schema.object` without it |
| `try?` / `catch { print(error) }` | handle it, or `withContext("…") { … }` |
| `URLSession` calls with hand-rolled retry, timeout or decoding | `HTTPClient` (`StoicHTTP`): network calls go through it; `POST` needs an `IdempotencyKey`; tests use `ScriptedTransport` |

## Rules

1. Every retry ends in `.attempts(n)`; it will not compile otherwise.
2. For non-idempotent requests, send `attempt.idempotencyKey` (the same on every attempt), or create an `IdempotencyKey` outside `retry`.
3. Don't nest retries for the same dependency (inner ones make one attempt).
4. Declare backends and operations (`readOnly`, `idempotent`, `keyed`, `notRepeatable`) and call `perform`; never hand-pick timeouts, attempts or breaker numbers at a call site. A keyed operation sends `attempt.idempotencyKey`; an `OperationError` with `outcome == .unknown` is reconciled under its key, never asked again.
5. Never catch `CancellationError` to keep going; never wrap it.
6. Bug-shaped errors conform to `Defect`; dependency errors to `Retryable`.
7. Release resources in finalizers; commit in the body.
8. No `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency` or `try!` without a written reason (`// stoic:allow(<rule>): <why>`).
9. Tests: `TestClock` + `waitForSleepers(count:)` + `advance(by:)`; `ImmediateClock` only to record delays; `FaultInjector` for failures; `@Test(.stoic(seed:))` for isolation. No real sleeps. For concurrent logic (caches, sync engines, anything with shared state across tasks), add a `simulate(seeds: 0..<500) { sim in … }` test: it explores interleavings deterministically and a failure names the seed that replays it.

## Declaring a schema

With the `Macros` trait (`.package(url: …, traits: ["Macros"])`, products
`StoicSchema` and `StoicMacros`), the macro is the default way to declare a
schema: put `@Schema` on the type and its constraints on its properties.

```swift
import StoicMacros
import StoicSchema

/// Application settings.
@Schema
struct Settings {
    /// Pixels per second.
    @Range(200...4000) @Unit("px/s") var scrollSpeed: Double = 1200
    var theme: Theme = .system                       // Theme: an enum with @Schema, or Schematic by hand
    @Key("api_token") @Secret var apiToken: String = ""
    @Length(1...253) @Count(0...8) @Unique var hosts: [String] = []
}

@Schema enum Theme: String { case light, dark, system }       // string enumeration
@Schema(discriminator: "type") enum Shape {                   // tagged union
    case circle(radius: Double)
    case rect(width: Double, height: Double)
    @Key("pt") case point
}
```

- Every property needs a default (the schema's default instance is `Settings()`);
  a type with initialisers needs `init()`. Write the type of a property that has
  no literal default.
- `@Range @GreaterThan @LessThan @MultipleOf @Length @Pattern` constrain the
  innermost value (`[String]` with `@Length` bounds each element); `@Count` and
  `@Unique` the collection. `@Key @Secret @Unit @Aliases @Deprecated @Nullable
  @Ignored @PreserveUnknownKeys` are the other markers. `@Refined(Int.self,
  .range(1...65_535)) enum PortRule {}` declares a refinement.
- `@Schema(version: 2, migrations: […], unknownKeys: .reject)` takes what
  `Schema.object` takes. Other schemas refer to the type as `Settings.schema`.
- The macro only writes `Schema.object { Field(…) }`, `Schema.enumeration` and
  `Schema.union`. Without the trait, write those by hand: the behaviour is the
  same. Mistakes are compile errors at the offending line (read them).
- Test it like any schema: `expectSchemaSuite(Settings.schema, seed: 1)`.

## Compiler gotchas

- Typed-throws closures need `{ _ throws(MyError) in … }`; Swift does not infer them.
- `withTimeout`, `retry(_:attemptTimeout:)`, `TaskSlot.run`, `withTaskScope` run work in a child task: results must be `Sendable`, captured mutable locals are rejected; on an actor, the closure runs on that actor.
- `race` takes two to four closures, or `[Racer]`.
- `TaskSlot.run(for: self) { [api] in … } deliver: { @MainActor model, result in … }`: called on an actor; `deliver` gets the owner, so neither closure captures `self`.

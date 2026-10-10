# Stoic

Robustness primitives for Swift apps.

Stoic gives an app the guarantees that make long-lived, asynchronous
software dependable — resources are always released, failures are
classified, retries are policy rather than loops, every wait has an end,
work never outlives what started it, and every decision is observable — as
plain `async` functions, structs and actors over Swift's own concurrency.
No effect type, no new way of writing Swift: the debugger, stack traces and
Instruments work as they always have.

The name is the design. Stoicism separates what you control from what you
do not, and meets the second with composure. Stoic separates expected
failures (typed, handled, retried by policy) from defects (reported loudly,
never retried), and stays composed under the conditions that break
hand-written code: cancellation, timeouts, hung dependencies, slow cleanup,
and the machine going to sleep in the middle of it all.

> **Status:** pre-release. The API will change before 1.0. Requires Swift
> 6.4 and macOS, iOS, tvOS, watchOS or visionOS 27.

## A tour

**Deadlines** propagate through everything beneath them, and narrow but
never widen. The work runs as a child task, inherits the caller's actor,
and is cancelled — with a recorded cause — when time is up.

```swift
let profile = try await withTimeout(.seconds(5)) {
    try await api.fetchProfile()
}
```

**Retry** is a bounded, jittered, budgeted policy. An unbounded retry does
not compile; retrying inside another retry collapses to one attempt; a
per-call-site budget caps how much retrying can add to an outage; and it
never sleeps past the deadline.

```swift
let user = try await retry(.exponential(base: .milliseconds(200)).attempts(5), attemptTimeout: .seconds(2)) { attempt in
    try await api.fetchUser(id)
}
```

**Scopes** release what they acquired — on success, failure and
cancellation, in reverse order, shielded and time-bounded.

```swift
try await withScope { scope in
    let socket = try await scope.acquire { try await Socket.connect(host) }
                                  release: { socket, _ in await socket.close() }
    try await serve(socket)
}
```

**TaskSlot** replaces generation counters: only the newest work delivers.

```swift
search.run { try await api.search(query) } deliver: { self.results = (try? $0.get()) ?? [] }
```

**State machines** make work belong to a state, and explore their own
graph in a test.

```swift
let dictation = StateMachine<Phase, Input>(initial: .idle, label: "dictation") { phase, input in
    switch (phase, input) {
    case (.idle, .start): .to(.listening, timeout: .init(after: .seconds(13), send: .timeout))
    case (.listening, .heard): .to(.transcribing)
    default: .ignore
    }
}
dictation.whileIn(.listening, label: "microphone") { sender in await listen(then: sender) }
```

**Supervisors** keep long-lived work running, back off between restarts,
detect hangs with heartbeats on a clock that stops while the Mac sleeps,
and escalate when restarting stops helping.

```swift
let supervisor = Supervisor(label: "app") {
    Child("sync") { _ in try await syncEngine.run() }
    Child("tap", heartbeat: .init(interval: .seconds(5))) { heartbeat in try await tap.run(onTick: heartbeat.beat) }
}
```

**Service graphs** start an app's services in dependency order — side by
side where independent — and stop them in reverse.

```swift
let graph = try ServiceGraph(label: "app") {
    Provide(database) { _ in try await Database.open(url) } stop: { db, _ in await db.close() }
    Provide(sync, needs: [database.any]) { services in SyncEngine(database: services[database]) }
}
try await graph.run { services in try await AppModel(sync: services[sync]).run() }
```

**Resilience policies** compose into one pipeline with one flat error:

```swift
let api = Pipeline(
    Retrying(.exponential(base: .milliseconds(200)).attempts(3)),
    CircuitBreaker(label: "api"),
    RateLimiter(rate: 50, per: .seconds(1), burst: 100, label: "api"),
    Bulkhead(maxConcurrent: 8, queueLimit: 16, label: "api")
)
let response = try await api.execute { try await client.send(request) }
```

And more: `race`, `hedge`, `mapConcurrent`, `SingleFlight`, `AsyncSemaphore`,
`AsyncMutex`, a bounded `Channel` with explicit overflow policies, `Saga`,
`Report` errors with context chains, `Secret`, `IdempotencyKey`, and
`StoicJSON`, a strict JSON parser that is the foundation of the validation
layer.

## Testing

`StoicTesting` makes time, randomness and failure controllable:

```swift
@Test(.stoic(seed: 42))
func retriesThroughAnOutage() async throws {
    let clock = TestClock()
    let api = FaultInjector<APIError>.failing(2, with: .offline)
    async let user = withTestAmbient(clock: clock) {
        try await retry(.fixed(.seconds(30)).attempts(5)) { _ in try await api.run { try await fetchUser() } }
    }
    await clock.waitForSleepers(count: 1); await clock.advance(by: .seconds(30))
    await clock.waitForSleepers(count: 1); await clock.advance(by: .seconds(30))
    _ = try await user
    #expect(api.callCount == 3)
}
```

## Products

| Product        | What                                                      | Depends on                      |
| -------------- | --------------------------------------------------------- | ------------------------------- |
| `Stoic`        | Every runtime primitive                                   | stdlib, `Synchronization`, `os` |
| `StoicTesting` | Test clocks, fault injection, recorded events, test trait | `Stoic`, Swift Testing          |
| `StoicJSON`    | Strict JSON: duplicate keys, exact numbers, positions     | stdlib                          |
| `StoicSchema`  | Validation: one declaration drives decode, encode, defaults, every error, JSON Schema | `StoicJSON` |
| `StoicApple`   | Platform errors that classify themselves for retry; HTTP status semantics; device conditions | `Stoic`, Foundation |
| `StoicAppKit`  | A Mac app finishes its async shutdown before quitting, with a hard deadline | `Stoic`, AppKit |
| `StoicUIKit`   | Background work bounded by the time iOS grants             | `Stoic`, UIKit                  |
| `StoicObservability` | Events to swift-log and swift-metrics                 | behind the `Logging` / `Metrics` traits |
| `StoicLint`    | Build-tool plugin: unsafe patterns fail the build         | swift-syntax, behind the `Lint` trait |

`StoicLint` is opt in, so apps that do not use it never fetch swift-syntax:

```swift
.package(url: "https://github.com/…/stoic", from: "0.1.0", traits: ["Lint"]),
// …and on a target:
plugins: [.plugin(name: "StoicLint", package: "stoic")]
```

See [design/13](design/13-build-enforcement.md) for the rules, the
`// stoic:allow(rule): reason` suppression and the baseline ratchet.

Coming: schema migrations, generators and a self-testing suite; `@Schema`;
crash-consistent persistence (`StoicStore`).

## Design

[DESIGN.md](DESIGN.md) is the north star: the principles, the contracts
every primitive shares, and the quality bar. [design/](design/) has one
contract per primitive — semantics, cancellation, errors, a failure-mode
table, events and a test plan — and the code is held to them.

## Adopting

[docs/Adopting.md](docs/Adopting.md) walks an existing app onto Stoic one
call site at a time: the lint baseline, warnings phased in by group, and the
patterns to replace in order of payoff.

## For agents

[AGENTS.md](AGENTS.md) is written for coding agents, and for anyone who
wants the rules in one place: which primitive to reach for, the patterns
to replace, and the conventions this repository holds itself to.

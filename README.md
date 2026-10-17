<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/stoic-mark-dark.svg">
  <img src="docs/assets/stoic-mark-light.svg" alt="Stoic's mark: an arched niche between two columns, sheltering a green sphere." width="72">
</picture>

# Stoic

[![CI](https://github.com/Vaccone-Software/stoic/actions/workflows/ci.yml/badge.svg)](https://github.com/Vaccone-Software/stoic/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Robustness primitives for Swift apps. [Website](https://vaccone-software.github.io/stoic-site/) · [Documentation](https://vaccone-software.github.io/stoic-site/docs/documentation/stoic/)

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

> **Status:** pre-release (0.x). The API will change before 1.0, as
> Lodestar, the pilot app, takes each primitive into production. Requires
> Swift 6.4 and macOS, iOS, tvOS, watchOS or visionOS 27; the libraries that
> need no Apple framework also build on Linux.

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

**Operations** take the numbers away from call sites. Declare each backend
once (what it is, how much it can take) and each operation on it by
whether repeating it is harmless; say who is waiting. `perform` derives
the rest — deadline, retries, attempt timeout, breaker, admission with
capacity kept for people, budget, idempotency key — and its error says
whether the backend may have acted.

```swift
extension Backend { static let payments = Backend.remote("payments") }
enum Payments { static let subscribe = Backend.payments.keyed("subscribe") }

let receipt = try await withUrgency(.interactive) {
    try await Payments.subscribe.perform(idempotencyKey: checkout.key) { attempt in
        try await api.subscribe(plan, idempotencyKey: attempt.idempotencyKey)
    }
}   // on failure, `error.outcome == .unknown` means: reconcile under the key, never re-ask
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

**TaskSlot** replaces generation counters: only the newest work delivers,
to an owner the slot holds weakly, so a view model that goes away takes its
request with it.

```swift
search.run(for: self) { [api] in try await api.search(query) } deliver: { @MainActor model, result in
    model.results = (try? result.get()) ?? []
}
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
    let api = FaultInjector<any Error>.failing(2, with: APIError.offline)
    async let user = withTestAmbient(clock: clock) {
        try await retry(.fixed(.seconds(30)).attempts(5)) { _ in try await api.run { try await fetchUser() } }
    }
    await clock.waitForSleepers(count: 1); await clock.advance(by: .seconds(30))
    await clock.waitForSleepers(count: 1); await clock.advance(by: .seconds(30))
    _ = try await user
    #expect(api.callCount == 3)
}
```

Concurrent logic gets a deterministic simulation: one thread, a seed that
picks every interleaving and fault timing, virtual time, and a failing seed
that replays exactly.

```swift
@Test func cacheNeverServesAStaleValue() async throws {
    try await simulate(seeds: 0..<500) { sim in
        let cache = TokenCache(refresh: { try await Ambient.sleep(for: .seconds(1)); return .fresh })
        async let a = cache.token(); async let b = cache.token()
        try #require(try await [a, b].allSatisfy { $0 == .fresh })
    }
}
```

## Products

| Product        | What                                                      | Depends on                      |
| -------------- | --------------------------------------------------------- | ------------------------------- |
| `Stoic`        | Every runtime primitive                                   | stdlib, `Synchronization`, `os` |
| `StoicTesting` | Test clocks, fault injection, recorded events, test trait | `Stoic`, Swift Testing          |
| `StoicJSON`    | Strict JSON: duplicate keys, exact numbers, positions     | stdlib                          |
| `StoicSchema`  | One declaration per type: decode, encode, validate, JSON Schema, migrations, generators, `SchemaSuite` | `StoicJSON` |
| `StoicSchemaTesting` | `expectSchemaSuite`, the Swift Testing glue for `SchemaSuite` | `StoicSchema`, Swift Testing |
| `StoicStore`   | Atomic file writes done right, a crash-consistent journal, an outbox, a crash-loop launch guard, a flight recorder the next launch can read — checked at every crash point | `Stoic` |
| `StoicSettings` | Settings that a crash, a bad value, an old format or a newer app version cannot ruin; observable | `StoicSchema`, `StoicStore` |
| `StoicSealed`  | Files and journals AES-256-GCM sealed, each bound to what it is for; keys in a keyring the app keeps in its own custody; tampered, torn, unknown-key and not-sealed told apart; deleting a record is destroying its key; crash-tested | `Stoic`, `StoicStore`, swift-crypto, behind the `Crypto` trait |
| `StoicHTTP`    | An HTTP client with the resilience written once: per-host retry honouring `Retry-After`, circuit breaker and bulkhead, idempotency keys on `POST`, bounded responses decoded through schemas, coalesced `GET`s, redirects followed by the client (no credential leaves its origin, never `https` to `http`), no credentials in events; a scripted transport so every failure is a test on virtual time | `Stoic`, `StoicFoundation`, `StoicSchema`, Foundation |
| `StoicFoundation` | Foundation's errors (`URLError`, `POSIXError`, `CocoaError`) classify themselves for retry; portable | `Stoic`, Foundation |
| `StoicApple`   | Device conditions; settled reachability; BGTask work bounded by expiry; Keychain secrets | `Stoic`, `StoicFoundation`, Apple frameworks |
| `StoicAppKit`  | A Mac app finishes its async shutdown before quitting, with a hard deadline | `Stoic`, AppKit |
| `StoicUIKit`   | Background work bounded by the time iOS grants             | `Stoic`, UIKit                  |
| `StoicObservability` | Events to swift-log and swift-metrics                 | behind the `Logging` / `Metrics` traits |
| `StoicMacros`  | `@Schema` writes a type's schema from its declaration; `@Refined` a named refinement | `StoicSchema`, swift-syntax, behind the `Macros` trait |
| `StoicLint`    | Build-tool plugin: unsafe patterns fail the build         | swift-syntax, behind the `Lint` trait |

`StoicLint` is opt in, so apps that do not use it never fetch swift-syntax:

```swift
.package(url: "https://github.com/Vaccone-Software/stoic", from: "0.1.0", traits: ["Lint"]),
// …and on a target:
plugins: [.plugin(name: "StoicLint", package: "stoic")]
```

See [design/13](design/13-build-enforcement.md) for the rules, the
`// stoic:allow(rule): reason` suppression and the baseline ratchet.

`StoicMacros` is opt in too, for the same reason. It makes the declaration of a
schema the declaration of the type:

```swift
.package(url: "https://github.com/Vaccone-Software/stoic", from: "0.1.0", traits: ["Macros"]),
// …and on a target:
dependencies: [.product(name: "StoicSchema", package: "stoic"), .product(name: "StoicMacros", package: "stoic")]
```

```swift
import StoicMacros
import StoicSchema

/// Application settings.
@Schema
struct Settings {
    /// Pixels per second.
    @Range(200...4000) @Unit("px/s") var scrollSpeed: Double = 1200
    var theme: Theme = .system
    @Key("api_token") @Secret var apiToken: String = ""
    @Length(1...253) @Count(0...8) @Unique var hosts: [String] = []
}

// Every issue, with its line and column; warnings (a deprecated spelling, a
// dropped element) go where you say, never nowhere.
try Settings.schema.decode(text) { warning in log(warning) }
```

A property with no default is a required field, which is what an API's model
wants: `var id: Int` makes a missing `id` an issue instead of a `0`, `var
email: String?` may be missing or `null`, and the schema builds the value with
the memberwise initializer. `Date`, `URL`, `UUID`, `Data` and `Decimal` are
fields too. An enumeration a server may extend names the case that stands for
what it does not know: `@UnknownCase case unknown` (or `case unknown(String)`)
reads an unfamiliar value as that case, with a warning instead of an error,
and `@Lossy` on an array drops the elements that do not decode, one warning
each, instead of failing the list. A `Codable` type you do not want to write a
schema for is `@Codable var payload: Payload` (or `.codable(Payload.self)`):
read by `JSONDecoder`, one issue on failure, `{}` in the JSON Schema.

The macro only writes calls to the `StoicSchema` API you could write by hand
(`Schema.object(…) { Field(…) }`), the same schema with the same behaviour;
without the trait, write that. Mistakes are compile errors at the line that is
wrong: a `@Length` on an `Int`, a default that
breaks its own `@Range`, a key used twice. See
[design/06](design/06-validation.md#as-built-layer-4-stoicmacros).

`StoicSealed` is opt in as well, so that adopting the other libraries fetches
no cryptography package (and builds no BoringSSL on Linux):

```swift
.package(url: "https://github.com/Vaccone-Software/stoic", from: "0.4.0", traits: ["Crypto"]),
// …and on a target:
dependencies: [.product(name: "StoicSealed", package: "stoic")]
```

```swift
import StoicSealed

// The keys live in a keyring the app keeps in its own custody (the Keychain,
// through an adapter design/24 shows), never beside the data.
let ring = try Keyring.open(name: "app.keyring", custody: custody, ifMissing: .create).keyring
let notes = SealedFile(keyring: ring)                          // 0o600, atomic, crash-tested
try notes.write(data, to: path, context: SealContext("app.notes", note.id))
let data = try notes.read(path, context: SealContext("app.notes", note.id))   // nil if no file

// A log whose every record is sealed; compacting with rotation makes everything
// written before it unreadable for ever (crypto-shredding), which is how a
// deleted record stops existing on a disk that never erases.
let log = try SealedJournal.open(at: logPath, context: SealContext("app.log", "main"), keyring: ring)
try log.append(batch: records)
try log.compact(snapshot: encode(state), rotatingKey: true)
```

An unreachable custody is never an empty one, and a failure is never "corrupt":
`.tampered`, `.torn`, `.unknownKey` and `.notSealed` are four different facts. See
[design/24](design/24-sealed-storage.md) for the threat model (backups, synced
folders and copied disks, not code running as the app), the formats, rotation
and the 2³² bound, key custody on Apple platforms, and what deleting a file
does not do.

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

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

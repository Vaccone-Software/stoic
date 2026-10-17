# Adopting Stoic in an existing app

Stoic is designed to be adopted one call site at a time. Nothing requires
rewriting an app around it; each primitive replaces one hand-rolled pattern
and pays for itself on its own.

## 1. Prerequisites

- Swift 6.4 tools (`// swift-tools-version: 6.4`) and a deployment target of
  macOS, iOS, tvOS, watchOS or visionOS 27. Stoic's cleanup guarantee rests
  on runtime features (cancellation shields, `await` in `defer`) that ship
  with the 27 releases.
- Swift 6 language mode is recommended but not required to _use_ Stoic.

## 2. Add the package, with the lint plugin

```swift
dependencies: [
    .package(url: "https://github.com/Vaccone-Software/stoic", from: "0.1.0", traits: ["Lint"]),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "Stoic", package: "stoic"),
            .product(name: "StoicApple", package: "stoic"),        // platform integration; Foundation errors classify themselves
        ],
        plugins: [.plugin(name: "StoicLint", package: "stoic")]
    ),
    .testTarget(name: "AppTests", dependencies: ["App", .product(name: "StoicTesting", package: "stoic")]),
]
```

## 3. Take a baseline, then ratchet

An existing codebase will have findings. Record them once, so the build
passes today and fails on anything new:

```sh
swift run --traits Lint stoic-lint --write-baseline .stoic-lint-baseline.json Sources
```

Baselined findings appear as warnings; new ones are errors. When a finding
is fixed, the baseline reports it as stale; regenerate it, and the count
only ever falls.

## 4. Warnings as errors, by group

Turning on `.treatAllWarnings(as: .error)` in one step usually fails the
build. Phase it in with SE-0480's per-group controls: make the groups you
have already fixed errors first, then widen.

```swift
swiftSettings: [
    .treatWarning("DeprecatedDeclaration", as: .error),
    .treatWarning("StrictMemorySafety", as: .error),
    // … then, once clean:
    .treatAllWarnings(as: .error),
]
```

## 5. Replace patterns in order of payoff

1. **Timeouts built by hand** → `withTimeout`, or `abandoningAfter` for
   blocking calls that cannot be cancelled. These are where hangs come from.
2. **Retry loops** → `retry(.exponential(base:).attempts(n))`. State the
   budget once; derive any outer watchdog from `worstCase(attemptTimeout:)`.
3. **Generation counters and stale callbacks** → `TaskSlot`.
4. **Lifecycle booleans** → `StateMachine`, with `whileIn` for the work
   each state owns. Add a `StateGraph.explore` test.
5. **Watchdog timers and restart loops** → `Supervisor` with heartbeats.
6. **Startup and shutdown lists** → `ServiceGraph`, and on macOS
   `GracefulTermination` from `applicationShouldTerminate`.
7. **Config validation** → `StoicSchema`: one declaration per type. With the `Macros` trait the declaration is the type itself (`@Schema struct Settings { … }`); without it, `Schema.object`.
8. **`try?` and stringified errors** → handle them, or `withContext`.
9. **Settings written with `Data.write`** → `SettingsStore.open(at:schema:)`:
   validated updates, crash-safe writes, migrations, and an older build that
   cannot destroy what a newer one saved.
   For a config file people edit by hand while the app runs (and a command-line
   tool may edit too), open it with `format: .handEdited`: a file with a typo is
   never renamed or overwritten, the issue says `line:column`, an update reads
   the file again under a lock (`coordinatedUpdate` waits for the other writer),
   writes are sparse and byte-stable (`.canonical(order: KeyOrder(root: [...]))`
   puts your sections in the order people read them, also over `Schema.json()`),
   and `watch()` picks up edits made outside the app. Say `missingVersion: .current`
   in the schema of such a file. Also: `comments: .refused` makes a comment a
   problem with a line and column instead of losing it at the next save;
   `blockingUpdate(waitingUpTo:)` is the update for code that cannot `await`
   (it blocks the thread: never on the main actor); `materialize()` writes the
   file on first launch; `replaceUnusableFile(with:keepingCopyAt:)` is the
   "reset" for a file that does not parse (it copies the person's bytes aside
   first); and `for await change in settings.changes()` gives each change of the
   value with `old`, `new` and a `cause` (`.update`, `.reload`, `.reset`), for a
   history that tells the app's edits from the person's.
10. **Handles closed under a wedged call** → when a scope's work may be
    abandoned, declare the handle's release `ifWorkAbandoned: .quarantine`.
11. **Private data in plain files, or a key beside the data it protects** →
    `SealedFile` and `SealedJournal` (`StoicSealed`, behind the `Crypto` trait:
    `traits: ["Lint", "Crypto"]` above, and `StoicSealed` as a product). The
    keys live in a `Keyring` the app keeps in a `KeyCustody`; for the Keychain,
    the app writes the twenty-line adapter over `SecretStore` that
    [design/24](../design/24-sealed-storage.md#the-keychain-on-apple-platforms)
    shows (`StoicApple` and `StoicSealed` do not depend on each other). Decide
    first what a lost key means for each store: a cache starts fresh
    (`ifMissing: .create`), durable data refuses and says why (`.fail`), and
    neither ever creates a key, or deletes a file, because the Keychain was
    locked. On macOS, an app with no application-identifier entitlement uses
    `KeychainSecretStore(loginKeychainService:)`; design/24 says what that
    changes (items outlive the app and are in backups). A plaintext file an
    earlier version wrote is sealed in place with `SealedFile.adopt`, which
    cannot erase the old blocks: only retiring a key (`compact(…, rotatingKey:
true)`) makes a deletion real.
12. **A hand-rolled retry queue for sends that must survive a relaunch** →
    `Outbox` over an `HTTPClient` made with `HTTPPolicy.singleAttempt`, so the
    outbox is the one layer that retries. Say what became of each entry by
    what the delivery returns (`.delivered`; `.discard(reason:)` for a `400`
    that will never succeed; `.keep`), and open it on
    `PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700)` when what
    it holds is private. `outbox.deliver(key) { … }` sends one entry now and
    says what happened to it, while a schedule drains the rest.

## 6. Make tests deterministic

Wrap time-sensitive tests in `withTestAmbient(clock: TestClock())`, drive
time with `waitForSleepers(count:)` and `advance(by:)` (an XCTest file needs
only `import StoicTesting`), inject failures with
`FaultInjector`, and end with `#expect(await stoicTasksStillRunning().isEmpty)`
so leaked work fails the test by name.

For anything concurrent — a cache, a sync engine, shared state across tasks
— add a simulation test. It explores hundreds of interleavings and fault
timings deterministically, and a failure names the seed that replays it:

```swift
@Test func syncSurvivesEveryInterleaving() async throws {
    try await simulate(seeds: 0..<500) { sim in
        let engine = SyncEngine(store: FakeStore())
        try await engine.syncAll()
        try #require(engine.pending.isEmpty)   // #require: it must throw to fail the seed
    }
}
```

Where the _path_ matters as much as the result, pin the decisions with a
golden trace: `expectTrace(events, """…""")`.

## 7. Watch the decisions

At launch, install a diagnostics ring and the device's conditions:

```swift
let ring = Diagnostics.install()
try await withAmbient({
    $0.instrumentation = CompositeInstrumentation([$0.instrumentation, ring])
    $0.conditions = DeviceConditions.shared
}) {
    try await app.run()
}
```

`Diagnostics.snapshot()` then gives a bug report the last decisions Stoic
made, every Stoic task still running, and any abandoned work.

To know what the _previous_ run was doing when it died, add a flight
recorder, and check it at launch:

```swift
let recorder = try FlightRecorder(path: supportDirectory + "/flight.rec")
if let last = recorder.previousRun, !last.endedCleanly {
    report("previous run ended abruptly", last.events.suffix(50))
}
// …add `recorder` to the CompositeInstrumentation above, and on the way out:
recorder.markCleanExit()
```

An AppKit `main.swift` is synchronous: `NSApplication.shared.run()` never
returns and must not run inside a task. Bind with the synchronous form,
`withAmbient({ … }) { NSApplication.shared.run() }`: the delegate, timers,
main-queue blocks and every `Task {}` they start see it (`Task.detached` and
global queues do not).

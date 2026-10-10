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
            .product(name: "StoicApple", package: "stoic"),        // platform errors classify themselves
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
7. **Config validation** → `StoicSchema`: one declaration per type.
8. **`try?` and stringified errors** → handle them, or `withContext`.

## 6. Make tests deterministic

Wrap time-sensitive tests in `withTestAmbient(clock: TestClock())`, drive
time with `waitForSleepers(count:)` and `advance(by:)`, inject failures with
`FaultInjector`, and end with `#expect(await stoicTasksStillRunning().isEmpty)`
so leaked work fails the test by name.

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

# Testing

Put time, randomness and failure in the test's hands.

@Metadata {
    @PageImage(purpose: card, source: "plate-testing", alt: "Goya's etching of a sleeping figure surrounded by owls and bats, set in an arched niche, printed as two-colour static.")
    @PageColor(green)
}

## What it does

@Row {
    @Column(size: 3) {
        Stoic reads its clock, its randomness and its event sink from ``Ambient``. In a
        test, `withTestAmbient` replaces them: a `TestClock` that moves only when the test
        moves it, a seeded random source, recorded events and fresh retry budgets.
        `FaultInjector` scripts failures, latency and hangs between code and its
        dependency.

        `simulate` runs a scenario on one thread, with a seed that chooses every
        interleaving and virtual time. A failing seed replays exactly. `expectTrace`
        checks the decisions Stoic made, not only the result.
    }
    @Column {
        ![Goya's etching of a sleeping figure surrounded by owls and bats, set in an arched niche, printed as two-colour static.](plate-testing)
    }
}

## Use it when

- Code races work against time, and the test must not sleep.
- A retry, a breaker or a supervisor must be shown to behave under a scripted failure.
- A concurrency bug shows once in a thousand runs and must be reproduced on demand.

## Example

```swift
@Test(.stoic(seed: 42))
func retriesThroughAnOutage() async throws {
    let clock = TestClock()
    let api = FaultInjector<any Error>.failing(2, with: APIError.offline)
    async let user = withTestAmbient(clock: clock) {
        try await retry(.fixed(.seconds(30)).attempts(5)) { _ in try await api.run { try await fetchUser() } }
    }
    for _ in 1...2 { await clock.waitForSleepers(count: 1); await clock.advance(by: .seconds(30)) }
    _ = try await user
    #expect(api.callCount == 3)
}
```

## What happens if…

| …                                            | Stoic                                                                    |
| -------------------------------------------- | ------------------------------------------------------------------------ |
| a simulated scenario fails on one seed       | `simulate(seeds:)` runs the seed again and says whether it reproduced    |
| nothing can run and nothing is asleep        | It is reported as `stalled`, with the Stoic tasks still running          |
| the scenario outlasts the virtual time limit | It is reported as `virtualTimeLimit`, a livelock                         |
| a `#expect` fails inside `simulate`          | It is recorded but does not fail the seed; use `#require`                |
| work escapes the simulation (an unstructured `Task {}`, Dispatch, a real sleep) or is left running | A test issue naming the cause and the fix, unless `allowEscapes: true`; `Simulated.report` has the counts |
| `waitForSleepers` never gets its sleepers    | After `timeout` (5 s real time, or on cancellation) an issue prints the clock's state |
| a test uses `ImmediateClock` for a timeout   | Every sleep returns at once; use it to record delays, never for timeouts |
| a golden trace differs                       | The issue shows the first differing line and the whole actual trace      |

The full contracts, with every case, are `design/12-testing.md` and
`design/11-observability.md` in the repository.

## The API

- ``Ambient``
- ``AnyClock``
- ``RandomSource``
- ``Instrumentation``
- ``Event``
- ``EventName``
- ``EventCatalog``
- ``TaskLedger``

The test tools live in the `StoicTesting` module, so they are not linked here:
`simulate`, `TestClock`, `ImmediateClock`, `withTestAmbient`, `FaultInjector`,
`expectTrace` and the `.stoic(seed:)` trait.

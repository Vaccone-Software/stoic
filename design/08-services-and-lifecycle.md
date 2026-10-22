# 08 · Services and app lifecycle

A dependency graph for an app's long-lived services. Every app has a handful of long-lived services —
a database, a network client, a sync engine, a model — that depend on each
other, must start in the right order, and must stop in the reverse order
when the app quits, the user signs out, or a test ends. By hand, startup is
a sequence in `applicationDidFinishLaunching` and teardown is a list in
`applicationWillTerminate`: unordered when it matters, unbounded when a
service hangs, synchronous where cleanup is async, and with every failure
swallowed.

## Origin

- **Effect's `Layer` and ZIO's `ZLayer`.** Services built from the services
  they need, constructed concurrently where independent, with resource-safe
  teardown. ZIO checks the graph at compile time with a macro; Effect at
  the type level.
- **Bluefin and Eio.** Capabilities as _values_: two of the same service
  are two values, not a lookup by type.
- **ServiceLifecycle.** Reverse-order graceful shutdown, and an escalation
  ladder when it does not finish.

## API

```swift
public struct ServiceKey<Value: Sendable>: Hashable { init(_ name: String); var any: AnyServiceKey }
public struct Provide {
    init<Value>(_ key: ServiceKey<Value>, needs: [AnyServiceKey] = [], startTimeout: Duration = .seconds(30),
                stopTimeout: Duration? = nil, start: @escaping @Sendable (Services) async throws -> Value,
                stop: @escaping @Sendable (Value, Exit) async throws -> Void = { _, _ in })
}
public struct Services { subscript<Value>(key: ServiceKey<Value>) -> Value }
public struct ServiceGraph {
    init(label: String, @ServicesBuilder _ services: () -> [Provide]) throws(ServiceGraphError)
    var startOrder: [AnyServiceKey]
    func run<R>(exitBudget: Duration = .seconds(30), stopTimeout: Duration = .seconds(10), startGrace: Duration = .seconds(5),
                _ body: nonisolated(nonsending) (Services) async throws -> R) async throws -> R
}
public enum ServiceGraphError: Error { case duplicate, missing, cycle, startFailed }
```

## Semantics

**Keys are values.** A `ServiceKey<Database>("cache")` and a
`ServiceKey<Database>("primary")` are different services of the same type.

**Validated when built.** Duplicates, dependencies on absent services and
cycles are initialiser errors, with the cycle spelled out (`x → y → z → x`),
before anything starts.

**Declared needs are enforced.** A factory sees only the services it listed
in `needs`; reading any other is a programming error caught on first use, so
the declared graph — which decides start and stop order — cannot quietly
drift from what the code does.

**Starting.** A service starts as soon as everything it needs has started,
so independent services start concurrently. Each start runs under its own
cooperative `startTimeout`. If any start fails or times out, the other
starts are cancelled, every service that did start is stopped, and `run`
throws `startFailed` naming the service and its error.

**Every start ends.** Cooperative is not enough on its own: a start that
ignores cancellation (a synchronous call into a framework that stopped
answering) would hold `run`, and the app's launch, for ever, while stops are
already abandoned after their timeout. So a start that has not returned
`startGrace` (five seconds) after it was told to stop — by its timeout, or
by the graph's cancellation after another start failed — is abandoned:
listed in `AbandonedWork` until it ends, reported
(`service.start_abandoned`), and treated as having failed (a deadline
rejection) or been cancelled. The drain after a failure is bounded the same
way. If an abandoned start finishes after all, its service is stopped at
once (Exit `.failure`, or `.cancelled`): nothing else holds it.

**Stopping.** However the body ends, services stop in the reverse of the
order their starts completed — a service always stops before anything it
needs — through a scope's exit: shielded from cancellation, each bounded by
its `stopTimeout`, all within `exitBudget`, failures reported, and a hung
stop abandoned so the next one still runs. The `Exit` passed to each stop
says whether the app is ending normally.

## App lifecycle bridges (`StoicAppKit` / `StoicUIKit`)

`applicationWillTerminate` is synchronous; async teardown run from it is
cut off when the process exits. The correct macOS pattern is to return
`.terminateLater` from `applicationShouldTerminate`, run the graph's
shutdown, and reply `true` when it finishes — or when a hard deadline
passes, so a hung service can never stop the app from quitting. On iOS the
equivalent is a background task whose expiration handler cancels the
shutdown scope with cause `systemExpiring`. Both bridges are small, and live
in integration products so the core stays free of UI frameworks.

`GracefulTermination` runs the shutdown *off* the main actor and keeps the
deadline on it, so a step that blocks its thread (a synchronous call into a
framework that stopped answering) cannot hold the timer and the reply
hostage; at the deadline the app quits and `lifecycle.terminate_overran`
names what was left running (`abandoned_work`, `tasks_running`, and the
labels of both). Work that needs the main actor hops there itself.

Built: `GracefulTermination` (AppKit) and `BackgroundWork.run(named:)`
(UIKit). The iOS bridge is a thin shell over `ExpiringWork`, in the core so
it is tested on every platform: the work runs under a deadline of the time
granted, is cancelled by expiry (cause `systemExpiring`), by that deadline
and by its caller, and each run has its own cause. Expiry is final. A
refusal of time is a different thing, `BackgroundTimeRefused`, and does not
run the work. Four rules came from review:

- UIKit reports `backgroundTimeRemaining` as `Double.greatestFiniteMagnitude`
  in the foreground. It is finite, and converting it to a duration traps, so
  only a grant of up to an hour is treated as one.
- Awaiting an unstructured task's value does not cancel it when the awaiting
  task is cancelled. The bridge passes cancellation on explicitly.
- The system requires the background task ended before the expiration
  handler returns. The handler ends it at once, without waiting for the
  work to unwind; the normal exit path ends it otherwise, exactly once.
- `beginBackgroundTask` returns `.invalid` when the system will not grant
  time. The work does not run — nothing is keeping the process awake, and
  a remaining time of 0 is not a deadline — and the call throws
  `BackgroundTimeRefused`. It is not a `CancellationError`: nothing was
  cancelled, the caller's task is untouched, and no cause is invented for
  a task that is not cancelled (`CancellationCause.current` is unchanged;
  design/01). It is not a `Defect` (the system's answer is not a bug) and
  its `retryDecision` is `.stop`, so a `retry` around the call does not
  ask again at once; a later attempt is the app's to schedule.

## Failure modes

| What happens if…                             | Behaviour                                                         |
| -------------------------------------------- | ----------------------------------------------------------------- |
| two services share a key                     | `duplicate` from the initialiser                                  |
| a service needs one that is absent           | `missing` from the initialiser                                    |
| services need each other                     | `cycle`, with the path                                            |
| a factory reads a service it did not declare | Programming error on first use                                    |
| a start throws or times out                  | Other starts cancelled; started services stopped; `startFailed`   |
| a start ignores its timeout                  | Abandoned after `startGrace`; `startFailed`; stopped if it finishes later |
| a start ignores cancellation after another fails | Abandoned after `startGrace`; the first failure is thrown     |
| the body throws                              | Every service stopped (Exit `.failure`); the error passes through |
| a stop hangs                                 | Abandoned after its timeout; the rest still stop                  |
| the app's task is cancelled                  | Every service stopped, shielded                                   |
| the system refuses a background assertion    | The work does not run; throws `BackgroundTimeRefused`            |

## Events

`service.started` (debug) as each start completes; `service.start_abandoned`
(error) for a start that outlived its grace; `service.start_failed`
(error, with the service and its error, a timeout as a deadline rejection)
for the start that fails the graph; `service.stopped` as each stop returns,
with how long it took (`warning` with the error when it threw). A stop that
hangs is abandoned by the scope that runs it, which reports that, and
`service.stopped` follows if it ever returns. On macOS,
`lifecycle.terminate_started`, `lifecycle.terminate_completed` and
`lifecycle.terminate_overran` (error, naming what was left running).

## Testing

Start order and reverse stop order; two services of one type; concurrency
of independent starts; every validation error and its message; start
failure and start timeout with cleanup of what started; a start that
ignores its timeout, and one that ignores cancellation after a sibling
failed, each abandoned after the grace; stops after a
failing body. 200 repetitions are clean.

## Planned

- `@Services` macro: a graph declared as a struct is checked at compile
  time — missing dependencies and cycles become compiler errors.
- Supervised services: a service's long-running work as a supervisor child,
  with the graph as the supervisor's parent.
- ServiceLifecycle trait: run a graph as a `Service`.

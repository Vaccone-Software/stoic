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
    func run<R>(exitBudget: Duration = .seconds(30), stopTimeout: Duration = .seconds(10),
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
and by its caller, and each run has its own cause. Expiry is final. Three
rules came from review:

- UIKit reports `backgroundTimeRemaining` as `Double.greatestFiniteMagnitude`
  in the foreground. It is finite, and converting it to a duration traps, so
  only a grant of up to an hour is treated as one.
- Awaiting an unstructured task's value does not cancel it when the awaiting
  task is cancelled. The bridge passes cancellation on explicitly.
- The system requires the background task ended before the expiration
  handler returns. The handler ends it at once, without waiting for the
  work to unwind; the normal exit path ends it otherwise, exactly once.

## Failure modes

| What happens if…                             | Behaviour                                                         |
| -------------------------------------------- | ----------------------------------------------------------------- |
| two services share a key                     | `duplicate` from the initialiser                                  |
| a service needs one that is absent           | `missing` from the initialiser                                    |
| services need each other                     | `cycle`, with the path                                            |
| a factory reads a service it did not declare | Programming error on first use                                    |
| a start throws or times out                  | Other starts cancelled; started services stopped; `startFailed`   |
| the body throws                              | Every service stopped (Exit `.failure`); the error passes through |
| a stop hangs                                 | Abandoned after its timeout; the rest still stop                  |
| the app's task is cancelled                  | Every service stopped, shielded                                   |

## Testing

Start order and reverse stop order; two services of one type; concurrency
of independent starts; every validation error and its message; start
failure and start timeout with cleanup of what started; stops after a
failing body. 200 repetitions are clean.

## Planned

- `@Services` macro: a graph declared as a struct is checked at compile
  time — missing dependencies and cycles become compiler errors.
- Supervised services: a service's long-running work as a supervisor child,
  with the graph as the supervisor's parent.
- ServiceLifecycle trait: run a graph as a `Service`.

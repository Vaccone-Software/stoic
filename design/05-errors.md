# 05 · Errors and reports

Failures are classified, not flattened. An app needs three things from an
error: _what_ failed (the original error, intact and matchable), _where and
why_ (what the app was doing at each layer), and _what to do_ (retry, give
up, tell the user, file a bug). Hand-rolled code loses all three:
`try?` discards the error, `"\(error)"` flattens it to a string, and a
`catch` that rethrows something new loses the original.

## Origin

- **Rust's error-stack.** A `Report` pairs a typed current context with a
  chain of context frames — better than thiserror (typed, no context) and
  anyhow (context, untyped).
- **Effect's `Cause`.** Failures, defects and interruption are different
  things; Effect 4 flattened its cause tree into a list of reasons.
- **Java's suppressed exceptions.** An error raised while handling another
  is kept, not lost.

## API

```swift
public struct Report: Error {
    public let root: any Error            // the original; never itself a Report
    public var frames: [Frame] { get }     // innermost first: message, metadata, fileID, line
    public var suppressed: [any Error] { get }
    public init(_ error: any Error)        // reporting a report returns it
    public func adding(_ frame: Frame) -> Report
    public func suppressing(_ error: any Error) -> Report
    public func first<E: Error>(_: E.Type) -> E?
    public func contains<E: Error>(_: E.Type) -> Bool
    public var isDefect: Bool
}

public func withContext<R>(_ message: @autoclosure () -> String, metadata: [Event.Field] = [],
                           operation: nonisolated(nonsending) () async throws -> R) async throws -> R
public func withContext<R>(…, operation: () throws -> R) throws -> R
extension Error { public func context(_ message: String, metadata: [Event.Field] = []) -> any Error }

public protocol Defect: Error {}
```

## Semantics

**One flat chain.** Wrapping a report adds a frame; it never nests reports
inside reports. The rendering is a short tree, outermost first, ending in
the root's type and description.

**Cancellation is never wrapped.** `withContext` and `context(_:)` pass a
`CancellationError` through as itself, so `catch is CancellationError` and
Stoic's own cancellation checks keep working.

**The root stays reachable.** `first(_:)` looks through reports, rejected
and failed `PolicyError`s and `ConcurrentFailure`s; Stoic's classification
(retry decisions, `containsDefect`, `containsCancellation`) does the same, so
adding context never changes how an error is handled.

**Untyped on purpose.** A report's job is to cross layers, and each layer
has its own error type; Swift has no error unions. Typed errors stay typed
inside a layer (Stoic's primitives pass them through), and become a report
where a layer adds context on the way out.

**Defects.** An error type conforming to `Defect` means "this code is
wrong", not "the world did something": never retried, never counted against
a dependency by a circuit breaker, reported at error level.

**Privacy.** Frame messages and metadata are data the app chose to write;
in events, a report travels as an error value, whose description is private
by default.

## Failure modes

| What happens if…                                   | Behaviour                                               |
| -------------------------------------------------- | ------------------------------------------------------- |
| an error passes through three `withContext` layers | One report, three frames, the root intact               |
| the error is a `CancellationError`                 | Passed through unwrapped                                |
| a defect is wrapped in a report                    | `isDefect` is true; retry stops                         |
| a report wraps a `PolicyError` wrapping the root   | `first(Root.self)` finds it                             |
| cleanup fails while handling an error              | `suppressing(_:)` keeps it; shown in `debugDescription` |

## Testing

Frame order and rendering; cancellation passthrough in both forms; root
lookup through every wrapper; classification through reports (a defect in
a report stops a retry).

## Planned

- A platform error catalog (`URLError`, `POSIXError`, `CocoaError`,
  `NWError` → transient, permanent, needs-user, defect) in an Apple
  integration product, feeding retry classification.
- A `UserFacing` protocol hook for presenting recoverable errors; the
  presentation itself is the app's.
- Lint: `try?` on a call whose error matters, and `catch { print(error) }`,
  are flagged with a fix-it toward `withContext`.

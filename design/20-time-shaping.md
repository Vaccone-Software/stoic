# 20 · Time shaping

Four small primitives for work that arrives faster, or older, than anyone
wants to act on it. A debouncer runs the latest of a burst of calls once the
burst is quiet; a throttler lets one call through per interval; an expiring
cache serves a value that has gone stale while it fetches a fresh one; a
broadcast hands every element to every subscriber, each through a buffer of
its own. Each is a plain value that measures time on a clock it is given, so a
test on `TestClock` decides when a burst ends and when an entry goes stale,
and each ends cleanly when its caller, its subscriber or its scope does.

## Origin

- **lodash `debounce` and `throttle`.** The `leading` and `trailing` options,
  and the rule that a trailing call opens the next window. Stoic keeps both
  and adds what lodash cannot say: a call that does not run is told so
  (`superseded`, `suppressed`) instead of returning the previous result.
- **Rx `debounceTime`, `throttleTime`; Combine `debounce`, `throttle(latest:)`.**
  Operators on a stream. Stoic's are policies on a call, because an app's
  search box is a function that is called, not a stream someone built.
- **HTTP `stale-while-revalidate` (RFC 5861); Caffeine `refreshAfterWrite`.**
  Serve the stale value while one refresh runs, and keep it if the refresh
  fails. The refresh runs through a single flight (the Go `singleflight`
  idiom), and, unlike a library's refresh pool, in a scope the caller owns.
- **Kotlin `SharedFlow`; Tokio `broadcast`.** A multi-subscriber channel with
  an explicit overflow rule: `BufferOverflow.SUSPEND`, `DROP_OLDEST`,
  `DROP_LATEST`. Tokio's lagging receiver loses the oldest. Stoic puts the
  rule on the subscriber, not the channel, and has no replay.
- **In apps.** A `DispatchWorkItem` cancelled and rescheduled on every
  keystroke, a `lastFired` date compared to `Date()`, a `[String: (Date, Value)]`
  dictionary that never evicts, and a `PassthroughSubject` whose slowest
  subscriber decides how much memory the app uses.

Facts about the systems above are from prior knowledge, not re-checked.

## API

```swift
// Both run the operation inline, in the caller's task, and are Policies.
public final class Debouncer: Policy {
    public init(quiet: Duration, leading: Bool = false, trailing: Bool = true, label: String, clock: AnyClock? = nil)
    public func execute<R, Failure>(_ operation: () async throws(Failure) -> R) async throws(PolicyError<Failure>) -> R
    public func submit(in scope: borrowing TaskScope, label: String? = nil, _ operation: @escaping @Sendable () async throws -> Void)
}
public final class Throttler: Policy {
    public init(interval: Duration, leading: Bool = true, trailing: Bool = false, label: String, clock: AnyClock? = nil)
    public func execute<R, Failure>(_ operation: () async throws(Failure) -> R) async throws(PolicyError<Failure>) -> R
    public func submit(in scope: borrowing TaskScope, label: String? = nil, _ operation: @escaping @Sendable () async throws -> Void)
}
extension Rejection.Reason { public static let superseded, suppressed: Reason }

public actor ExpiringCache<Key: Hashable & Sendable, Value: Sendable, Failure: Error> {
    // A factory, not an init: a scope is not Sendable and cannot cross into an actor's initializer.
    public static func make(in scope: borrowing TaskScope, ttl: Duration, staleWindow: Duration = .zero,
                            maxEntries: Int, negativeTTL: Duration? = nil, label: String, clock: AnyClock? = nil,
                            loader: @escaping @Sendable (Key) async throws(Failure) -> Value) -> ExpiringCache
    public func value(for key: Key) async throws(PolicyError<Failure>) -> Value
    public var count: Int
}

public final class Broadcast<Element: Sendable>: Sendable {
    public enum Buffer { case dropOldest(Int), dropNewest(Int), suspend(Int) }
    public init(label: String)
    public func subscribe(_ buffer: Buffer) -> Subscription       // an AsyncSequence of Element
    public func publish(_ element: Element) async throws(Rejection)
    public func finish()
    public var subscriberCount: Int
    // Subscription: cancel(), droppedCount, bufferedCount
}
```

## Semantics

**One call, one fate.** A debounced or throttled call ends in exactly one of:
it runs (the operation's result or `.failed`), it is `.superseded` by a newer
call, it is `.suppressed` by the rule, or it is `.cancelled`. Nobody is left
waiting for a call that will not run: replaced and suppressed callers are
told when the newer call arrives, not when the timer would have fired.

**Debounce.** A burst lasts until `quiet` has passed since its last call. The
first call of a burst runs at once if `leading`; every other call waits for
the burst to end, and only the last of them runs (`trailing`). Operations are
not serialised: a call after the burst starts a new one even if the last
operation is still running.

**Throttle.** A window opens when a call runs (`leading`), or, without
`leading`, when the first call arrives, and lasts `interval`. With `trailing`
the latest call of a window runs when it ends and opens the next window.
Without it, calls in the window are suppressed. A throttler drops where a
`RateLimiter` delays: use the limiter when every call must happen.

**Owned waiting.** A pending call waits in its own caller's task, on a timer
that is a child of that wait. No task is started that a caller or a scope does
not own, so cancelling the caller withdraws the call and ending the scope that
holds a `submit` fork does the same; there is no timer to leak. `submit` is
for callers that do not wait for the answer: rejections end the fork quietly,
an error from the operation fails the scope as any fork's does. Time is the
clock's, not the timer's: a timer always fires a little late, and a call that
arrives after a burst or window has ended, in that gap, finds the waiting call
due and lets it run rather than replacing it.

**Expiring cache.** An entry is fresh for `ttl`, then stale for `staleWindow`,
then gone. A stale read returns the value and starts at most one refresh per
key, forked into the cache's scope; the refresh and any cold callers share one
run of the loader through a `SingleFlight`, so cancelling a waiter never
cancels the load for another, and cancelling the last one cancels the load. A
failed refresh keeps the stale value. A load that fails with no value to fall
back on is thrown to its waiters and forgotten, unless `negativeTTL` is set;
cancelled loads and rejections are never remembered. Only a live load stores
its outcome (the flight commits it before any caller sees it): one every
caller left, if it returns anyway, stores nothing. Memory is bounded by
`maxEntries`, evicting the least recently used. The cache must not outlive its
scope: afterwards stale entries are served until they expire but not refreshed.
It stops trying quietly: the first refresh the ended scope refuses is the
last attempted, with nothing reported and nothing kept per key.

**Broadcast.** Each subscriber has its own bounded buffer and policy, chosen
when it subscribes, and sees only what is published afterwards. Publishing
visits subscribers in subscription order; a `suspend` subscriber that is full
holds the publisher, and so every subscriber after it, until it takes an
element, leaves, or the publisher is cancelled. A subscription ends (its loop
sees `nil`) after `finish()` and its drained buffer, when its consuming task
is cancelled, after `cancel()`, or when it is dropped, and in each case leaves
the broadcast at once, so a vanished subscriber can neither hold up a
publisher nor grow without bound. Drops reuse `Channel`'s counting and event.

## Failure modes

| What happens if…                                              | Behaviour                                                                                                                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| a debounced call arrives while an earlier one waits           | The earlier call throws `.rejected(.superseded)` at once; the quiet period restarts from the new call; `debounce.dropped`                              |
| the quiet period passes with no newer call                    | The latest call runs its operation, in its own task, and returns the result                                                                            |
| `leading` is on and a call opens a burst                      | It runs at once; with `trailing` also on, the last later call of the burst runs when the burst ends, and a burst of one call runs once                 |
| `leading` only and a call arrives inside the burst            | `.rejected(.suppressed)` and the burst is extended; `debounce.dropped`                                                                                 |
| a waiting debounced call is cancelled                         | `.rejected(.cancelled)` (`.deadlineExceeded` when its deadline did it); the call is withdrawn and nothing runs for it                                  |
| the scope that owns a `submit` ends                           | The waiting call is withdrawn with its fork; nothing runs afterwards and the scope's outcome is unchanged                                              |
| a debounced operation throws                                  | `.failed(error)` for that caller; the next call starts a new burst                                                                                     |
| a call arrives inside the window with `trailing` off          | `.rejected(.suppressed)`; `throttle.dropped`                                                                                                           |
| calls arrive inside the window with `trailing` on             | Only the latest is kept and runs when the window ends; each one it replaces throws `.superseded` at once; `throttle.dropped`                           |
| a trailing call runs                                          | It opens the next window of `interval`, so runs are never closer than that                                                                             |
| `leading` is off and a call opens a window                    | It waits for the window to end, then runs; nothing runs sooner than `interval` after the first call                                                    |
| a call waiting for the window's end is cancelled              | `.rejected(.cancelled)`; the window stays open and nothing runs for it                                                                                 |
| a call arrives after the quiet period, before its timer fires | The waiting call runs (its burst is over) instead of being superseded; the new call opens the next burst                                               |
| a call arrives after the window ends, before its timer fires  | The waiting call runs and opens the next window, as its timer would have; the new call falls inside that window                                        |
| a fresh entry is read                                         | Returned without calling the loader                                                                                                                    |
| a stale entry is read                                         | Returned at once; one refresh for the key starts in the background, forked into the cache's scope, however many readers see it                         |
| callers miss the same key together                            | One load runs and every caller gets its value or its error (single flight)                                                                             |
| a background refresh fails                                    | The stale value is kept and served; `cache.refresh_failed`; the next stale read tries again                                                            |
| a load with no value to fall back on fails                    | `.failed(error)` to every waiting caller; nothing is cached, so the next caller tries again                                                            |
| `negativeTTL` is set and a load fails                         | The failure is remembered for that long and thrown to callers without calling the loader                                                               |
| one of several callers waiting on a load is cancelled         | It leaves with `.rejected(.cancelled)`; the load continues for the others and its value is cached                                                      |
| every caller waiting on a load is cancelled                   | The load is cancelled and nothing is cached, not even a failure                                                                                        |
| a load every caller left finishes anyway                      | Its outcome is dropped: not cached, so it cannot overwrite a newer load's value or mark old data fresh                                                 |
| an entry is added past `maxEntries`                           | The least recently used entry is evicted; a read counts as a use                                                                                       |
| the scope ends while a refresh runs                           | The refresh is cancelled and awaited, and is not reported as a failure; the stale entry stays until it expires                                         |
| a stale entry is read after the cache's scope ended           | Served as it is and not refreshed; no refresh is attempted again, nothing is reported, and nothing is kept for the key                                 |
| a `dropOldest` subscriber's buffer is full                    | Its oldest element is discarded for the new one; the publisher does not wait; `droppedCount` rises; `channel.dropped`                                  |
| a `dropNewest` subscriber's buffer is full                    | The new element is not delivered to it; the publisher does not wait; `droppedCount` rises; `channel.dropped`                                           |
| a `suspend` subscriber's buffer is full                       | The publish waits, in subscription order, until it takes an element; later subscribers get the element after it                                        |
| a `suspend` subscriber ends while a publish waits for it      | The publish is released, skips that subscriber and goes on with the rest                                                                               |
| the publisher is cancelled while it waits for a subscriber    | `.rejected(.cancelled)` (`.deadlineExceeded` for a deadline); subscribers earlier in the order have the element, later ones do not                     |
| a subscriber's task is cancelled                              | Its loop ends and the subscriber is removed from the broadcast at once                                                                                 |
| a subscription is dropped without being iterated              | It is removed from the broadcast; nothing is buffered for it afterwards                                                                                |
| `finish()` is called                                          | Subscribers drain what they buffered and then end; `publish` throws `.rejected(.closed)`; a later `subscribe` returns a subscription that ends at once |

## Events

`debounce.dropped` and `throttle.dropped` (reason: `superseded` or
`suppressed`; debug), `cache.refresh_failed` (error; warning). Broadcast drops
are `channel.dropped`, labelled with the broadcast. Keys are never put in an
event: they are usually identifiers of the user's data.

## Testing

- Every row of the table has a test on `TestClock`, with no real waiting;
  waiting calls are awaited with `clock.waitForSleepers(count:)`.
- Debounce and throttle: the exact boundaries of the quiet period and the
  window; leading, trailing and both; supersession order with several
  waiters; a cancelled latest call; a scope ending over `submit` forks.
- Cache: loader call counts across fresh, stale and expired reads; a gated
  loader to hold a refresh open while waiters cancel; eviction order with
  interleaved reads; a failing refresh and a failing cold load, with and
  without `negativeTTL`.
- Broadcast: each buffer policy against a consumer that does not run; a
  suspended publish released by cancel, by the subscriber's cancellation and
  by `finish()`; `subscriberCount` back to zero after every kind of end.

## Non-goals

A `maxWait` that forces a debounced call out during an endless burst (a
throttler with `trailing` is that); replay or history for late subscribers;
a publish that does not wait on its `suspend` subscribers one after another;
time-based eviction sweeps (an expired entry is noticed when it is read, and
bounded by `maxEntries` until then); invalidation and manual refresh of
cache entries; a cache that outlives its scope.

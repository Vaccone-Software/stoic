# 34 · Inactivity

Work that should show signs of progress (a session streaming a reply, a build
printing, a download moving) sometimes stops showing them, and something
should notice. By hand, that is a `lastActivity` date and a timer that
compares it with `Date()`: a wall clock, so a laptop that slept for an hour
wakes to find all its work an hour quiet and reports every bit of it stuck.
`Inactivity` is the quiet-spell detector on its own: poked at each sign of
life, measured on the liveness clock (which does not advance while the
machine sleeps), each spell heard once.

## The ideal scenario

> A thread working for another shows no sign of work for ten minutes, its
> turn still under way. Its boss is told, once. The Mac sleeps over lunch
> with the thread mid-turn: nobody is told anything on waking.

```swift
let quiet = Inactivity(after: .seconds(600), label: "thread.stall")
session.onEvent = { _ in quiet.poke() }
for await spell in quiet.quietSpells() { boss.tell("no sign of work for \(spell)") }
```

## Origin

- **Woodsmoke**, the pilot: a stall watch that compared `Moment.now` with the
  time of the last event once a minute, and told a boss its thread was stuck
  after every long sleep.
- **Stoic's `Supervisor` heartbeats** (design/09) measure on the same clock,
  and stop and restart a child that goes silent. This is the half of them that
  only notices, for work nothing should restart.

## API

```swift
public final class Inactivity: Sendable {
    public init(after: Duration, label: String, clock: AnyClock? = nil)   // nil: Ambient.livenessClock
    public let after: Duration
    public func poke()
    public var quietFor: Duration { get }
    public var isQuiet: Bool { get }
    public func untilQuiet() async throws(CancellationError)
    public func nextPoke() async throws(CancellationError)
    public func quietSpells() -> QuietSpells                              // AsyncSequence of Duration
}
```

## Semantics

A poke records the clock's now under a lock and wakes anyone waiting in
`nextPoke`; it never wakes a watcher in `untilQuiet`, which on waking reads
the latest poke and sleeps again for what is left. So a poke per line of
output costs a lock, not a wake-up. `quietSpells` yields when the work has
been quiet for `after`, then nothing until a poke and another quiet stretch.

## Failure modes

| What happens if…                  | Behaviour                                                                 |
| --------------------------------- | ------------------------------------------------------------------------- |
| nothing pokes it for the stretch  | `untilQuiet` returns once `after` has passed since the last poke          |
| it is poked while a watcher waits | The wait ends `after` from the latest poke                                |
| the machine sleeps                | The liveness clock does not advance: no quiet time accrues                |
| a quiet spell goes on             | `quietSpells` reports it once; the next comes only after a poke           |
| the watcher is cancelled          | `untilQuiet` and `nextPoke` throw `CancellationError`; `quietSpells` ends |

## Events

`inactivity.quiet` (info), once per spell reported by `quietSpells`, with
how long it had been quiet.

## Testing

On a `TestClock`: a watcher waits, the clock advances to a second short of
the stretch and then to it; a poke midway moves the end; `withTestAmbient`
with `jumpWallClock` shows that a wall-clock jump is not quiet time.

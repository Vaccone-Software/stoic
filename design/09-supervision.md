# 09 · Supervision

Long-lived work fails. A sync engine loses its connection, an event tap
gets disabled by the system, a model server crashes on a bad input. The
hand-rolled answers — a watchdog timer that pings and aborts, a `while true
{ do { … } catch { sleep } }` loop — restart too eagerly or not at all, fire
during a slow launch or right after the Mac wakes, and turn a persistent
fault into a crash loop. Supervision is the discipline for this, and Erlang
has had the specification right for thirty years.

## Origin

- **Erlang/OTP supervisors.** Restart strategies (`one_for_one`,
  `one_for_all`, `rest_for_one`), restart types (`permanent`, `transient`,
  `temporary`), an intensity window that escalates when restarts are not
  helping, ordered start and reverse-ordered shutdown with per-child
  timeouts.
- **Akka.** Backoff with randomisation between restarts.
- **ServiceLifecycle.** A ladder from graceful shutdown to cancellation to
  giving up, and no restart option at all — the gap this fills.

## API

```swift
public final class Supervisor: Sendable {
    public init(label: String, strategy: Strategy = .oneForOne, intensity: Intensity = .standard,
                backoff: Schedule = .exponential(base: .milliseconds(500)).capped(at: .seconds(30)),
                resetAfter: Duration = .seconds(30), @ChildrenBuilder children: () -> [Child])
    public func run() async throws            // SupervisorEscalation, or CancellationError
    public var events: AsyncStream<SupervisorEvent>
}
public struct Child { init(_ label: String, restart: RestartPolicy = .permanent, heartbeat: HeartbeatPolicy? = nil,
                           shutdownTimeout: Duration = .seconds(5), run: @escaping @Sendable (Heartbeat) async throws -> Void) }
public enum RestartPolicy { case permanent, transient, temporary }
public struct HeartbeatPolicy { init(interval: Duration, misses: Int = 3, grace: Duration = .seconds(30)) }
public final class Heartbeat { public func beat() }
```

## Semantics

**One loop decides.** Children, heartbeat monitors and restart timers send
signals to a single loop that owns all state. Every child run has a
generation; a signal from a generation that has been stopped or replaced is
stale and ignored, so a child stopped by the supervisor can never be
mistaken for one that crashed.

**Restarts.** `permanent` children restart whenever they stop; `transient`
only when they throw; `temporary` never. When every child has finished for
good, `run()` returns.

**Strategies.** `oneForOne` restarts the stopped child. `oneForAll` stops the
others newest first and restarts all in order. `restForOne` does the same
for the stopped child and those started after it.

**Intensity.** More than `maxRestarts` within `window` (five a minute by
default) means restarting is not helping: every child is stopped and `run()`
throws `SupervisorEscalation` with the child and its last error, for the
next level up — a parent supervisor, a service graph, or the process. A
crash (a trap) cannot be caught in-process; that level is the operating
system restarting the process, and is configured there (launchd's
`KeepAlive`, the app being relaunched).

**Backoff.** Each child waits on the supervisor's schedule before
restarting (jittered exponential by default, capped at 30 s); a child that
ran for `resetAfter` without stopping starts its backoff over.

**Heartbeats.** A child with a `HeartbeatPolicy` calls `beat()` while it
makes progress. Silence for `misses` consecutive intervals (three by
default — one slow moment is not a hang) means hung: the child is stopped
and restarted like a failure. Heartbeats use the liveness clock, which
stops while the machine sleeps, and are not checked during `grace` after a
start, for slow launches. Both rules exist because watchdogs that ignored
them have turned slow launches and wake-from-sleep into crash loops.

**Stopping.** Newest first. Each child is cancelled with cause
`supervisorStopped` and given its `shutdownTimeout`; one that does not stop
is abandoned and reported (`supervisor.child_abandoned`) so shutdown always
finishes.

## Failure modes

| What happens if…                         | Behaviour                                                      |
| ---------------------------------------- | -------------------------------------------------------------- |
| a permanent child throws                 | Restarted after its backoff                                    |
| a transient child returns                | Done; not restarted                                            |
| a temporary child throws                 | Done; reported                                                 |
| restarts exceed the intensity            | All children stopped; `SupervisorEscalation` thrown            |
| a child stops beating                    | After `misses` intervals (past `grace`): stopped and restarted |
| the Mac sleeps                           | The liveness clock stops; no false hang                        |
| the supervisor's task is cancelled       | Children stopped newest first; `CancellationError`             |
| a child ignores cancellation on shutdown | Abandoned after `shutdownTimeout`; reported                    |
| a child ran long and then failed         | Its backoff starts over                                        |

## Events

`supervisor.child_started`, `supervisor.child_exited` (failed or not, with
the error), `supervisor.child_restarting` (delay), `supervisor.child_hung`,
`supervisor.child_abandoned`, `supervisor.escalated`, `supervisor.stopped`;
also published on `events` for a UI or a parent.

## Testing

Each row above, on the virtual clock: restart after backoff, transient and
temporary completion, escalation, both multi-child strategies, a silent child
detected and a beating one left alone, cancellation order and causes, and
abandonment. 300 repetitions are clean.

## Planned

- `Supervisor` as a ServiceLifecycle `Service` (trait), and as a child of a
  parent supervisor without ceremony.
- "Significant" children whose completion stops the supervisor (OTP's
  `auto_shutdown`).
- A crash-loop marker for the process level: unclean launches counted
  across restarts, with a safe mode after too many (design/15, planned).

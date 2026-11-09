# 25 · XPC services

An app that moves its riskiest work into a helper process — a language model
that can take gigabytes and crash, a clipboard read that can hang on another
app's lazy data — trades one failure for a set of new ones. The helper can be
killed by the app, by the system or by a crash at any moment. It can wedge
mid-request. It can still be exiting when the next request arrives, and that
request then reaches the process that is leaving. It can be a newer build than
the app talking to it, because the app was updated on disk while it ran. By
hand, each of those is a generation counter, a continuation resumed from two
callbacks, a flag, and a sleep before `exit`; and each is found by CI, under
load, by luck. `StoicXPC` is the one way to call a helper process: the
service's lifecycle is explicit, every wait is bounded, every loss is one event,
and what a lost call may have done is known.

## The ideal scenario

> The editor asks a language model that runs in another process. That process
> can be killed by the app, by the system or by a crash at any moment. It can
> wedge mid-generation, or still be exiting when the next request arrives. The
> app never hangs on it, never sends to a process that is exiting, and never
> talks to a build it was not built with. Every one of those decisions is made
> once, by the framework, and reported.

```swift
// The module both the app and the service import.
extension Backend {
    static let models = Backend.compute("models")           // one generation at a time
    static let modelsControl = Backend.system("models.control")
}
enum ModelsAPI {
    static let respond = XPCMethod<Generate, String, ModelsFailure>(
        Backend.models.notRepeatable("respond", length: .long), ifStuck: .endService(after: .seconds(20)))
    static let stats = XPCMethod<Empty, ModelsStats, Never>(Backend.modelsControl.readOnly("stats"))
}

// The app.
let models = XPCPeer(service: "com.example.app.models", build: Build.id)
let text = try await models.call(ModelsAPI.respond, Generate(prompt))
let stats = try await models.call(ModelsAPI.stats, Empty(), ifRunning: true)   // never starts the service

// The service's main.swift.
let host = XPCHost(build: Build.id)
host.handle(ModelsAPI.respond) { request, _ throws(ModelsFailure) in try await engine.respond(request) }
host.handle(ModelsAPI.stats) { _, _ in engine.stats }
host.run()
```

## Origin

- **Lodestar 0.54.21 and 0.54.22**, the pilot. `ModelsClient` and `ModelsService`
  are this contract written by hand: `Once`, `Request`, `Answer`, an `epoch`
  compared in callbacks, a table of early cancels capped at 64, an idle exit
  driven by a generation counter, `wedgedAfter` and `exit(1)` in the clipboard
  reader. Two of their bugs are rows below: `41f2de7` (a reload reached the
  process that was exiting) and `6a7ce61` (the loss of a run was handled twice,
  once from each callback).
- **Apple DTS (Quinn)**: XPC is the preferred inter-process mechanism on Apple
  platforms; Mach messaging directly is discouraged; sockets are for crossing
  namespaces or talking to non-Apple code; `Subprocess` is for one-shot tools;
  distributed actors ship no transport. One transport, then, and its names say
  so: `XPCPeer`, not `Peer`.
- **A spike on macOS 27.2**, measured, not read (the numbers are observations,
  and the contract depends on none of them being exact):
  - An `XPCSession` is dead for good once its service exits; `NSXPCConnection`
    relaunches the service behind the same object. One session is one run of
    the service, which is the model here.
  - A new session made right after asking the service to exit reaches the
    exiting process, which answers. The asked session's cancellation handler
    runs within a millisecond of the process's real exit: the "gone" signal.
  - `cancel()` does not fail a pending reply (the reply still arrives, seconds
    later): the caller needs its own deadline.
  - Releasing a session that was never cancelled traps the client.
  - launchd delays the next start of a service that lived under ten seconds
    until ten seconds after its launch, silently; one that lived longer
    restarts in 15–30 ms.
  - A handler that lets a reply-expecting message go without replying tears
    the client's session down while the process lives.
  - The listener's queue is shared by every session: a blocked handler stalls
    all of them. Replying later, from a task, frees it.
  - Messages and replies are delivered in order, both ways. The order of a
    reply's failure and the session's cancellation handler was stable at idle,
    and is documented nowhere.
  - Each client process has its own instance of a bundled service, gone within
    100 ms of the client exiting.
  - The app bundle replaced on disk while the old app runs: the services it
    starts next are the new build.
  - A sandboxed app cannot signal its own service (`EPERM`, even signal 0), and
    cancelling the service's only session does not end it. Only the service
    can end itself.
  - Swift 6 refuses every way of carrying an `XPCReceivedMessage` off the
    handler (it is not `Sendable`, and the handler's parameter is not
    `sending`): replying later needs one audited wrapper.
  - A `[Float]` of 480 000 samples costs 518 ms through XPC's `Codable`
    encoding and 0.37 ms as `Data`.

## Rules

1. **Bundled services only**, in `Contents/XPCServices`, found by name. launchd
   lets only the containing app connect, so no peer requirement is needed. A
   Mach service (a launch agent, `SMAppService`) waits for a use case.
2. **One `XPCPeer` per service per process.** The service is one process per
   client process, and the peer is its single owner: two peers would share a
   process each thinks it owns. A second declaration is reported at error level.
3. **The build is part of the handshake.** Both sides are given the same
   compiled-in identifier (`Build.id`, from a module both import); a different
   one is refused, never decoded.
4. **Bulk data crosses as `Data`.** XPC's `Codable` encoding of a large array of
   numbers is three orders of magnitude slower; a `Data` field goes out of line.

## API

```swift
public struct XPCMethod<Request: Codable & Sendable, Reply: Codable & Sendable, Failure: Error & Codable & Sendable>: Sendable {
    public init(_ operation: Backend.Operation, ifStuck: XPCStuck = .wait)
    public let operation: Backend.Operation
    public let ifStuck: XPCStuck
    public var name: String                         // "<backend>.<operation>": the wire name
}
public enum XPCStuck: Sendable, Hashable { case wait, endService(after: Duration) }
public struct XPCEmpty: Codable, Sendable, Hashable { public init() }

public final class XPCPeer: Sendable {
    public convenience init(service: String, build: String, policy: XPCPeerPolicy = .standard)
    public convenience init(service: String, build: String, policy: XPCPeerPolicy = .standard, transport: any XPCTransport)
    public func call<Request, Reply, Failure>(_ method: XPCMethod<Request, Reply, Failure>, _ request: Request,
                                              ifRunning: Bool = false, idempotencyKey: IdempotencyKey? = nil)
        async throws(OperationError<XPCCallError<Failure>>) -> Reply
    public var run: XPCRun? { get }                 // the live run, if any
    public func end(reason: String) async -> XPCEndResult
    public func shutdown()
}
public struct XPCPeerPolicy: Sendable, Hashable { handshakeTimeout, endGrace, killGrace; static let standard }
public struct XPCRun: Sendable, Hashable { number, pid, build }
public enum XPCEndResult: Sendable, Hashable { case notRunning, exited, killed, wedged, inProgress }
public enum XPCCallError<Failure>: Error, Retryable {
    case failed(Failure)                  // the handler's own answer
    case lost(afterSending: Bool)         // the run ended on its own: a crash, an idle exit, the watchdog
    case ended(afterSending: Bool)        // the app ended the run: end, a stuck request, shutdown (not counted by the breaker)
    case cancelled(afterSending: Bool)    // the caller left, or an attempt timed out
    case notRunning                       // `ifRunning`, and no live run
    case buildMismatch(expected: String, found: String)
    case unavailable(XPCUnavailable)      // .noSession, .noHandshake, .wedged, .shutDown: nothing sent
    case refused(String)                  // an unknown method, a request that does not decode: not run
    case protocolViolation(String)        // a reply that does not decode: it may have run
}

public final class XPCHost: Sendable {
    public init(build: String, policy: XPCHostPolicy = .standard)
    public func handle<Request, Reply, Failure>(_ method: XPCMethod<Request, Reply, Failure>,
        _ handler: @escaping @Sendable (Request, XPCRequestContext) async throws(Failure) -> Reply)
    public func hold(_ reason: String)    // keeps an idle service alive: a loaded model
    public func release(_ reason: String)
    public func run(service: String? = nil) -> Never
}
public struct XPCHostPolicy: Sendable { idleExit: Duration?, watchdogGrace, exit: (@Sendable (Int32) -> Never)?; static let standard }
public struct XPCRequestContext: Sendable { id, method, idempotencyKey, budget }

public protocol XPCTransport: Sendable { … }     // the seam: XPCSession, or the simulation
public protocol XPCConnection: Sendable { … }
public final class XPCSimulatedService: XPCTransport {
    init(firstPID:, exitLag:, permitsKill:, makeHost:)
    crash(sessionsEndFirst:), dropSessions(), exitLag, launchDelay, permitsKill, refusesConnections, runs, sessions, exits, pid, host
}
```

## Semantics

**A run.** The peer's state is one of: no run; _starting_ (a session is open and
the handshake in flight); _running_; _ending_ (the run was asked to exit and the
peer waits for it to be gone); _wedged_ (it would not exit); _mismatched_; _shut
down_. A run begins with a session and a handshake — the client's build, and
the service's build and pid in reply — and ends with the first sign that its
process is gone: the session's cancellation handler, or a reply that failed
because the connection did. Whichever comes first ends the run once; the other
is ignored. Every call still waiting on that run fails at once with
`.lost(afterSending: true)`, or `.ended(afterSending: true)` when the app
decided the end. A peer opens a new session only when the run before it is
gone, and sends nothing on a run it has begun to end, so a request never
reaches a process the peer knows is leaving.

**Starting.** The first call with no run starts one; calls that arrive while it
starts wait for the same handshake (one session, one hello). The handshake runs
on the peer's behalf, not the first caller's: it is bounded by
`handshakeTimeout` (20 s: launchd's relaunch delay is ten), not by the deadline
of whoever happened to start it, and each waiter is bounded by its own. The
peer's own tasks (the handshake, an end, a stuck watch) inherit nothing from
the caller that started them but the context the peer was made in
(`Task.owned`, package-level in the kernel). A service that is not in the
bundle fails `.unavailable(.noSession)`. A run whose build is
not the peer's is refused: the session is ended, `xpc.build_mismatch` is
reported at error level, and every call fails `.buildMismatch` until the app
restarts. A run that answers "exiting" is the old process lingering: the peer
treats it as ending and waits for it to be gone; the "exiting" answer carries
the process's pid, so a process that lingers can be killed. A run of another
build is asked to exit, so it does not live on, unused, beside the app.

**A call** runs through the method's operation's `perform` (design/22): the
deadline, retries by the declared repeat safety, the breaker, admission by the
backend's capacity. Each attempt takes the live run (starting one if none),
sends the request with the time left before the deadline, and waits for the
reply or its own cancellation, whichever is first — `cancel` does not fail a
pending reply, so the attempt does not wait for XPC to. A failure before the
request was sent is `neverReachedBackend` (so even a `.notRepeatable` call is
repeated); a run lost after the send is `.lost(afterSending: true)`, outcome
`.unknown`, repeated only when the declaration allows. A request the service
refused without running it (no handler, a request that does not decode) is
`.refused`, `.notExecuted`, and not repeated. The handler's own
`Failure` arrives typed, as the backend's permanent answer (`.executed`), and is
retried only if the failure is `Retryable` and says so. A `.keyed` method's
attempts send `attempt.idempotencyKey`; the handler reads it from its context.
`ifRunning: true` fails `.notRunning` at once, starting nothing, unless a run is
live: a status read that must not launch the model.

**Cancellation.** A caller cancelled (or an attempt timed out) after its request
was sent returns at once; the peer then sends a cancel for that request on the
same session, and the service cancels the handler's task. Delivery is in order,
so a cancel never arrives before its request, and the service needs no table of
early cancels: a cancel for an id it does not hold is reported at debug level
and dropped. The handler's reply, when it comes, is dropped (`xpc.late_reply`).

**Stuck.** `ifStuck: .endService(after: d)` declares that a request still
unanswered `d` after its caller left means the service is wedged. The verdict is
measured on the liveness clock, so a Mac asleep is not a wedge. The peer then
ends the run (below), and reports `xpc.call_stuck`. An end the app decides is
not the backend failing: calls on that run fail `.ended`, which the breaker
ignores as it ignores a cancellation (`CallerDecidedFailure`, package-level in
the kernel).

**Ending.** `end(reason:)` on a run that is starting waits for its handshake
first (the calls waiting on it are not failed for the end). It then moves the
run to _ending_, asks the service to exit,
and waits up to `endGrace` (2 s) for it to be gone. Calls made meanwhile wait
for it too, within their own deadlines, and then reach a new run. A run still
there after the grace is killed — `SIGKILL`, to the pid from its handshake, only
after checking that the process at that pid is an executable in this app's
`Contents/XPCServices` — and given `killGrace` (1 s). A sandboxed app may not
signal its service; then, or if the kill does not end it, the run is _wedged_:
`xpc.run_wedged` at error level, and every call fails `.unavailable` at once
until the process goes (the service's own watchdog, below, is what ends it). A
peer released without `shutdown()` cancels its session as it goes (releasing a
live one traps the app), which ends the run.

**The relaunch delay.** When a run that lived under ten seconds is gone, the next
start is reported as `xpc.relaunch_throttled` with the expected wait. Nothing is
failed for it: the deadline still decides.

**The host** listens on its bundle's service name, one state per process. Each
message is decoded on the listener's queue — cheap for small values and for
`Data`, which arrives out of line; a large array of numbers is not, which is
rule 4 — and every handler runs in its own task, so a slow handler holds no
other session up. Each request is answered
exactly once — the reply, the handler's failure, "cancelled", or a refusal — and
a message is never let go unanswered (that would end the client's session). A
request carries its budget: the handler runs under that deadline, cooperatively.
**The watchdog** is a timer on its own queue, off the cooperative pool and off
the listener's queue, on the liveness clock: a handler still running
`watchdogGrace` (10 s) past its budget has ignored cancellation, and the process
exits (`xpc.watchdog_exit`, error level) so the next call gets a fresh one. That
is the only way a wedged service ends in a sandbox.

**Idle exit.** With `idleExit` set, a service with nothing in flight and nothing
held (`hold`/`release`, by reason: a loaded model) for that long exits
(`xpc.idle_exit`). Holding puts the idle period off until the release, from
which it starts again. The decision is made under the same lock that admits
requests: from that moment every request is refused "exiting" — never executed
— so the client resends it to the next run.

**Exit** happens on a queue no request ever holds, through `policy.exit`
(`_exit` by default: a model's destructors need not run on the way out), after
a drain of a quarter of a second in which requests are still answered
"exiting": one already on its way when the decision was made is refused, not
lost with the process and left `.unknown`. A client session that ends cancels
that session's handlers.

## Failure modes

| What happens if…                                                 | Then                                                                                     |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| the service is not in the app's bundle                           | `.unavailable`, not repeated, `neverReachedBackend`                                      |
| the run is lost before a request is sent                         | the request is sent to a new run: `neverReachedBackend`                                  |
| the run is lost after an idempotent request is sent              | the request is resent once, to a new run                                                 |
| the run is lost after a not-repeatable request is sent           | it fails `.lost(afterSending: true)`, outcome `.unknown`, not resent                     |
| the reply's failure and the session's end arrive in either order | one loss: one `xpc.run_lost`, every waiting call failed once                             |
| a call is made while an ended run is still exiting               | it waits for the run to be gone, then reaches a new run                                  |
| a request reaches a run that has decided to exit                 | it is refused, never executed, and resent to the next run                                |
| a new session reaches a process that is exiting | its handshake is answered "exiting", with its pid; the peer waits for it to go, then starts the next |
| many calls arrive while no run is live                           | one session, one handshake                                                               |
| the caller's deadline is shorter than the handshake              | that caller fails at its deadline; the handshake goes on for the others                  |
| the caller is cancelled before its request is sent               | nothing is sent                                                                          |
| the caller is cancelled after its request is sent                | it returns at once; the service cancels the handler                                      |
| a reply arrives after its caller left                            | it is dropped and reported                                                               |
| a cancel arrives for a request the service no longer holds       | it is dropped and reported at debug level                                                |
| a cancelled request stays unanswered past `ifStuck` | the run is ended and `xpc.call_stuck` reported |
| the app ends a run with other calls in flight | they fail `.ended`, outcome `.unknown`; the breaker does not count them |
| the app ends a run while it is starting | the end waits for the handshake, then asks the process to exit; waiting calls are not failed for it |
| the run does not exit when asked                                 | it is killed, after the pid is checked to be this app's service                          |
| the run cannot be killed (a sandbox) and does not exit | `xpc.run_wedged`; calls fail `.unavailable(.wedged)` at once until it goes, then a new run starts |
| the service is another build | `xpc.build_mismatch`; it is asked to exit; every call fails `.buildMismatch`, not repeated |
| the client is another build                                      | the service refuses its requests                                                         |
| a handler throws its declared failure                            | the caller gets it, typed: `.failed`, outcome `.executed`, not repeated                  |
| a handler ignores cancellation past its budget and the grace     | the service exits (`xpc.watchdog_exit`); the client sees the run lost                    |
| the service is idle and holds nothing for the idle period        | it exits (`xpc.idle_exit`); the next call starts a new run                               |
| a request arrives during the idle period                         | the idle exit is put off                                                                 |
| the service holds something                                      | it does not idle-exit until released                                                     |
| the service is held outside a request | the idle exit waits for the release, and the idle period starts again there |
| a request names a method the service does not handle | `.refused`, not run, not repeated |
| a request does not decode as the method's type | `.refused`, not run, not repeated |
| a client's session ends with handlers running                    | those handlers are cancelled                                                             |
| `ifRunning` is asked with no live run                            | `.notRunning` at once; nothing is started                                                |
| the run before lived under ten seconds                           | the next start is reported as `xpc.relaunch_throttled`                                   |
| a second peer is made for the same service                       | `xpc.peer_duplicate` at error level                                                      |
| the peer is shut down with calls waiting | sent ones fail `.ended`, outcome `.unknown`; later calls `.unavailable(.shutDown)`; the session is cancelled |

## Events

All in `EventCatalog`, labelled with the service name (client) or the method
(host). They carry pids, builds, run numbers, method names, durations and
counts; never a request or a reply.

| Event                    | Level   | Meaning                                                              |
| ------------------------ | ------- | -------------------------------------------------------------------- |
| `xpc.run_started`        | info    | a run answered the handshake: run, pid, build, how long it took      |
| `xpc.run_lost` | warning | a run ended without being asked: run, pid, lifetime, calls in flight (a notice with none) |
| `xpc.run_ended`          | info    | a run ended as asked: run, reason, how long the exit took            |
| `xpc.run_wedged`         | error   | a run would not exit: calls are refused until it does                |
| `xpc.end_escalated`      | warning | a run outlived its grace; whether the kill was permitted             |
| `xpc.build_mismatch`     | error   | the other side is another build: expected, found                     |
| `xpc.relaunch_throttled` | notice  | the run before lived under ten seconds; the expected wait            |
| `xpc.call_stuck`         | warning | a cancelled request stayed unanswered past `ifStuck`                 |
| `xpc.late_reply`         | debug   | a reply arrived after its caller left                                |
| `xpc.handshake_failed`   | warning | a run could not be started: why                                      |
| `xpc.peer_duplicate`     | error   | a second peer for one service                                        |
| `xpc.host_started`       | info    | the service listens: build, pid                                      |
| `xpc.request_refused`    | notice  | unknown method, undecodable, exiting, or another build               |
| `xpc.cancel_unknown`     | debug   | a cancel for a request no longer held                                |
| `xpc.host_exiting`       | info    | the service exits as asked                                           |
| `xpc.idle_exit`          | info    | the service exits, idle                                              |
| `xpc.watchdog_exit`      | error   | a handler ignored cancellation; the service exits                    |

## Testing

- Every row above on `XPCSimulatedService`: the real `XPCHost` and its handlers
  in-process, a run that can crash (replies or end first, or a fault point
  between), linger while exiting (`exitLag`), refuse a kill, or wedge; on a
  `TestClock`.
- `scripts/xpc-integration.sh`: the same peer and host as real processes, in an
  app bundle assembled from SwiftPM's products and signed ad hoc — the
  handshake, a crash, a requested end, the watchdog, a cancelled call. It
  signals nothing but the service it started, through the same pid check.

## Review

Reviewed before release by two independent agents (Fable, Sonnet 5.5), against
the code and this contract. What they found, and what changed:

- The idle exit's decision and admission were two locks apart: a request
  admitted between them ran in a process about to exit. Now one lock decides,
  and admission checks it.
- `hold` outside a request left the idle period's start stale: the timer
  spun, and the release exited at once. Holding now clears it.
- `end(reason:)` during a handshake failed the waiting calls as if the peer
  were shut down, and could leave the process running. It now waits for the
  handshake.
- A request sent before `shutdown()` was reported as never sent, so a
  `.notRepeatable` caller could repeat it. Calls on a run the app ended fail
  `.ended(afterSending:)`, which also gives the breaker what it needs to ignore
  them: the claim that an app-decided end is not counted was not implemented.
- The real host exited at once, so a request already on its way was lost
  `.unknown`; it now drains for a quarter of a second, refusing.
- A call could be sent behind the peer's own `.end`; a run being ended now
  takes no requests. A lost reply ends the run at once and is counted in
  flight. A dropped peer leaked its session; a wrong-build process was left
  running; refusals that never ran were reported `.executed`; the duplicate
  registry forgot a surviving peer. All fixed, with tests.
- The simulation's handlers inherited the client's deadline and retry
  attempt; host and simulation tasks are now `Task.owned`.

Kept as they are, on purpose: `hold`/`release` by reason (a model's handle is
a reason), the pid reported by the service (the session's audit token is not
public API), and the lifecycle as a hand-written enum rather than
`StateMachine` (its states carry the run, which a `StateMachine` state cannot).

## Not built

- `PeerResident`: state kept in the service (a loaded model) and loaded again
  on demand when its run is lost. It waits for the Lodestar pilot to give it
  its shape.
- Streaming replies (a generation's tokens as they come), which the ideal
  scenario will want.
- Methods typed by their service (`XPCMethod<Service, …>`), so a call to
  another service's method does not compile. The wire name and the build
  already catch it at run time.
- Mach services and `SMAppService` agents, with peer requirements.
- Large payloads out of band (shared memory, file descriptors, `IOSurface`).
- iOS: the system's session and listener initializers are unavailable there;
  the library compiles to nothing on platforms other than macOS.

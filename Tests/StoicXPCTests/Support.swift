#if os(macOS)
import Foundation
import Stoic
@testable import StoicXPC
import StoicTesting
import Synchronization
import Testing

/// Polls `condition` until it holds, or fails the test after `timeout` of
/// real time. For work on other tasks that needs no help from the test.
func eventually(
    timeout: Duration = .seconds(10),
    _ message: @autoclosure () -> String = "the condition never became true",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= limit {
            Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
            return
        }
        do {
            try await clock.sleep(for: .milliseconds(1))
        } catch {
            return
        }
    }
}

extension RecordingInstrumentation {
    func count(_ name: EventName) -> Int { events(named: name).count }
}

extension Event {
    func text(_ key: String) -> String? {
        if case .string(let value)? = self[key] { value } else { nil }
    }

    func flag(_ key: String) -> Bool? {
        if case .bool(let value)? = self[key] { value } else { nil }
    }
}

struct Declined: Error, Codable, Sendable, Equatable {
    var why: String
}

/// The methods the tests' service offers. The backend is a `system` one, as
/// an XPC service's is.
enum Probe {
    static let backend = Backend.system("xpc.tests")

    /// Answers at once.
    static let echo = XPCMethod<String, String, Never>(backend.readOnly("echo"))
    /// Waits for the control's pause on its first call, then answers.
    static let store = XPCMethod<String, String, Never>(backend.idempotent("store"))
    static let charge = XPCMethod<String, String, Never>(backend.notRepeatable("charge"))
    /// Throws its declared failure.
    static let decline = XPCMethod<String, String, Declined>(backend.readOnly("decline"))
    /// Waits until cancelled, cooperatively.
    static let hang = XPCMethod<XPCEmpty, XPCEmpty, Never>(backend.readOnly("hang", length: .long))
    /// Waits for the control's pause, ignoring cancellation.
    static let slow = XPCMethod<XPCEmpty, String, Never>(backend.readOnly("slow", length: .long))
    /// Ignores cancellation until the pause opens; ends the service when stuck.
    static let wedge = XPCMethod<XPCEmpty, XPCEmpty, Never>(
        backend.readOnly("wedge", length: .long), ifStuck: .endService(after: .seconds(1)))
    /// Answers with its idempotency key.
    static let keyed = XPCMethod<String, String, Never>(backend.keyed("keyed"))
    /// Holds and releases the service.
    static let load = XPCMethod<String, String, Never>(backend.idempotent("load"))
    static let unload = XPCMethod<String, String, Never>(backend.idempotent("unload"))
    /// Not handled by the service.
    static let missing = XPCMethod<XPCEmpty, XPCEmpty, Never>(backend.readOnly("missing"))
    /// The client's idea of a method the service declares with a String request.
    static let mistyped = XPCMethod<Int, String, Never>(backend.readOnly("mistyped"))
    static let mistypedHost = XPCMethod<String, String, Never>(backend.readOnly("mistyped"))
}

/// A flag set once, read from anywhere.
final class Flag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool {
        state.withLock { $0 }
    }

    func set() {
        state.withLock { $0 = true }
    }
}

/// What the tests' handlers saw and wait for.
final class Control: Sendable {
    private let seen = Mutex<[String: Int]>([:])
    let pause = TestGate()

    func note(_ event: String) {
        seen.withLock { $0[event, default: 0] += 1 }
    }

    func count(_ event: String) -> Int {
        seen.withLock { $0[event] ?? 0 }
    }

    /// Waits until the task is cancelled.
    static func untilCancelled() async {
        let gate = TestGate()
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.open()
        }
    }
}

/// A host with every probe method, as a service's main would make it.
func makeHost(_ control: Control, build: String, policy: XPCHostPolicy) -> XPCHost {
    let host = XPCHost(build: build, policy: policy)
    host.handle(Probe.echo) { text, _ in
        control.note("echo")
        return text
    }
    host.handle(Probe.store) { text, _ in
        control.note("store")
        if control.count("store") == 1 { await control.pause.wait() }
        return text
    }
    host.handle(Probe.charge) { text, _ in
        control.note("charge")
        await control.pause.wait()
        return text
    }
    host.handle(Probe.decline) { text, _ throws(Declined) in
        control.note("decline")
        throw Declined(why: text)
    }
    host.handle(Probe.hang) { _, _ in
        control.note("hang")
        await Control.untilCancelled()
        control.note("hang.cancelled")
        return XPCEmpty()
    }
    host.handle(Probe.slow) { _, _ in
        control.note("slow")
        await control.pause.wait()
        return "late"
    }
    host.handle(Probe.wedge) { _, _ in
        control.note("wedge")
        await control.pause.wait()
        return XPCEmpty()
    }
    host.handle(Probe.keyed) { _, context in
        context.idempotencyKey?.rawValue ?? "no key"
    }
    host.handle(Probe.load) { [weak host] model, _ in
        host?.hold(model)
        return model
    }
    host.handle(Probe.unload) { [weak host] model, _ in
        host?.release(model)
        return model
    }
    host.handle(Probe.mistypedHost) { text, _ in text }
    return host
}

/// A peer over a simulated service, on a test clock.
struct Rig {
    let clock: TestClock
    let events: RecordingInstrumentation
    let control: Control
    let service: XPCSimulatedService
    let peer: XPCPeer

    /// Starts a call of `method` in a task of its own.
    func start<Request, Reply, Failure>(
        _ method: XPCMethod<Request, Reply, Failure>, _ request: Request, ifRunning: Bool = false
    ) -> Task<Reply, any Error> {
        let peer = peer
        return Task { try await peer.call(method, request, ifRunning: ifRunning) }
    }

    /// The call's failure, or `nil` if it succeeded.
    func failure<Reply, Failure>(of task: Task<Reply, any Error>, _: Failure.Type) async -> OperationError<XPCCallError<Failure>>? {
        switch await task.result {
        case .success: nil
        case .failure(let error): error as? OperationError<XPCCallError<Failure>>
        }
    }

    /// The task's value, moving the clock a second at a time until it has
    /// one: for a call whose path (a retry or not) a race decides.
    func value<Reply>(of task: Task<Reply, any Error>, limit: Int = 30) async throws -> Reply {
        let done = Flag()
        let watcher = Task {
            _ = await task.result
            done.set()
        }
        let real = ContinuousClock()
        for _ in 0..<limit where !done.isSet {
            await clock.advance(by: .seconds(1))
            // A moment of real time for what the advance woke to settle.
            let until = real.now.advanced(by: .milliseconds(50))
            while !done.isSet, real.now < until {
                do {
                    try await real.sleep(for: .milliseconds(1))
                } catch {
                    break
                }
            }
        }
        await watcher.value
        return try await task.value
    }

    /// Waits until `count` attempts have failed, then moves the clock past
    /// the backoff that follows.
    func passBackoff(after count: Int) async {
        await eventually("attempt \(count) never failed") { events.count("retry.attempt_failed") >= count }
        await advance(by: .seconds(1))
    }

    /// Moves the clock by `duration`, once something is asleep that is due
    /// within it, waiting up to a fifth of a second of real time for that:
    /// work woken by the test's last step (a grace, a backoff, a watcher)
    /// goes to sleep on a task of its own, and a clock moved before it does
    /// leaves it asleep past the advance.
    func advance(by duration: Duration) async {
        let real = ContinuousClock()
        let until = real.now.advanced(by: .milliseconds(200))
        while real.now < until, !clock.pendingDeadlines.contains(where: { clock.now.duration(to: $0) <= duration }) {
            do {
                try await real.sleep(for: .milliseconds(1))
            } catch {
                break
            }
        }
        await clock.advance(by: duration)
    }
}

/// Runs `body` with a peer of build `build` over a simulated service whose
/// hosts are build `hostBuild`.
func withRig(
    build: String = "1",
    hostBuild: String = "1",
    policy: XPCPeerPolicy = XPCPeerPolicy(endGrace: .seconds(2), killGrace: .seconds(1)),
    host hostPolicy: XPCHostPolicy = XPCHostPolicy(watchdogGrace: .seconds(1)),
    exitLag: Duration = .zero,
    permitsKill: Bool = true,
    _ body: (Rig) async throws -> Void
) async throws {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    try await withTestAmbient(clock: clock, seed: 7, events: events) { () async throws in
        let control = Control()
        let service = XPCSimulatedService(exitLag: exitLag, permitsKill: permitsKill) {
            makeHost(control, build: hostBuild, policy: hostPolicy)
        }
        let peer = XPCPeer(service: "xpc.tests", build: build, policy: policy, transport: service)
        defer {
            peer.shutdown()
            control.pause.open()
        }
        try await body(Rig(clock: clock, events: events, control: control, service: service, peer: peer))
    }
}
#endif

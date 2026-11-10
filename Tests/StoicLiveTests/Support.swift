import Observation
import Stoic
@testable import StoicLive
import StoicTesting
import Synchronization
import Testing

enum API {
    static let backend = Backend.remote("test.api", capacity: 8)
    static let detail = backend.readOnly("events.detail")
    static let roster = backend.readOnly("events.roster")
    static let minors = backend.readOnly("profiles.minors")
    static let roles = backend.readOnly("permissions.mine")
    static let feed = backend.readOnly("events.feed")
    static let signUp = backend.keyed("commitments.create")
    static let remove = backend.notRepeatable("events.delete")
    static let rename = backend.idempotent("events.rename")
}

/// A permanent failure, the backend's answer.
struct Refused: Error, Retryable {
    var retryDecision: RetryDecision { .stop }
}

/// A failure that proves nothing reached the backend.
struct Unreached: Error, Retryable {
    var retryDecision: RetryDecision { .stop }
    var neverReachedBackend: Bool { true }
}

/// A transient failure after the request was sent, retried at once: an
/// unknown outcome once the attempts run out.
struct Lost: Error, Retryable {
    var retryDecision: RetryDecision { .retryAfter(.zero) }
}

/// What a scripted backend does on each call, in order; the last step repeats.
enum Step<Value: Sendable>: Sendable {
    case value(Value)
    case failure(any Error & Sendable)
    /// Waits for the gate, ignoring cancellation, then answers.
    case gated(TestGate, Value)
    /// Sleeps on the ambient clock until cancelled.
    case hang
}

/// A backend a test scripts: each call takes the next step, and every call
/// is recorded with its urgency and key.
final class Script<Value: Sendable>: Sendable {
    enum Counter: Sendable { case calls, cancelled, finished }

    private struct State {
        var steps: [Step<Value>]
        var urgencies: [Urgency] = []
        var keys: [IdempotencyKey] = []
        var cancelled = 0
        var finished = 0
        var waiters: [(counter: Counter, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func value(of counter: Counter) -> Int {
            switch counter {
            case .calls: urgencies.count
            case .cancelled: cancelled
            case .finished: finished
            }
        }

        /// The waiters whose count has been reached, taken out.
        mutating func ready() -> [CheckedContinuation<Void, Never>] {
            let counts = (calls: urgencies.count, cancelled: cancelled, finished: finished)
            func reached(_ counter: Counter, _ count: Int) -> Bool {
                switch counter {
                case .calls: counts.calls >= count
                case .cancelled: counts.cancelled >= count
                case .finished: counts.finished >= count
                }
            }
            let ready = waiters.filter { reached($0.counter, $0.count) }.map(\.continuation)
            waiters.removeAll { reached($0.counter, $0.count) }
            return ready
        }
    }

    private let state: Mutex<State>

    init(_ steps: Step<Value>...) {
        state = Mutex(State(steps: steps))
    }

    var calls: Int { state.withLock { $0.urgencies.count } }
    var urgencies: [Urgency] { state.withLock { $0.urgencies } }
    var keys: [IdempotencyKey] { state.withLock { $0.keys } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    var finished: Int { state.withLock { $0.finished } }

    func then(_ step: Step<Value>) {
        state.withLock { $0.steps.append(step) }
    }

    /// Returns once `counter` has reached `count`: no polling, no real time.
    func wait(_ counter: Counter, _ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.value(of: counter) >= count { return true }
                state.waiters.append((counter, count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    private func bump(_ change: (inout State) -> Void) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            change(&state)
            return state.ready()
        }
        for waiter in ready { waiter.resume() }
    }

    func call(_ attempt: Attempt?, keyed: Bool = false) async throws -> Value {
        let urgency = Urgency.current
        let step = state.withLock { state -> Step<Value> in
            if keyed, let attempt { state.keys.append(attempt.idempotencyKey) }
            return state.steps.count > 1 ? state.steps.removeFirst() : state.steps[0]
        }
        bump { $0.urgencies.append(urgency) }
        defer { bump { $0.finished += 1 } }
        switch step {
        case .value(let value):
            return value
        case .failure(let error):
            throw error
        case .gated(let gate, let value):
            await gate.wait()
            return value
        case .hang:
            do {
                try await Ambient.sleep(for: .seconds(1_000_000))
            } catch {
                bump { $0.cancelled += 1 }
                throw error
            }
            throw Refused()
        }
    }
}

/// Waits until `predicate`, observed: no real-time wait, no polling.
@MainActor
func until(_ predicate: @escaping @MainActor @Sendable () -> Bool) async {
    for await holds in Observations({ predicate() }) where holds { return }
}

/// Events as a test reads them: every one recorded, and a wait for a count of
/// one name, so a test waits on the event it needs.
final class AwaitedEvents: Instrumentation, Sendable {
    private struct State {
        var events: [Event] = []
        var waiters: [(name: EventName, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())
    private let next: any Instrumentation

    init(forwardingTo next: any Instrumentation) {
        self.next = next
    }

    func record(_ event: Event) {
        next.record(event)
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.events.append(event)
            var ready: [CheckedContinuation<Void, Never>] = []
            let events = state.events
            state.waiters.removeAll { waiter in
                let reached = events.count { $0.name == waiter.name } >= waiter.count
                if reached { ready.append(waiter.continuation) }
                return reached
            }
            return ready
        }
        for waiter in ready { waiter.resume() }
    }

    func events(named name: EventName) -> [Event] {
        state.withLock { $0.events.filter { $0.name == name } }
    }

    func count(_ name: EventName) -> Int { events(named: name).count }

    func wait(for name: EventName, count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.events.count(where: { $0.name == name }) >= count { return true }
                state.waiters.append((name, count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// `body` on a test clock, with a fresh ambient, on the main actor.
@MainActor
func onLiveTime<R>(_ body: @MainActor (TestClock, AwaitedEvents) async throws -> R) async throws -> R {
    let clock = TestClock()
    return try await withTestAmbient(clock: clock) { () async throws -> R in
        let events = AwaitedEvents(forwardingTo: Ambient.current.instrumentation)
        return try await withAmbient({ $0.instrumentation = events }) { () async throws -> R in
            try await body(clock, events)
        }
    }
}

extension Live.Phase {
    var value: Value? {
        switch self {
        case .pending: nil
        case .fresh(let value), .stale(let value, _): value
        case .failed(_, let last): last
        }
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    var failure: Presented? {
        if case .failed(let presented, _) = self { return presented }
        return nil
    }
}


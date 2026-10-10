import Stoic
internal import Synchronization

/// One scripted behaviour for an injected call.
public enum Fault<Failure: Error>: Sendable {
    /// Call through to the real operation.
    case succeed
    /// Throw this error instead of calling through.
    case fail(Failure)
    /// Wait this long on the ambient clock, then call through.
    case latency(Duration)
    /// Wait until cancelled — the dependency that never answers.
    case hang
    /// Wait until `gate` opens, ignoring cancellation — the CoreAudio call on
    /// a wedged queue, the synchronous call into a hung process.
    case hangIgnoringCancellation(TestGate)
}

/// Puts a script of faults between a caller and a real operation.
///
///     let api = FaultInjector<APIError>([.fail(.offline), .latency(.seconds(2)), .succeed])
///     let user = try await retry(.exponential(base: .seconds(1)).attempts(5)) { _ in
///         try await api.run { try await realAPI.fetchUser(42) }
///     }
///     #expect(api.callCount == 3)
///
/// Each call takes the next fault in the script; once the script is used up,
/// calls take `then` (by default, `.succeed`). The injector counts calls, so a
/// test can assert exactly how many attempts a policy made.
public final class FaultInjector<Failure: Error>: Sendable {
    private let state: Mutex<(script: [Fault<Failure>], calls: Int)>
    private let fallback: Fault<Failure>

    public init(_ script: [Fault<Failure>], then fallback: Fault<Failure> = .succeed) {
        state = Mutex((script, 0))
        self.fallback = fallback
    }

    /// Fails `count` times with `error`, then succeeds.
    public static func failing(_ count: Int, with error: Failure) -> FaultInjector {
        FaultInjector(Array(repeating: .fail(error), count: count))
    }

    /// How many times the injector has been called.
    public var callCount: Int {
        state.withLock { $0.calls }
    }

    /// Runs the next fault, calling through to `operation` when the fault allows.
    public func run<R>(_ operation: nonisolated(nonsending) () async throws(Failure) -> R) async throws(Failure) -> R {
        let fault = state.withLock { state -> Fault<Failure> in
            state.calls += 1
            return state.script.isEmpty ? fallback : state.script.removeFirst()
        }
        switch fault {
        case .succeed:
            break
        case .fail(let failure):
            throw failure
        case .latency(let duration):
            // stoic:allow(discarded-try): only cancellation can end the sleep early; the call proceeds and `operation` observes the cancellation itself
            try? await Ambient.sleep(for: duration)
        case .hang:
            while !Task.isCancelled {
                // stoic:allow(discarded-try): only cancellation can end the sleep early, and the loop condition tests for exactly that
                try? await Ambient.sleep(for: .seconds(3600))
            }
        case .hangIgnoringCancellation(let gate):
            await gate.wait()
        }
        return try await operation()
    }
}

/// A one-shot gate that ignores cancellation: for modelling work that
/// cannot be interrupted, and for sequencing steps in a test.
public final class TestGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    public init() {}

    /// Whether the gate has opened.
    public var isOpen: Bool {
        state.withLock { $0.open }
    }

    /// Waits until the gate opens. Not cancellation-aware, on purpose.
    public func wait() async {
        await withCheckedContinuation { continuation in
            let openNow = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if openNow { continuation.resume() }
        }
    }

    /// Opens the gate, releasing every waiter now and in the future.
    public func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

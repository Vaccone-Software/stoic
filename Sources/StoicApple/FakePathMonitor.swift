internal import Synchronization

/// A ``PathMonitor`` the test drives.
///
///     let monitor = FakePathMonitor(.satisfied)
///     let task = Task { try await monitor.waitUntilReachable(until: deadline) }
///     monitor.send(.unsatisfied)
///
/// Like the real one, each subscription starts with the current path. Every
/// path sent reaches every subscription in order (none are dropped), so a
/// test can script a flap exactly. Subscribe before sending: a subscription
/// that starts late sees only the current path. ``waitForSubscribers(_:)``
/// says when the code under test has.
public final class FakePathMonitor: PathMonitor {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var current: NetworkPath
        var subscribers: [UInt64: AsyncStream<NetworkPath>.Continuation] = [:]
        var nextID: UInt64 = 0
        var totalSubscriptions = 0
        var waiters: [Waiter] = []

        /// Waiters whose condition now holds: `count` open subscriptions, or
        /// none for an idle waiter (count 0).
        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let open = subscribers.count
            let (ready, rest) = waiters.partitioned { $0.count == 0 ? open == 0 : open >= $0.count }
            waiters = rest
            return ready.map(\.continuation)
        }
    }

    private let state: Mutex<State>

    public init(_ initial: NetworkPath = .satisfied) {
        state = Mutex(State(current: initial))
    }

    /// The path a new subscription starts with.
    public var current: NetworkPath { state.withLock { $0.current } }

    /// Subscriptions that are open now.
    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// Subscriptions opened since creation, finished or not.
    public var totalSubscriptions: Int { state.withLock { $0.totalSubscriptions } }

    public func updates() -> AsyncStream<NetworkPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let (id, ready) = state.withLock { state -> (UInt64, [CheckedContinuation<Void, Never>]) in
                defer { state.nextID += 1 }
                let id = state.nextID
                state.subscribers[id] = continuation
                state.totalSubscriptions += 1
                continuation.yield(state.current)
                return (id, state.takeSatisfiedWaiters())
            }
            ready.forEach { $0.resume() }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    state.subscribers.removeValue(forKey: id)
                    return state.takeSatisfiedWaiters()
                }
                ready.forEach { $0.resume() }
            }
        }
    }

    /// Makes `path` the current one and delivers it to every subscription.
    public func send(_ path: NetworkPath) {
        // Yielded outside the lock: a stream holds its own lock while it runs
        // its termination handler, which takes this one.
        let subscribers = state.withLock { state in
            state.current = path
            return Array(state.subscribers.values)
        }
        subscribers.forEach { $0.yield(path) }
    }

    /// Ends every open subscription, as a monitor that was cancelled would.
    public func finish() {
        let subscribers = state.withLock { state in
            Array(state.subscribers.values)
        }
        // Each finish runs its termination handler, which forgets it.
        subscribers.forEach { $0.finish() }
    }

    /// Suspends until at least `count` subscriptions are open.
    public func waitForSubscribers(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.subscribers.count >= count { return true }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Suspends until no subscription is open: everything that listened has
    /// stopped.
    public func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let idle = state.withLock { state -> Bool in
                if state.subscribers.isEmpty { return true }
                state.waiters.append(Waiter(count: 0, continuation: continuation))
                return false
            }
            if idle { continuation.resume() }
        }
    }
}

extension Array {
    /// The elements that satisfy `predicate`, and the rest, each in order.
    fileprivate func partitioned(_ predicate: (Element) -> Bool) -> (matching: [Element], rest: [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self { if predicate(element) { matching.append(element) } else { rest.append(element) } }
        return (matching, rest)
    }
}

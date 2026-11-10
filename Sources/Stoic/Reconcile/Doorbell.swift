internal import Synchronization

/// Wakes one waiting loop early: a reconciler's run loop sleeps until its
/// next due instant, and a trigger rings it so it looks again.
///
/// A ring with nobody waiting is kept, so the next wait returns at once:
/// a trigger that arrives while the loop is busy is never lost.
final class Doorbell: Sendable {
    private struct State {
        var rung = false
        var waiter: CheckedContinuation<Void, Never>?
        // The waiter was cancelled before it could be stored.
        var cancelled = false
    }

    private let state = Mutex(State())

    func ring() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.rung = true
            return nil
        }
        waiter?.resume()
    }

    /// Returns when the bell is rung (or was, since the last wait), or at
    /// `instant` on `clock`, whichever comes first. `nil` waits for the bell
    /// alone.
    func wait(until instant: AnyClock.Instant?, clock: AnyClock) async throws(CancellationError) {
        if state.withLock({ state in defer { state.rung = false }; return state.rung }) { return }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                if let instant {
                    group.addTask { try await clock.sleep(until: instant, tolerance: nil) }
                }
                group.addTask { await self.rung() }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            throw CancellationError()
        }
        if Task.isCancelled { throw CancellationError() }
    }

    /// Suspends until rung; returns at once when cancelled.
    private func rung() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if state.rung || state.cancelled {
                        state.rung = false
                        state.cancelled = false
                        return true
                    }
                    state.waiter = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard let waiter = state.waiter else {
                    state.cancelled = true
                    return nil
                }
                state.waiter = nil
                return waiter
            }
            waiter?.resume()
        }
    }
}

/// How far a reconciler has got, for its tests: passes ended and times its
/// loop went to sleep, each awaitable without a real-time wait.
final class ReconcilerProgress: Sendable {
    enum Mark: Sendable { case passes, sleeps }

    private struct State {
        var passes = 0
        var sleeps = 0
        var waiters: [(mark: Mark, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var passes: Int { state.withLock { $0.passes } }
    var sleeps: Int { state.withLock { $0.sleeps } }

    func note(_ mark: Mark) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            switch mark {
            case .passes: state.passes += 1
            case .sleeps: state.sleeps += 1
            }
            let (passes, sleeps) = (state.passes, state.sleeps)
            var ready: [CheckedContinuation<Void, Never>] = []
            state.waiters.removeAll { waiter in
                let reached = waiter.count <= (waiter.mark == .passes ? passes : sleeps)
                if reached { ready.append(waiter.continuation) }
                return reached
            }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }

    /// Returns once `count` of `mark` have happened since the reconciler was made.
    func wait(for mark: Mark, count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if count <= (mark == .passes ? state.passes : state.sleeps) { return true }
                state.waiters.append((mark, count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

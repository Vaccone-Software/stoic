internal import Synchronization

/// A backend's bulkhead, partitioned by urgency (design/22, Admission).
///
/// At most `capacity` calls hold a slot. The caps are cumulative: calls at
/// an urgency *or lower* together hold at most `caps[rank]` slots, so a
/// person's tap always has a slot that row loads and syncs together cannot
/// take, and background work never holds the last half. A freed slot goes
/// to the most urgent waiter whose cumulative cap allows it, first come
/// first served within an urgency. Each urgency may have at most
/// `waiterLimit` waiters; past that a call is refused at once. A wait lasts
/// at most until ``Deadline/current``, and a waiter that leaves (cancelled,
/// or out of time) never takes a slot, as with ``AsyncSemaphore``.
///
/// The same gate with one slot is a `local` backend's writer lane: one
/// writer at a time, the most urgent first.
///
/// A newcomer never overtakes a waiter of its own urgency, nor one more
/// urgent, including one still on the way into the queue. The caps are
/// cumulative, so whatever keeps a more urgent waiter out keeps a less
/// urgent newcomer out too.
final class AdmissionGate: Sendable {
    let label: String
    let capacity: Int
    /// The cumulative cap of each urgency, by ``Urgency/rank``.
    let caps: [Int]
    /// The most waiters each urgency may have.
    let waiterLimit: Int

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Rejection?, Never>
    }

    private struct State {
        /// Slots held, by the holder's rank.
        var held = [0, 0, 0, 0]
        /// Waiters in arrival order, by rank.
        var queues: [[Waiter]] = [[], [], [], []]
        /// Waiters queued or on their way to the queue, by rank: what the
        /// waiter limit counts.
        var waiting = [0, 0, 0, 0]
        /// Waiters that have an id but have not queued yet, with their rank.
        var arriving: [UInt64: Int] = [:]
        /// Arriving waiters whose cancellation or deadline came first.
        var leftEarly: [UInt64: Rejection] = [:]
        var nextID: UInt64 = 0

        /// Whether a call at `rank` may take a slot now: every cumulative
        /// cap it would count against has room.
        func admits(_ rank: Int, caps: [Int]) -> Bool {
            var atOrBelow = 0
            for level in 0..<4 {
                atOrBelow += held[level]
                if level >= rank, atOrBelow + 1 > caps[level] { return false }
            }
            return true
        }

        /// Whether a waiter of rank `rank` or higher has not reached the queue.
        func isArriving(atLeast rank: Int) -> Bool {
            arriving.values.contains { $0 >= rank }
        }

        /// Hands slots to the most urgent queued waiters the caps admit.
        ///
        /// A waiter still on the way to the queue keeps their place, as a
        /// semaphore waiter does. Granting stops there: the slot they would
        /// take stays free until they queue, and nobody behind them (a less
        /// urgent waiter, or a later arrival at their urgency) receives one.
        mutating func grant(caps: [Int]) -> [Waiter] {
            var granted: [Waiter] = []
            var progress = true
            while progress {
                progress = false
                for rank in stride(from: 3, through: 0, by: -1) where admits(rank, caps: caps) {
                    if let head = queues[rank].first {
                        // An earlier arrival at this urgency has not queued.
                        let earlierStillArriving = arriving.contains { id, arrived in arrived == rank && id < head.id }
                        if earlierStillArriving { return granted }
                        granted.append(queues[rank].removeFirst())
                        held[rank] += 1
                        waiting[rank] -= 1
                        progress = true
                        break
                    }
                    // The next waiter at this urgency has not queued.
                    if arriving.values.contains(rank) { return granted }
                }
            }
            return granted
        }
    }

    private let state = Mutex(State())

    init(label: String, capacity: Int, caps: [Int], waiterLimit: Int) {
        precondition(caps.count == 4 && caps.allSatisfy { $0 >= 1 && $0 <= capacity }, "admission caps must be within the capacity")
        self.label = label
        self.capacity = capacity
        self.caps = caps
        self.waiterLimit = waiterLimit
    }

    /// Whether nothing holds a slot or waits for one.
    var isIdle: Bool {
        state.withLock { state in state.held.allSatisfy { $0 == 0 } && state.waiting.allSatisfy { $0 == 0 } }
    }

    /// Slots held right now, by rank.
    var held: [Int] {
        state.withLock { $0.held }
    }

    /// Waiters right now, by rank. Includes those still on the way to the queue.
    var waiting: [Int] {
        state.withLock { $0.waiting }
    }

    /// Waiters that have reached the queue, by rank.
    var queued: [Int] {
        state.withLock { $0.queues.map(\.count) }
    }

    /// Takes a slot for a call at `rank`, waiting if the caps say so.
    /// Returns `nil` once granted (pair it with ``release(rank:)``), or why
    /// not: `.bulkheadFull` when the urgency's waiters are at their limit,
    /// `.cancelled`, or `.deadlineExceeded` when ``Deadline/current`` passed.
    nonisolated(nonsending) func acquire(rank: Int) async -> Rejection? {
        if Task.isCancelled {
            return Rejection(CancellationCause.current == .deadline ? .deadlineExceeded : .cancelled, label: label)
        }
        enum Admission { case granted, full, wait(UInt64) }
        let admission = state.withLock { state -> Admission in
            // A waiter of this urgency, or a more urgent one, still on its
            // way to the queue is ahead of a newcomer, however briefly.
            if state.queues[rank].isEmpty, !state.isArriving(atLeast: rank), state.admits(rank, caps: caps) {
                state.held[rank] += 1
                return .granted
            }
            if state.waiting[rank] >= waiterLimit { return .full }
            defer { state.nextID += 1 }
            state.arriving[state.nextID] = rank
            state.waiting[rank] += 1
            return .wait(state.nextID)
        }
        let id: UInt64
        switch admission {
        case .granted: return nil
        case .full: return Rejection(.bulkheadFull, label: label)
        case .wait(let ticket): id = ticket
        }
        defer {
            // Whatever ended the wait, this waiter is gone: forget it, and
            // let through anyone whose slot it was holding.
            let granted = state.withLock { state -> [Waiter] in
                state.leftEarly.removeValue(forKey: id)
                guard state.arriving.removeValue(forKey: id) != nil else { return [] }
                state.waiting[rank] -= 1
                return state.grant(caps: caps)
            }
            for waiter in granted { waiter.continuation.resume(returning: nil) }
        }
        // Between deciding to wait and queueing: where a cancellation or a
        // deadline must find the waiter in `arriving`, and where a freed
        // slot has to be kept for them.
        await FaultPoint.hit("admission.arriving")
        let deadline = Deadline.current
        if let deadline, deadline.hasPassed {
            return Rejection(.deadlineExceeded, label: label)
        }
        return await withTaskGroup(of: Void.self) { group in
            if let deadline {
                group.addTask {
                    do {
                        try await deadline.clock.sleep(until: deadline.instant, tolerance: nil)
                        self.leave(id, because: Rejection(.deadlineExceeded, label: self.label))
                    } catch {}
                }
            }
            let waited = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Rejection?, Never>) in
                    enqueue(Waiter(id: id, continuation: continuation), rank: rank)
                }
            } onCancel: {
                leave(id, because: Rejection(.cancelled, label: label))
            }
            group.cancelAll()
            if waited?.reason == .cancelled, CancellationCause.current == .deadline {
                return Rejection(.deadlineExceeded, label: label)
            }
            return waited
        }
    }

    /// Gives back a slot a call at `rank` held, to the most urgent waiter
    /// the caps admit.
    func release(rank: Int) {
        let granted = state.withLock { state -> [Waiter] in
            precondition(state.held[rank] > 0, "AdmissionGate \(label): released a slot it does not hold")
            state.held[rank] -= 1
            return state.grant(caps: caps)
        }
        for waiter in granted { waiter.continuation.resume(returning: nil) }
    }

    private func enqueue(_ waiter: Waiter, rank: Int) {
        let (rejection, granted) = state.withLock { state -> (Rejection?, [Waiter]) in
            if let rejection = state.leftEarly.removeValue(forKey: waiter.id) {
                // `leave` already took this waiter out of `arriving` and
                // handed on the slot it was holding the line for.
                return (rejection, [])
            }
            state.arriving.removeValue(forKey: waiter.id)
            // Usually the newest id, so usually the end. One that took
            // longer to get here than a later arrival goes ahead of it.
            let index = state.queues[rank].lastIndex { $0.id < waiter.id }.map { $0 + 1 } ?? 0
            state.queues[rank].insert(waiter, at: index)
            return (nil, state.grant(caps: caps))
        }
        if let rejection { waiter.continuation.resume(returning: rejection) }
        for waiter in granted { waiter.continuation.resume(returning: nil) }
    }

    /// Takes waiter `id` out of the queue, if it is still waiting.
    private func leave(_ id: UInt64, because rejection: Rejection) {
        let (waiter, granted) = state.withLock { state -> (Waiter?, [Waiter]) in
            for rank in 0..<4 {
                if let index = state.queues[rank].firstIndex(where: { $0.id == id }) {
                    state.waiting[rank] -= 1
                    return (state.queues[rank].remove(at: index), [])
                }
            }
            if let arrived = state.arriving.removeValue(forKey: id) {
                // Not queued yet: it finds this on arrival and leaves, and
                // the slot kept for it goes to whoever is next.
                state.waiting[arrived] -= 1
                state.leftEarly[id] = rejection
                return (nil, state.grant(caps: caps))
            }
            // Otherwise it was already granted a slot, or has gone.
            return (nil, [])
        }
        waiter?.continuation.resume(returning: rejection)
        for waiter in granted { waiter.continuation.resume(returning: nil) }
    }
}

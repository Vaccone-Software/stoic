internal import Synchronization

/// A bounded queue between producers and consumers, with an explicit answer
/// to "what if the consumer falls behind?".
///
/// `AsyncStream`'s default buffer is unbounded: a producer faster than its
/// consumer grows memory until the app is killed. Every wait has an end,
/// and every queue has a bound, so a `Channel` makes the producer choose
/// what happens when it is full:
///
/// - ``Overflow/suspend``: the sender waits for space (backpressure). Waiting
///   is first-in first-out, and ends early on cancellation or when
///   ``Deadline/current`` passes.
/// - ``Overflow/dropOldest``: the oldest buffered element is discarded — the
///   right choice for "latest state wins" streams such as progress or
///   location.
/// - ``Overflow/dropNewest``: the new element is discarded.
/// - ``Overflow/reject``: `send` throws, so the producer can shed load
///   itself.
///
/// Every drop is counted (``droppedCount``) and reported
/// (`channel.dropped`). Any number of producers and consumers may share a
/// channel; each element goes to exactly one consumer, in order. ``finish()``
/// ends it: consumers drain what is buffered and then see the end.
public final class Channel<Element: Sendable>: Sendable, AsyncSequence {
    /// What `send` does when the buffer is full.
    public enum Overflow: Sendable, Hashable {
        case suspend
        case dropOldest
        case dropNewest
        case reject
    }

    public let label: String
    public let capacity: Int
    public let overflow: Overflow

    private struct Sender {
        let id: UInt64
        let element: Element
        let continuation: CheckedContinuation<Rejection?, Never>
    }

    private struct Receiver {
        let id: UInt64
        let continuation: CheckedContinuation<Element?, Never>
    }

    private struct State {
        var buffer: [Element] = []
        var head = 0
        var senders: [Sender] = []
        var receivers: [Receiver] = []
        var finished = false
        var nextID: UInt64 = 0
        var arriving: [UInt64: Rejection?] = [:]
        var dropped = 0

        var count: Int { buffer.count - head }

        mutating func popFirst() -> Element? {
            guard head < buffer.count else { return nil }
            let element = buffer[head]
            head += 1
            if head > 64, head * 2 > buffer.count {
                buffer.removeFirst(head)
                head = 0
            }
            return element
        }
    }

    private let state = Mutex(State())

    // Continuations are only ever resumed after `state` is unlocked. Resuming
    // takes the woken task's status lock, and the runtime holds that same
    // lock while it runs the task's cancellation handler — which takes
    // `state`. Resuming under `state` is therefore a lock-order inversion
    // that deadlocks when a delivery races a cancellation (found by review
    // with a 100%-reproducible stress; now a regression test).
    private enum SendStep {
        case done
        case handOff(CheckedContinuation<Element?, Never>)
        case wait(UInt64)
        case reject(Rejection)
        case dropped
    }

    public init(capacity: Int, overflow: Overflow = .suspend, label: String) {
        precondition(capacity >= 1, "a channel needs a capacity of at least one")
        self.capacity = capacity
        self.overflow = overflow
        self.label = label
    }

    /// Elements buffered right now.
    public var count: Int {
        state.withLock { $0.count }
    }

    /// Elements discarded by a drop policy so far.
    public var droppedCount: Int {
        state.withLock { $0.dropped }
    }

    /// Whether ``finish()`` has been called.
    public var isFinished: Bool {
        state.withLock { $0.finished }
    }

    // MARK: Sending

    /// Sends `element`, applying the channel's overflow policy if it is full.
    ///
    /// - Throws: a ``Rejection``: `.closed` after ``finish()``; `.full` under
    ///   ``Overflow/reject``; under ``Overflow/suspend``, `.cancelled` or
    ///   `.deadlineExceeded` if the wait for space ended first. A rejected
    ///   element was not sent.
    public nonisolated(nonsending) func send(_ element: Element) async throws(Rejection) {
        let next = state.withLock { state -> SendStep in
            if state.finished { return .reject(Rejection(.closed, label: label)) }
            if !state.receivers.isEmpty {
                return .handOff(state.receivers.removeFirst().continuation)
            }
            if state.count < capacity {
                state.buffer.append(element)
                return .done
            }
            switch overflow {
            case .reject:
                return .reject(Rejection(.full, label: label))
            case .dropNewest:
                state.dropped += 1
                return .dropped
            case .dropOldest:
                _ = state.popFirst()
                state.buffer.append(element)
                state.dropped += 1
                return .dropped
            case .suspend:
                let id = state.nextID
                state.nextID += 1
                state.arriving[id] = .some(nil)
                return .wait(id)
            }
        }
        switch next {
        case .done:
            return
        case .handOff(let receiver):
            receiver.resume(returning: element)
        case .dropped:
            Ambient.record(Event("channel.dropped", level: .debug, label: label, fields: [
                .init("policy", .string(overflow == .dropOldest ? "drop_oldest" : "drop_newest"), privacy: .public),
            ]))
        case .reject(let rejection):
            throw rejection
        case .wait(let id):
            if let rejection = await waitForSpace(id, element: element) {
                throw rejection
            }
        }
    }

    /// Sends `element` if there is room (or a waiting receiver) right now.
    /// Never applies a drop policy and never waits.
    @discardableResult
    public func trySend(_ element: Element) -> Bool {
        let (sent, receiver) = state.withLock { state -> (Bool, CheckedContinuation<Element?, Never>?) in
            guard !state.finished else { return (false, nil) }
            if !state.receivers.isEmpty {
                return (true, state.receivers.removeFirst().continuation)
            }
            guard state.count < capacity else { return (false, nil) }
            state.buffer.append(element)
            return (true, nil)
        }
        receiver?.resume(returning: element)
        return sent
    }

    private nonisolated(nonsending) func waitForSpace(_ id: UInt64, element: Element) async -> Rejection? {
        let deadline = Deadline.current
        let label = label
        let outcome: Rejection? = await withTaskGroup(of: Void.self) { group in
            if let deadline {
                group.addTask {
                    do {
                        try await deadline.clock.sleep(until: deadline.instant, tolerance: nil)
                        self.leaveSenders(id, because: Rejection(.deadlineExceeded, label: label))
                    } catch {}
                }
            }
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Rejection?, Never>) in
                    var receiver: CheckedContinuation<Element?, Never>?
                    let early = state.withLock { state -> Rejection?? in
                        let early = state.arriving.removeValue(forKey: id) ?? nil
                        if let early { return .some(early) }
                        // Space may have opened between the first check and now.
                        if !state.receivers.isEmpty {
                            receiver = state.receivers.removeFirst().continuation
                            return .some(nil)
                        }
                        if state.count < capacity, !state.finished {
                            state.buffer.append(element)
                            return .some(nil)
                        }
                        if state.finished { return .some(Rejection(.closed, label: label)) }
                        state.senders.append(Sender(id: id, element: element, continuation: continuation))
                        return nil
                    }
                    // Wake others only after the lock is released (see below).
                    receiver?.resume(returning: element)
                    if let early { continuation.resume(returning: early) }
                }
            } onCancel: {
                self.leaveSenders(id, because: Rejection(.cancelled, label: label))
            }
            group.cancelAll()
            return outcome
        }
        if outcome?.reason == .cancelled, CancellationCause.current == .deadline {
            return Rejection(.deadlineExceeded, label: label)
        }
        return outcome
    }

    private func leaveSenders(_ id: UInt64, because rejection: Rejection) {
        let sender = state.withLock { state -> Sender? in
            if let arriving = state.arriving[id] {
                if arriving == nil { state.arriving[id] = .some(rejection) }
                return nil
            }
            guard let index = state.senders.firstIndex(where: { $0.id == id }) else { return nil }
            return state.senders.remove(at: index)
        }
        sender?.continuation.resume(returning: rejection)
    }

    // MARK: Receiving

    /// The next element, or `nil` once the channel is finished and drained —
    /// or when the receiving task is cancelled.
    public func receive() async -> Element? {
        if Task.isCancelled { return nil }
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                var woken: CheckedContinuation<Rejection?, Never>?
                let ready = state.withLock { state -> Element?? in
                    if let element = state.popFirst() {
                        // A waiting sender's element takes the freed place.
                        if !state.senders.isEmpty {
                            let sender = state.senders.removeFirst()
                            state.buffer.append(sender.element)
                            woken = sender.continuation
                        }
                        return .some(element)
                    }
                    if !state.senders.isEmpty {
                        let sender = state.senders.removeFirst()
                        woken = sender.continuation
                        return .some(sender.element)
                    }
                    if state.finished || Task.isCancelled { return .some(nil) }
                    state.receivers.append(Receiver(id: id, continuation: continuation))
                    return nil
                }
                woken?.resume(returning: nil)
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let receiver = state.withLock { state -> Receiver? in
                guard let index = state.receivers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.receivers.remove(at: index)
            }
            receiver?.continuation.resume(returning: nil)
        }
    }

    /// Ends the channel: no more sends. Buffered elements are still
    /// delivered; then every consumer sees the end. Waiting senders are
    /// rejected with `.closed`.
    public func finish() {
        let (senders, receivers) = state.withLock { state -> ([Sender], [Receiver]) in
            state.finished = true
            defer {
                state.senders = []
                if state.count == 0 { state.receivers = [] }
            }
            return (state.senders, state.count == 0 ? state.receivers : [])
        }
        for sender in senders { sender.continuation.resume(returning: Rejection(.closed, label: label)) }
        for receiver in receivers { receiver.continuation.resume(returning: nil) }
    }

    // MARK: AsyncSequence

    public struct AsyncIterator: AsyncIteratorProtocol {
        let channel: Channel

        public mutating func next() async -> Element? {
            await channel.receive()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> Element? {
            await channel.receive()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(channel: self)
    }
}

extension Rejection.Reason {
    /// A channel or queue has been finished and accepts nothing more.
    public static let closed = Rejection.Reason(rawValue: "closed")
    /// A bounded queue is full and its policy is to reject.
    public static let full = Rejection.Reason(rawValue: "full")
}

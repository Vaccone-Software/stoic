internal import Synchronization

/// Delivers every published element to every subscriber, each through a
/// buffer of its own with a policy of its own for when it falls behind.
///
/// A ``Channel`` hands each element to exactly one consumer. A `Broadcast` is
/// the other shape: the element goes to all of them (a download's progress to
/// the row, the badge and the log), and they do not agree on how much they
/// can keep up with. So each subscriber says, when it subscribes, how many
/// elements it will buffer and what happens to a publish that finds the
/// buffer full:
///
/// - ``Buffer/dropOldest(_:)``: the oldest buffered element goes. Latest
///   state wins; the publisher never waits.
/// - ``Buffer/dropNewest(_:)``: the new element is not delivered to this
///   subscriber. The publisher never waits.
/// - ``Buffer/suspend(_:)``: the publisher waits for room (backpressure), in
///   subscription order, so one slow subscriber slows the publisher and every
///   subscriber after it. The wait ends on the publisher's cancellation or
///   deadline, and when the subscriber ends.
///
/// Every buffer is bounded, so memory is bounded by the subscribers' sizes;
/// a subscriber only ever sees elements published after it subscribed. Drops
/// are counted per subscription (``Subscription/droppedCount``) and reported
/// (`channel.dropped`, labelled with the broadcast).
///
/// **Subscriptions end cleanly.** Iterating one is an ordinary
/// `for await`; the loop ends when the broadcast finishes (after the buffered
/// elements), when the iterating task is cancelled, or after
/// ``Subscription/cancel()``. In every case the subscriber is removed
/// immediately, a publisher suspended on it is released, and dropping the
/// subscription does the same. A subscription is meant for one consuming
/// loop; two loops over it share its elements.
public final class Broadcast<Element: Sendable>: Sendable {
    /// A subscriber's buffer: its size, at least 1, and what to do when full.
    public enum Buffer: Sendable, Hashable {
        case dropOldest(Int)
        case dropNewest(Int)
        case suspend(Int)
    }

    public let label: String

    private struct State {
        var subscribers: [UInt64: Channel<Element>] = [:]
        var nextID: UInt64 = 0
        var finished = false
    }

    private let state = Mutex(State())

    public init(label: String) {
        self.label = label
    }

    deinit {
        finish()
    }

    /// The subscriptions that have not ended.
    public var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    /// Subscribes with `buffer`. The subscription sees what is published from now on.
    ///
    /// Subscribing to a finished broadcast returns a subscription that ends at once.
    public func subscribe(_ buffer: Buffer) -> Subscription {
        let (capacity, overflow): (Int, Channel<Element>.Overflow) = switch buffer {
        case .dropOldest(let size): (size, .dropOldest)
        case .dropNewest(let size): (size, .dropNewest)
        case .suspend(let size): (size, .suspend)
        }
        let channel = Channel<Element>(capacity: capacity, overflow: overflow, label: label)
        let id = state.withLock { state -> UInt64? in
            guard !state.finished else { return nil }
            state.nextID += 1
            state.subscribers[state.nextID] = channel
            return state.nextID
        }
        guard let id else {
            channel.finish()
            return Subscription(channel: channel, unsubscribe: {})
        }
        return Subscription(channel: channel) { [weak self] in self?.remove(id) }
    }

    /// Delivers `element` to every subscriber, in the order they subscribed.
    ///
    /// Returns once each has buffered it (or dropped it, by its policy). A
    /// subscriber that ends while the publish waits for it is skipped.
    ///
    /// Concurrent publishes are not ordered with each other: two subscribers
    /// may see two concurrently published elements in different orders.
    /// Publish from one task when every subscriber must see one order.
    ///
    /// - Throws: A ``Rejection``: `.closed` after ``finish()``, or when it
    ///   ends the broadcast while this publish is under way and some
    ///   subscriber has not got the element; `.cancelled`
    ///   or `.deadlineExceeded` if a wait for a ``Buffer/suspend(_:)``
    ///   subscriber was cut short. Subscribers earlier in the order already
    ///   have the element.
    public nonisolated(nonsending) func publish(_ element: Element) async throws(Rejection) {
        let channels = try state.withLock { state throws(Rejection) -> [Channel<Element>] in
            if state.finished { throw Rejection(.closed, label: label) }
            return state.subscribers.valuesInKeyOrder
        }
        var missed = false
        for channel in channels {
            do throws(Rejection) {
                try await channel.send(element)
            } catch {
                if error.reason != .closed { throw error }
                missed = true
            }
        }
        // A subscriber that left is skipped. One that `finish()` ended while
        // this publish was under way missed the element, and the publisher
        // must not believe it was delivered.
        if missed, state.withLock({ $0.finished }) { throw Rejection(.closed, label: label) }
    }

    /// Ends the broadcast: no more publishes, and every subscription ends
    /// once it has drained what it buffered.
    public func finish() {
        let channels = state.withLock { state -> [Channel<Element>] in
            state.finished = true
            defer { state.subscribers = [:] }
            return state.subscribers.valuesInKeyOrder
        }
        for channel in channels { channel.finish() }
    }

    private func remove(_ id: UInt64) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }

    /// One subscriber's view of a broadcast.
    public final class Subscription: AsyncSequence, Sendable {
        private let channel: Channel<Element>
        private let unsubscribe: @Sendable () -> Void

        fileprivate init(channel: Channel<Element>, unsubscribe: @escaping @Sendable () -> Void) {
            self.channel = channel
            self.unsubscribe = unsubscribe
        }

        deinit {
            end()
        }

        /// Elements this subscription's policy discarded so far.
        public var droppedCount: Int { channel.droppedCount }

        /// Elements buffered, not yet taken.
        public var bufferedCount: Int { channel.count }

        /// Leaves the broadcast. What is buffered can still be iterated, then the sequence ends.
        public func cancel() {
            end()
        }

        fileprivate func end() {
            unsubscribe()
            channel.finish()
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate let subscription: Subscription

            public mutating func next() async -> Element? {
                await next(isolation: nil)
            }

            public mutating func next(isolation actor: isolated (any Actor)?) async -> Element? {
                let element = await subscription.channel.receive()
                // Finished and drained, or the consumer was cancelled: either
                // way this subscriber is done, and must not hold up a publisher.
                if element == nil { subscription.end() }
                return element
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(subscription: self)
        }
    }
}

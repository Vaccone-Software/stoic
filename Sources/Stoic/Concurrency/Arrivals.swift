/// The waiters that have an id and have not yet reached the place they wait
/// in, and those among them whose cancellation or deadline came first.
///
/// A waiter takes its id under the lock that decides it must wait, and joins
/// the queue (or the flight, or the clock) under a later one, with an await
/// between. In that gap it is *on its way*, and first in, first out has to
/// count it: a newcomer must not overtake a waiter for being briefly late to
/// the queue, and a slot freed meanwhile is kept for it. A cancellation or a
/// deadline can land in the gap too, when there is nothing yet to take the
/// waiter out of. It *leaves early*: it no longer holds the line for anyone,
/// and finds its reason waiting when it arrives.
///
/// Those are two states of one id, and an id is in exactly one. The state is
/// an enum, so a waiter that is both on its way and gone cannot be written
/// down, as it could be with two collections kept in step by hand. Whatever
/// asks who is still on the way, ``onTheirWayCount`` and ``onTheirWay``, leaves
/// out a waiter that left early.
///
/// The ids are the caller's. They come from a counter the caller shares with
/// other ids, so this does not hand them out. It is plain state, to be kept
/// under the caller's own lock.
package struct Arrivals<Tag: Sendable, Reason: Sendable>: Sendable {
    private enum Status: Sendable {
        /// Carries what the caller wants to know about the waiter while it
        /// is not yet in a queue of its own, such as its rank.
        case onItsWay(Tag)
        /// Carries why: the rejection the waiter will be given on arrival.
        case leftEarly(Reason)
    }

    private var statuses: [UInt64: Status] = [:]

    /// How many waiters are on their way: not those that left early. Kept
    /// as it changes, so a hot path reading it does not walk the ids.
    package private(set) var onTheirWayCount = 0

    package init() {}

    /// The waiters on their way, with the tag each began with.
    package var onTheirWay: some Sequence<(id: UInt64, tag: Tag)> {
        statuses.lazy.compactMap { id, status in
            guard case .onItsWay(let tag) = status else { return nil }
            return (id: id, tag: tag)
        }
    }

    /// Records that `id` has a place to reach and is on its way to it.
    package mutating func begin(_ id: UInt64, tag: Tag) {
        precondition(statuses.updateValue(.onItsWay(tag), forKey: id) == nil, "Arrivals: id \(id) began twice")
        onTheirWayCount += 1
    }

    /// Records that `id` left before it arrived, for `reason`.
    ///
    /// - Returns: The tag it began with, if it was on its way and so has now
    ///   left; `nil` if it had already left early (the first reason stands),
    ///   or has arrived or been forgotten, and so is not here to leave.
    @discardableResult
    package mutating func leave(_ id: UInt64, because reason: Reason) -> Tag? {
        guard case .onItsWay(let tag)? = statuses[id] else { return nil }
        statuses[id] = .leftEarly(reason)
        onTheirWayCount -= 1
        return tag
    }

    /// Records that `id` has reached its place, and no longer needs tracking.
    ///
    /// - Returns: The reason it left early, if it did: it must not take its
    ///   place, and ends its wait with that reason instead.
    package mutating func arrive(_ id: UInt64) -> Reason? {
        guard case .leftEarly(let reason)? = remove(id) else { return nil }
        return reason
    }

    /// Drops `id` however its wait ended, early or not, so nothing of it is
    /// left behind.
    ///
    /// - Returns: The tag it began with, if it was still on its way: it was
    ///   holding the line, and whoever it held up may now go through.
    @discardableResult
    package mutating func forget(_ id: UInt64) -> Tag? {
        guard case .onItsWay(let tag)? = remove(id) else { return nil }
        return tag
    }

    private mutating func remove(_ id: UInt64) -> Status? {
        let status = statuses.removeValue(forKey: id)
        if case .onItsWay? = status { onTheirWayCount -= 1 }
        return status
    }
}

extension Arrivals where Tag == Void {
    /// ``begin(_:tag:)`` for waiters with nothing to tell apart but their id.
    package mutating func begin(_ id: UInt64) {
        begin(id, tag: ())
    }
}

extension Arrivals where Reason == Void {
    /// ``leave(_:because:)`` for waiters whose leaving needs no reason.
    @discardableResult
    package mutating func leave(_ id: UInt64) -> Tag? {
        leave(id, because: ())
    }
}

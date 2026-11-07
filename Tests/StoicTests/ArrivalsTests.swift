@testable import Stoic
import Testing

/// The waiters on their way to a queue, and those that left before they
/// arrived. No time is involved: the type is plain state, and every
/// interleaving of its operations can be written down.
@Suite("Arrivals")
struct ArrivalsTests {
    typealias Ranked = Arrivals<Int, String>

    struct Waiter: Equatable {
        var id: UInt64
        var tag: Int
    }

    /// The waiters on their way, in id order.
    func onTheirWay(_ arrivals: Ranked) -> [Waiter] {
        arrivals.onTheirWay.map { Waiter(id: $0.id, tag: $0.tag) }.sorted { $0.id < $1.id }
    }

    @Test func aWaiterThatBeganIsOnItsWayWithItsTag() {
        var arrivals = Ranked()
        arrivals.begin(7, tag: 2)
        arrivals.begin(9, tag: 0)
        #expect(arrivals.onTheirWayCount == 2)
        #expect(onTheirWay(arrivals) == [Waiter(id: 7, tag: 2), Waiter(id: 9, tag: 0)])
    }

    @Test func aWaiterThatArrivesOnItsWayIsGoneAndHasNoReason() {
        var arrivals = Ranked()
        arrivals.begin(1, tag: 3)
        #expect(arrivals.arrive(1) == nil)
        #expect(arrivals.onTheirWayCount == 0)
        #expect(onTheirWay(arrivals).isEmpty)
        #expect(arrivals.forget(1) == nil, "nothing of it is left to forget")
    }

    @Test func aWaiterThatLeftEarlyIsNoLongerOnItsWayAndArrivesWithItsReason() {
        var arrivals = Ranked()
        arrivals.begin(1, tag: 3)
        arrivals.begin(2, tag: 1)
        #expect(arrivals.leave(1, because: "cancelled") == 3, "the tag it was on its way with")
        #expect(arrivals.onTheirWayCount == 1)
        #expect(onTheirWay(arrivals) == [Waiter(id: 2, tag: 1)])
        #expect(arrivals.arrive(1) == "cancelled")
        #expect(arrivals.arrive(1) == nil, "the reason is given once")
        #expect(arrivals.onTheirWayCount == 1)
    }

    @Test func theFirstReasonToLeaveStands() {
        var arrivals = Ranked()
        arrivals.begin(1, tag: 0)
        #expect(arrivals.leave(1, because: "cancelled") == 0)
        #expect(arrivals.leave(1, because: "deadline") == nil, "already gone: nothing more to take")
        #expect(arrivals.onTheirWayCount == 0, "leaving twice does not count twice")
        #expect(arrivals.arrive(1) == "cancelled")
    }

    @Test func leavingAfterArrivingOrForgettingIsNothing() {
        var arrivals = Ranked()
        arrivals.begin(1, tag: 0)
        arrivals.begin(2, tag: 0)
        _ = arrivals.arrive(1)
        arrivals.forget(2)
        #expect(arrivals.leave(1, because: "late") == nil)
        #expect(arrivals.leave(2, because: "late") == nil)
        #expect(arrivals.leave(3, because: "never began") == nil)
        #expect(arrivals.onTheirWayCount == 0)
        #expect(arrivals.arrive(1) == nil, "a late leave leaves no reason behind to be found")
        #expect(arrivals.arrive(2) == nil)
        #expect(arrivals.arrive(3) == nil)
    }

    @Test func forgettingAWaiterOnItsWayReturnsTheTagItWasHoldingTheLineWith() {
        var arrivals = Ranked()
        arrivals.begin(1, tag: 2)
        arrivals.begin(2, tag: 1)
        #expect(arrivals.forget(1) == 2)
        #expect(arrivals.onTheirWayCount == 1)
        #expect(onTheirWay(arrivals) == [Waiter(id: 2, tag: 1)])
        #expect(arrivals.forget(1) == nil)
    }

    @Test func forgettingAWaiterThatLeftEarlyHoldsNobodyUpAndLeavesNothingBehind() {
        var arrivals = Ranked()
        arrivals.begin(1, tag: 2)
        arrivals.leave(1, because: "cancelled")
        #expect(arrivals.forget(1) == nil)
        #expect(arrivals.onTheirWayCount == 0)
        #expect(arrivals.arrive(1) == nil, "its reason went with it")
    }

    @Test func anUnknownIdIsNeitherArrivingNorLeaving() {
        var arrivals = Ranked()
        #expect(arrivals.arrive(5) == nil)
        #expect(arrivals.forget(5) == nil)
        #expect(arrivals.leave(5, because: "x") == nil)
        #expect(arrivals.onTheirWayCount == 0)
    }

    @Test func aWaiterWithNothingToTellApartAndNoReasonNeedsOnlyItsId() {
        var arrivals = Arrivals<Void, Void>()
        arrivals.begin(1)
        arrivals.begin(2)
        #expect(arrivals.onTheirWayCount == 2)
        arrivals.leave(1)
        #expect(arrivals.onTheirWayCount == 1)
        #expect(arrivals.arrive(1) != nil, "it left early: a reason that is nothing is still one")
        #expect(arrivals.arrive(2) == nil)
        #expect(arrivals.onTheirWayCount == 0)
    }

    /// The count and the list of waiters on their way are the same thing, and
    /// an id is never counted twice or found in both states, whatever the
    /// order: the type against a model that keeps the two states in two
    /// collections, as the code it replaces did.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func anyOrderOfOperationsAgreesWithTwoCollectionsKeptInStep(seed: UInt64) {
        var generator = OperationPropertyTests.Generator(state: seed)
        var arrivals = Ranked()
        var onItsWay: [UInt64: Int] = [:]
        var leftEarly: [UInt64: String] = [:]
        var next: UInt64 = 0
        for step in 0..<2_000 {
            let id = UInt64.random(in: 0...next, using: &generator)
            switch Int.random(in: 0..<5, using: &generator) {
            case 0:
                arrivals.begin(next, tag: Int(next % 4))
                onItsWay[next] = Int(next % 4)
                next += 1
            case 1:
                let expected = onItsWay[id]
                if expected != nil {
                    onItsWay[id] = nil
                    leftEarly[id] = "reason \(step)"
                }
                #expect(arrivals.leave(id, because: "reason \(step)") == expected)
            case 2:
                let expected = leftEarly.removeValue(forKey: id)
                onItsWay[id] = nil
                #expect(arrivals.arrive(id) == expected)
            case 3:
                let expected = onItsWay.removeValue(forKey: id)
                leftEarly[id] = nil
                #expect(arrivals.forget(id) == expected)
            default:
                break
            }
            #expect(arrivals.onTheirWayCount == onItsWay.count)
            #expect(Set(arrivals.onTheirWay.map(\.id)) == Set(onItsWay.keys))
        }
    }
}

@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// `Reconciler.settling(_:due:query:)` over any lifecycle store (design/27,
/// design/30, Jobs that converge by themselves).
@Suite("Reconciler settling")
struct ReconcilerSettlingTests {
    static let due = Backend.remote("test.lifecycle-db").readOnly("due")

    /// The ids whose records are due by `now`: the app's query on `dueAt`,
    /// written over a store a test fills.
    static func query<L: Lifecycle>(
        _ store: InMemoryLifecycleStore<L, String>, ids: [String], repeating: Bool = false
    ) -> @Sendable (Moment, Int, Attempt) async throws -> [String] {
        { now, limit, _ in
            var due: [String] = []
            for id in ids {
                if let record = await store.load(id), let at = record.written.dueAt, at <= now { due.append(id) }
            }
            // A server's query whose join returns a row twice.
            return Array((repeating ? due + due : due).prefix(limit))
        }
    }

    @Test func dueRecordsAreSettledAndCountedAsCorrected() async throws {
        try await onReconcilerTime { clock, _ in
            let store = InMemoryLifecycleStore<Reminder, String>()
            for (id, at) in [("early", TestClock.wallClockStart), ("late", TestClock.wallClockStart + hour * 5)] {
                _ = await store.insert(.new(in: .waiting, by: "ana", because: "made", at: at), as: id)
            }
            let reconciler = Reconciler.settling(store, due: Self.due, policy: quickPolicy(), query: Self.query(store, ids: ["early", "late"]))
            await clock.advance(by: hour * 2)
            let report = try await reconciler.pass()
            #expect(report.applied == 1)
            #expect(report.differences == 1)
            #expect(await store.load("early")?.written.state == .done)
            #expect(await store.load("late")?.written.state == .waiting, "not due yet")
            #expect(reconciler.status.phase == .converged)
            #expect(reconciler.name == "test.reminder.settling")
        }
    }

    @Test(.failureMode("design/30", "a lifecycle record's timeout does not move it"))
    func aTimeoutThatDoesNotMoveItsRecordIsRefusedAndWaitsItsBackoff() async throws {
        try await onReconcilerTime { clock, events in
            let store = InMemoryLifecycleStore<Stuck, String>()
            _ = await store.insert(.new(in: .stuck, by: "ana", because: "made"), as: "bad")
            let reconciler = Reconciler.settling(store, due: Self.due, policy: quickPolicy(), query: Self.query(store, ids: ["bad"]))
            await clock.advance(by: hour * 2)
            let first = try await reconciler.pass()
            #expect(first.outcome == .partial)
            let stuck = try #require(reconciler.status.stuck.first)
            #expect(stuck.key == "bad")
            #expect(stuck.reason == .refused("its timeout does not move it"))
            #expect(stuck.passes == 1, "stuck at once")
            #expect(reconciler.status.phase == .stuck(differences: 1))
            #expect(events.count("reconciler.stuck") == 1)
            #expect(events.events(named: "reconciler.stuck").first?["reason"]?.description == "refused", "the words stay out of the event")
            // Waiting its backoff: not settled again, still stuck, nothing new.
            let waiting = try await reconciler.pass()
            #expect(waiting.waiting == 1)
            #expect(waiting.applied == 0)
            #expect(reconciler.status.stuck.count == 1)
            #expect(events.count("reconciler.stuck") == 1)
            await clock.advance(by: .seconds(8))
            try await reconciler.pass()
            #expect(reconciler.status.stuck.map(\.key) == ["bad"], "tried again on its backoff, refused again")
        }
    }

    @Test func aServersQueryThatReturnsAnIdTwiceSettlesItOnce() async throws {
        try await onReconcilerTime { clock, _ in
            let store = InMemoryLifecycleStore<Relay, String>()
            _ = await store.insert(.new(in: .first, by: "ana", because: "made"), as: "relay")
            let reconciler = Reconciler.settling(
                store, due: Self.due, policy: quickPolicy(), query: Self.query(store, ids: ["relay"], repeating: true))
            await clock.advance(by: hour * 3)
            let report = try await reconciler.pass()
            #expect(report.differences == 1)
            #expect(report.applied == 1)
            #expect(await store.load("relay")?.written.state == .third, "the whole chain, at the store's moment")
            #expect(await store.history(of: "relay").count == 2, "one settle: two timed entries, once")
            #expect(reconciler.status.stuck.isEmpty)
        }
    }

    @Test func aQueryThatReturnsItsLimitIsFollowedByAnotherPass() async throws {
        try await onReconcilerTime { clock, _ in
            let store = InMemoryLifecycleStore<Reminder, String>()
            let ids = (0..<5).map(key)
            for id in ids { _ = await store.insert(.new(in: .waiting, by: "ana", because: "made"), as: id) }
            let reconciler = Reconciler.settling(
                store, due: Self.due, policy: quickPolicy { $0.correctionsPerPass = 3 }, query: Self.query(store, ids: ids))
            await clock.advance(by: hour * 2)
            let first = try await reconciler.pass()
            #expect(first.applied == 3)
            #expect(first.outcome == .cutShort, "there may be more")
            let second = try await reconciler.pass()
            #expect(second.applied == 2)
            #expect(second.outcome == .corrected)
            for id in ids { #expect(await store.load(id)?.written.state == .done) }
        }
    }

    @Test func aFailingQueryIsAPassThatCouldNotRead() async throws {
        struct Down: Error, Retryable { var retryDecision: RetryDecision { .stop } }
        try await onReconcilerTime { _, _ in
            let store = InMemoryLifecycleStore<Reminder, String>()
            let reconciler = Reconciler.settling(store, due: Self.due, policy: quickPolicy()) { _, _, _ in throw Down() }
            await #expect(throws: ReconcileError.self) { try await reconciler.pass() }
            #expect(reconciler.status.phase == .unreadable(.truth))
        }
    }

    @Test func aDueQueryThatIsNotReadOnlyIsRefusedWhereTheJobIsMade() async {
        await #expect(processExitsWith: .failure) {
            let store = InMemoryLifecycleStore<Reminder, String>()
            _ = Reconciler.settling(store, due: Backend.remote("test.lifecycle-db").idempotent("sweep")) { _, _, _ in [] }
        }
    }
}

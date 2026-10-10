import Dispatch
@testable import Stoic
import StoicTesting
import Testing

/// Events are API (AGENTS.md), and EventCatalogTests only proves that a name
/// appears in the sources. Each test here makes the library emit one event
/// that no other test provoked, and checks its level, label and fields.
///
/// `scope.fork_after_exit` is covered in TaskScopeStateTests, through the
/// scope's state: through the public API it cannot be triggered at all,
/// because the handle that forks cannot outlive its body. `slot.superseded_late`
/// is covered in FailureModeTests (work that ignores cancellation).
@Suite("Events: every one is provoked by a test")
struct EventExerciseTests {
    func fields(of event: Event) -> [String: String] {
        Dictionary(uniqueKeysWithValues: event.fields.map { ($0.key, "\($0.value)") })
    }

    @Test(.stoic(seed: 21))
    func channelDroppedReportsThePolicy() async throws {
        let oldest = Channel<Int>(capacity: 1, overflow: .dropOldest, label: "progress")
        try await oldest.send(1)
        try await oldest.send(2)
        let newest = Channel<Int>(capacity: 1, overflow: .dropNewest, label: "first")
        try await newest.send(1)
        try await newest.send(2)
        let drops = StoicTest.events.events(named: "channel.dropped")
        #expect(drops.map(\.label) == ["progress", "first"])
        #expect(drops.map { fields(of: $0)["policy"] } == ["drop_oldest", "drop_newest"])
    }

    @Test(.stoic(seed: 22), .timeLimit(.minutes(1)))
    func semaphoreRejectedReportsAWaiterThatLeft() async throws {
        let semaphore = AsyncSemaphore(permits: 1, label: "pool")
        let hold = TestGate()
        let holder = Task { try await semaphore.withPermit { await hold.wait() } }
        #expect(await eventually { semaphore.availablePermits == 0 })
        let waiter = Task { try await semaphore.withPermit {} }
        #expect(await eventually { semaphore.waiterCount == 1 })
        waiter.cancel()
        _ = try? await waiter.value
        hold.open()
        try await holder.value

        let events = StoicTest.events.events(named: "semaphore.rejected")
        #expect(events.count == 1)
        #expect(events.first?.label == "pool")
        #expect(events.first.map { fields(of: $0)["reason"] } == "cancelled")
        #expect(events.first?.level == .info)
    }

    @Test(.stoic(seed: 23), .timeLimit(.minutes(1)))
    func singleFlightReportsJoiningAndAbandoning() async throws {
        let flight = SingleFlight<Int, Int, CancellationError>(label: "avatar")
        let started = TestGate()
        let operationCancelled = TestGate()
        let operation: @Sendable () async throws(CancellationError) -> Int = {
            started.open()
            do { try await Task.sleep(for: .seconds(3600)) } catch {
                operationCancelled.open()
                throw CancellationError()
            }
            return 1
        }
        let first = Task { try await flight.run(1, operation: operation) }
        await started.wait()
        let second = Task { try await flight.run(1, operation: operation) }
        #expect(await eventually { flight.waiterCount(for: 1) == 2 })
        #expect(StoicTest.events.events(named: "singleflight.joined").map(\.label) == ["avatar"])
        #expect(StoicTest.events.events(named: "singleflight.abandoned").isEmpty, "one caller leaving is not abandonment")

        first.cancel()
        _ = try? await first.value
        #expect(StoicTest.events.events(named: "singleflight.abandoned").isEmpty, "the second caller is still waiting")
        second.cancel()
        _ = try? await second.value
        await operationCancelled.wait()
        let abandoned = StoicTest.events.events(named: "singleflight.abandoned")
        #expect(abandoned.map(\.label) == ["avatar"], "the last caller leaving abandons the flight")
    }

    @Test(.stoic(seed: 24))
    func serviceStartedNamesEachService() async throws {
        let database = ServiceKey<Int>("database")
        let sync = ServiceKey<Int>("sync")
        let graph = try ServiceGraph(label: "app") {
            Provide(database) { _ in 1 }
            Provide(sync, needs: [database.any]) { services in services[database] + 1 }
        }
        try await graph.run { _ in }
        let started = StoicTest.events.events(named: "service.started")
        #expect(started.map { fields(of: $0)["service"] } == ["database", "sync"])
        #expect(started.allSatisfy { $0.label == "app" && $0.level == .debug })
    }

    @Test(.stoic(seed: 25))
    func abandonedCompletedReportsHowLateTheWorkWas() async throws {
        final class Wedge: Sendable {
            let semaphore = DispatchSemaphore(value: 0)
            func block() { semaphore.wait() }   // stoic:allow(blocking-in-async): models a wedged synchronous call, on a Dispatch thread
            func release() { semaphore.signal() }
        }
        let clock = TestClock()
        let wedge = Wedge()
        let label = "completes-late.\(IdempotencyKey.random().rawValue.prefix(8))"
        let task = Task {
            try await withAmbient({ $0.clock = clock.erased }) {
                try await abandoningAfter(.seconds(2), label: label) { () throws(CancellationError) -> Int in
                    wedge.block()
                    return 1
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(2))
        _ = try? await task.value
        #expect(StoicTest.events.events(named: "abandoned.completed").isEmpty, "still wedged")
        await clock.advance(by: .seconds(5))   // it is five seconds late when it finally returns
        wedge.release()

        #expect(await eventually { !StoicTest.events.events(named: "abandoned.completed").isEmpty })
        let completed = StoicTest.events.events(named: "abandoned.completed")
        #expect(completed.map(\.label) == [label])
        #expect(completed.first?.level == .notice)
        #expect(completed.first.map { Set(fields(of: $0).keys) } == ["ran_for", "late_by"])
    }

    @Test(.stoic(seed: 26), .timeLimit(.minutes(1)))
    func scopeFinalizerSlowReportsAFinalizerThatUsedMostOfItsAllowance() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let task = Task {
            await withAmbient({ $0.clock = clock.erased; $0.instrumentation = events }) {
                await withScope(finalizerTimeout: .seconds(5)) { scope in
                    scope.onExit(label: "quick") { _ in }
                    scope.onExit(label: "sluggish") { _ in try await clock.sleep(for: .seconds(3)) }
                }
            }
        }
        // The sluggish finalizer (newest) runs first: 3 s of its 5 s allowance.
        await eventually { clock.pendingDeadlines.count == 2 }
        await clock.advance(to: clock.now.advanced(by: .seconds(3)))
        await task.value

        let slow = events.events(named: "scope.finalizer_slow")
        #expect(slow.count == 1, "only the finalizer that used more than half its allowance")
        #expect(slow.first.map { fields(of: $0)["finalizer"] } == "sluggish")
        #expect(slow.first?.level == .notice)
        #expect(!events.names.contains("scope.finalizer_abandoned"))
    }
}

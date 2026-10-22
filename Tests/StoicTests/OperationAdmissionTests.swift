@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// A backend's capacity, partitioned by urgency, and a local backend's
/// writer lane (design/22, Admission and Writers).
@Suite("Operation admission")
struct OperationAdmissionTests {
    /// Starts `perform` of `operation` at `urgency` in `group`, recording the
    /// stop of a call that ends in failure.
    static func start(
        _ group: inout TaskGroup<String>, _ operation: Backend.Operation, at urgency: Urgency, _ script: Script
    ) {
        group.addTask {
            await withUrgency(urgency) {
                switch await performing(operation, script) {
                case .success: "ok"
                case .failure(let error): error.stopName
                }
            }
        }
    }

    /// The backend's state in the running test's registry.
    static func state(_ backend: Backend) -> BackendState? {
        Ambient.current.backends.existing(backend)
    }

    @Test(.failureMode("design/22", "userInitiated and background calls together fill what they may"))
    func anInteractiveCallStillGetsASlot() async throws {
        let backend = Backend.remote("admission.reserved", capacity: 4)
        let sync = backend.readOnly("sync", length: .long)
        let tap = Script([.hang])
        let run = try await simulated { _ in
            await withTaskGroup(of: String.self) { group in
                for _ in 0..<3 { Self.start(&group, sync, at: .background, Script([.hang])) }
                try? await Ambient.sleep(for: .seconds(1))
                for _ in 0..<3 { Self.start(&group, sync, at: .userInitiated, Script([.hang])) }
                try? await Ambient.sleep(for: .seconds(1))
                let filled = Self.state(backend)!.slots.held
                Self.start(&group, sync, at: .interactive, tap)
                try? await Ambient.sleep(for: .seconds(1))
                let after = Self.state(backend)!.slots.held
                group.cancelAll()
                return (filled, after)
            }
        }
        // Background holds its half; background and userInitiated together
        // hold three of four; the fourth was the tap's, at once.
        #expect(run.value.0 == [2, 0, 1, 0])
        #expect(run.value.1 == [2, 0, 1, 1])
        #expect(tap.count == 1)
    }

    @Test(.failureMode("design/22", "background work fills the backend"))
    func backgroundWorkHoldsAtMostHalf() async throws {
        let backend = Backend.remote("admission.background-half", capacity: 6)
        let sync = backend.readOnly("sync", length: .long)
        let run = try await simulated { _ in
            await withTaskGroup(of: String.self) { group in
                for _ in 0..<10 { Self.start(&group, sync, at: .background, Script([.hang])) }
                try? await Ambient.sleep(for: .seconds(1))
                let gate = Self.state(backend)!.slots
                let reading = (gate.held, gate.waiting)
                group.cancelAll()
                return reading
            }
        }
        #expect(run.value.0 == [3, 0, 0, 0])
        #expect(run.value.1 == [7, 0, 0, 0])
    }

    @Test(.failureMode("design/22", "more than 4 × capacity calls of one urgency wait"))
    func theNextWaiterPastTheLimitIsRefusedAtOnce() async throws {
        let backend = Backend.compute("admission.waiter-limit")   // capacity 1: four waiters
        let infer = backend.readOnly("infer")
        let run = try await simulated { _ in
            await withTaskGroup(of: String.self) { group in
                for _ in 0..<5 { Self.start(&group, infer, at: .utility, Script([.hang])) }
                try? await Ambient.sleep(for: .seconds(1))
                let waiting = Self.state(backend)!.slots.waiting
                let late = await withUrgency(.utility) { await performing(infer, Script([.succeed])) }
                // Another urgency has its own four places.
                let other = Self.state(backend)!.slots.waiting
                group.cancelAll()
                return (waiting, late.error?.stopName, other)
            }
        }
        #expect(run.value.0 == [0, 4, 0, 0])
        #expect(run.value.1 == "bulkhead_full")
        #expect(run.value.2 == [0, 4, 0, 0])
    }

    @Test(.failureMode("design/22", "a slot frees while an interactive and a background call wait"))
    func theInteractiveWaiterGetsTheFreedSlot() async throws {
        let backend = Backend.compute("admission.most-urgent-first")   // one slot
        let infer = backend.readOnly("infer")
        let interactive = Script([.after(.seconds(1), .succeed)])
        let background = Script([.after(.seconds(1), .succeed)])
        let run = try await simulated { _ in
            await withTaskGroup(of: String.self) { group in
                Self.start(&group, infer, at: .utility, Script([.after(.seconds(5), .succeed)]))
                try? await Ambient.sleep(for: .seconds(1))
                Self.start(&group, infer, at: .background, background)   // the first to wait
                try? await Ambient.sleep(for: .seconds(1))
                Self.start(&group, infer, at: .interactive, interactive)
                var results: [String] = []
                for await result in group { results.append(result) }
                return results
            }
        }
        #expect(run.value == ["ok", "ok", "ok"])
        #expect(interactive.calls.map(\.at) == [.seconds(5)])
        #expect(background.calls.map(\.at) == [.seconds(6)])
    }

    /// Holds a waiter in the gap between deciding to wait and queueing.
    private struct StallArrival: FaultPolicy {
        func action(at site: String) -> FaultAction {
            site == "admission.arriving" ? .delay(.seconds(1)) : .proceed
        }
    }

    /// Acquires `rank` on `gate` while stalled in ``StallArrival``, then runs
    /// `mark` and releases. Returns the rejection when the wait ends without a slot.
    private func stalled(
        _ gate: AdmissionGate, rank: Int, clock: TestClock, _ mark: @escaping @Sendable () -> Void
    ) -> Task<Rejection?, Never> {
        Task {
            await withAmbient({ $0.clock = clock.erased; $0.faultPolicy = StallArrival() }) {
                let rejection = await gate.acquire(rank: rank)
                if rejection == nil {
                    mark()
                    gate.release(rank: rank)
                }
                return rejection
            }
        }
    }

    /// One slot, held until `open` opens.
    private func holding(_ gate: AdmissionGate, rank: Int, until open: TestGate) -> Task<Void, Never> {
        Task {
            if await gate.acquire(rank: rank) == nil {
                await open.wait()
                gate.release(rank: rank)
            }
        }
    }

    @Test(.stoic(seed: 220), .timeLimit(.minutes(1)), .failureMode("design/22", "a slot frees while a waiter is on its way to the queue"))
    func aFreedSlotIsKeptForAMoreUrgentWaiterStillOnItsWay() async {
        let gate = AdmissionGate(label: "arriving", capacity: 1, caps: [1, 1, 1, 1], waiterLimit: 4)
        let clock = TestClock()
        let order = OrderLog()
        let open = TestGate()
        let holder = holding(gate, rank: Urgency.utility.rank, until: open)
        #expect(await eventually { gate.held == [0, 1, 0, 0] })
        // Already queued, so a release that only looks at the queues would
        // hand it the slot while the interactive waiter is still arriving.
        let background = Task {
            if await gate.acquire(rank: Urgency.background.rank) == nil {
                order.append("background")
                gate.release(rank: Urgency.background.rank)
            }
        }
        #expect(await eventually { gate.queued == [1, 0, 0, 0] })

        FaultPoint.install()
        defer { FaultPoint.uninstall() }
        let interactive = stalled(gate, rank: Urgency.interactive.rank, clock: clock) { order.append("interactive") }
        await clock.waitForSleepers(count: 1)
        #expect(gate.queued[Urgency.interactive.rank] == 0)
        #expect(gate.waiting[Urgency.interactive.rank] == 1)

        open.open()
        await holder.value
        #expect(gate.held == [0, 0, 0, 0])
        #expect(gate.queued == [1, 0, 0, 0])
        #expect(order.values.isEmpty)

        // A later background call finds the slot free. Queueing it must not
        // hand that slot to either background waiter.
        let late = Task {
            if await gate.acquire(rank: Urgency.background.rank) == nil {
                order.append("late")
                gate.release(rank: Urgency.background.rank)
            }
        }
        #expect(await eventually { gate.queued[Urgency.background.rank] == 2 || gate.held[Urgency.background.rank] == 1 })
        #expect(gate.held == [0, 0, 0, 0])
        #expect(gate.queued == [2, 0, 0, 0])
        #expect(order.values.isEmpty)

        await clock.advance(by: .seconds(1))
        _ = await interactive.value
        _ = await background.value
        _ = await late.value
        #expect(order.values == ["interactive", "background", "late"])
        #expect(gate.isIdle)
    }

    @Test(.stoic(seed: 221), .timeLimit(.minutes(1)), .failureMode("design/22", "a slot frees while a waiter is on its way to the queue"))
    func aLaterArrivalDoesNotTakeASlotKeptForAnEarlierWaiter() async {
        let gate = AdmissionGate(label: "arriving-fifo", capacity: 1, caps: [1, 1, 1, 1], waiterLimit: 4)
        let clock = TestClock()
        let order = OrderLog()
        let open = TestGate()
        let holder = holding(gate, rank: Urgency.utility.rank, until: open)
        #expect(await eventually { gate.held == [0, 1, 0, 0] })

        FaultPoint.install()
        defer { FaultPoint.uninstall() }
        let first = stalled(gate, rank: Urgency.background.rank, clock: clock) { order.append("first") }
        await clock.waitForSleepers(count: 1)
        open.open()
        await holder.value
        #expect(gate.held == [0, 0, 0, 0])

        let second = Task {
            if await gate.acquire(rank: Urgency.background.rank) == nil {
                order.append("second")
                gate.release(rank: Urgency.background.rank)
            }
        }
        #expect(await eventually { gate.queued[Urgency.background.rank] == 1 || gate.held[Urgency.background.rank] == 1 })
        #expect(gate.held == [0, 0, 0, 0])
        #expect(gate.queued == [1, 0, 0, 0])
        #expect(order.values.isEmpty)

        await clock.advance(by: .seconds(1))
        _ = await first.value
        _ = await second.value
        #expect(order.values == ["first", "second"])
        #expect(gate.isIdle)
    }

    @Test(.stoic(seed: 222), .timeLimit(.minutes(1)), .failureMode("design/22", "a waiter on its way to the queue is cancelled"))
    func aWaiterThatLeavesOnItsWayLetsTheNextWaiterThrough() async {
        let gate = AdmissionGate(label: "arriving-leave", capacity: 1, caps: [1, 1, 1, 1], waiterLimit: 4)
        let clock = TestClock()
        let order = OrderLog()
        let open = TestGate()
        let holder = holding(gate, rank: Urgency.utility.rank, until: open)
        #expect(await eventually { gate.held == [0, 1, 0, 0] })
        let background = Task {
            if await gate.acquire(rank: Urgency.background.rank) == nil {
                order.append("background")
                gate.release(rank: Urgency.background.rank)
            }
        }
        #expect(await eventually { gate.queued == [1, 0, 0, 0] })

        FaultPoint.install()
        defer { FaultPoint.uninstall() }
        let interactive = stalled(gate, rank: Urgency.interactive.rank, clock: clock) { order.append("interactive") }
        await clock.waitForSleepers(count: 1)
        open.open()
        await holder.value
        // The slot is free, and kept for the interactive waiter. Cancelling
        // them there must hand it to the background waiter at once.
        #expect(gate.held == [0, 0, 0, 0])
        #expect(order.values.isEmpty)
        interactive.cancel()
        #expect(await eventually { order.values == ["background"] })
        #expect(await interactive.value?.reason == .cancelled)
        await background.value
        #expect(order.values == ["background"])
        #expect(gate.isIdle)
    }

    @Test(.failureMode("design/22", "two writes to a local backend run at once"))
    func aSecondWriteWaitsForTheLaneHoldingNoSlot() async throws {
        let backend = Backend.local("admission.writer-lane")   // capacity 4
        let save = backend.idempotent("save")
        let load = backend.readOnly("load")
        let reads = Script([.after(.seconds(2), .succeed)])
        let run = try await simulated { _ in
            await withTaskGroup(of: String.self) { group in
                for _ in 0..<2 { Self.start(&group, save, at: .userInitiated, Script([.after(.seconds(5), .succeed)])) }
                try? await Ambient.sleep(for: .seconds(1))
                let state = Self.state(backend)!
                let writing = (state.slots.held, state.lane!.held, state.lane!.waiting)
                for _ in 0..<2 { Self.start(&group, load, at: .userInitiated, reads) }
                try? await Ambient.sleep(for: .seconds(1))
                let reading = state.slots.held
                var results: [String] = []
                for await result in group { results.append(result) }
                return (writing, reading, results)
            }
        }
        let (writing, reading, results) = run.value
        #expect(writing.0 == [0, 0, 1, 0])     // one writer holds a slot
        #expect(writing.1 == [0, 0, 1, 0])     // and the lane
        #expect(writing.2 == [0, 0, 1, 0])     // the other waits for the lane
        #expect(reading == [0, 0, 3, 0])       // reads were not held
        #expect(reads.calls.map(\.at) == [.seconds(1), .seconds(1)])   // at once
        #expect(results == ["ok", "ok", "ok", "ok"])
        #expect(run.elapsed == .seconds(10))   // the writes, one after the other
    }

    @Test func aWaitForASlotEndsAtTheDeadlineAndIsNotAnAttempt() async throws {
        let backend = Backend.compute("admission.deadline")
        let infer = backend.readOnly("infer")
        let run = try await simulated { _ in
            await withTaskGroup(of: String.self) { group in
                Self.start(&group, infer, at: .utility, Script([.hang]))
                try? await Ambient.sleep(for: .seconds(1))
                let waited = await withUrgency(.interactive) { await performing(infer, Script([.succeed])) }
                group.cancelAll()
                return waited
            }
        }
        let error = try #require(run.value.error)
        #expect(error.stopName == "deadline_exceeded")
        #expect(error.attempts == 0)
        #expect(error.outcome == .notExecuted)
    }

    @Test func capacityOneGivesEveryUrgencyTheSlot() {
        #expect(Urgency.allByRank.map { OperationPolicy.admission(capacity: 1, urgency: $0) } == [1, 1, 1, 1])
        #expect(Urgency.allByRank.map { OperationPolicy.admission(capacity: 2, urgency: $0) } == [1, 1, 1, 2])
        #expect(Urgency.allByRank.map { OperationPolicy.admission(capacity: 4, urgency: $0) } == [2, 3, 3, 4])
        #expect(Urgency.allByRank.map { OperationPolicy.admission(capacity: 6, urgency: $0) } == [3, 4, 5, 6])
        #expect(Urgency.allByRank.map { OperationPolicy.admission(capacity: 8, urgency: $0) } == [4, 6, 6, 8])
    }
}

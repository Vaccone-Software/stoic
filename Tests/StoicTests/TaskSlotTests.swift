@testable import Stoic
import StoicTesting
import Testing

@Suite("TaskSlot")
@MainActor
struct TaskSlotTests {
    final class Model {
        var delivered: [String] = []
    }

    @Test func onlyTheNewestResultIsDelivered() async throws {
        let model = Model()
        let slot = TaskSlot<String, Never>(label: "search")
        let gates = (0..<3).map { _ in AsyncGate() }
        for index in 0..<3 {
            let gate = gates[index]
            slot.run(for: model) {
                await gate.wait()      // ignores cancellation: finishes late
                return "result \(index)"
            } deliver: { model, result in
                MainActor.assertIsolated()
                model.delivered.append(result.get())
            }
        }
        // Finish them out of order: the newest first, then the stale ones.
        gates[2].open()
        #expect(await eventually { model.delivered == ["result 2"] })
        gates[0].open()
        gates[1].open()
        // The stale work has run to its end (and been dropped) once the slot
        // holds nothing: only then is "still just result 2" a real statement.
        #expect(await eventually { slot.unfinishedCount == 0 })
        #expect(model.delivered == ["result 2"])
    }

    @Test func supersededWorkIsCancelledWithACause() async throws {
        let owner = SlotOwner()
        let slot = TaskSlot<Void, any Error>(label: "slot")
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        slot.run(for: owner) {
            started.open()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                observed.mutate { $0 = CancellationCause.current }
                throw error
            }
        } deliver: { _, _ in }
        await started.wait()
        slot.run(for: owner) {} deliver: { _, _ in }
        #expect(await eventually { observed.value != nil })
        #expect(observed.value == .superseded)
    }

    @Test func exclusiveWorkNeverOverlaps() async throws {
        let owner = SlotOwner()
        let slot = TaskSlot<Void, Never>(label: "microphone")
        let gauge = SendableBox((current: 0, overlapped: false))
        let firstGate = AsyncGate()
        slot.run(for: owner) {
            gauge.mutate { $0.current += 1 }
            await firstGate.wait()          // winding down takes a while
            gauge.mutate { $0.current -= 1 }
        } deliver: { _, _ in }
        #expect(await eventually { gauge.value.current == 1 })
        let done = AsyncGate()
        slot.runExclusively(for: owner) {
            gauge.mutate { $0.overlapped = $0.overlapped || $0.current > 0; $0.current += 1 }
            gauge.mutate { $0.current -= 1 }
        } deliver: { _, _ in done.open() }
        #expect(slot.unfinishedCount == 2)
        // Exclusive work has had its chance to start; it must not have.
        #expect(await holdsThroughout { gauge.value.current == 1 && !gauge.value.overlapped })
        firstGate.open()
        await done.wait()
        #expect(gauge.value.overlapped == false)
    }

    @Test func cancelStopsDelivery() async throws {
        let model = Model()
        let slot = TaskSlot<String, Never>(label: "cancel")
        let gate = AsyncGate()
        slot.run(for: model) {
            await gate.wait()
            return "late"
        } deliver: { model, result in model.delivered.append(result.get()) }
        slot.cancel()
        gate.open()
        // The work has finished (its late answer was dropped) once the slot
        // holds nothing; only then does "nothing delivered" mean something.
        #expect(await eventually { slot.unfinishedCount == 0 })
        #expect(model.delivered.isEmpty)
        #expect(!slot.isRunning)
    }

    @Test func aReleasedSlotCancelsItsWork() async throws {
        let owner = SlotOwner()
        let cancelled = AsyncGate()
        let started = AsyncGate()
        var slot: TaskSlot<Void, any Error>? = TaskSlot(label: "released")
        slot?.run(for: owner) {
            started.open()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled.open()
                throw error
            }
        } deliver: { _, _ in Issue.record("a released slot must not deliver") }
        await started.wait()
        slot = nil
        await cancelled.wait()
    }

    @Test func manyRapidRunsDeliverExactlyTheLast() async throws {
        let model = Model()
        let slot = TaskSlot<String, Never>(label: "rapid")
        for index in 0..<500 {
            slot.run(for: model) {
                await Task.yield()
                return "\(index)"
            } deliver: { model, result in model.delivered.append(result.get()) }
            if index % 7 == 0 { await Task.yield() }
        }
        #expect(await eventually { slot.unfinishedCount == 0 })
        #expect(model.delivered.last == "499")
        #expect(model.delivered.count <= 500)
        // Deliveries only ever move forward: never an older one after a newer.
        let numbers = model.delivered.compactMap(Int.init)
        #expect(numbers == numbers.sorted())
    }

    // MARK: The owner goes, the work goes

    /// The documented shape: a view model owns its slot, its work captures
    /// what it needs, and `deliver` gets the model from the slot.
    @MainActor final class SearchModel {
        let search = TaskSlot<Int, any Error>(label: "search")
        let api: SearchAPI
        var hits = 0

        init(api: SearchAPI) { self.api = api }

        func queryChanged() {
            search.run(for: self) { [api] in
                try await api.search()
            } deliver: { @MainActor model, result in
                model.hits = (try? result.get()) ?? 0
            }
        }
    }

    final class SearchAPI: Sendable {
        let started = SendableBox(false)
        let cancelled = SendableBox(false)

        func search() async throws -> Int {
            started.mutate { $0 = true }
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled.mutate { $0 = true }
                throw error
            }
            return 1
        }
    }

    @Test(.timeLimit(.minutes(1)), .failureMode("design/03", "the owner of a TaskSlot's work goes away"))
    func aReleasedOwnerTakesItsInFlightWorkWithIt() async {
        let api = SearchAPI()
        var model: SearchModel? = SearchModel(api: api)
        weak let watched = model
        model?.queryChanged()
        await waitUntil { api.started.value }
        model = nil
        // Previously `deliver` captured the model, the running work held
        // `deliver`, and the slot held the work: the model never went.
        #expect(watched == nil, "the slot's work kept its owner alive")
        #expect(await eventually { api.cancelled.value }, "the owner went but its work ran on")
    }

    @Test func nothingIsDeliveredToAnOwnerThatHasGone() async {
        let slot = TaskSlot<Int, Never>(label: "orphaned")
        let gate = AsyncGate()
        var owner: SlotOwner? = SlotOwner()
        weak let watched = owner
        slot.run(for: owner!) {
            await gate.wait()   // ignores cancellation, and outlives the owner
            return 1
        } deliver: { _, _ in Issue.record("delivered to an owner that had gone") }
        owner = nil
        #expect(watched == nil)
        gate.open()
        #expect(await eventually { slot.unfinishedCount == 0 })
    }
}

@Suite("TaskSlot: review fixes")
@MainActor
struct TaskSlotReviewTests {
    /// Work that ignores cancellation and records how many copies run at once.
    final class Microphone: Sendable {
        let live = SendableBox((now: 0, peak: 0))
        func use(until gate: TestGate) async {
            live.mutate { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            await gate.wait()
            live.mutate { $0.now -= 1 }
        }
    }

    @Test func exclusiveWorkWaitsForEveryEarlierPiece() async {
        let slot = TaskSlot<Void, Never>(label: "mic")
        let microphone = Microphone()
        let first = TestGate(), second = TestGate()
        slot.run(for: microphone) { await microphone.use(until: first) } deliver: { _, _ in }
        await eventually { microphone.live.value.now == 1 }
        slot.run(for: microphone) { await microphone.use(until: second) } deliver: { _, _ in }   // supersedes, overlapping on purpose
        await eventually { microphone.live.value.now == 2 }
        let done = TestGate()
        slot.runExclusively(for: microphone) {
            await microphone.use(until: TestGate.alreadyOpen)
        } deliver: { _, _ in done.open() }
        second.open()
        #expect(await eventually { microphone.live.value.now == 1 }, "the second work ended")
        #expect(await holdsThroughout { microphone.live.value.now == 1 }, "the first work is still running; exclusive work must not start")
        first.open()
        await done.wait()
        #expect(microphone.live.value.peak == 2, "previously 3: exclusive work overlapped the first")
    }

    @Test func exclusiveWorkWaitsForCancelledWork() async {
        let slot = TaskSlot<Void, Never>(label: "mic")
        let microphone = Microphone()
        let first = TestGate()
        slot.run(for: microphone) { await microphone.use(until: first) } deliver: { _, _ in }
        await eventually { microphone.live.value.now == 1 }
        slot.cancel()
        let done = TestGate()
        slot.runExclusively(for: microphone) { await microphone.use(until: TestGate.alreadyOpen) } deliver: { _, _ in done.open() }
        #expect(await holdsThroughout { microphone.live.value.peak == 1 }, "exclusive work must wait for the cancelled work")
        first.open()
        await done.wait()
        #expect(microphone.live.value.peak == 1, "previously overlapped: cancel() forgot the cancelled work")
    }

    /// Runs from many actors at once: each call is serialised with its own
    /// actor's deliveries, not with the others'.
    @Test func concurrentRunsLeaveNothingUncancelled() async {
        let slot = TaskSlot<Void, Never>(label: "busy")
        let owner = SlotOwner()
        await withTaskGroup { group in
            for _ in 0..<200 {
                group.addTask {
                    await SlotCaller().run(slot, for: owner) {
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                    } deliver: { _, _ in }
                }
            }
        }
        await slot.cancelAndWait()
        #expect(slot.unfinishedCount == 0, "previously most tasks were never registered and ran forever")
    }

    /// Work outlives the `withTimeout` it was started in, so it must not
    /// carry that deadline: it would run already expired.
    @Test func workStartedInsideAnEndedTimeoutRunsWithoutItsDeadline() async {
        let clock = TestClock()
        let slot = TaskSlot<Bool, Never>(label: "outlives")
        let owner = SlotOwner()
        let gate = AsyncGate()
        let delivered = AsyncGate()
        let outcome = SendableBox<Bool?>(nil)
        await withTestAmbient(clock: clock) {
            await withTimeout(.seconds(1)) {
                slot.run(for: owner) {
                    await gate.wait()
                    return Deadline.current == nil
                } deliver: { _, result in
                    outcome.mutate { $0 = result.get() }
                    delivered.open()
                }
            }
            await clock.advance(by: .seconds(5))   // the timeout's instant is long past
            gate.open()
            await delivered.wait()
        }
        #expect(outcome.value == true, "the work inherited the caller's deadline")
    }

    @MainActor final class SearchModel {
        let search = TaskSlot<[String], Never>(label: "search")
        var hits: [String] = []
        func queryChanged(_ query: String) {
            // The documented example: deliver touches main-actor state.
            search.run(for: self) { [query] } deliver: { @MainActor model, result in model.hits = result.get() }
        }
    }

    @Test func theDocumentedMainActorExampleCompilesAndDelivers() async {
        let model = SearchModel()
        model.queryChanged("swift")
        await eventually { model.hits == ["swift"] }
        #expect(model.hits == ["swift"])
    }
}

/// What a ``TaskSlot``'s work is for, in tests whose deliveries need no
/// state of their own. Keep it alive for as long as a delivery is expected:
/// a slot delivers nothing once its owner has gone.
final class SlotOwner: Sendable {}

/// An actor to call a ``TaskSlot`` from, for a test that is not on one: a
/// slot must be called on an actor, which runs its deliveries. The work keeps
/// the isolation it was written with (nonisolated, in such a test).
actor SlotCaller {
    func run<Success: Sendable, Failure: Error>(
        _ slot: TaskSlot<Success, Failure>,
        for owner: SlotOwner,
        _ operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
        deliver: sending @escaping (SlotOwner, Result<Success, Failure>) -> Void
    ) {
        slot.run(for: owner, operation, deliver: deliver)
    }
}

extension TestGate {
    static let alreadyOpen: TestGate = {
        let gate = TestGate()
        gate.open()
        return gate
    }()
}

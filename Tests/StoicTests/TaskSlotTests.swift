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
            slot.run {
                await gate.wait()      // ignores cancellation: finishes late
                return "result \(index)"
            } deliver: { result in
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
        let slot = TaskSlot<Void, any Error>(label: "slot")
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        slot.run {
            started.open()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                observed.mutate { $0 = CancellationCause.current }
                throw error
            }
        } deliver: { _ in }
        await started.wait()
        slot.run {} deliver: { _ in }
        #expect(await eventually { observed.value != nil })
        #expect(observed.value == .superseded)
    }

    @Test func exclusiveWorkNeverOverlaps() async throws {
        let slot = TaskSlot<Void, Never>(label: "microphone")
        let gauge = SendableBox((current: 0, overlapped: false))
        let firstGate = AsyncGate()
        slot.run {
            gauge.mutate { $0.current += 1 }
            await firstGate.wait()          // winding down takes a while
            gauge.mutate { $0.current -= 1 }
        } deliver: { _ in }
        #expect(await eventually { gauge.value.current == 1 })
        let done = AsyncGate()
        slot.runExclusively {
            gauge.mutate { $0.overlapped = $0.overlapped || $0.current > 0; $0.current += 1 }
            gauge.mutate { $0.current -= 1 }
        } deliver: { _ in done.open() }
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
        slot.run {
            await gate.wait()
            return "late"
        } deliver: { model.delivered.append($0.get()) }
        slot.cancel()
        gate.open()
        // The work has finished (its late answer was dropped) once the slot
        // holds nothing; only then does "nothing delivered" mean something.
        #expect(await eventually { slot.unfinishedCount == 0 })
        #expect(model.delivered.isEmpty)
        #expect(!slot.isRunning)
    }

    @Test func aReleasedSlotCancelsItsWork() async throws {
        let cancelled = AsyncGate()
        let started = AsyncGate()
        var slot: TaskSlot<Void, any Error>? = TaskSlot(label: "released")
        slot?.run {
            started.open()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled.open()
                throw error
            }
        } deliver: { _ in Issue.record("a released slot must not deliver") }
        await started.wait()
        slot = nil
        await cancelled.wait()
    }

    @Test func manyRapidRunsDeliverExactlyTheLast() async throws {
        let model = Model()
        let slot = TaskSlot<String, Never>(label: "rapid")
        for index in 0..<500 {
            slot.run {
                await Task.yield()
                return "\(index)"
            } deliver: { model.delivered.append($0.get()) }
            if index % 7 == 0 { await Task.yield() }
        }
        #expect(await eventually { slot.unfinishedCount == 0 })
        #expect(model.delivered.last == "499")
        #expect(model.delivered.count <= 500)
        // Deliveries only ever move forward: never an older one after a newer.
        let numbers = model.delivered.compactMap(Int.init)
        #expect(numbers == numbers.sorted())
    }
}

@Suite("TaskSlot: review fixes")
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
        slot.run { await microphone.use(until: first) } deliver: { _ in }
        await eventually { microphone.live.value.now == 1 }
        slot.run { await microphone.use(until: second) } deliver: { _ in }   // supersedes, overlapping on purpose
        await eventually { microphone.live.value.now == 2 }
        let done = TestGate()
        slot.runExclusively {
            await microphone.use(until: TestGate.alreadyOpen)
        } deliver: { _ in done.open() }
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
        slot.run { await microphone.use(until: first) } deliver: { _ in }
        await eventually { microphone.live.value.now == 1 }
        slot.cancel()
        let done = TestGate()
        slot.runExclusively { await microphone.use(until: TestGate.alreadyOpen) } deliver: { _ in done.open() }
        #expect(await holdsThroughout { microphone.live.value.peak == 1 }, "exclusive work must wait for the cancelled work")
        first.open()
        await done.wait()
        #expect(microphone.live.value.peak == 1, "previously overlapped: cancel() forgot the cancelled work")
    }

    @Test func concurrentRunsLeaveNothingUncancelled() async {
        let slot = TaskSlot<Void, Never>(label: "busy")
        await withTaskGroup { group in
            for _ in 0..<200 {
                group.addTask {
                    slot.run {
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                    } deliver: { _ in }
                }
            }
        }
        await slot.cancelAndWait()
        #expect(slot.unfinishedCount == 0, "previously most tasks were never registered and ran forever")
    }

    @MainActor final class SearchModel {
        let search = TaskSlot<[String], Never>(label: "search")
        var hits: [String] = []
        func queryChanged(_ query: String) {
            // The documented example: deliver touches main-actor state.
            search.run { [query] } deliver: { @MainActor result in self.hits = result.get() }
        }
    }

    @Test @MainActor func theDocumentedMainActorExampleCompilesAndDelivers() async {
        let model = SearchModel()
        model.queryChanged("swift")
        await eventually { model.hits == ["swift"] }
        #expect(model.hits == ["swift"])
    }
}

extension TestGate {
    static let alreadyOpen: TestGate = {
        let gate = TestGate()
        gate.open()
        return gate
    }()
}

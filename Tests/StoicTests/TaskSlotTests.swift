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
        while slot.isRunning { await Task.yield() }
        gates[0].open()
        gates[1].open()
        for _ in 0..<100 { await Task.yield() }
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
        while slot.isRunning { await Task.yield() }
        for _ in 0..<100 where observed.value == nil { await Task.yield() }
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
        for _ in 0..<10 { await Task.yield() }
        let done = AsyncGate()
        slot.runExclusively {
            gauge.mutate { $0.overlapped = $0.overlapped || $0.current > 0; $0.current += 1 }
            gauge.mutate { $0.current -= 1 }
        } deliver: { _ in done.open() }
        for _ in 0..<10 { await Task.yield() }
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
        for _ in 0..<100 { await Task.yield() }
        #expect(model.delivered.isEmpty)
        #expect(!slot.isRunning)
    }

    @Test func aReleasedSlotCancelsItsWork() async throws {
        let cancelled = AsyncGate()
        var slot: TaskSlot<Void, any Error>? = TaskSlot(label: "released")
        slot?.run {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled.open()
                throw error
            }
        } deliver: { _ in Issue.record("a released slot must not deliver") }
        for _ in 0..<10 { await Task.yield() }
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
        while slot.isRunning { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        #expect(model.delivered.last == "499")
        #expect(model.delivered.count <= 500)
        // Deliveries only ever move forward: never an older one after a newer.
        let numbers = model.delivered.compactMap(Int.init)
        #expect(numbers == numbers.sorted())
    }
}

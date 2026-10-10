@testable import Stoic
import StoicTesting
import Testing

/// design/03: "across random sequences of run, completion and cancellation,
/// deliver is called only with the newest task's result and at most once per
/// task" and, for runExclusively, "never overlap".
///
/// Everything runs on the main actor, so the driver and every `deliver`
/// are serialised: when a delivery happens, the driver's idea of which run
/// is newest is exact, and the check needs no tolerance.
@Suite("TaskSlot: random sequences")
@MainActor
struct TaskSlotPropertyTests {
    enum Kind: CaseIterable {
        case quick       // finishes after a yield
        case patient     // runs until cancelled
        case stubborn    // ignores cancellation until its gate opens
    }

    /// What the work and the deliveries did, for the invariants to read.
    final class Log {
        var newest: Int?                      // the run `deliver` is allowed to answer for
        var deliveries: [Int: Int] = [:]      // run -> times delivered
        var wrongDeliveries: [String] = []
        var live = Set<Int>()                 // runs whose work is executing
        var overlaps: [String] = []
        var started: [Int] = []
        var gates: [Int: TestGate] = [:]
        var trace: [String] = []
    }

    @Test(.stoic(seed: 303), .timeLimit(.minutes(1)), arguments: Array(0..<10))
    func randomSequencesKeepTheSlotsPromises(round: Int) async {
        var generator = Ambient.current.random.generator(discriminator: UInt64(round))
        let slot = TaskSlot<Int, any Error>(label: "property-\(round)")
        let log = Log()
        var next = 0
        var waiters: [Task<Void, Never>] = []

        func start(exclusive: Bool, forcing forced: Kind? = nil) {
            let index = next
            next += 1
            let kind = forced ?? Kind.allCases.randomElement(using: &generator)!
            let gate = TestGate()
            log.gates[index] = gate
            log.newest = index
            log.trace.append("\(exclusive ? "runExclusively" : "run") #\(index) \(kind)")
            let work: @isolated(any) () async throws -> Int = {
                if exclusive, let earlier = log.live.first(where: { $0 < index }) {
                    log.overlaps.append("exclusive #\(index) started while #\(earlier) was still running")
                }
                log.live.insert(index)
                log.started.append(index)
                defer { log.live.remove(index) }
                switch kind {
                case .quick: await Task.yield()
                case .patient: try await Task.sleep(for: .seconds(60))
                case .stubborn: await gate.wait()
                }
                return index
            }
            let deliver: (Result<Int, any Error>) -> Void = { result in
                log.deliveries[index, default: 0] += 1
                if log.newest != index {
                    log.wrongDeliveries.append("#\(index) delivered while the newest was \(log.newest.map(String.init) ?? "nothing")")
                }
                if case .failure = result, kind != .patient {
                    log.wrongDeliveries.append("#\(index) (\(kind)) delivered a failure")
                }
            }
            if exclusive {
                slot.runExclusively(work, deliver: deliver)
            } else {
                slot.run(work, deliver: deliver)
            }
        }

        for _ in 0..<(40 * testScale) {
            switch Int.random(in: 0..<10, using: &generator) {
            case 0..<3: start(exclusive: false)
            case 3..<5: start(exclusive: true)
            case 5:
                log.trace.append("cancel")
                log.newest = nil
                slot.cancel()
            case 6:
                log.trace.append("cancelAndWait")
                // The cancellation happens when this task first runs, with
                // no suspension before it, so the model moves at that moment.
                waiters.append(Task {
                    log.newest = nil
                    await slot.cancelAndWait()
                })
                await Task.yield()
            case 7:
                // Some stubborn work finally lets go.
                if let gate = log.gates.values.randomElement(using: &generator) { gate.open() }
            default:
                for _ in 0..<Int.random(in: 1...4, using: &generator) { await Task.yield() }
            }
            // A cancelAndWait that has been issued must not stop later runs
            // from being delivered, so the model keeps going.
        }

        // Whatever happened, the newest work delivers: the sequence ends with
        // one more run, and its delivery is the positive signal that the
        // absence checks below are not vacuous.
        // (Stubborn work lets go first: exclusive work waits for all of it.)
        for gate in log.gates.values { gate.open() }
        let last = next
        start(exclusive: Bool.random(using: &generator), forcing: .quick)
        let delivered = await eventually { log.deliveries[last] == 1 }
        #expect(delivered, "the newest run never delivered in round \(round): \(log.trace.joined(separator: ", "))")

        // Let everything go, then require the slot to wind down completely.
        for gate in log.gates.values { gate.open() }
        await slot.cancelAndWait()
        for waiter in waiters { await waiter.value }
        let drained = await eventually { slot.unfinishedCount == 0 && log.live.isEmpty }

        let context = "round \(round): \(log.trace.joined(separator: ", "))"
        #expect(log.wrongDeliveries.isEmpty, "\(log.wrongDeliveries.joined(separator: "; ")) in \(context)")
        #expect(log.overlaps.isEmpty, "\(log.overlaps.joined(separator: "; ")) in \(context)")
        #expect(log.deliveries.values.allSatisfy { $0 == 1 }, "a run delivered twice in \(context)")
        #expect(drained, "unfinishedCount \(slot.unfinishedCount) after cancelAndWait in \(context)")
        #expect(!slot.isRunning)
        #expect(await stoicTasksStillRunning().isEmpty, "a slot task outlived cancelAndWait in \(context)")
    }
}

@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// A gate whose wait ends when the gate opens or the waiting task is
/// cancelled: an operation that a flight can cancel.
final class CancellableGate: Sendable {
    private struct State {
        var open = false
        var nextID: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
        var cancelledEarly: Set<UInt64> = []
    }

    private let state = Mutex(State())

    func wait() async throws {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Next { case resume, cancel, wait }
                let next = state.withLock { state -> Next in
                    if state.cancelledEarly.remove(id) != nil { return .cancel }
                    if state.open { return .resume }
                    state.waiters[id] = continuation
                    return .wait
                }
                switch next {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// design/03: "SingleFlight reference-counting model test." A model of the
/// flights (which callers wait on which key's operation) is compared with
/// the real group after every random operation.
@Suite("SingleFlight: reference model")
struct SingleFlightModelTests {
    enum Outcome: Equatable, Sendable {
        case value(Int)                       // the serial of the run that produced it
        case rejected(Rejection.Reason)
    }

    struct Flight {
        let serial: Int
        var callers: [Int] = []
    }

    struct Model {
        var flights: [String: Flight] = [:]
        var runs = 0
        var cancelled: Set<Int> = []         // serials of flights cancelled because every caller left
        var landed: Set<Int> = []

        /// Returns whether this caller started the operation.
        mutating func join(_ id: Int, key: String) {
            if flights[key] != nil {
                flights[key]!.callers.append(id)
            } else {
                runs += 1
                flights[key] = Flight(serial: runs, callers: [id])
            }
        }

        mutating func leave(_ id: Int, key: String) {
            flights[key]!.callers.removeAll { $0 == id }
            if flights[key]!.callers.isEmpty {
                cancelled.insert(flights[key]!.serial)
                flights[key] = nil
            }
        }

        mutating func land(key: String) -> Flight {
            let flight = flights.removeValue(forKey: key)!
            landed.insert(flight.serial)
            return flight
        }
    }

    final class Caller: Sendable {
        let id: Int
        let key: String
        let deadline: Duration?
        let task = SendableBox<Task<Outcome, Never>?>(nil)
        let done = SendableBox(false)
        init(id: Int, key: String, deadline: Duration?) {
            self.id = id; self.key = key; self.deadline = deadline
        }

        /// What the caller got. A caller the model says is finished but the
        /// group never answered fails the test instead of hanging it.
        var outcome: Outcome {
            get async {
                if await !eventually(within: .seconds(5), { done.value }) {
                    Issue.record("caller \(id) (\(key)) was never answered")
                    task.value?.cancel()
                }
                return await task.value!.value
            }
        }
    }

    /// The operations the flights run, observable.
    final class World: Sendable {
        let gates = SendableBox<[Int: CancellableGate]>([:])
        let started = SendableBox<[Int]>([])
        let cancelled = SendableBox<Set<Int>>([])
        let counter = SendableBox(0)

        func gate(_ serial: Int) -> CancellableGate {
            gates.mutate { gates in
                if let gate = gates[serial] { return gate }
                let gate = CancellableGate()
                gates[serial] = gate
                return gate
            }
        }
    }

    @Test(.stoic(seed: 404), .timeLimit(.minutes(1)),
          .failureMode("design/03", "two single-flight waiters, the first cancels"),
          .failureMode("design/03", "every single-flight waiter cancels"), arguments: Array(0..<8))
    func randomOperationsMatchTheReferenceCountingModel(round: Int) async {
        var generator = Ambient.current.random.generator(discriminator: UInt64(round))
        let flight = SingleFlight<String, Int, CancellationError>(label: "model-\(round)")
        let world = World()
        let clock = TestClock()
        let keys = ["a", "b", "c"]
        var model = Model()
        var callers: [Int: Caller] = [:]
        var now = Duration.zero
        var trace: [String] = []

        func settle(_ step: String) async -> Bool {
            let converged = await eventually(within: .seconds(5)) {
                flight.flightCount == model.flights.count
                    && keys.allSatisfy { flight.waiterCount(for: $0) == model.flights[$0]?.callers.count ?? 0 }
                    && world.started.value.count == model.runs
                    && world.cancelled.value == model.cancelled
            }
            if !converged {
                Issue.record("""
                    round \(round) after \(step): the group diverged from the model.
                    model: flights \(model.flights.mapValues { "run \($0.serial) callers \($0.callers)" }) runs \(model.runs) cancelled \(model.cancelled.sorted())
                    real:  flights \(flight.flightCount) waiters \(keys.map { "\($0)=\(flight.waiterCount(for: $0))" }) runs \(world.started.value.count) cancelled \(world.cancelled.value.sorted())
                    trace: \(trace.joined(separator: ", "))
                    """)
            }
            return converged
        }

        func abandon() {
            for caller in callers.values { caller.task.value?.cancel() }
            for gate in world.gates.value.values { gate.open() }
        }

        await withAmbient({ $0.clock = clock.erased }) {
            var diverged = false
            for step in 0..<(60 * testScale) {
                switch Int.random(in: 0..<12, using: &generator) {
                case 0..<5:   // a caller joins (or starts) a flight
                    let id = callers.count
                    let key = keys.randomElement(using: &generator)!
                    let patience: Duration? = Int.random(in: 0..<4, using: &generator) == 0
                        ? .seconds(Int.random(in: 1...10, using: &generator)) : nil
                    let deadline = patience.map { now + $0 }   // absolute, on the test clock
                    let caller = Caller(id: id, key: key, deadline: deadline)
                    callers[id] = caller
                    model.join(id, key: key)
                    trace.append("join \(id) \(key)\(patience.map { " for \($0)" } ?? "")")
                    let limit = patience.map { Deadline.after($0, clock: clock.erased) }
                    caller.task.mutate {
                        $0 = Task {
                            defer { caller.done.mutate { $0 = true } }
                            return await Deadline.$stored.withValue(limit) {
                                do throws(PolicyError<CancellationError>) {
                                    return .value(try await flight.run(key) { () async throws(CancellationError) -> Int in
                                        let serial = world.counter.mutate { $0 += 1; return $0 }
                                        world.started.mutate { $0.append(serial) }
                                        do {
                                            try await world.gate(serial).wait()
                                        } catch {
                                            world.cancelled.mutate { _ = $0.insert(serial) }
                                            throw CancellationError()
                                        }
                                        return serial
                                    })
                                } catch {
                                    return .rejected(error.rejection?.reason ?? .cancelled)
                                }
                            }
                        }
                    }
                case 5..<7:   // a caller gives up
                    let waiting = model.flights.flatMap { key, flight in flight.callers.map { (key, $0) } }
                    guard let (key, id) = waiting.randomElement(using: &generator) else { continue }
                    trace.append("cancel \(id)")
                    callers[id]!.task.value!.cancel()
                    #expect(await callers[id]!.outcome == .rejected(.cancelled))
                    model.leave(id, key: key)
                case 7..<9:   // an operation finishes
                    guard let key = model.flights.keys.sorted().randomElement(using: &generator) else { continue }
                    trace.append("land \(key)")
                    let landed = model.land(key: key)
                    world.gate(landed.serial).open()
                    for id in landed.callers {
                        #expect(await callers[id]!.outcome == .value(landed.serial), "caller \(id) must get the flight's own value")
                    }
                default:      // time passes
                    let by = Duration.seconds(Int.random(in: 1...6, using: &generator))
                    now += by
                    trace.append("advance to \(now)")
                    await clock.advance(by: by)
                    // Callers whose own deadline has passed leave; the flight goes on for the rest.
                    let due = model.flights.flatMap { key, flight in
                        flight.callers.filter { (callers[$0]!.deadline ?? .seconds(100_000)) <= now }.map { (key, $0) }
                    }
                    for (key, id) in due.sorted(by: { $0.1 < $1.1 }) {
                        #expect(await callers[id]!.outcome == .rejected(.deadlineExceeded), "caller \(id) past its deadline")
                        model.leave(id, key: key)
                    }
                }
                guard await settle("step \(step) (\(trace.last ?? ""))") else { diverged = true; break }
            }
            if diverged { abandon() }

            // Quiescence: land what is left; nothing may remain in flight.
            for key in model.flights.keys.sorted() where !diverged {
                let landed = model.land(key: key)
                world.gate(landed.serial).open()
                for id in landed.callers { #expect(await callers[id]!.outcome == .value(landed.serial)) }
            }
            for caller in callers.values { _ = await caller.outcome }
            if !diverged { _ = await settle("quiescence") }
            #expect(flight.flightCount == 0)
            #expect(keys.allSatisfy { flight.waiterCount(for: $0) == 0 })
            // An operation is cancelled exactly when its last caller left: no
            // landed flight was cancelled, no abandoned one kept running.
            #expect(world.cancelled.value.isDisjoint(with: model.landed))
            #expect(await stoicTasksStillRunning().isEmpty)
        }
    }
}


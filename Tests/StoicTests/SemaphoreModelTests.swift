@testable import Stoic
import StoicTesting
import Testing

/// design/03: "Model-based tests for AsyncSemaphore against a reference FIFO
/// model under random arrivals, cancellations and deadlines; invariant:
/// permits in use + available = capacity, at every step."
///
/// The driver applies one random operation at a time to the real semaphore
/// and to a model that is a few lines of arrays, then waits until the real
/// thing has settled and compares the two. Operations are sequential, so the
/// order tasks reach the queue is known and FIFO can be checked exactly; the
/// scheduler still decides when each woken task runs, which is why the
/// comparison waits for the state to converge instead of reading it once.
@Suite("AsyncSemaphore: reference model")
struct SemaphoreModelTests {
    /// What the semaphore must do, written as plainly as possible.
    struct Model {
        let capacity: Int
        var holders: [Int] = []
        var queue: [Int] = []
        var deadlines: [Int: Duration] = [:]

        var available: Int { capacity - holders.count }

        /// A newcomer never overtakes a waiter, even when a permit is free.
        mutating func arrive(_ id: Int, deadline: Duration?) {
            if available > 0, queue.isEmpty {
                holders.append(id)
            } else {
                queue.append(id)
                deadlines[id] = deadline
            }
        }

        /// The permit passes directly to the head of the queue.
        mutating func release(_ id: Int) {
            holders.removeAll { $0 == id }
            if !queue.isEmpty {
                let next = queue.removeFirst()
                deadlines[next] = nil
                holders.append(next)
            }
        }

        mutating func leave(_ id: Int) {
            queue.removeAll { $0 == id }
            deadlines[id] = nil
        }
    }

    enum Outcome: Equatable, Sendable {
        case completed
        case rejected(Rejection.Reason)
    }

    /// One task asking for a permit, and what it has seen so far.
    final class Client: Sendable {
        let id: Int
        let gate = TestGate()
        let entered = SendableBox(false)
        let task = SendableBox<Task<Outcome, Never>?>(nil)

        init(id: Int) { self.id = id }

        let done = SendableBox(false)

        /// What the task got. A task the model says is finished but the
        /// semaphore never answered fails the test instead of hanging it.
        var outcome: Outcome {
            get async {
                if await !eventually(within: .seconds(5), { done.value }) {
                    Issue.record("task \(id) was never answered")
                    task.value?.cancel()
                    gate.open()
                }
                return await task.value!.value
            }
        }
    }

    @Test(.stoic(seed: 101), .timeLimit(.minutes(1)),
          .failureMode("design/03", "a semaphore waiter is cancelled while queued"),
          .failureMode("design/03", "a semaphore waiter's deadline passes while queued"), arguments: Array(0..<8))
    func randomOperationsMatchTheReferenceModel(round: Int) async {
        var generator = Ambient.current.random.generator(discriminator: UInt64(round))
        let capacity = Int.random(in: 1...4, using: &generator)
        let semaphore = AsyncSemaphore(permits: capacity, label: "model-\(round)")
        let clock = TestClock()
        var model = Model(capacity: capacity)
        var clients: [Int: Client] = [:]
        var now = Duration.zero

        func settle(_ step: String) async -> Bool {
            let converged = await eventually(within: .seconds(5)) {
                semaphore.waiterCount == model.queue.count
                    && semaphore.availablePermits == model.available
                    && clients.values.allSatisfy { ($0.entered.value && !$0.gate.isOpen) == model.holders.contains($0.id) }
            }
            if !converged {
                let entered = clients.values.filter { $0.entered.value && !$0.gate.isOpen }.map(\.id).sorted()
                Issue.record("""
                    round \(round) (capacity \(capacity)) after \(step): the semaphore diverged from the model.
                    model: holders \(model.holders.sorted()) queue \(model.queue) available \(model.available)
                    real:  holders \(entered) waiters \(semaphore.waiterCount) available \(semaphore.availablePermits)
                    """)
            }
            return converged
        }

        /// After a divergence nothing can be trusted: release everything so
        /// the test ends with its failure instead of hanging on it.
        func abandon() {
            for client in clients.values {
                client.gate.open()
                client.task.value?.cancel()
            }
        }

        await withAmbient({ $0.clock = clock.erased }) {
            var trace: [String] = []
            var diverged = false
            for step in 0..<(60 * testScale) {
                let choice = Int.random(in: 0..<12, using: &generator)
                switch choice {
                case 0..<4:   // arrive, sometimes with a deadline
                    let id = clients.count
                    let client = Client(id: id)
                    clients[id] = client
                    let deadline: Duration? = Int.random(in: 0..<3, using: &generator) == 0
                        ? now + .seconds(Int.random(in: 1...20, using: &generator)) : nil
                    model.arrive(id, deadline: deadline)
                    trace.append("arrive \(id)\(deadline.map { " by \($0)" } ?? "")")
                    let limit = deadline.map { Deadline.after($0 - now, clock: clock.erased) }
                    client.task.mutate {
                        $0 = Task {
                            defer { client.done.mutate { $0 = true } }
                            return await Deadline.$stored.withValue(limit) {
                                do throws(PolicyError<Never>) {
                                    try await semaphore.withPermit { () async -> Void in
                                        client.entered.mutate { $0 = true }
                                        await client.gate.wait()
                                    }
                                    return .completed
                                } catch {
                                    return .rejected(error.rejection?.reason ?? .cancelled)
                                }
                            }
                        }
                    }
                case 4..<7 where !model.holders.isEmpty:   // a holder finishes
                    let id = model.holders.randomElement(using: &generator)!
                    trace.append("release \(id)")
                    clients[id]!.gate.open()
                    #expect(await clients[id]!.outcome == .completed, "holder \(id) must finish normally")
                    model.release(id)
                case 7..<9 where !model.queue.isEmpty:   // a waiter is cancelled
                    let id = model.queue.randomElement(using: &generator)!
                    trace.append("cancel waiter \(id)")
                    clients[id]!.task.value!.cancel()
                    #expect(await clients[id]!.outcome == .rejected(.cancelled), "waiter \(id) cancelled while queued")
                    model.leave(id)
                case 9 where !model.holders.isEmpty:   // cancelling a granted task changes nothing
                    let id = model.holders.randomElement(using: &generator)!
                    trace.append("cancel holder \(id)")
                    clients[id]!.task.value!.cancel()
                case 10..<12:   // time passes: queued waiters whose deadline passed leave
                    let step = Duration.seconds(Int.random(in: 1...8, using: &generator))
                    now += step
                    trace.append("advance to \(now)")
                    await clock.advance(by: step)
                    let expired = model.queue.filter { model.deadlines[$0].map { $0 <= now } ?? false }
                    for id in expired {
                        #expect(await clients[id]!.outcome == .rejected(.deadlineExceeded), "waiter \(id) past its deadline")
                        model.leave(id)
                    }
                default:
                    continue
                }
                guard await settle("step \(step) (\(trace.last ?? ""))") else {
                    Issue.record("trace: \(trace.joined(separator: ", "))")
                    diverged = true
                    break
                }
                // Invariants that hold at every settled step.
                #expect(semaphore.availablePermits + model.holders.count == capacity, "permits in use + available = capacity")
                #expect(semaphore.availablePermits == 0 || semaphore.waiterCount == 0, "a free permit with a waiter is a lost wakeup")
            }

            if diverged { abandon() }

            // Quiescence: finish every holder (each hand-off wakes the next
            // waiter), then cancel what remains. Nothing may be left behind.
            while !diverged, let id = model.holders.first {
                clients[id]!.gate.open()
                _ = await clients[id]!.outcome
                model.release(id)
                guard await settle("draining \(id)") else { abandon(); break }
            }
            #expect(diverged || model.queue.isEmpty, "draining the holders must serve every waiter that is still queued")
            for client in clients.values { _ = await client.outcome }
            #expect(semaphore.availablePermits == capacity)
            #expect(semaphore.waiterCount == 0)
            #expect(await stoicTasksStillRunning().isEmpty)
        }
    }

    /// No settling between operations: arrivals, cancellations, deadlines and
    /// the clock race each other as the scheduler pleases. What must hold
    /// regardless is the part of the contract that does not depend on order.
    @Test(.stoic(seed: 202), .timeLimit(.minutes(1)), arguments: Array(0..<6))
    func chaosNeverExceedsCapacityNorLosesAWakeup(round: Int) async {
        var generator = Ambient.current.random.generator(discriminator: UInt64(round))
        let capacity = Int.random(in: 1...3, using: &generator)
        let semaphore = AsyncSemaphore(permits: capacity, label: "chaos-\(round)")
        let clock = TestClock()
        let count = 150 * testScale
        let inside = SendableBox((now: 0, peak: 0))
        let finished = SendableBox(0)
        var tasks: [Task<Outcome, Never>] = []
        var mayBeRejected = Set<Int>()   // cancelled or given a deadline

        await withAmbient({ $0.clock = clock.erased }) {
            for index in 0..<count {
                let limit: Deadline? = Int.random(in: 0..<4, using: &generator) == 0
                    ? Deadline.after(.seconds(Int.random(in: 1...5, using: &generator)), clock: clock.erased) : nil
                if limit != nil { mayBeRejected.insert(index) }
                let spins = Int.random(in: 0...3, using: &generator)
                tasks.append(Task {
                    let outcome: Outcome = await Deadline.$stored.withValue(limit) {
                        do throws(PolicyError<Never>) {
                            try await semaphore.withPermit { () async -> Void in
                                inside.mutate { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                                for _ in 0..<spins { await Task.yield() }
                                inside.mutate { $0.now -= 1 }
                            }
                            return .completed
                        } catch {
                            return .rejected(error.rejection?.reason ?? .cancelled)
                        }
                    }
                    finished.mutate { $0 += 1 }
                    return outcome
                })
                // Interleave disturbances with the arrivals.
                switch Int.random(in: 0..<6, using: &generator) {
                case 0:
                    let victim = Int.random(in: 0...index, using: &generator)
                    mayBeRejected.insert(victim)
                    tasks[victim].cancel()
                case 1:
                    await clock.advance(by: .seconds(1))
                case 2:
                    await Task.yield()
                default:
                    break
                }
            }
            await clock.advance(by: .seconds(10))   // every remaining deadline passes

            let drained = await eventually(within: .seconds(10)) { finished.value == count }
            if !drained {
                Issue.record("round \(round): \(count - finished.value) of \(count) tasks never finished: a lost wakeup (available \(semaphore.availablePermits), waiters \(semaphore.waiterCount))")
                for task in tasks { task.cancel() }
            }
            var outcomes: [Outcome] = []
            for task in tasks { outcomes.append(await task.value) }

            #expect(inside.value.peak <= capacity, "round \(round): \(inside.value.peak) bodies at once, capacity \(capacity)")
            for (index, outcome) in outcomes.enumerated() {
                switch outcome {
                case .completed: break
                case .rejected(let reason):
                    #expect(mayBeRejected.contains(index), "task \(index) was rejected (\(reason)) though nothing cancelled it and it had no deadline")
                    #expect(reason == .cancelled || reason == .deadlineExceeded)
                }
            }
            #expect(semaphore.availablePermits == capacity, "round \(round): a permit leaked")
            #expect(semaphore.waiterCount == 0)
        }
    }
}

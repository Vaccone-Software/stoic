@testable import Stoic
import StoicTesting
import Testing

/// design/04: "for any random interleaving of acquire, fork, throw and
/// cancel, every acquired resource is released exactly once, in reverse
/// order" and "thousands of scopes under random cancellation; the resource
/// counter returns to zero."
@Suite("Scopes: random scripts and leaks")
struct ScopePropertyTests {
    struct Boom: Error {}

    enum Step: Sendable, CustomStringConvertible {
        case acquire(shielded: Bool, yields: Int)
        case failingAcquire
        case fork(Fork)
        case fail                 // the body throws
        case pause(Int)           // yields

        enum Fork: Sendable { case sleeps, failsAfter(Int), quick }

        var description: String {
            switch self {
            case .acquire(let shielded, let yields): "acquire(\(shielded ? "shielded, " : "")\(yields) yields)"
            case .failingAcquire: "failingAcquire"
            case .fork(let fork): "fork(\(fork))"
            case .fail: "fail"
            case .pause(let count): "pause(\(count))"
            }
        }
    }

    static func script(_ generator: inout RandomGenerator) -> [Step] {
        (0..<Int.random(in: 3...14, using: &generator)).map { _ in
            switch Int.random(in: 0..<12, using: &generator) {
            case 0..<4: .acquire(shielded: Bool.random(using: &generator), yields: Int.random(in: 0...3, using: &generator))
            case 4: .failingAcquire
            case 5..<7: .fork(.sleeps)
            case 7: .fork(.failsAfter(Int.random(in: 0...3, using: &generator)))
            case 8: .fork(.quick)
            case 9: .fail
            default: .pause(Int.random(in: 1...3, using: &generator))
            }
        }
    }

    final class Ledger: Sendable {
        let acquired = SendableBox<[Int]>([])
        let released = SendableBox<[Int]>([])
        let exits = SendableBox<[String]>([])
        let childrenRunning = SendableBox(0)
        let violations = SendableBox<[String]>([])
    }

    /// Runs `script` in a task scope, cancelling the whole thing after
    /// `cancelAfter` yields (if any). Returns how the scope ended.
    static func execute(_ script: [Step], cancelAfter: Int?, ledger: Ledger) async -> String {
        let outer = SendableBox<Task<String, Never>?>(nil)
        let task = Task { () async -> String in
            do {
                try await withTaskScope(label: "script") { scope in
                    var resource = 0
                    for step in script {
                        switch step {
                        case .acquire(let shielded, let yields):
                            let id = resource
                            resource += 1
                            _ = try await scope.acquire(shielded: shielded, { () async throws(CancellationError) -> Int in
                                for _ in 0..<yields { await Task.yield() }
                                if Task.isCancelled { throw CancellationError() }
                                ledger.acquired.mutate { $0.append(id) }
                                return id
                            }, release: { value, exit in
                                if ledger.childrenRunning.value != 0 {
                                    ledger.violations.mutate { $0.append("resource \(value) released while a fork was running") }
                                }
                                ledger.released.mutate { $0.append(value) }
                                ledger.exits.mutate { $0.append("\(exit)") }
                            })
                        case .failingAcquire:
                            _ = try await scope.acquire({ () async throws(Boom) -> Int in throw Boom() }, release: { _, _ in
                                ledger.violations.mutate { $0.append("a failed acquire registered a release") }
                            })
                        case .fork(let kind):
                            scope.fork(label: "child") {
                                ledger.childrenRunning.mutate { $0 += 1 }
                                defer { ledger.childrenRunning.mutate { $0 -= 1 } }
                                switch kind {
                                case .sleeps: try await Task.sleep(for: .seconds(3600))
                                case .failsAfter(let yields):
                                    for _ in 0..<yields { await Task.yield() }
                                    throw Boom()
                                case .quick: break
                                }
                            }
                        case .fail:
                            throw Boom()
                        case .pause(let count):
                            for _ in 0..<count { await Task.yield() }
                        }
                    }
                }
                return "success"
            } catch is CancellationError {
                return "cancelled"
            } catch is Boom {
                return "boom"
            } catch is ConcurrentFailure<any Error> {
                return "concurrent"
            } catch {
                return "other: \(error)"
            }
        }
        outer.mutate { $0 = task }
        if let cancelAfter {
            Task {
                for _ in 0..<cancelAfter { await Task.yield() }
                outer.value?.cancel()
            }
        }
        return await task.value
    }

    @Test(.stoic(seed: 505), .timeLimit(.minutes(1)), arguments: Array(0..<25))
    func randomScriptsReleaseEverythingOnceInReverse(round: Int) async {
        var generator = Ambient.current.random.generator(discriminator: UInt64(round))
        for attempt in 0..<(8 * testScale) {
            let script = Self.script(&generator)
            let cancelAfter: Int? = Bool.random(using: &generator) ? Int.random(in: 0...12, using: &generator) : nil
            let ledger = Ledger()
            let ended = await Self.execute(script, cancelAfter: cancelAfter, ledger: ledger)
            let context = "round \(round).\(attempt), script [\(script.map(\.description).joined(separator: ", "))], cancel after \(cancelAfter.map(String.init) ?? "never"), ended \(ended)"

            #expect(ledger.released.value == ledger.acquired.value.reversed(), "released exactly once, newest first: \(context)")
            #expect(ledger.violations.value.isEmpty, "\(ledger.violations.value) in \(context)")
            #expect(ledger.childrenRunning.value == 0, "a fork outlived the scope: \(context)")
            #expect(["success", "boom", "cancelled", "concurrent"].contains(ended), "unexpected outcome: \(context)")
            if ended == "success" {
                #expect(ledger.exits.value.allSatisfy { $0 == "success" }, "a successful scope showed a finalizer \(ledger.exits.value): \(context)")
            } else {
                #expect(ledger.exits.value.allSatisfy { $0 != "success" }, "a failed scope showed a finalizer success: \(context)")
            }
        }
        #expect(await stoicTasksStillRunning().isEmpty)
    }

    @Test(.stoic(seed: 606), .timeLimit(.minutes(2)))
    func thousandsOfScopesUnderRandomCancellationLeakNothing() async {
        var generator = Ambient.current.random.generator()
        let live = SendableBox((now: 0, opened: 0, closed: 0))
        let tag = Ambient.current.ledgerTag
        let baseline = tag.map { TaskLedger.entries(tag: $0).count } ?? 0
        let waves = 20 * testScale
        let perWave = 150

        for _ in 0..<waves {
            var tasks: [Task<Void, Never>] = []
            for _ in 0..<perWave {
                let resources = Int.random(in: 1...3, using: &generator)
                let forks = Int.random(in: 0...2, using: &generator)
                let outcome = Int.random(in: 0..<3, using: &generator)   // finish, throw, wait to be cancelled
                tasks.append(Task {
                    _ = try? await withTaskScope { scope in
                        for _ in 0..<resources {
                            _ = try await scope.acquire({ () async throws(CancellationError) -> Int in
                                if Task.isCancelled { throw CancellationError() }
                                live.mutate { $0.now += 1; $0.opened += 1 }
                                return 1
                            }, release: { _, _ in live.mutate { $0.now -= 1; $0.closed += 1 } })
                        }
                        for _ in 0..<forks { scope.fork(label: "leak") { try await Task.sleep(for: .seconds(3600)) } }
                        switch outcome {
                        case 0: break
                        case 1: throw Boom()
                        default: try await Task.sleep(for: .seconds(3600))
                        }
                    }
                })
                if Int.random(in: 0..<3, using: &generator) == 0 {
                    for _ in 0..<Int.random(in: 0...2, using: &generator) { await Task.yield() }
                    tasks[Int.random(in: 0..<tasks.count, using: &generator)].cancel()
                }
            }
            // Whatever is still waiting to be cancelled gets cancelled now.
            await Task.yield()
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            #expect(live.value.now == 0, "resources still open after a wave: \(live.value)")
        }
        #expect(live.value.opened == live.value.closed)
        #expect(live.value.opened > waves * perWave / 2, "the test must actually acquire things: \(live.value)")
        let leftover = await stoicTasksStillRunning()
        #expect(leftover.count <= baseline, "\(leftover.count) Stoic tasks left behind: \(leftover.prefix(3))")
    }
}

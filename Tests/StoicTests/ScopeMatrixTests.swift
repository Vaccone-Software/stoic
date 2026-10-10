@testable import Stoic
import StoicTesting
import Testing

/// design/04: "Exhaustive outcome matrix (success, throw, cancel) × (0, 1, n
/// finalizers) × (finalizer ok, throws, hangs) × (0, 1, n children), on the
/// virtual clock, asserting order, Exit value and outcome."
@Suite("Scopes: outcome matrix")
struct ScopeMatrixTests {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    struct CleanupFailed: Error {}

    enum Body: String, CaseIterable, Sendable { case succeeds, fails, cancelled }
    enum Fin: String, Sendable { case ok, fails, hangs }
    enum Shape: Sendable, CustomStringConvertible {
        case plain                  // withScope: no forks
        case tasks(children: Int)   // withTaskScope with this many forks

        var description: String {
            switch self {
            case .plain: "withScope"
            case .tasks(let children): "withTaskScope(\(children) children)"
            }
        }
    }

    struct Cell: Sendable, CustomStringConvertible {
        var body: Body
        var fins: [Fin]        // in registration order
        var shape: Shape

        var description: String {
            "\(shape), body \(body), finalizers [\(fins.map(\.rawValue).joined(separator: ", "))]"
        }
    }

    struct Observation {
        var result: String
        var log: [String]
        var events: [EventName]
        var elapsed: Duration
    }

    static let cells: [Cell] = {
        let finalizerSets: [[Fin]] = [
            [], [.ok], [.fails], [.hangs],
            [.ok, .fails, .hangs],
            [.ok, .ok, .ok], [.fails, .fails, .fails], [.hangs, .hangs, .hangs],
        ]
        let shapes: [Shape] = [.plain, .tasks(children: 0), .tasks(children: 1), .tasks(children: 3)]
        return shapes.flatMap { shape in
            Body.allCases.flatMap { body in
                finalizerSets.map { Cell(body: body, fins: $0, shape: shape) }
            }
        }
    }()

    /// Runs one cell to completion on a virtual clock and reports what happened.
    static func run(_ cell: Cell) async -> Observation {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = OrderLog()
        let hangGate = TestGate()
        let bodyEntered = TestGate()
        let hangersEntered = SendableBox(0)

        let finalizers: [@Sendable (Exit) async throws -> Void] = cell.fins.enumerated().map { index, kind in
            { exit in
                log.append("f\(index) \(exit)")
                switch kind {
                case .ok: break
                case .fails: throw CleanupFailed()
                case .hangs:
                    hangersEntered.mutate { $0 += 1 }
                    await hangGate.wait()   // ignores cancellation, like a wedged call
                }
            }
        }
        let body = cell.body
        let runBody: @Sendable () async throws -> Int = {
            switch body {
            case .succeeds: return 42
            case .fails: throw Boom()
            case .cancelled:
                bodyEntered.open()
                try await Task.sleep(for: .seconds(3600))
                return 0
            }
        }

        let task = Task { () async -> String in
            await withAmbient({ $0.clock = clock.erased; $0.instrumentation = events }) {
                do {
                    let value: Int
                    switch cell.shape {
                    case .plain:
                        value = try await withScope { (scope: borrowing Scope) async throws -> Int in
                            for (index, finalizer) in finalizers.enumerated() { scope.onExit(label: "f\(index)", finalizer) }
                            return try await runBody()
                        }
                    case .tasks(let children):
                        value = try await withTaskScope { scope in
                            for (index, finalizer) in finalizers.enumerated() { scope.onExit(label: "f\(index)", finalizer) }
                            for child in 0..<children {
                                scope.fork(label: "c\(child)") {
                                    do { try await Task.sleep(for: .seconds(3600)) } catch {
                                        log.append("c\(child) stopped")
                                        throw error
                                    }
                                }
                            }
                            return try await runBody()
                        }
                    }
                    return "value \(value)"
                } catch is CancellationError {
                    return "cancelled"
                } catch let error as Boom {
                    return "\(error)"
                } catch {
                    return "other: \(error)"
                }
            }
        }

        if cell.body == .cancelled {
            await bodyEntered.wait()
            task.cancel()
        }
        // Each hung finalizer is abandoned when its allowance runs out: wait
        // until it is the only thing the clock is timing, then let that
        // time pass. Finalizers run one at a time, so no ok finalizer's
        // timer can be pending then.
        let hangers = cell.fins.filter { $0 == .hangs }.count
        for k in stride(from: 1, through: hangers, by: 1) {
            let timing = await eventually { hangersEntered.value == k && clock.pendingDeadlines.count == 1 }
            #expect(timing, "\(cell): hung finalizer \(k) was never timed")
            if !timing { break }
            await clock.advanceToNextDeadline()
        }
        let result = await task.value
        hangGate.open()
        return Observation(result: result, log: log.values, events: events.names, elapsed: clock.now.offset)
    }

    /// The virtual time the hung finalizers take: each gets
    /// max(250 ms, min(its timeout, what is left of the 10 s budget)).
    static func expectedElapsed(_ cell: Cell) -> Duration {
        var remaining = Duration.seconds(10)
        var elapsed = Duration.zero
        for fin in cell.fins.reversed() where fin == .hangs {
            let allowed = max(.milliseconds(250), min(.seconds(5), remaining))
            elapsed += allowed
            remaining = max(.zero, remaining - allowed)
        }
        return elapsed
    }

    @Test(.timeLimit(.minutes(1)), arguments: cells)
    func everyCellEndsTheSameWayWhateverTheFinalizersDo(cell: Cell) async {
        let observed = await Self.run(cell)

        // The outcome is the body's, untouched by any finalizer.
        let (expectedResult, expectedExit): (String, String) = switch cell.body {
        case .succeeds: ("value 42", "success")
        case .fails: ("boom", "failure(boom)")
        case .cancelled: ("cancelled", "cancelled")
        }
        #expect(observed.result == expectedResult, "\(cell)")

        // Every finalizer ran exactly once, newest first, and saw the Exit.
        let finalizerLines = observed.log.filter { $0.hasPrefix("f") }
        let expectedLines = cell.fins.indices.reversed().map { "f\($0) \(expectedExit)" }
        #expect(finalizerLines == expectedLines, "\(cell)")

        // Forks are stopped (once each) before any finalizer runs.
        if case .tasks(let children) = cell.shape {
            let stopped = observed.log.indices.filter { observed.log[$0].hasSuffix("stopped") }
            let firstFinalizer = observed.log.firstIndex { $0.hasPrefix("f") } ?? observed.log.endIndex
            #expect(stopped.count == children, "\(cell)")
            #expect(stopped.allSatisfy { $0 < firstFinalizer }, "a fork was still running when a finalizer started: \(cell)")
        }

        // Reported, never rethrown.
        #expect(observed.events.filter { $0 == "scope.finalizer_failed" }.count == cell.fins.filter { $0 == .fails }.count, "\(cell)")
        #expect(observed.events.filter { $0 == "scope.finalizer_abandoned" }.count == cell.fins.filter { $0 == .hangs }.count, "\(cell)")

        // Bounded: the hung ones took their allowance, the budget and the floor included.
        #expect(observed.elapsed == Self.expectedElapsed(cell), "\(cell): took \(observed.elapsed)")
    }
}

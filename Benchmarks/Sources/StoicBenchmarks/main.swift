import Darwin
import Foundation
import Stoic
import Synchronization

// Micro-benchmarks of Stoic's hot paths, and the allocation gate.
//
//   swift run -c release                              report time and allocations
//   swift run -c release StoicBenchmarks --check allocations.json
//   swift run -c release StoicBenchmarks --record allocations.json
//
// Time is reported, never gated: CI machines are shared and their timings
// drift by more than any regression worth catching. Allocations per
// iteration are close to deterministic, so they are the gate (DESIGN.md's
// quality bar): `--check` fails when a path allocates more than recorded,
// and says when it allocates less, so the record can be ratcheted down.

/// Every allocation in the process, counted by the malloc logging hook.
/// The hook runs inside malloc, so it does nothing but an atomic add.
let allocationCount = Atomic<Int>(0)

typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// Installs the hook through `malloc_logger`, the variable libmalloc calls
/// on every allocation when it is set (what malloc stack logging uses).
func installAllocationCounter() {
    let hook: MallocLogger = { type, _, _, _, _, _ in
        // MALLOC_LOG_TYPE_ALLOCATE
        if type & 2 != 0 { allocationCount.add(1, ordering: .relaxed) }
    }
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {  // RTLD_DEFAULT
        fatalError("malloc_logger is not available; allocations cannot be counted")
    }
    symbol.assumingMemoryBound(to: MallocLogger?.self).pointee = hook
}

struct Measurement {
    let name: String
    let nanoseconds: Double
    let allocations: Double
}

let collected = Mutex<[Measurement]>([])

/// Runs `body` `iterations` times, three rounds, and records the best
/// nanoseconds and the fewest allocations per iteration (the least
/// disturbed round: other threads allocate too, now and then).
func measure(_ name: String, iterations: Int = 200_000, _ body: () async throws -> Void) async rethrows {
    let clock = ContinuousClock()
    var best = Duration.seconds(3600)
    var fewest = Double.infinity
    for _ in 0..<3 {
        let allocationsBefore = allocationCount.load(ordering: .relaxed)
        let start = clock.now
        for _ in 0..<iterations { try await body() }
        best = min(best, start.duration(to: clock.now))
        let allocated = allocationCount.load(ordering: .relaxed) - allocationsBefore
        fewest = min(fewest, Double(allocated) / Double(iterations))
    }
    let nanoseconds = Double(best.components.seconds) * 1e9 + Double(best.components.attoseconds) / 1e9
    let measurement = Measurement(name: name, nanoseconds: nanoseconds / Double(iterations), allocations: fewest)
    collected.withLock { $0.append(measurement) }
}

struct Failure: Error {}

installAllocationCounter()

try await withAmbient({ $0.instrumentation = NoInstrumentation() }) {
    await measure("Ambient.current") { _ = Ambient.current.clock }

    let semaphore = AsyncSemaphore(permits: 8, label: "bench")
    try await measure("AsyncSemaphore.withPermit (uncontended)") {
        try await semaphore.withPermit { () throws(Never) in }
    }

    let breaker = CircuitBreaker(label: "bench")
    try await measure("CircuitBreaker.execute (closed, success)") {
        try await breaker.execute { () throws(Failure) in }
    }

    // A count window, filled first so every call evicts: recording must not
    // cost in proportion to the window.
    let counting = CircuitBreaker(label: "bench", .init(window: .calls(10_000), minimumCalls: 10_000))
    for _ in 0..<10_000 { try await counting.execute { () throws(Failure) in } }
    try await measure("CircuitBreaker.execute (closed, .calls(10_000) window)") {
        try await counting.execute { () throws(Failure) in }
    }

    var stepper = Schedule.exponential(base: .milliseconds(100)).makeStepper(random: RandomSource.seeded(1).generator())
    await measure("Schedule step (exponential, jittered)", iterations: 1_000_000) {
        _ = stepper.next(elapsed: .zero)
    }

    try await measure("retry, first attempt succeeds", iterations: 100_000) {
        _ = try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(Failure) in 1 }
    }

    // The first-attempt-success path of a declared operation, on a remote
    // backend (breaker, bulkhead, budget) and a local one (writer lane).
    let remoteRead = Backend.remote("bench.remote").readOnly("read")
    try await measure("perform, first attempt succeeds (remote)", iterations: 100_000) {
        _ = try await remoteRead.perform { _ throws(Failure) in 1 }
    }
    let localWrite = Backend.local("bench.local").idempotent("write")
    try await measure("perform, first attempt succeeds (local)", iterations: 100_000) {
        _ = try await localWrite.perform { _ throws(Failure) in 1 }
    }

    await measure("withScope, one finalizer", iterations: 50_000) {
        await withScope { scope in scope.onExit { _ in } }
    }

    let machine = StateMachine<Int, Int>(initial: 0, label: "bench", historyLimit: 1) { state, _ in .to(state &+ 1) }
    await measure("StateMachine.send", iterations: 200_000) { machine.send(1) }

    // The default history, full: a record replaces the oldest in place.
    let recording = StateMachine<Int, Int>(initial: 0, label: "bench") { state, _ in .to(state &+ 1) }
    await measure("StateMachine.send (history of 64)", iterations: 200_000) { recording.send(1) }

    try await measure("withTimeout, completes at once", iterations: 20_000) {
        try await withTimeout(.seconds(10)) { () throws(Failure) in }
    }
}

// MARK: Report and gate

let results = collected.withLock { $0 }

func rounded(_ value: Double, places: Double = 1) -> Double {
    let scale = pow(10, places)
    return (value * scale).rounded() / scale
}

print("Stoic hot paths (release build, best of 3)\n")
for result in results {
    let padding = String(repeating: " ", count: max(1, 44 - result.name.count))
    print(result.name + padding + "\(rounded(result.nanoseconds)) ns    \(rounded(result.allocations, places: 2)) allocations")
}

let arguments = CommandLine.arguments.dropFirst()
/// A path allocating more than recorded by this much has regressed; the
/// slack absorbs the odd allocation another thread makes during a round.
let tolerance = 0.5

if let flag = arguments.first, let path = arguments.dropFirst().first {
    let url = URL(fileURLWithPath: path)
    switch flag {
    case "--record":
        let record = Dictionary(uniqueKeysWithValues: results.map { ($0.name, rounded($0.allocations, places: 2)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(record) + Data("\n".utf8)).write(to: url)
        print("\nrecorded allocations for \(results.count) paths in \(path)")
    case "--check":
        let record = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url))
        var regressions: [String] = []
        var improvements: [String] = []
        for result in results {
            guard let recorded = record[result.name] else {
                regressions.append("\(result.name): no recorded allocation count; record one with --record")
                continue
            }
            let measured = rounded(result.allocations, places: 2)
            if measured > recorded + tolerance {
                regressions.append("\(result.name): \(measured) allocations per call, recorded \(recorded)")
            } else if measured < recorded - tolerance {
                improvements.append("\(result.name): \(measured) allocations per call, recorded \(recorded)")
            }
        }
        for name in record.keys where !results.contains(where: { $0.name == name }) {
            regressions.append("\(name): recorded, but no longer measured; record again with --record")
        }
        if !improvements.isEmpty {
            print("\nFewer allocations than recorded; ratchet the record down with --record:")
            improvements.forEach { print("  \($0)") }
        }
        if !regressions.isEmpty {
            print("\nAllocation regressions:")
            regressions.forEach { print("  \($0)") }
            exit(1)
        }
        print("\nallocations within the record for all \(results.count) paths")
    default:
        print("usage: StoicBenchmarks [--check <file> | --record <file>]")
        exit(2)
    }
}

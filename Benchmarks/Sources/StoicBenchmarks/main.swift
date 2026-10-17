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
// drift by more than any regression worth catching. Allocations are the gate
// (DESIGN.md's quality bar), and the gate is the MEDIAN allocations of one
// call, not the mean. A path that starts child tasks allocates a few extra
// task-allocator slabs on the calls where the scheduler lands a cancel
// mid-setup, so its mean moves with machine load; its median does not, while
// a structural regression (one more box on every call) moves the median by
// exactly one. `--check` fails when a median exceeds the record, and says
// when it is below, so the record can be ratcheted down. A loaded machine
// can show those paths below their record; record on an idle one.

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
    /// The median allocations of one call, in the round where it was least.
    let median: Int
    /// The mean, for information: scheduler bursts move it, the median not.
    let mean: Double
}

/// Calls allocating this many times or more share the last bucket.
let histogramBuckets = 256

let collected = Mutex<[Measurement]>([])

/// Runs `body` `iterations` times, three rounds. Records the best
/// nanoseconds per iteration (the least disturbed round), and the allocations
/// of every single call: the counter is read before and after each call (an
/// atomic load, no allocation) and the difference lands in a histogram
/// allocated before anything is measured, so counting perturbs nothing it
/// counts. A round's median is its middle call; the gate is the least median
/// of the rounds, as the best time is the least time: other threads and the
/// scheduler allocate too, and the least disturbed round is the honest one.
/// The mean (fewest over rounds) is reported beside it.
func measure(_ name: String, iterations: Int = 200_000, _ body: () async throws -> Void) async rethrows {
    let clock = ContinuousClock()
    let histogram = UnsafeMutablePointer<Int>.allocate(capacity: histogramBuckets)
    histogram.initialize(repeating: 0, count: histogramBuckets)
    defer { histogram.deallocate() }
    var best = Duration.seconds(3600)
    var fewest = Double.infinity
    var least = Int.max
    for _ in 0..<3 {
        histogram.update(repeating: 0, count: histogramBuckets)
        var total = 0
        let start = clock.now
        for _ in 0..<iterations {
            let before = allocationCount.load(ordering: .relaxed)
            try await body()
            let allocated = allocationCount.load(ordering: .relaxed) - before
            histogram[min(allocated, histogramBuckets - 1)] += 1
            total += allocated
        }
        best = min(best, start.duration(to: clock.now))
        fewest = min(fewest, Double(total) / Double(iterations))
        // The least count that at least half of the calls did not exceed
        // (the lower median when the calls are even).
        var cumulative = 0
        var median = histogramBuckets - 1
        for count in 0..<histogramBuckets {
            cumulative += histogram[count]
            if cumulative * 2 >= iterations {
                median = count
                break
            }
        }
        least = min(least, median)
    }
    let nanoseconds = Double(best.components.seconds) * 1e9 + Double(best.components.attoseconds) / 1e9
    let measurement = Measurement(
        name: name, nanoseconds: nanoseconds / Double(iterations), median: least, mean: fewest)
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
    print(
        result.name + padding
            + "\(rounded(result.nanoseconds)) ns    \(result.median) allocations (mean \(rounded(result.mean, places: 2)))")
}

let arguments = CommandLine.arguments.dropFirst()
// There is no tolerance: medians are whole numbers, and the median ignores
// the odd extra allocation another thread or the scheduler makes, so a path
// whose median exceeds the record has regressed by at least one allocation
// on every call.

if let flag = arguments.first, let path = arguments.dropFirst().first {
    let url = URL(fileURLWithPath: path)
    switch flag {
    case "--record":
        let record = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.median) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(record) + Data("\n".utf8)).write(to: url)
        print("\nrecorded median allocations for \(results.count) paths in \(path)")
    case "--check":
        let record = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))
        var regressions: [String] = []
        var improvements: [String] = []
        for result in results {
            guard let recorded = record[result.name] else {
                regressions.append("\(result.name): no recorded median allocation count; record one with --record")
                continue
            }
            if result.median > recorded {
                regressions.append("\(result.name): median \(result.median) allocations per call, recorded \(recorded)")
            } else if result.median < recorded {
                improvements.append("\(result.name): median \(result.median) allocations per call, recorded \(recorded)")
            }
        }
        for name in record.keys where !results.contains(where: { $0.name == name }) {
            regressions.append("\(name): recorded, but no longer measured; record again with --record")
        }
        if !improvements.isEmpty {
            print("\nFewer allocations than recorded; ratchet the record down with --record (on an idle machine):")
            improvements.forEach { print("  \($0)") }
        }
        if !regressions.isEmpty {
            print("\nAllocation regressions:")
            regressions.forEach { print("  \($0)") }
            exit(1)
        }
        print("\nmedian allocations within the record for all \(results.count) paths")
    default:
        print("usage: StoicBenchmarks [--check <file> | --record <file>]")
        exit(2)
    }
}

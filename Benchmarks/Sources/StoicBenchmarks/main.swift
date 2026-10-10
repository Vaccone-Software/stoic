import Stoic

/// Runs `body` `iterations` times, three rounds, and reports the best
/// nanoseconds per iteration (the least disturbed round).
func measure(_ name: String, iterations: Int = 200_000, _ body: () async throws -> Void) async rethrows {
    let clock = ContinuousClock()
    var best = Duration.seconds(3600)
    for _ in 0..<3 {
        let start = clock.now
        for _ in 0..<iterations { try await body() }
        best = min(best, start.duration(to: clock.now))
    }
    let nanoseconds = Double(best.components.seconds) * 1e9 + Double(best.components.attoseconds) / 1e9
    let perIteration = nanoseconds / Double(iterations)
    let rounded = (perIteration * 10).rounded() / 10
    print(name + String(repeating: " ", count: max(1, 44 - name.count)) + "\(rounded) ns")
}

struct Failure: Error {}

print("Stoic hot paths (release build, best of 3)\n")

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

    var stepper = Schedule.exponential(base: .milliseconds(100)).makeStepper(random: RandomSource.seeded(1).generator())
    await measure("Schedule step (exponential, jittered)", iterations: 1_000_000) {
        _ = stepper.next(elapsed: .zero)
    }

    try await measure("retry, first attempt succeeds", iterations: 100_000) {
        _ = try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(Failure) in 1 }
    }

    await measure("withScope, one finalizer", iterations: 50_000) {
        await withScope { scope in scope.onExit { _ in } }
    }

    let machine = StateMachine<Int, Int>(initial: 0, label: "bench", historyLimit: 1) { state, _ in .to(state &+ 1) }
    await measure("StateMachine.send", iterations: 200_000) { machine.send(1) }

    try await measure("withTimeout, completes at once", iterations: 20_000) {
        try await withTimeout(.seconds(10)) { () throws(Failure) in }
    }
}

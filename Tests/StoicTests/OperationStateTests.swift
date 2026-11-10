@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// What a backend remembers: its retry budget, the registry that holds its
/// state, and how an `OperationError` classifies for a layer that missed the
/// settled mark (design/22, Budget, State and Errors).
@Suite("Operation state")
struct OperationStateTests {
    // MARK: Budget

    @Test func theBudgetIsTheBackendsNamedBudgetAndWorkNobodyWaitsForSparesItsReserve() async throws {
        let backend = Backend.remote("state.budget")
        let fetch = backend.readOnly("fetch")
        let run = try await simulated { _ in
            let ambient = Ambient.current
            let state = ambient.backends.enter(backend, ambient: ambient)
            defer { state.leave() }
            // Five of the reserve's ten tokens, spent by whoever shares it.
            for _ in 0..<5 { _ = state.budget.withdraw(clock: ambient.clock) }
            let shared = RetryBudget.named(backend.name).available() ?? 0
            let sync = Script([.fail(Transient())])
            let background = await withUrgency(.background) { await performing(fetch, sync) }
            let person = Script([.fail(Transient()), .succeed])
            let tap = await withUrgency(.userInitiated) { await performing(fetch, person) }
            return (shared, background, sync.count, tap, person.count)
        }
        let (shared, background, syncAttempts, tap, tapAttempts) = run.value
        // The hand-written `retry(budget: .named(...))` sees the same tokens.
        #expect(abs(shared - 5) < 0.0001)
        // The last half of the reserve is kept for a person's retry.
        let refused = try #require(background.error)
        #expect(refused.stopName == "budget_exhausted")
        #expect(syncAttempts == 1)
        #expect(refused.last is Transient)
        #expect(tap.success == 2)
        #expect(tapAttempts == 2)
    }

    // MARK: The registry

    @Test func theRegistryForgetsTheLeastRecentlyUsedIdleBackend() async {
        await withTestAmbient(clock: TestClock()) {
            let ambient = Ambient.current
            let registry = BackendRegistry()
            let backends = (0...BackendRegistry.limit).map { Backend.remote("state.lru.\($0)") }
            for backend in backends.dropLast() { registry.enter(backend, ambient: ambient).leave() }
            #expect(registry.count == BackendRegistry.limit)
            // Using the first again makes the second the least recently used.
            registry.enter(backends[0], ambient: ambient).leave()
            registry.enter(backends[BackendRegistry.limit], ambient: ambient).leave()
            #expect(registry.count == BackendRegistry.limit)
            #expect(registry.existing(backends[0]) != nil)
            #expect(registry.existing(backends[1]) == nil)
            #expect(registry.existing(backends[BackendRegistry.limit]) != nil)
        }
    }

    @Test func aBackendWithWorkInFlightIsNeverForgottenAndTheRegistryGrowsAndSaysOnce() async {
        let events = RecordingInstrumentation()
        await withTestAmbient(clock: TestClock(), events: events) {
            let ambient = Ambient.current
            let registry = BackendRegistry()
            let backends = (0..<BackendRegistry.limit + 2).map { Backend.remote("state.busy.\($0)") }
            let entered = backends.map { registry.enter($0, ambient: ambient) }
            #expect(registry.count == BackendRegistry.limit + 2)
            for backend in backends { #expect(registry.existing(backend) != nil) }
            let reported = events.events(named: "operation.registry_full")
            #expect(reported.count == 1)
            #expect(reported.first?.level == .warning)
            #expect(reported.first?.number("backends") == BackendRegistry.limit + 1)
            entered.forEach { $0.leave() }
            // Idle again, the next new backend makes room by forgetting one.
            registry.enter(Backend.remote("state.busy.last"), ambient: ambient).leave()
            #expect(registry.count == BackendRegistry.limit + 2)
        }
    }

    // MARK: Errors

    @Test func anOperationErrorSaysStopUnlessNothingReachedTheBackend() {
        func error(
            _ stop: OperationError<Transient>.Stop, _ outcome: OperationError<Transient>.Outcome, last: Transient? = nil
        ) -> OperationError<Transient> {
            OperationError(stop: stop, outcome: outcome, last: last, attempts: 1, safety: .readOnly, idempotencyKey: nil)
        }
        let refused = error(.rejected(Rejection(.circuitOpen)), .notExecuted)
        #expect(refused.retryDecision == .retry)
        #expect(refused.neverReachedBackend)
        let tooLong = error(.rejected(Rejection(.budgetExhausted)), .notExecuted)
        #expect(tooLong.retryDecision == .stop)
        let offline = error(.failed(Transient()), .notExecuted, last: Transient())
        #expect(offline.retryDecision == .retry)
        #expect(offline.neverReachedBackend)
        for outcome in [OperationError<Transient>.Outcome.executed, .unknown] {
            let reached = error(.failed(Transient()), outcome, last: Transient())
            #expect(reached.retryDecision == .stop)
            #expect(!reached.neverReachedBackend)
        }
        #expect(error(.cancelled, .notExecuted).retryDecision == .stop)
    }

    @Test func aDeferredAttemptTimeoutIsRetriedAndAPlainCancellationIsNot() {
        let timedOut = OperationError(
            stop: .failed(CancellationError()), outcome: .unknown, last: CancellationError(),
            attempts: 1, safety: .readOnly, idempotencyKey: nil, defersToEnclosing: true, attemptTimedOut: true
        )
        #expect(timedOut.retryDecision == .retry)
        let thrown = OperationError(
            stop: .failed(CancellationError()), outcome: .unknown, last: CancellationError(),
            attempts: 1, safety: .readOnly, idempotencyKey: nil, defersToEnclosing: true
        )
        #expect(thrown.retryDecision == .stop)
        let caller = OperationError<CancellationError>(
            stop: .cancelled, outcome: .unknown, last: nil,
            attempts: 1, safety: .readOnly, idempotencyKey: nil, defersToEnclosing: true, attemptTimedOut: true
        )
        #expect(caller.retryDecision == .stop)
        let broken = OperationError(
            stop: .failed(Broken()), outcome: .unknown, last: Broken(),
            attempts: 1, safety: .readOnly, idempotencyKey: nil, defersToEnclosing: true, attemptTimedOut: true
        )
        #expect(broken.retryDecision == .stop)
        // Classifiers see that decision. Unwrapping to the body's
        // `CancellationError` would make a transient-only classifier stop.
        #expect(RetryClassifier<any Error>.transientOnly.decision(for: timedOut, attemptTimedOut: false) == .retry)
        #expect(standardDecision(for: timedOut) == .retry)
        #expect(RetryClassifier<any Error>.transientOnly.decision(for: thrown, attemptTimedOut: false) == .stop)
    }

    @Test func aDefectInTheLastFailureIsADefectToAnEnclosingLayer() {
        let broken = OperationError<Broken>(
            stop: .failed(Broken()), outcome: .executed, last: Broken(), attempts: 1, safety: .readOnly, idempotencyKey: nil
        )
        #expect(containsDefect(broken))
        #expect(containsDefect(PolicyError<OperationError<Broken>>.failed(broken)))
        let cancelled = OperationError<Transient>(
            stop: .cancelled, outcome: .notExecuted, last: nil, attempts: 0, safety: .readOnly, idempotencyKey: nil
        )
        #expect(cancelled.isCancellation)
        #expect(containsCancellation(PolicyError<OperationError<Transient>>.failed(cancelled)))
    }
}

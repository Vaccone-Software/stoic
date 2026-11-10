@testable import Stoic
import StoicTesting
import Synchronization
import Testing

typealias Side = SimulatedSide<String, Int>
typealias SideSync = SimulatedReconciliation<String, Int>

/// "The person at this device confirmed": the evidence an app with no
/// accounts declares for a confirmation (design/30, amendment 1).
struct PersonAtDevice: PrincipalEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "the person at this device confirmed"

    static func verified(_ name: String) -> Verified<String, PersonAtDevice> {
        Minter<PersonAtDevice>(Mint()).verified(name, PersonAtDevice())
    }
}

let ana = PersonAtDevice.verified("ana@kindora.example")

/// A policy for tests: small backoffs, so the loop's waits are a few seconds
/// of virtual time.
func quickPolicy(_ change: (inout ReconcilePolicy) -> Void = { _ in }) -> ReconcilePolicy {
    var policy = ReconcilePolicy()
    policy.keyBackoff = .exponential(base: .seconds(1)).capped(at: .seconds(8)).unjittered()
    policy.failedPassBackoff = .exponential(base: .seconds(30)).capped(at: .seconds(120)).unjittered()
    change(&policy)
    return policy
}

/// `body` on a fresh test clock and ambient, with the events recorded.
func onReconcilerTime<R: Sendable>(
    _ body: (TestClock, RecordingInstrumentation) async throws -> R
) async throws -> R {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    return try await withTestAmbient(clock: clock, events: events) { () async throws -> R in
        try await body(clock, events)
    }
}

/// `count` keys, `k0000` on, each with its index as its value.
func entries(_ count: Int, offset: Int = 0, value: (Int) -> Int = { $0 }) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: (0..<count).map { (key($0 + offset), value($0 + offset)) })
}

/// `k0042`: keys that sort as their numbers do.
func key(_ index: Int) -> String {
    let digits = String(index)
    return "k" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
}

extension RecordingInstrumentation {
    func count(_ name: EventName) -> Int { events(named: name).count }
}

/// A reconciliation whose reads and correction a test writes as closures, on
/// the remote backend `test.scripted`.
struct ScriptedReconciliation: Reconciliation {
    static let name = "test.scripted"
    static let readsTruth = Backend.remote("test.scripted", capacity: 8).readOnly("truth")
    static let readsDerived = Backend.remote("test.scripted", capacity: 8).readOnly("derived")
    static let corrects = Backend.remote("test.scripted", capacity: 8).keyed("correct")

    var truth: @Sendable (ReconcileScope<String>, Attempt) async throws -> [String: Int]
    var derived: @Sendable (ReconcileScope<String>, Attempt) async throws -> [String: Int]
    var apply: @Sendable (Correction<String, Int, Int>, Attempt) async throws -> Void
    var next: @Sendable () async -> Moment? = { nil }

    func desired(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { try await truth(scope, attempt) }
    func actual(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { try await derived(scope, attempt) }
    func correct(_ correction: Correction<String, Int, Int>, attempt: Attempt) async throws { try await apply(correction, attempt) }
    func nextChange() async -> Moment? { await next() }
}

/// Over two simulated sides, through `ScriptedReconciliation`'s keyed
/// correction, with `apply` seeing each attempt first.
func scripted(
    truth: Side, derived: Side,
    seeing: @escaping @Sendable (Correction<String, Int, Int>, Attempt) async throws -> Void = { _, _ in },
    next: @escaping @Sendable () async -> Moment? = { nil }
) -> ScriptedReconciliation {
    ScriptedReconciliation(
        truth: { scope, _ in try await truth.read(scope) },
        derived: { scope, _ in try await derived.read(scope) },
        apply: { correction, attempt in
            try await seeing(correction, attempt)
            switch correction {
            case .create(let key, let value), .update(let key, let value, was: _): try await derived.write(key, value)
            case .remove(let key, was: _): try await derived.write(key, nil)
            }
        },
        next: next)
}

/// A transient failure that a declared operation retries.
struct Flaky: Error, Retryable {
    var retryDecision: RetryDecision { .retry }
}

struct CorrectionBug: Defect {}

/// `body` as a deterministic simulation with no fault points perturbing it:
/// virtual time moves only when everything is asleep, so attempt timers,
/// backoffs and slow sides take exactly the time they say.
func simulated<R: Sendable>(
    seed: UInt64 = 0, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable (TestClock, RecordingInstrumentation) async throws -> R
) async throws -> R {
    try await simulate(seed: seed, faults: .none, schedule: .uniform, sourceLocation: sourceLocation) { context in
        try await body(context.clock, context.events)
    }.value
}

/// Holds a task for an interceptor to cancel: a crash at a chosen call.
final class TaskHandle: Sendable {
    private let task = Mutex<Task<ReconcilePassReport<String>, any Error>?>(nil)
    func set(_ value: Task<ReconcilePassReport<String>, any Error>) { task.withLock { $0 = value } }
    func cancel() { task.withLock { $0 }?.cancel() }
}

/// A reconciliation on the local backend `test.local`: one attempt per call,
/// and no attempt timer but the deadline.
struct LocalReconciliation: Reconciliation {
    static let name = "test.local"
    static let readsTruth = Backend.local("test.local").readOnly("truth")
    static let readsDerived = Backend.local("test.local").readOnly("derived")
    static let corrects = Backend.local("test.local").idempotent("correct")

    let truth: Side
    let derived: Side

    func desired(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { try await truth.read(scope) }
    func actual(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { try await derived.read(scope) }
    func correct(_ correction: Correction<String, Int, Int>, attempt: Attempt) async throws {
        switch correction {
        case .create(let key, let value), .update(let key, let value, was: _): try await derived.write(key, value)
        case .remove(let key, was: _): try await derived.write(key, nil)
        }
    }
}

extension SimulatedSide {
    /// Every write takes `duration` on the ambient clock before it applies;
    /// reads are as fast as ever. A write cancelled meanwhile does not apply.
    func slowWrites(by duration: Duration) {
        intercept { call in
            guard case .write = call else { return }
            do {
                try await Ambient.sleep(for: duration)
            } catch {
                // Cancelled: the write's own cancellation check refuses it.
                return
            }
        }
    }
}

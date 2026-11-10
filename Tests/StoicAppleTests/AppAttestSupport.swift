#if canImport(DeviceCheck) && canImport(CryptoKit)
import DeviceCheck
import Foundation
import Stoic
@testable import StoicApple
import StoicTesting
import Synchronization
import Testing

extension Trait where Self == ConditionTrait {
    /// Names the design/29 row a test proves, until the contract is committed
    /// and the name becomes a `.failureMode` claim.
    static func designRow(_ row: String) -> Self { .enabled(if: true) }
}

/// The app's server, from a script: numbered challenges, recorded enrolments,
/// failures queued per call.
final class ScriptedAttestServer: AppAttestServer {
    struct Enrolment: Sendable, Hashable {
        let key: String
        let attestation: [UInt8]
        let challenge: [UInt8]
    }

    private struct State {
        var issued: [AppAttestChallengePurpose] = []
        var enrolments: [Enrolment] = []
        var challengeFailures: [AppAttestServerError] = []
        var enrolFailures: [AppAttestServerError] = []
        var enrolmentLifetime: Duration = .seconds(600)
        var firstRequestChallenge = true
    }

    private let state = Mutex(State())

    var issued: [AppAttestChallengePurpose] { state.withLock { $0.issued } }
    var enrolments: [Enrolment] { state.withLock { $0.enrolments } }

    func failChallenge(with error: AppAttestServerError) { state.withLock { $0.challengeFailures.append(error) } }
    func failEnrol(with error: AppAttestServerError, times: Int = 1) {
        state.withLock { $0.enrolFailures += Array(repeating: error, count: times) }
    }
    func setEnrolmentLifetime(_ lifetime: Duration) { state.withLock { $0.enrolmentLifetime = lifetime } }

    func challenge(for purpose: AppAttestChallengePurpose) async throws(AppAttestServerError) -> AppAttestChallenge {
        let (failure, number, lifetime) = state.withLock { state -> (AppAttestServerError?, Int, Duration) in
            if !state.challengeFailures.isEmpty { return (state.challengeFailures.removeFirst(), 0, .zero) }
            state.issued.append(purpose)
            return (nil, state.issued.count, purpose == .enrolment ? state.enrolmentLifetime : .seconds(300))
        }
        if let failure { throw failure }
        return AppAttestChallenge(bytes: [purpose == .enrolment ? 1 : 2, UInt8(number)], lifetime: lifetime)
    }

    func enrol(_ key: AppAttestKeyID, attestation: [UInt8], challenge: AppAttestChallenge)
        async throws(AppAttestServerError) -> AppAttestChallenge?
    {
        let (failure, first) = state.withLock { state -> (AppAttestServerError?, Bool) in
            state.enrolments.append(Enrolment(key: key.base64, attestation: attestation, challenge: challenge.bytes))
            if !state.enrolFailures.isEmpty { return (state.enrolFailures.removeFirst(), false) }
            return (nil, state.firstRequestChallenge)
        }
        if let failure { throw failure }
        return first ? AppAttestChallenge(bytes: [2, 0], lifetime: .seconds(300)) : nil
    }
}

/// A secret store whose numbered writes can fail, to play a process that
/// dies between two steps: the write that would have recorded the step is
/// the one that never happens.
final class FlakyStore: SecretStore {
    let inner = InMemorySecretStore()
    private let state = Mutex<(writes: Int, failing: [Int: SecretStoreError])>((0, [:]))

    /// Fails the `number`-th call of `set` (1-based, counted from now on).
    func failWrite(_ number: Int, with error: SecretStoreError = .unavailable) {
        state.withLock { state in state.failing[state.writes + number] = error }
    }

    func failNext(with error: SecretStoreError) { inner.failNext(with: error) }

    func get(_ key: String) throws(SecretStoreError) -> Data? { try inner.get(key) }

    func set(_ value: Data, for key: String) throws(SecretStoreError) {
        let failure = state.withLock { state -> SecretStoreError? in
            state.writes += 1
            return state.failing.removeValue(forKey: state.writes)
        }
        if let failure { throw failure }
        try inner.set(value, for: key)
    }

    func delete(_ key: String) throws(SecretStoreError) { try inner.delete(key) }

    /// The record's phase on file, for assertions.
    func phase(of account: String) -> String? {
        guard let data = try? inner.get("stoic.app-attest.\(account)"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["phase"] as? String
    }
}

/// A phone: App Attest supported, not an extension.
let aPhone = AppAttestPlatform(isSimulator: false, isMac: false, isAppExtension: false, isWatch: false)

/// A backoff a test can follow: 2 s doubling, capped at 60 s, no jitter.
let predictableBackoff = Schedule.exponential(base: .seconds(2)).capped(at: .seconds(60)).unjittered().attempts(8)

/// An attester on a scripted service and server, made under the test's
/// ambient context so it keeps the test clock.
struct AttesterRig {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let service = ScriptedAppAttestService()
    let server = ScriptedAttestServer()
    let store = FlakyStore()

    func attester(account: String = "volunteer-7", policy: AppAttestPolicy = AppAttestPolicy(unavailableBackoff: predictableBackoff),
                  platform: AppAttestPlatform = aPhone) async -> AppAttester {
        await withTestAmbient(clock: clock, events: events) {
            AppAttester(account: account, secrets: store, server: server, service: service, policy: policy, platform: platform)
        }
    }

    func run<R>(_ body: () async throws -> R) async rethrows -> R {
        try await withTestAmbient(clock: clock, events: events) { () async throws -> R in try await body() }
    }

    func outcome(_ attester: AppAttester) async -> Result<AppAttestKeyID, AppAttestError> {
        await run {
            do throws(AppAttestError) { return .success(try await attester.enrolledKey()) } catch { return .failure(error) }
        }
    }

    /// Steps the clock deadline by deadline until `task` is done: at each
    /// step, waits for `sleepers` to be asleep (the enrolment's timeout is
    /// one) before moving to the next deadline.
    func drive<T: Sendable>(_ task: Task<T, Never>, sleepers: Int = 2, steps: Int = 40) async -> T {
        let done = SendableBox(false)
        let watcher = Task { _ = await task.value; done.mutate { $0 = true } }
        let real = ContinuousClock()
        for _ in 0..<steps where !done.value {
            // Until `sleepers` are asleep, or the task is done; never longer than 5 s of real time.
            let limit = real.now.advanced(by: .seconds(5))
            while !done.value, clock.sleeperCount < sleepers, real.now < limit {
                try? await real.sleep(for: .milliseconds(1))
            }
            if done.value { break }
            _ = await clock.advanceToNextDeadline()
        }
        await watcher.value
        return await task.value
    }
}
#endif

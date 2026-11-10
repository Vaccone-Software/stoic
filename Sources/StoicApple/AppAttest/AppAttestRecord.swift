#if canImport(DeviceCheck) && canImport(CryptoKit)
internal import Foundation
internal import Stoic
internal import Synchronization

/// What an attester keeps in its `SecretStore`, under `stoic.app-attest.<account>`:
/// how far the key's enrolment got (design/29, The key, on the device).
///
/// JSON, version 1:
/// `{"v":1,"phase":"attesting","key":"…","challenge":"<base64>","lifetime":600,"challengeAt":"<RFC 3339>"}`.
/// Each phase holds what the next step needs and nothing more: `generated`
/// the key; `attesting` the key and the enrolment challenge with its
/// lifetime in seconds and when it arrived by the wall clock; `attested` the
/// key, the challenge and the attestation object; `enrolled` the key; and
/// `refused` the code and the moment until which nothing is enrolled.
struct AppAttestRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case generated, attesting, attested, enrolled, refused
    }

    var v = 1
    var phase: Phase
    var key: String?
    var challenge: String?
    var lifetime: Int64?
    var challengeAt: Moment?
    var attestation: String?
    var until: Moment?
    var code: String?

    static func generated(_ key: String) -> Self { Self(phase: .generated, key: key) }

    static func attesting(_ key: String, _ challenge: AppAttestChallenge, at moment: Moment) -> Self {
        Self(phase: .attesting, key: key, challenge: Data(challenge.bytes).base64EncodedString(),
             lifetime: challenge.lifetime.components.seconds, challengeAt: moment)
    }

    static func attested(_ key: String, _ challenge: AppAttestChallenge, attestation: [UInt8]) -> Self {
        Self(phase: .attested, key: key, challenge: Data(challenge.bytes).base64EncodedString(),
             lifetime: challenge.lifetime.components.seconds, attestation: Data(attestation).base64EncodedString())
    }

    static func enrolled(_ key: String) -> Self { Self(phase: .enrolled, key: key) }

    static func refused(code: String, until: Moment) -> Self { Self(phase: .refused, until: until, code: code) }

    /// The challenge it holds, if it holds one that decodes.
    var heldChallenge: AppAttestChallenge? {
        guard let challenge, let bytes = Data(base64Encoded: challenge), let lifetime else { return nil }
        return AppAttestChallenge(bytes: Array(bytes), lifetime: .seconds(lifetime))
    }

    var heldAttestation: [UInt8]? {
        attestation.flatMap { Data(base64Encoded: $0) }.map(Array.init)
    }

    /// Whether the record has what its phase needs. A record that does not
    /// is treated as absent (its key, if any, cannot be used without it).
    var isComplete: Bool {
        guard v == 1 else { return false }
        switch phase {
        case .generated, .enrolled: return key != nil
        case .attesting: return key != nil && heldChallenge != nil && challengeAt != nil
        case .attested: return key != nil && heldChallenge != nil && heldAttestation != nil
        case .refused: return until != nil && code != nil
        }
    }

    /// The record's JSON. A moment outside RFC 3339's years (a wall clock
    /// set absurdly) does not encode, and is the store's `invalidValue`.
    func encoded() throws(AppAttestError) -> Data {
        do {
            return try JSONEncoder().encode(self)
        } catch {
            throw .keychain(.invalidValue)
        }
    }
}

/// Where the callers of `enrolledKey()` wait for the enrolment in flight:
/// each until the enrolment ends or it is itself cancelled, whichever comes
/// first. The enrolment does not wait for them.
final class EnrolmentFlight: Sendable {
    typealias Outcome = Result<AppAttestKeyID, AppAttestError>

    private struct State {
        var outcome: Outcome?
        var waiters: [Int: CheckedContinuation<Outcome?, Never>] = [:]
        var cancelled: Set<Int> = []
        var next = 0
    }

    private let state = Mutex(State())

    var outcome: Outcome? { state.withLock { $0.outcome } }

    /// The callers waiting now: a test's way to know every caller joined.
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Ends the flight: every waiter gets `outcome`.
    func finish(_ outcome: Outcome) {
        let waiters = state.withLock { state -> [CheckedContinuation<Outcome?, Never>] in
            state.outcome = outcome
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// The flight's outcome, or `nil` if the caller was cancelled first.
    func wait() async -> Outcome? {
        let id = state.withLock { state -> Int in
            defer { state.next += 1 }
            return state.next
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome?, Never>) in
                let now = state.withLock { state -> Outcome?? in
                    if let outcome = state.outcome { return .some(outcome) }
                    if state.cancelled.remove(id) != nil { return .some(nil) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Outcome?, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                if state.outcome == nil { state.cancelled.insert(id) }
                return nil
            }
            waiter?.resume(returning: nil)
        }
    }
}
#endif

#if canImport(DeviceCheck) && canImport(CryptoKit)
public import DeviceCheck
public import Foundation
internal import Stoic
internal import Synchronization

/// `DCAppAttestService`'s shape: the seam an ``AppAttester`` calls, which
/// tests replace with ``ScriptedAppAttestService``.
///
/// Errors are the service's own, `DCError` above all; the attester
/// classifies them (design/29, `DCError`, classified).
public protocol AppAttestService: Sendable {
    /// Whether the service says this device can attest.
    var isSupported: Bool { get }
    /// A new key in the Secure Enclave: its id.
    func generateKey() async throws -> String
    /// Apple's attestation of `keyID` over a 32-byte client data hash.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    /// An assertion by `keyID` over a 32-byte client data hash.
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// The device's App Attest service: `DCAppAttestService.shared`.
public struct SystemAppAttestService: AppAttestService {
    public init() {}

    public var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

/// An App Attest service that answers from a script, for tests of anything
/// built on ``AppAttester``: no Secure Enclave, no Apple.
///
/// Keys are `key-1`, `key-2`, … (base64 of nothing in particular).
/// Attestations and assertions are bytes that name the key and the hash, so
/// a test can tell what was signed: `attestation:<key>:<hash hex>` and
/// `assertion:<n>:<key>:<hash hex>`. It behaves as the device does where the
/// headers say so: a key attests once (a second `attestKey` fails
/// `invalidKey`), a key it never generated, or one invalidated, fails
/// `invalidKey`, and an assertion needs an attested key.
///
/// Failures and delays are queued per call kind (``fail(_:with:times:)``,
/// ``delay(_:by:)``); a delay waits on the ambient clock. Every call is
/// recorded.
public final class ScriptedAppAttestService: AppAttestService {
    /// The three calls.
    public enum Operation: Sendable, Hashable {
        case generateKey, attestKey, generateAssertion
    }

    /// A recorded call: what was asked, and of which key.
    public struct Call: Sendable, Hashable {
        public let operation: Operation
        public let keyID: String?
        public let clientDataHash: [UInt8]?
    }

    private struct State {
        var isSupported: Bool
        var generated = 0
        var assertions = 0
        var keys: [String: KeyState] = [:]
        var failures: [Operation: [any Error & Sendable]] = [:]
        var delays: [Operation: [Duration]] = [:]
        var calls: [Call] = []
    }

    private enum KeyState {
        case generated, attested, invalidated
    }

    private let state: Mutex<State>

    public init(isSupported: Bool = true) {
        state = Mutex(State(isSupported: isSupported))
    }

    public var isSupported: Bool { state.withLock { $0.isSupported } }

    /// Every call made, in order.
    public var calls: [Call] { state.withLock { $0.calls } }

    /// The calls of one kind.
    public func calls(_ operation: Operation) -> [Call] { calls.filter { $0.operation == operation } }

    /// Makes the next `times` calls of `operation` fail with `DCError(code)`.
    public func fail(_ operation: Operation, with code: DCError.Code, times: Int = 1) {
        fail(operation, withError: DCError(code), times: times)
    }

    /// Makes the next `times` calls of `operation` fail with `error`.
    public func fail(_ operation: Operation, withError error: any Error & Sendable, times: Int = 1) {
        state.withLock { $0.failures[operation, default: []] += Array(repeating: error, count: times) }
    }

    /// Makes the next call of `operation` wait `delay` on the ambient clock first.
    public func delay(_ operation: Operation, by delay: Duration) {
        state.withLock { $0.delays[operation, default: []].append(delay) }
    }

    /// Clears the failures and delays still queued for `operation`.
    public func reset(_ operation: Operation) {
        state.withLock { state in
            state.failures[operation] = nil
            state.delays[operation] = nil
        }
    }

    /// The key is gone from the Secure Enclave, as after a reinstall or a
    /// restore: every use of it now fails `invalidKey`.
    public func invalidate(_ keyID: String) {
        state.withLock { $0.keys[keyID] = .invalidated }
    }

    public func generateKey() async throws -> String {
        try await begin(.generateKey, key: nil, hash: nil)
        return state.withLock { state in
            state.generated += 1
            let id = "key-\(state.generated)"
            state.keys[id] = .generated
            return id
        }
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await begin(.attestKey, key: keyID, hash: clientDataHash)
        try state.withLock { state throws in
            guard clientDataHash.count == 32 else { throw DCError(.invalidInput) }
            guard state.keys[keyID] == .generated else { throw DCError(.invalidKey) }
            state.keys[keyID] = .attested
        }
        return Data("attestation:\(keyID):\(Self.hex(clientDataHash))".utf8)
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await begin(.generateAssertion, key: keyID, hash: clientDataHash)
        let number = try state.withLock { state throws -> Int in
            guard clientDataHash.count == 32 else { throw DCError(.invalidInput) }
            guard state.keys[keyID] == .attested else { throw DCError(.invalidKey) }
            state.assertions += 1
            return state.assertions
        }
        return Data("assertion:\(number):\(keyID):\(Self.hex(clientDataHash))".utf8)
    }

    /// Records the call, waits any delay queued for it, then throws any
    /// failure queued for it.
    private func begin(_ operation: Operation, key: String?, hash: Data?) async throws {
        let delay = state.withLock { state -> Duration? in
            state.calls.append(Call(operation: operation, keyID: key, clientDataHash: hash.map(Array.init)))
            guard var queued = state.delays[operation], !queued.isEmpty else { return nil }
            defer { state.delays[operation] = queued }
            return queued.removeFirst()
        }
        if let delay { try await Ambient.sleep(for: delay) }
        let failure = state.withLock { state -> (any Error)? in
            guard var queued = state.failures[operation], !queued.isEmpty else { return nil }
            defer { state.failures[operation] = queued }
            return queued.removeFirst()
        }
        if let failure { throw failure }
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { byte in
            let digits = Array("0123456789abcdef")
            return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
        }.joined()
    }
}
#endif

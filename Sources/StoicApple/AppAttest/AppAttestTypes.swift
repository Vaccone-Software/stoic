#if canImport(DeviceCheck) && canImport(CryptoKit)
public import Stoic

/// Whether this process can attest, decided once (design/29).
public enum AppAttestAvailability: Sendable, Hashable {
    case supported
    case unsupported(AppAttestUnsupported)
}

/// Why this process cannot attest. Its raw value is what a request declares
/// (`App-Attest: unsupported;reason=mac`).
public enum AppAttestUnsupported: String, Sendable, Hashable, Codable {
    /// A macOS app, Mac Catalyst, or an iOS app on a Mac.
    case mac
    /// The iOS Simulator.
    case simulator
    /// An app extension, where `generateKey` fails whatever `isSupported` says.
    case appExtension = "app-extension"
    /// The device says it cannot (`isSupported` is false, or the service
    /// answered `featureUnsupported`).
    case device
}

/// Where an attester stands, for a screen or a test.
public enum AppAttestState: Sendable, Hashable {
    case unsupported(AppAttestUnsupported)
    /// No key is known to be enrolled in this process yet (a key on record is
    /// found when one is first needed).
    case notEnrolled
    case enrolling
    case enrolled(AppAttestKeyID)
    /// The last enrolment failed with this; the next call tries again, once
    /// any hold-off has passed.
    case failed(AppAttestError)
}

/// A key's id as `generateKey` returns it: base64 of the SHA-256 of the public
/// key. Not secret, but it links one install, so it prints truncated.
public struct AppAttestKeyID: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The id exactly as `generateKey` returned it.
    public let base64: String

    public init(base64: String) {
        self.base64 = base64
    }

    /// The first six characters and "…".
    public var description: String { String(base64.prefix(6)) + "…" }
}

/// How an attester enrols and asserts. The defaults are design/29's.
public struct AppAttestPolicy: Sendable, Hashable {
    /// One enrolment, start to finish: a challenge, Apple's attestation, the
    /// enrolment `POST`. 60 s.
    public var enrolmentTimeout: Duration
    /// Between attempts of `attestKey` when Apple's service cannot be
    /// reached: 2 s doubling, capped at 60 s, within the enrolment's timeout.
    public var unavailableBackoff: BoundedSchedule
    /// Attempts of a call that fails `unknownSystemFailure`. 3.
    public var systemFailureAttempts: Int
    /// How long a refused enrolment, a refused fresh key or a revoked key
    /// keeps the attester from enrolling again: each try costs an
    /// attestation. 1 h.
    public var refusedRetryAfter: Duration
    /// Keys tried in one enrolment: a fresh one after a spent one, never a
    /// third. 2.
    public var keysPerEnrolment: Int

    public init(
        enrolmentTimeout: Duration = .seconds(60),
        unavailableBackoff: BoundedSchedule = Schedule.exponential(base: .seconds(2)).capped(at: .seconds(60)).attempts(8),
        systemFailureAttempts: Int = 3,
        refusedRetryAfter: Duration = .seconds(3600),
        keysPerEnrolment: Int = 2
    ) {
        precondition(enrolmentTimeout > .zero && refusedRetryAfter >= .zero, "AppAttestPolicy: durations must be positive")
        precondition(systemFailureAttempts >= 1 && keysPerEnrolment >= 1, "AppAttestPolicy: at least one attempt and one key")
        self.enrolmentTimeout = enrolmentTimeout
        self.unavailableBackoff = unavailableBackoff
        self.systemFailureAttempts = systemFailureAttempts
        self.refusedRetryAfter = refusedRetryAfter
        self.keysPerEnrolment = keysPerEnrolment
    }

    public static let standard = AppAttestPolicy()
}

/// Why an attester could not give a key or an assertion.
///
/// Carries no key id, challenge, attestation or assertion: it is what events,
/// descriptions and logs see.
public enum AppAttestError: Error, Sendable, Hashable, Retryable, CustomStringConvertible {
    /// This process cannot attest: `.stop`.
    case unsupported(AppAttestUnsupported)
    /// Apple's service could not be reached while attesting, for the whole
    /// of the enrolment's timeout: `.retry`. The next call resumes with the
    /// same key.
    case serviceUnavailable
    /// `DCError.unknownSystemFailure` (or another domain's transient error),
    /// after its attempts: `.retry`.
    case systemFailure
    /// The device's key is gone (a reinstall, a restore, a migration); it was
    /// discarded. Enrol again and sign again: `.retry`.
    case keyInvalidated
    /// A fresh key was refused too: `.stop` until the hold-off passes.
    case keyRefused
    /// `DCError.invalidInput`: Stoic's own defect, reported at error level: `.stop`.
    case invalidInput
    /// The app's server refused the attestation with this code: `.stop`
    /// until the hold-off passes.
    case enrolmentRefused(code: String)
    /// The app's server could not be asked: its own classification.
    case serverUnavailable(RetryDecision)
    /// The key's record could not be read or kept: the store's classification.
    case keychain(SecretStoreError)
    /// The enrolment outlasted its timeout, or a waiter its deadline: `.retry`.
    case timedOut
    /// The caller was cancelled.
    case cancelled

    /// Whether the caller's cancellation ended this.
    public var isCancellation: Bool { self == .cancelled }

    public var retryDecision: RetryDecision {
        switch self {
        case .unsupported, .keyRefused, .invalidInput, .enrolmentRefused, .cancelled: .stop
        case .serviceUnavailable, .systemFailure, .keyInvalidated, .timedOut: .retry
        case .serverUnavailable(let decision): decision
        case .keychain(let error): error.retryDecision
        }
    }

    /// True where nothing can have reached the app's server: the attester
    /// decided locally. False wherever an enrolment request may have been sent.
    public var neverReachedBackend: Bool {
        switch self {
        case .unsupported, .keyInvalidated, .invalidInput, .keychain, .cancelled: true
        case .serviceUnavailable, .systemFailure, .keyRefused, .enrolmentRefused, .serverUnavailable, .timedOut: false
        }
    }

    /// A short, stable name: what events and the authenticator's codes say.
    public var code: String {
        switch self {
        case .unsupported: "unsupported"
        case .serviceUnavailable: "service_unavailable"
        case .systemFailure: "system_failure"
        case .keyInvalidated: "key_invalidated"
        case .keyRefused: "key_refused"
        case .invalidInput: "invalid_input"
        case .enrolmentRefused: "enrolment_refused"
        case .serverUnavailable: "server_unavailable"
        case .keychain: "keychain"
        case .timedOut: "timed_out"
        case .cancelled: "cancelled"
        }
    }

    public var description: String {
        switch self {
        case .unsupported(let reason): "App Attest is unsupported here (\(reason.rawValue))"
        case .enrolmentRefused(let code): "the server refused the enrolment (\(code))"
        case .keychain(let error): "the key's record could not be kept (\(error))"
        default: "App Attest: \(code)"
        }
    }
}

/// The app's server, as an attester needs it: a challenge, and an enrolment.
/// `HTTPAppAttestServer` (StoicAttestedHTTP) speaks design/29's wire protocol.
public protocol AppAttestServer: Sendable {
    /// A fresh challenge for `purpose`.
    func challenge(for purpose: AppAttestChallengePurpose) async throws(AppAttestServerError) -> AppAttestChallenge

    /// Enrols `key` with its attestation over `challenge`. Returns the first
    /// request challenge, if the server gives one. Sent again with the same
    /// attestation after a lost response, which the server answers as the
    /// same enrolment.
    func enrol(_ key: AppAttestKeyID, attestation: [UInt8], challenge: AppAttestChallenge)
        async throws(AppAttestServerError) -> AppAttestChallenge?
}

/// What a challenge is for.
public enum AppAttestChallengePurpose: String, Sendable, Hashable, Codable {
    case enrolment, requests
}

/// A challenge the server issued, and how long it stays good from when it
/// arrives.
public struct AppAttestChallenge: Sendable, Hashable, Codable {
    public let bytes: [UInt8]
    public let lifetime: Duration

    public init(bytes: [UInt8], lifetime: Duration) {
        self.bytes = bytes
        self.lifetime = lifetime
    }
}

/// Why the app's server did not answer as an attester needs.
public enum AppAttestServerError: Error, Sendable, Hashable, Retryable {
    /// It could not be asked, or did not answer: the transport's
    /// classification, and whether the request was certainly never sent.
    case unreachable(RetryDecision, neverReachedBackend: Bool)
    /// It answered with a refusal code (design/29's table).
    case refused(code: String)

    public var retryDecision: RetryDecision {
        switch self {
        case .unreachable(let decision, _): decision
        case .refused: .stop
        }
    }

    public var neverReachedBackend: Bool {
        if case .unreachable(_, let never) = self { return never }
        return false
    }
}
#endif

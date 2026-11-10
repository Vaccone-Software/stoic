#if canImport(DeviceCheck) && canImport(CryptoKit)
internal import CryptoKit
internal import DeviceCheck
internal import Foundation
internal import Stoic
internal import Synchronization
internal import StoicFoundation

/// The App Attest key of one account on this install: generated, attested
/// and enrolled once, kept in a `SecretStore`, replaced when it dies
/// (design/29).
///
///     let attester = AppAttester(account: user.id, secrets: KeychainSecretStore(service: "app.kindora"),
///                                server: .http(enrolmentClient))
///     let key = try await attester.enrolledKey()
///
/// - **One key per account per install.** The key's record lives under
///   `stoic.app-attest.<account>`, written phase by phase (generated,
///   attesting, attested, enrolled) before the next step begins, so a process
///   that dies resumes where it stopped and Apple's rate limit and risk
///   metric are spent once per key however often the network fails.
/// - **One enrolment, however many callers.** The enrolment is the
///   attester's own work, bounded by ``AppAttestPolicy/enrolmentTimeout``,
///   not by whoever started it; it goes on when a caller leaves, and each
///   caller waits within its own deadline and cancellation.
/// - **A dead key is replaced once.** An assertion that finds the device's
///   key gone discards it if it is still the current key, so two requests
///   that find it cause one enrolment.
/// - **Unsupported is decided once**, at init (``availability``): nothing is
///   generated, attested or stored where App Attest cannot run.
///
/// Its `SecretStore` calls are synchronous and may wait on the Keychain, so
/// they run on this actor, never on the main actor. Time is the ambient
/// clock in force when it was made; events go to that ambient context's
/// instrumentation.
public actor AppAttester {
    /// Whether this process can attest, decided at init from the platform
    /// and the service. Never throws.
    public nonisolated let availability: AppAttestAvailability
    /// The account the key belongs to: a label the app chooses, not a secret.
    public nonisolated let account: String

    private let secrets: any SecretStore
    private let server: any AppAttestServer
    private let service: any AppAttestService
    private let policy: AppAttestPolicy
    private let ambient: Ambient
    private let recordKey: String

    private var enrolled: AppAttestKeyID?
    private var flight: EnrolmentFlight?
    private var lastFailure: AppAttestError?
    /// No enrolment until this instant (monotonic), with the error to give.
    private var holdOff: (until: AnyClock.Instant, error: AppAttestError)?
    /// `generateKey` or `generateAssertion` said `featureUnsupported`.
    private var serviceUnsupported = false
    private var reportedUnsupported = false
    /// Keys this process found dead: a record naming one is not trusted.
    private var deadKeys: Set<String> = []
    /// The first request challenge an enrolment returned, for the
    /// authenticator, with when it arrived.
    private var firstRequestChallenge: (challenge: AppAttestChallenge, arrived: AnyClock.Instant)?

    /// - Parameters:
    ///   - account: The app's label for the account (one key each).
    ///   - secrets: Where the key's record is kept: `KeychainSecretStore`.
    ///   - server: The app's server (`.http(client)` in StoicAttestedHTTP).
    ///   - service: Apple's service; tests pass `ScriptedAppAttestService`.
    ///   - policy: Timeouts, backoff and limits.
    public init(
        account: String, secrets: any SecretStore, server: any AppAttestServer,
        service: any AppAttestService = SystemAppAttestService(), policy: AppAttestPolicy = .standard
    ) {
        self.init(account: account, secrets: secrets, server: server, service: service, policy: policy, platform: .current)
    }

    init(
        account: String, secrets: any SecretStore, server: any AppAttestServer,
        service: any AppAttestService, policy: AppAttestPolicy, platform: AppAttestPlatform
    ) {
        self.account = account
        self.secrets = secrets
        self.server = server
        self.service = service
        self.policy = policy
        self.ambient = Ambient.current
        self.recordKey = "stoic.app-attest.\(account)"
        self.availability = Self.availability(isSupported: service.isSupported, platform: platform)
        if case .unsupported(let reason) = availability {
            AppAttestEvents.unsupported(reason, account: account)
            reportedUnsupported = true
        }
    }

    /// The decision ``availability`` records (design/29, Unsupported).
    static func availability(isSupported: Bool, platform: AppAttestPlatform) -> AppAttestAvailability {
        if platform.isSimulator { return .unsupported(.simulator) }
        if platform.isMac, !isSupported { return .unsupported(.mac) }
        if platform.isAppExtension, !platform.isWatch { return .unsupported(.appExtension) }
        return isSupported ? .supported : .unsupported(.device)
    }

    /// Where the attester stands now, in this process.
    public var state: AppAttestState {
        if case .unsupported(let reason) = availability { return .unsupported(reason) }
        if serviceUnsupported { return .unsupported(.device) }
        if flight != nil { return .enrolling }
        if let enrolled { return .enrolled(enrolled) }
        if let lastFailure { return .failed(lastFailure) }
        return .notEnrolled
    }

    /// The callers waiting on the enrolment in flight, for tests.
    var enrolmentWaiters: Int { flight?.waiterCount ?? 0 }

    // MARK: The key

    /// The enrolled key, enrolling one if needed: one enrolment, however many
    /// callers.
    ///
    /// A caller waits within its own deadline (`.timedOut`) and cancellation
    /// (`.cancelled`); the enrolment goes on without it.
    ///
    /// - Throws: ``AppAttestError``.
    public func enrolledKey() async throws(AppAttestError) -> AppAttestKeyID {
        try requireSupport()
        if let enrolled { return enrolled }
        if let holdOff, ambient.clock.now < holdOff.until { throw holdOff.error }
        if Task.isCancelled { throw Self.leaving() }
        let flight = self.flight ?? beginEnrolment()
        guard let outcome = await flight.wait() else { throw Self.leaving() }
        return try outcome.get()
    }

    /// An assertion object over a 32-byte client data hash, signed by `key`.
    ///
    /// `key` must be the one enrolled now: a key discarded meanwhile fails
    /// ``AppAttestError/keyInvalidated`` without asking the device. A device
    /// that finds the key gone fails the same, and the key is discarded (if
    /// it is still the current key) so the next ``enrolledKey()`` enrols
    /// another.
    public func assertion(over clientDataHash: [UInt8], with key: AppAttestKeyID) async throws(AppAttestError) -> [UInt8] {
        try requireSupport()
        guard enrolled == key, !deadKeys.contains(key.base64) else { throw .keyInvalidated }
        var systemFailures = 0
        while true {
            if Task.isCancelled { throw Self.leaving() }
            let result: Result<Data, any Error>
            do {
                result = .success(try await service.generateAssertion(key.base64, clientDataHash: Data(clientDataHash)))
            } catch {
                result = .failure(error)
            }
            // The device does not observe cancellation: a caller cancelled
            // during the call leaves when it ends.
            if Task.isCancelled { throw Self.leaving() }
            switch result {
            case .success(let assertion):
                return Array(assertion)
            case .failure(let error):
                switch DeviceCheckFailure(error) {
                case .invalidKey:
                    try invalidate(key)
                    throw .keyInvalidated
                case .systemFailure:
                    systemFailures += 1
                    if systemFailures >= policy.systemFailureAttempts { throw .systemFailure }
                case .unsupported:
                    markUnsupported()
                    throw .unsupported(.device)
                case .invalidInput:
                    AppAttestEvents.invalidInput(operation: "generateAssertion", account: account)
                    throw .invalidInput
                case .serverUnavailable, .other:
                    throw .systemFailure
                }
            }
        }
    }

    /// Forgets `key`: the server does not know it, or the device refused it.
    /// The next ``enrolledKey()`` enrols another. Nothing happens if `key` is
    /// not the current key.
    ///
    /// - Parameter reason: Why, in the app's words (`"unknown_key"`); recorded
    ///   privately in no event, kept for the caller's own log.
    public func discard(_ key: AppAttestKeyID, because reason: String) async throws(AppAttestError) {
        deadKeys.insert(key.base64)
        if enrolled == key { enrolled = nil }
        try deleteRecord(ifItNames: key)
    }

    /// Forgets `key` because the server revoked it, and enrols nothing for
    /// ``AppAttestPolicy/refusedRetryAfter``: each enrolment costs an
    /// attestation, and a revoked device is not one to spend it on.
    public func revoked(_ key: AppAttestKeyID) async throws(AppAttestError) {
        try await discard(key, because: "revoked")
        try refuse(.enrolmentRefused(code: "revoked"), code: "revoked")
    }

    /// A request challenge for the authenticator: the one the enrolment
    /// returned, if it is still fresh by the monotonic clock, else a new one
    /// from the server.
    public func requestChallenge() async throws(AppAttestError) -> AppAttestChallenge {
        if let held = firstRequestChallenge {
            firstRequestChallenge = nil
            if ambient.clock.now < held.arrived.advanced(by: held.challenge.lifetime) { return held.challenge }
        }
        do throws(AppAttestServerError) {
            return try await server.challenge(for: .requests)
        } catch {
            switch error {
            case .unreachable(let decision, _): throw .serverUnavailable(decision)
            case .refused: throw .serverUnavailable(.stop)
            }
        }
    }

    // MARK: Enrolment

    private func beginEnrolment() -> EnrolmentFlight {
        let flight = EnrolmentFlight()
        self.flight = flight
        Task.owned(in: ambient) { [self] in
            let outcome = await self.enrol()
            await self.finish(flight, outcome)
        }
        return flight
    }

    private func finish(_ flight: EnrolmentFlight, _ outcome: EnrolmentFlight.Outcome) {
        if self.flight === flight { self.flight = nil }
        switch outcome {
        case .success(let key):
            enrolled = key
            lastFailure = nil
        case .failure(let error):
            lastFailure = error
        }
        flight.finish(outcome)
    }

    /// One enrolment, from the phase on record, within its timeout.
    private func enrol() async -> EnrolmentFlight.Outcome {
        let clock = ambient.clock
        let started = clock.now
        let deadline = started.advanced(by: policy.enrolmentTimeout)
        let progress = EnrolmentProgress()
        let outcome = await withTimeout(policy.enrolmentTimeout, clock: clock, label: "app-attest enrolment") {
            () async -> Result<EnrolmentProgress.Enrolled, AppAttestError> in
            do throws(AppAttestError) {
                return .success(try await self.steps(until: deadline, progress: progress))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let enrolled):
            AppAttestEvents.enrolled(
                account: account, took: started.duration(to: clock.now), keys: enrolled.keysTried, replaced: enrolled.replaced)
            return .success(enrolled.key)
        case .failure(let error):
            AppAttestEvents.enrolmentFailed(error, account: account, retryIn: holdOff.map { clock.now.duration(to: $0.until) })
            return .failure(error)
        }
    }

    /// The steps of design/29's Enrolment, each written before the next.
    private func steps(until deadline: AnyClock.Instant, progress: EnrolmentProgress) async throws(AppAttestError) -> EnrolmentProgress.Enrolled {
        var record = try readRecord()
        let startingKey = record?.phase == .refused ? nil : record?.key
        var keysTried = startingKey != nil && record?.phase != .enrolled ? 1 : 0
        var backoff = policy.unavailableBackoff.makeStepper(random: ambient.random.generator())
        let backoffStarted = ambient.clock.now
        var systemFailures = 0
        func done(_ key: String) -> EnrolmentProgress.Enrolled {
            // It replaced one if it is not the key on record when it began,
            // or if this process found a key dead (whose record went with it).
            EnrolmentProgress.Enrolled(
                key: AppAttestKeyID(base64: key), keysTried: max(keysTried, 1),
                replaced: startingKey.map { $0 != key } ?? !deadKeys.isEmpty)
        }
        while true {
            if Task.isCancelled { throw progress.timedOut }
            guard let current = record else {
                guard keysTried < policy.keysPerEnrolment else {
                    AppAttestEvents.keyRefused(account: account)
                    try refuse(.keyRefused, code: "key_refused")
                    throw .keyRefused
                }
                keysTried += 1
                let key = try await generateKey()
                record = .generated(key)
                try write(.generated(key))
                continue
            }
            guard let key = current.key ?? (current.phase == .refused ? "" : nil) else { record = nil; continue }
            switch current.phase {
            case .enrolled:
                return done(key)

            case .refused:
                let now = ambient.wallClock.now
                if let until = current.until, now < until, now.duration(to: until) <= policy.refusedRetryAfter {
                    let error: AppAttestError = current.code == "key_refused" ? .keyRefused : .enrolmentRefused(code: current.code ?? "")
                    holdOff = (ambient.clock.now.advanced(by: now.duration(to: until)), error)
                    throw error
                }
                try deleteRecord()
                record = nil

            case .generated:
                let next = AppAttestRecord.attesting(key, try await enrolmentChallenge(), at: ambient.wallClock.now)
                try write(next)
                record = next

            case .attesting:
                guard let challenge = current.heldChallenge, let arrived = current.challengeAt else { record = nil; continue }
                // Measured by the wall clock from the arrival on record: the
                // record outlives the process. A wrong clock costs at worst a
                // server refusal of an expired challenge.
                if arrived.duration(to: ambient.wallClock.now) > challenge.lifetime {
                    let next = AppAttestRecord.attesting(key, try await enrolmentChallenge(), at: ambient.wallClock.now)
                    try write(next)
                    record = next
                    continue
                }
                let hash = Array(SHA256.hash(data: challenge.bytes))
                let result: Result<Data, any Error>
                do {
                    result = .success(try await service.attestKey(key, clientDataHash: Data(hash)))
                } catch {
                    result = .failure(error)
                }
                switch result {
                case .success(let attestation):
                    progress.reached()
                    let next = AppAttestRecord.attested(key, challenge, attestation: Array(attestation))
                    try write(next)
                    record = next
                case .failure(let error):
                    switch DeviceCheckFailure(error) {
                    case .invalidKey:
                        // Spent: already attested (a crash after `attestKey`),
                        // or rejected. A new key, within keysPerEnrolment.
                        try deleteRecord()
                        record = nil
                    case .serverUnavailable:
                        progress.unreachable()
                        // The same key and hash, after the backoff, while the
                        // enrolment lasts; past the challenge's lifetime the
                        // loop replaces the challenge and keeps the key.
                        guard let delay = backoff.next(elapsed: backoffStarted.duration(to: ambient.clock.now)),
                              ambient.clock.now.advanced(by: delay) < deadline else { throw .serviceUnavailable }
                        AppAttestEvents.serviceUnavailable(account: account, retryIn: delay)
                        do {
                            try await Ambient.sleep(for: delay)
                        } catch {
                            throw progress.timedOut
                        }
                    case .systemFailure:
                        systemFailures += 1
                        if systemFailures >= policy.systemFailureAttempts { throw .systemFailure }
                    case .unsupported:
                        markUnsupported()
                        throw .unsupported(.device)
                    case .invalidInput:
                        AppAttestEvents.invalidInput(operation: "attestKey", account: account)
                        throw .invalidInput
                    case .other:
                        throw .systemFailure
                    }
                }

            case .attested:
                guard let challenge = current.heldChallenge, let attestation = current.heldAttestation else { record = nil; continue }
                let first: AppAttestChallenge?
                do throws(AppAttestServerError) {
                    first = try await server.enrol(AppAttestKeyID(base64: key), attestation: attestation, challenge: challenge)
                } catch {
                    switch error {
                    case .refused(let code) where code == "challenge_expired" || code == "challenge_used":
                        // The attestation names that challenge, and the key
                        // cannot be attested again: a new key.
                        try deleteRecord()
                        record = nil
                        continue
                    case .refused(let code):
                        try deleteRecord()
                        try refuse(.enrolmentRefused(code: code), code: code)
                        throw .enrolmentRefused(code: code)
                    case .unreachable(let decision, _):
                        throw .serverUnavailable(decision)
                    }
                }
                try write(.enrolled(key))
                if let first { firstRequestChallenge = (first, ambient.clock.now) }
                return done(key)
            }
        }
    }

    private func enrolmentChallenge() async throws(AppAttestError) -> AppAttestChallenge {
        do throws(AppAttestServerError) {
            return try await server.challenge(for: .enrolment)
        } catch {
            switch error {
            case .unreachable(let decision, _): throw .serverUnavailable(decision)
            case .refused(let code): throw .enrolmentRefused(code: code)
            }
        }
    }

    private func generateKey() async throws(AppAttestError) -> String {
        var systemFailures = 0
        while true {
            if Task.isCancelled { throw .timedOut }
            do {
                return try await service.generateKey()
            } catch {
                switch DeviceCheckFailure(error) {
                case .systemFailure:
                    systemFailures += 1
                    if systemFailures >= policy.systemFailureAttempts { throw .systemFailure }
                case .unsupported:
                    markUnsupported()
                    throw .unsupported(.device)
                case .invalidInput:
                    AppAttestEvents.invalidInput(operation: "generateKey", account: account)
                    throw .invalidInput
                case .invalidKey, .serverUnavailable, .other:
                    throw .systemFailure
                }
            }
        }
    }

    // MARK: State

    private func requireSupport() throws(AppAttestError) {
        if case .unsupported(let reason) = availability { throw .unsupported(reason) }
        if serviceUnsupported { throw .unsupported(.device) }
    }

    private func markUnsupported() {
        serviceUnsupported = true
        enrolled = nil
        if !reportedUnsupported {
            reportedUnsupported = true
            AppAttestEvents.unsupported(.device, account: account)
        }
    }

    /// The device's key is gone: forget it if it is still the current key.
    private func invalidate(_ key: AppAttestKeyID) throws(AppAttestError) {
        guard !deadKeys.contains(key.base64) else { return }
        deadKeys.insert(key.base64)
        if enrolled == key { enrolled = nil }
        AppAttestEvents.keyInvalidated(account: account)
        try deleteRecord(ifItNames: key)
    }

    /// Records a refusal on the record and in memory: nothing is enrolled
    /// until ``AppAttestPolicy/refusedRetryAfter`` has passed.
    private func refuse(_ error: AppAttestError, code: String) throws(AppAttestError) {
        holdOff = (ambient.clock.now.advanced(by: policy.refusedRetryAfter), error)
        try write(.refused(code: code, until: ambient.wallClock.now + policy.refusedRetryAfter))
    }

    // MARK: The record

    /// The record on file, or `nil`: none, one that does not decode or lacks
    /// what its phase needs, or one naming a key this process found dead.
    /// A locked store throws, and is never a reason to generate a key.
    private func readRecord() throws(AppAttestError) -> AppAttestRecord? {
        guard let record = try storedRecord() else { return nil }
        if let key = record.key, deadKeys.contains(key) { return nil }
        return record
    }

    /// The record as stored, whatever key it names; `nil` as for ``readRecord()``.
    private func storedRecord() throws(AppAttestError) -> AppAttestRecord? {
        let data: Data?
        do throws(SecretStoreError) {
            data = try secrets.get(recordKey)
        } catch {
            throw .keychain(error)
        }
        guard let data else { return nil }
        // A record that does not decode is no record: its key cannot be used
        // without the rest, and the next write replaces it.
        let decoded: AppAttestRecord
        do {
            decoded = try JSONDecoder().decode(AppAttestRecord.self, from: data)
        } catch {
            return nil
        }
        return decoded.isComplete ? decoded : nil
    }

    /// Deletes the record if it is `key`'s: a record another enrolment wrote
    /// since is not this key's to delete.
    private func deleteRecord(ifItNames key: AppAttestKeyID) throws(AppAttestError) {
        if let record = try storedRecord(), record.key == key.base64 { try deleteRecord() }
    }

    private func write(_ record: AppAttestRecord) throws(AppAttestError) {
        let data = try record.encoded()
        do throws(SecretStoreError) {
            try secrets.set(data, for: recordKey)
        } catch {
            throw .keychain(error)
        }
    }

    private func deleteRecord() throws(AppAttestError) {
        do throws(SecretStoreError) {
            try secrets.delete(recordKey)
        } catch {
            throw .keychain(error)
        }
    }

    /// What a caller that leaves gets: its deadline, or its cancellation.
    private static func leaving() -> AppAttestError {
        CancellationCause.current == .deadline || Deadline.current?.hasPassed == true ? .timedOut : .cancelled
    }
}

/// What the steps of one enrolment have learnt, for its timeout to report.
final class EnrolmentProgress: Sendable {
    struct Enrolled: Sendable {
        var key: AppAttestKeyID
        var keysTried: Int
        var replaced: Bool
    }

    /// The last call to Apple's service could not reach it: a timeout then
    /// is Apple's service being unavailable, not the enrolment being slow.
    private let unavailable = Mutex(false)

    func unreachable() { unavailable.withLock { $0 = true } }
    func reached() { unavailable.withLock { $0 = false } }

    var timedOut: AppAttestError { unavailable.withLock { $0 } ? .serviceUnavailable : .timedOut }
}

/// The platform facts ``AppAttester/availability`` is decided from.
struct AppAttestPlatform: Sendable {
    var isSimulator: Bool
    var isMac: Bool
    var isAppExtension: Bool
    var isWatch: Bool

    static var current: AppAttestPlatform {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        #if os(macOS) || targetEnvironment(macCatalyst)
        let mac = true
        #else
        let mac = ProcessInfo.processInfo.isiOSAppOnMac
        #endif
        #if os(watchOS)
        let watch = true
        #else
        let watch = false
        #endif
        return AppAttestPlatform(
            isSimulator: simulator, isMac: mac, isAppExtension: Bundle.main.bundlePath.hasSuffix(".appex"), isWatch: watch)
    }
}

/// How a DeviceCheck call failed, as design/29's table reads it.
enum DeviceCheckFailure {
    case systemFailure, unsupported, invalidInput, invalidKey, serverUnavailable, other

    init(_ error: any Error) {
        if let error = error as? DCError {
            switch error.code {
            case .unknownSystemFailure: self = .systemFailure
            case .featureUnsupported: self = .unsupported
            case .invalidInput: self = .invalidInput
            case .invalidKey: self = .invalidKey
            case .serverUnavailable: self = .serverUnavailable
            @unknown default: self = .other
            }
            return
        }
        // Another domain: Foundation's table (design/05) says whether it is
        // transient; a transient one is retried as a system failure is.
        if let error = error as? URLError {
            self = error.retryDecision == .stop ? .other : .systemFailure
        } else if let error = error as? POSIXError {
            self = error.retryDecision == .stop ? .other : .systemFailure
        } else {
            self = .other
        }
    }
}

/// The attester's events (design/29, Events). Accounts are private; key ids,
/// challenges, attestations and assertions are never recorded.
enum AppAttestEvents {
    static let label = "app-attest"

    static func enrolled(account: String, took: Duration, keys: Int, replaced: Bool) {
        Ambient.record(Event("attest.enrolled", level: .info, label: label, fields: [
            .init("account", .string(account), privacy: .private),
            .init("duration", .duration(took)),
            .init("keys", .int(keys)),
            .init("replaced", .bool(replaced)),
        ]))
    }

    static func enrolmentFailed(_ error: AppAttestError, account: String, retryIn: Duration?) {
        var fields: [Event.Field] = [
            .init("account", .string(account), privacy: .private),
            .init("code", .string(error.code), privacy: .public),
        ]
        if let retryIn { fields.append(.init("retry_in", .duration(retryIn))) }
        Ambient.record(Event("attest.enrolment_failed", level: .warning, label: label, fields: fields))
    }

    static func serviceUnavailable(account: String, retryIn: Duration) {
        Ambient.record(Event("attest.service_unavailable", level: .notice, label: label, fields: [
            .init("account", .string(account), privacy: .private),
            .init("retry_in", .duration(retryIn)),
        ]))
    }

    static func keyInvalidated(account: String) {
        Ambient.record(Event("attest.key_invalidated", level: .notice, label: label, fields: [
            .init("account", .string(account), privacy: .private),
        ]))
    }

    static func keyRefused(account: String) {
        Ambient.record(Event("attest.key_refused", level: .error, label: label, fields: [
            .init("account", .string(account), privacy: .private),
        ]))
    }

    static func unsupported(_ reason: AppAttestUnsupported, account: String) {
        Ambient.record(Event("attest.unsupported", level: .notice, label: label, fields: [
            .init("account", .string(account), privacy: .private),
            .init("reason", .string(reason.rawValue), privacy: .public),
        ]))
    }

    static func invalidInput(operation: String, account: String) {
        Ambient.record(Event("attest.invalid_input", level: .error, label: label, fields: [
            .init("account", .string(account), privacy: .private),
            .init("operation", .string(operation), privacy: .public),
        ]))
    }
}
#endif

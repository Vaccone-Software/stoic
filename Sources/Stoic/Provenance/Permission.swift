/// A permission: what it is about, who asks, and a stable name (design/28).
///
///     enum EditEvent: Permission {
///         typealias Subject = EventID
///         typealias Principal = Someone
///         static let name = "events.edit"
///     }
///
/// Declared as a caseless enum. A ``PermissionPolicy`` decides it; Stoic
/// writes the check, which is the only code that makes a ``Granted`` proof.
public protocol Permission: Sendable {
    /// What the permission is about: an event's id.
    associatedtype Subject: Hashable & Sendable
    /// Who asks.
    associatedtype Principal: Hashable & Sendable
    /// Stable: grants and events carry it.
    static var name: String { get }
}

/// How one permission is decided: the app's code, in one place per
/// permission, reading whatever it needs.
///
///     struct OwnCommitment: PermissionPolicy {
///         let name = "own-commitment"
///         func decide(_ who: Verified<Someone, Session>, _ commitment: CommitmentID) async throws -> PermissionDecision {
///             guard let owner = try await commitments.owner(of: commitment) else { return .deny("no such commitment") }
///             return owner == who.value ? .allow : .deny("this is someone else's commitment")
///         }
///     }
///
/// The principal it receives is verified by the app's own principal
/// evidence (`Authentication`), so "who is asking" is never an argument the
/// caller chose. Throwing means "could not decide": the check reports it as
/// `.unknown(.unavailable(<error type>))`, never as a denial.
public protocol PermissionPolicy<Granting>: Sendable {
    /// The permission this policy decides.
    associatedtype Granting: Permission
    /// The evidence its principals must carry.
    associatedtype Authentication: PrincipalEvidence

    /// Recorded in every grant and event.
    var name: String { get }

    /// The decision for `principal` on `subject`. Runs on the caller's
    /// executor.
    nonisolated(nonsending) func decide(
        _ principal: Verified<Granting.Principal, Authentication>, _ subject: Granting.Subject
    ) async throws -> PermissionDecision
}

/// What a policy decided.
public enum PermissionDecision: Sendable, Hashable {
    /// The principal may.
    case allow
    /// The principal may not, for this reason, which goes to the caller and
    /// never to an event (a reason can name a person).
    case deny(String)
    /// No decision: the facts are not here yet, or could not be read.
    case unknown(PermissionUnknown)
}

/// Why there is no decision.
public enum PermissionUnknown: Sendable, Hashable {
    /// What the decision needs is still loading: draw it as loading, never
    /// as "denied" or "allowed".
    case loading
    /// What the decision needs could not be read: for a policy that throws,
    /// the error's type.
    case unavailable(String)
}

/// The outcome of a check: three answers, and none of them a `Bool`.
///
///     switch editCheck {
///     case .granted(let proof): Button("Edit") { open(proof) }     // the action takes the proof
///     case .denied(let denial): Text(denial.reason)
///     case .unknown:            ProgressView()
///     }
public enum PermissionCheck<P: Permission>: Sendable {
    /// Allowed: the subject, proved by the grant.
    case granted(Granted<P>)
    /// Denied, with the policy's reason.
    case denied(PermissionDenial<P>)
    /// Not decided.
    case unknown(PermissionUnknown)

    /// The grant, for a handler that must act or fail: a denial throws
    /// ``PermissionRefusal/denied(_:)`` (`.stop`, a 403) and an unknown
    /// ``PermissionRefusal/unknown(_:)`` (`.retry`, a 503, never a 403).
    public func granted() throws(PermissionRefusal<P>) -> Granted<P> {
        switch self {
        case .granted(let grant): return grant
        case .denied(let denial): throw .denied(denial)
        case .unknown(let unknown): throw .unknown(unknown)
        }
    }
}

/// Evidence that a policy allowed a principal `P` on a subject.
///
/// A record of a decision, made at ``decidedAt``: it does not expire by
/// itself, and nothing revokes it. A server checks per request and holds
/// none past it; a client holds grants to draw its screen, and encoded a
/// `Granted<P>` is only its subject, which the server checks again.
public struct Grant<P: Permission>: Evidence, Hashable {
    /// Constructible only in this file, by the check.
    public struct Mint {
        fileprivate init() {}
    }

    public static var proves: String {
        "the named policy allowed this principal \(P.name) on this subject, at the moment it decided"
    }

    /// Who was allowed.
    public let principal: P.Principal
    /// The name of the policy that allowed it.
    public let policy: String
    /// When the policy decided, by the ambient wall clock.
    public let decidedAt: Moment

    fileprivate init(principal: P.Principal, policy: String, decidedAt: Moment) {
        self.principal = principal
        self.policy = policy
        self.decidedAt = decidedAt
    }
}

/// A subject, proved granted: what an action takes in place of an id, so a
/// grant for one subject cannot be paired with another.
public typealias Granted<P: Permission> = Verified<P.Subject, Grant<P>>

/// A policy's refusal.
public struct PermissionDenial<P: Permission>: Sendable, Hashable {
    public let subject: P.Subject
    public let principal: P.Principal
    public let policy: String
    /// The policy's reason, for the caller to show or not.
    public let reason: String
}

/// Why ``PermissionCheck/granted()`` gave no grant.
public enum PermissionRefusal<P: Permission>: Error, Sendable, Hashable, Retryable {
    /// The policy denied: `.stop`, answered 403.
    case denied(PermissionDenial<P>)
    /// No decision: `.retry`, answered 503, never 403.
    case unknown(PermissionUnknown)

    public var retryDecision: RetryDecision {
        switch self {
        case .denied: .stop
        case .unknown: .retry
        }
    }
}

extension PermissionPolicy {
    /// Checks the claimed `subject` for `principal`: the only producer of a
    /// ``Granted`` proof.
    ///
    /// The subject is a claim (usually an id from a request) and this is its
    /// verifier. The policy decides; a policy that throws gives
    /// `.unknown(.unavailable(<error type>))`. Cancellation is checked before
    /// the policy runs and after it returns, and is never an outcome: a
    /// cancelled caller gets `CancellationError`, and nothing is reported.
    ///
    /// Reports `permission.granted` (debug), `permission.denied` (info) or
    /// `permission.unknown` (notice), labelled with the permission's name:
    /// the policy's name publicly, subject and principal as private
    /// descriptions, never the reason.
    public nonisolated(nonsending) func check(
        _ subject: Claimed<Granting.Subject>, by principal: Verified<Granting.Principal, Authentication>
    ) async throws(CancellationError) -> PermissionCheck<Granting> {
        let minter = Minter<Grant<Granting>>(Grant<Granting>.Mint())
        let target = minter.read(subject)
        if Task.isCancelled { throw CancellationError() }
        let clock = Ambient.current.clock
        let started = clock.now
        let decision: PermissionDecision
        var failure: String?
        do {
            decision = try await decide(principal, target)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            failure = String(reflecting: type(of: error))
            decision = .unknown(.unavailable(failure ?? ""))
        }
        if Task.isCancelled { throw CancellationError() }
        let took = started.duration(to: clock.now)
        let fields: [Event.Field] = [
            .init("policy", .string(name), privacy: .public),
            .init("subject", .string(String(describing: target)), privacy: .private),
            .init("principal", .string(String(describing: principal.value)), privacy: .private),
        ]
        switch decision {
        case .allow:
            let grant = Grant<Granting>(principal: principal.value, policy: name, decidedAt: Ambient.current.wallClock.now)
            Ambient.record(level: .debug) {
                Event("permission.granted", level: .debug, label: Granting.name, fields: fields + [.init("duration", .duration(took))])
            }
            return .granted(minter.verified(target, grant))
        case .deny(let reason):
            Ambient.record(Event("permission.denied", level: .info, label: Granting.name, fields: fields))
            return .denied(PermissionDenial(subject: target, principal: principal.value, policy: name, reason: reason))
        case .unknown(let unknown):
            var detail = fields
            switch unknown {
            case .loading:
                detail.append(.init("unknown", .string("loading"), privacy: .public))
            case .unavailable:
                detail.append(.init("unknown", .string("unavailable"), privacy: .public))
                // A thrown error's type is public; a reason the policy returned is its own words, and is not recorded.
                if let failure { detail.append(.init("error", .string(failure), privacy: .public)) }
            }
            Ambient.record(Event("permission.unknown", level: .notice, label: Granting.name, fields: detail))
            return .unknown(unknown)
        }
    }
}

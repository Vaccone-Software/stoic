/// Whether a reconciler's two sides agree, as a screen or a health check
/// reads it (design/30). It changes once per pass, at the end.
public struct ReconcilerStatus<Key: Hashable & Sendable & Comparable>: Sendable, Hashable {
    /// The most severe thing that applies.
    public enum Phase: Sendable, Hashable {
        /// No full pass has read both sides yet.
        case starting
        /// No difference is known.
        case converged
        /// Differences are known, and being corrected or verified.
        case converging(differences: Int)
        /// Some keys stopped converging (``ReconcilerStatus/stuck``).
        case stuck(differences: Int)
        /// Removals wait for a person (``ReconcilerStatus/hold``).
        case held(differences: Int)
        /// The latest pass could not read that side: nothing was corrected.
        case unreadable(ReconcileSide)
    }

    /// The most severe thing that applies.
    public let phase: Phase
    /// When a reading last found no difference left.
    public let lastConverged: Moment?
    /// When a full pass last read both sides.
    public let lastFullPass: Moment?
    /// Keys that stopped converging, in key order.
    public let stuck: [ReconcileStuck<Key>]
    /// Removals waiting for a person.
    public let hold: RemovalHold<Key>?
    /// Why the latest pass could not read a side.
    public let unreadable: ReconcileFailure?
    /// When the reconciler is overdue: the last full pass (or its start)
    /// plus `overdueAfter`.
    public let overdueAt: Moment

    /// Whether no full pass has read both sides for `overdueAfter`. A
    /// reconciler that stopped running is overdue, not converged.
    public func isOverdue(at now: Moment = .now) -> Bool {
        now >= overdueAt
    }
}

/// One of a reconciliation's two sides.
public enum ReconcileSide: String, Sendable, Hashable, CustomStringConvertible {
    case truth, derived

    public var description: String { rawValue }
}

/// A key that stopped converging, and why.
public struct ReconcileStuck<Key: Hashable & Sendable>: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// Its correction keeps failing.
        case failing(ReconcileFailure)
        /// Its correction succeeds, and the next reading still differs: a
        /// `matches` that disagrees with the derived side, usually.
        case doesNotTake
        /// A job said it cannot converge it, and why.
        case refused(String)
    }

    public let key: Key
    /// The correction that does not converge, when one was made.
    public let kind: CorrectionKind?
    public let reason: Reason
    /// Passes in a row.
    public let passes: Int
    /// When it became stuck.
    public let since: Moment
}

/// A failure as a reconciler reports it: never its description.
public struct ReconcileFailure: Sendable, Hashable {
    /// The error's type, as events record it.
    public let errorType: String
    /// Matches the event that reported it (design/31).
    public let reference: SupportReference
    /// Whether it was a ``Defect``.
    public let isDefect: Bool

    init(_ error: any Error) {
        var shown = error
        if let operation = error as? any OperationErrorCarrying {
            if let rejection = operation.carriedRejection {
                shown = rejection
            } else if let last = operation.carriedLast {
                shown = last
            }
        }
        errorType = String(reflecting: type(of: shown))
        reference = SupportReference.make()
        isDefect = containsDefect(error)
    }
}

/// What one pass did.
public struct ReconcilePassReport<Key: Hashable & Sendable>: Sendable {
    public enum Outcome: String, Sendable, Hashable, CustomStringConvertible {
        /// No difference.
        case clean
        /// Every difference it could correct was corrected.
        case corrected
        /// Some corrections failed, or waited their backoff.
        case partial
        /// Removals were held for a person.
        case held
        /// Its deadline or its limit stopped it: the rest follows.
        case cutShort
        /// It was cancelled; what it finished stands.
        case cancelled

        public var description: String { rawValue }
    }

    public let scope: ReconcileScope<Key>
    public let started: Moment
    public let ended: Moment
    public let outcome: Outcome
    /// Differences this pass's reading found.
    public let differences: Int
    /// Corrections that returned success.
    public let applied: Int
    /// Corrections that failed.
    public let failed: Int
    /// Corrections it did not start (its limit) or that its deadline cut off.
    public let deferred: Int
    /// Keys it skipped because they wait their backoff.
    public let waiting: Int
    /// Removals it held for a person.
    public let held: Int
    /// The reason a person gave to `confirm`, when this pass used their
    /// confirmation. Never put in an event.
    public let confirmation: String?
}

/// Why a pass, or a confirmation, did not happen.
public enum ReconcileError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A side could not be read: nothing was corrected.
    case unreadable(ReconcileSide, ReconcileFailure)
    /// The pass, or the wait for one in progress, was cancelled (its caller's
    /// deadline passed, or the system expired a background task).
    case cancelled
    /// `confirm`: that hold is no longer the current one.
    case holdChanged

    /// True for ``cancelled``: a typed throw cannot carry a
    /// `CancellationError`, so Stoic's classification reads this one as it.
    public var isCancellation: Bool {
        self == .cancelled
    }

    public var description: String {
        switch self {
        case .unreadable(let side, let failure): "the \(side) could not be read (\(failure.errorType), reference \(failure.reference))"
        case .cancelled: "cancelled"
        case .holdChanged: "that hold is no longer the current one"
        }
    }
}

extension ReconcileError: RejectionCarrying {
    var carriedRejection: Rejection? {
        isCancellation ? Rejection(.cancelled) : nil
    }

    var carriedFailure: (any Error)? { nil }
}

extension ReconcileError: PresentationLayer {
    var presentationStep: PresentationStep {
        switch self {
        case .unreadable: .decisive(StoicPresentation.sync)
        case .cancelled: .opaque
        case .holdChanged: .decisive(StoicPresentation.conflict)
        }
    }
}

extension IdempotencyKey {
    /// A correction's key: the pass's random key and the correction's position
    /// in the plan, so every attempt of one correction sends the same key and
    /// the next pass's is new (design/30).
    ///
    /// Frozen once built. Each half is the FNV-1a hash of `"reconciliation"`
    /// and `0xFF`, the half's index (8 bytes), the pass key's half as UTF-8 and
    /// `0xFF`, and the position (8 bytes), all little-endian, SplitMix64
    /// finalised, as 16 hexadecimal digits: `lifecycle(record:entry:position:)`'s
    /// construction under another name.
    public static func reconciliation(pass: IdempotencyKey, position: Int) -> IdempotencyKey {
        func half(_ part: Substring, _ which: UInt64) -> UInt64 {
            var hash = StableHash()
            hash.combine("reconciliation")
            hash.combine(which)
            hash.combine(part.utf8)
            hash.combine(CollectionOfOne(0xFF))
            hash.combine(UInt64(truncatingIfNeeded: position))
            var z = hash.value &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func hexadecimal(_ value: UInt64) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }
        let raw = pass.rawValue
        let middle = raw.index(raw.startIndex, offsetBy: raw.count / 2)
        return IdempotencyKey(rawValue: hexadecimal(half(raw[..<middle], 0)) + hexadecimal(half(raw[middle...], 1)))
    }
}

/// What a job that converges by itself is asked to do in one pass.
public struct ReconcileRequest<Key: Hashable & Sendable>: Sendable {
    /// The keys to look at.
    public let scope: ReconcileScope<Key>
    /// The most corrections to make: `correctionsPerPass`.
    public let limit: Int
    /// Keys the runner holds back, waiting their backoff after the job refused
    /// them: skip them. The runner keeps them as they were; one the job names
    /// again stays refused.
    public let waiting: Set<Key>
}

/// What a job's pass did.
public struct ReconcileOutcome<Key: Hashable & Sendable>: Sendable {
    /// Differences the job found.
    public let differences: Int
    /// Differences it corrected.
    public let corrected: Int
    /// Differences it did not get to: another pass follows after `coalesce`.
    public let deferred: Int
    /// Keys it cannot converge, with the reason in words: each is stuck at once.
    public let refused: [Key: String]

    public init(differences: Int, corrected: Int, deferred: Int = 0, refused: [Key: String] = [:]) {
        self.differences = differences
        self.corrected = corrected
        self.deferred = deferred
        self.refused = refused
    }
}

public import Stoic

/// What a delivery attempt says about its entry: the closure given to
/// `Outbox.deliverPending(using:)` returns one of these.
///
/// Throwing is the other answer, and it means "this did not work": the entry
/// stays pending and the error is reported. The outbox does not guess from an
/// error's `retryDecision` that an entry is *permanently* refused, because a
/// `.stop` is about this run (a 401 is `.stop`, and is fixed by signing in), and
/// dropping a user's data on a guess cannot be undone. A refusal the app knows
/// to be final, such as a `400`, is a value:
///
///     try await outbox.deliverPending { entry in
///         do {
///             _ = try await api.send(entry.item.request, idempotencyKey: entry.key)
///             return .delivered
///         } catch let error as HTTPError where error.isRefusal {
///             return .discard(reason: "refused")
///         }
///     }
public enum DeliveryResult: Sendable, Hashable {
    /// The server has it: acknowledge durably, so it is never sent again.
    case delivered

    /// The server refused it for good, or it can never be sent: acknowledge
    /// durably, so it leaves the queue, and report it as discarded, not
    /// delivered. `reason` is recorded in the report and in
    /// `store.outbox_discarded`: keep it short and free of the entry's content.
    case discard(reason: String)

    /// Not delivered, and not an error: leave it pending, and do not try it
    /// again in this run. For an entry the app has decided to hold (signed
    /// out, say), where throwing would need an error type invented for it.
    /// Like a failure it stops a run under ``DeliveryPolicy/FailureMode/stopAtFirst``,
    /// so that later entries cannot overtake it.
    case keep
}

/// Why an entry was dropped without being delivered.
public enum DiscardReason: Sendable, Hashable, CustomStringConvertible {
    /// The delivery said so (``DeliveryResult/discard(reason:)``), with its reason.
    case refused(String)
    /// It no longer decodes and ``DeliveryPolicy/onUndecodable`` is `.discard`.
    case undecodable
    /// It was older than ``DeliveryPolicy/Expiry/maxAge``.
    case expired

    /// A short name for the kind, for events: `refused`, `undecodable` or `expired`.
    public var kind: String {
        switch self {
        case .refused: "refused"
        case .undecodable: "undecodable"
        case .expired: "expired"
        }
    }

    public var description: String {
        switch self {
        case .refused(let reason): reason
        case .undecodable: "undecodable"
        case .expired: "expired"
        }
    }
}

/// What became of one entry in ``Outbox/deliver(_:using:)``.
public enum DeliveryOutcome: Sendable {
    /// Delivered and acknowledged.
    case delivered
    /// Dropped from the queue without being delivered.
    case discarded(DiscardReason)
    /// The attempts ended in `error` (the last one's); the entry is still pending.
    case failed(any Error, attempts: Int)
    /// The delivery returned ``DeliveryResult/keep``: still pending.
    case kept
    /// The entry is not in the outbox: never enqueued, or already delivered or
    /// discarded.
    case notPending
}

/// How an ``Outbox`` delivers.
public struct DeliveryPolicy: Sendable {
    /// What a failed entry does to the rest of the run.
    public enum FailureMode: Sendable, Hashable {
        /// Stop the run: later entries must not overtake a failed one.
        case stopAtFirst
        /// Leave the entry pending and try the next: for independent entries.
        case continueWithNext
    }

    /// What an entry that no longer decodes does.
    public enum Undecodable: Sendable, Hashable {
        /// Leave it pending and report it as failed with `.corrupt` and no
        /// attempts, so ``onFailure`` applies to it: under `.stopAtFirst` it
        /// stops every run until the app ``Outbox/discard(_:)``s it. The
        /// default: an entry written by a *newer* version of the app does not
        /// decode in an older one, and discarding it would destroy what the
        /// newer version, when it returns, could have sent.
        case keep
        /// Drop it durably and report it in ``Outbox/DeliveryReport/discarded``
        /// (`.undecodable`), and go on: for an app that would rather lose an
        /// entry it can never read than hold up the queue behind it.
        case discard
    }

    /// When an entry is too old to be worth sending.
    public struct Expiry: Sendable {
        /// An entry whose age is at least this when a run reaches it is
        /// discarded (`.expired`), unsent. Age is measured on the wall clock,
        /// from the moment it was enqueued, across launches.
        public var maxAge: Duration

        /// The time now, as a duration since 1970-01-01 UTC. The system clock
        /// by default; a test passes its own.
        public var wallClock: @Sendable () -> Duration

        /// - Parameters:
        ///   - maxAge: How old an entry may be. A wall clock is set by the
        ///     user and by time zones' neighbours, so this is for days, not
        ///     seconds: a clock set forward expires entries early, and one set
        ///     back, late.
        ///   - wallClock: The time now; the system clock by default.
        public init(maxAge: Duration, wallClock: @escaping @Sendable () -> Duration = Expiry.systemClock) {
            precondition(maxAge > .zero, "an entry's lifetime must be positive")
            self.maxAge = maxAge
            self.wallClock = wallClock
        }

        /// The system's wall clock.
        public static let systemClock: @Sendable () -> Duration = { .nanoseconds(WallClock.now()) }
    }

    /// The attempts each entry gets per run, and the waits between them.
    public var schedule: BoundedSchedule

    /// Which failures are worth another attempt. The default retries
    /// anything not known to be permanent.
    public var classify: RetryClassifier<any Error>

    /// Caps retries relative to successful deliveries, so a long outage does
    /// not turn into a retry storm on the first launch after it. Each policy
    /// made with the default has its own budget.
    public var budget: RetryBudget

    public var onFailure: FailureMode

    /// What happens to an entry that no longer decodes. Default ``Undecodable/keep``.
    public var onUndecodable: Undecodable

    /// Entries older than this are discarded instead of sent; `nil`, the
    /// default, never expires an entry.
    ///
    /// Only entries enqueued while this is set carry the time they were
    /// enqueued, so setting it does not age what is already queued, and the
    /// records it writes are not readable by an earlier release of the library
    /// (it reads an unknown record as damage, and refuses to open).
    public var expiry: Expiry?

    public init(
        schedule: BoundedSchedule = .exponential(base: .seconds(1)).capped(at: .seconds(30)).attempts(4),
        classify: RetryClassifier<any Error> = .standard,
        budget: RetryBudget = RetryBudget(),
        onFailure: FailureMode = .stopAtFirst
    ) {
        self.init(
            schedule: schedule, classify: classify, budget: budget, onFailure: onFailure, onUndecodable: .keep, expiry: nil)
    }

    public init(
        schedule: BoundedSchedule = .exponential(base: .seconds(1)).capped(at: .seconds(30)).attempts(4),
        classify: RetryClassifier<any Error> = .standard,
        budget: RetryBudget = RetryBudget(),
        onFailure: FailureMode = .stopAtFirst,
        onUndecodable: Undecodable = .keep,
        expiry: Expiry? = nil
    ) {
        self.schedule = schedule
        self.classify = classify
        self.budget = budget
        self.onFailure = onFailure
        self.onUndecodable = onUndecodable
        self.expiry = expiry
    }
}

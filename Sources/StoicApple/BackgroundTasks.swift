public import Foundation
internal import Stoic
internal import Synchronization

// Background tasks (design/21): the part of `BGTaskScheduler` that every app
// writes and most get wrong — register once, before launch finishes; run
// the work inside the time the system grants; stop when it expires; tell the
// system you are done exactly once; ask for the next run. The framework sits
// behind two small protocols so none of it needs a device to test.

/// A request for the system to launch the app in the background.
public struct BackgroundTaskRequest: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A short refresh (about thirty seconds) at a time the system picks.
        case appRefresh
        /// Longer work, usually when the device is idle and charging.
        case processing(requiresNetworkConnectivity: Bool, requiresExternalPower: Bool)
    }

    public var identifier: String
    public var kind: Kind
    /// The system will not launch the task before this. `nil` means whenever.
    public var earliestBeginDate: Date?

    public init(identifier: String, kind: Kind, earliestBeginDate: Date? = nil) {
        self.identifier = identifier
        self.kind = kind
        self.earliestBeginDate = earliestBeginDate
    }
}

/// Why registering or submitting a background task failed.
///
/// Carries codes only; the descriptions name no identifier or request.
public enum BackgroundTaskError: Error, Sendable, Hashable, CustomStringConvertible {
    /// This job already registered its identifier.
    case alreadyRegistered
    /// The system refused the registration: the identifier is missing from
    /// `BGTaskSchedulerPermittedIdentifiers` in Info.plist, it is registered
    /// already, or the app has finished launching.
    case registrationRejected
    /// Background tasks are off for the app or device, or unsupported here.
    case unavailable
    /// The app has too many requests pending.
    case tooManyPendingRequests
    /// The app lacks the background mode the request needs.
    case notPermitted
    /// An immediate run was asked for and is not allowed now.
    case immediateRunIneligible
    /// Any other failure, by its error code.
    case other(code: Int)

    public var description: String {
        switch self {
        case .alreadyRegistered: "already registered"
        case .registrationRejected: "registration rejected"
        case .unavailable: "unavailable"
        case .tooManyPendingRequests: "too many pending requests"
        case .notPermitted: "not permitted"
        case .immediateRunIneligible: "immediate run ineligible"
        case .other(let code): "error \(code)"
        }
    }
}

/// The system's task, as the job sees it: the `BGTask` seam.
public protocol BackgroundTaskHandle: Sendable {
    var identifier: String { get }
    /// Sets the closure the system calls when it takes the time back. It may
    /// be called on any thread, at any moment after it is set.
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    /// Tells the system the task is over. Call it once.
    func setTaskCompleted(success: Bool)
}

/// The system's scheduler: the `BGTaskScheduler` seam.
/// `SystemBackgroundTaskScheduler` is the real one, ``FakeBackgroundScheduler`` the test's.
public protocol BackgroundTaskScheduling: Sendable {
    /// Registers `launch` as the handler for `identifier`. Returns `false` if
    /// the system refuses. `launch` may run on any thread.
    func register(identifier: String, launch: @escaping @Sendable (any BackgroundTaskHandle) -> Void) -> Bool
    /// Asks the system to launch the app for `request`.
    func submit(_ request: BackgroundTaskRequest) async throws(BackgroundTaskError)
}

/// What one run of a ``BackgroundJob`` did.
public struct BackgroundRunReport: Sendable {
    /// How the work ended: it returned, threw, or was cancelled (a
    /// `CancellationError`, when the system or the budget cut it short).
    public var work: Result<Void, any Error>
    /// Whether the system took the time back during the run.
    public var expired: Bool
    /// The `success` the system was told. The first of the work's end and the
    /// expiration decides it; the other finds the task already completed.
    public var reportedSuccess: Bool
    /// Whether the next request was submitted.
    public var reschedule: Result<Void, BackgroundTaskError>
}

/// One background task identifier, wired end to end.
///
///     let sync = BackgroundJob.drainingOutbox(
///         identifier: "com.example.app.sync", every: .seconds(15 * 60), scheduler: SystemBackgroundTaskScheduler()
///     ) { try await outbox.deliverPending() }
///
///     // application(_:didFinishLaunchingWithOptions:), before it returns:
///     try sync.register()
///     // and once, when the app first goes to the background:
///     try await sync.schedule()
///
/// When the system launches the task, the job:
///
/// 1. submits the next request first, `every` from now. Apple's advice, and
///    the only safe order: once the work is over the process may be
///    suspended before a later submit runs. A submit that fails is reported,
///    never allowed to stop the work;
/// 2. sets the expiration handler before the work starts, so no expiry is
///    missed;
/// 3. runs the work as `ExpiringWork`: under a `Deadline` of `budget` if
///    one is given (cause `CancellationCause.deadline`), cancelled with
///    cause `CancellationCause.systemExpiring` the moment the system
///    expires the task;
/// 4. on expiry, completes the task at once with `success: false` without
///    waiting for the work to unwind (the system gives a moment, not a
///    grace period); otherwise completes it when the work ends, `true` if it
///    returned, `false` if it threw or was cut short. Whichever comes first
///    completes the task, and the other finds it done: the system hears
///    exactly once.
public final class BackgroundJob: Sendable {
    public let identifier: String
    public let kind: BackgroundTaskRequest.Kind
    /// How far ahead of now each request asks to be launched.
    public let interval: Duration
    /// The longest the work may run, whatever the system allows; `nil` for
    /// as long as the system gives.
    public let budget: Duration?

    private let scheduler: any BackgroundTaskScheduling
    private let now: @Sendable () -> Date
    private let work: @Sendable () async throws -> Void
    private let onReport: (@Sendable (BackgroundRunReport) -> Void)?
    private let registered = Mutex(false)

    /// - Parameters:
    ///   - identifier: The task identifier, listed in Info.plist.
    ///   - kind: Refresh or processing.
    ///   - interval: The earliest begin of each next run, from the moment it is requested.
    ///   - budget: A cap on the work's time.
    ///   - scheduler: The system's, or a fake.
    ///   - now: The wall clock, for `earliestBeginDate`.
    ///   - onReport: Called with each run's report, for logging.
    ///   - work: What to do. Throw to say it failed.
    public init(
        identifier: String,
        kind: BackgroundTaskRequest.Kind = .appRefresh,
        every interval: Duration,
        budget: Duration? = nil,
        scheduler: any BackgroundTaskScheduling,
        now: @escaping @Sendable () -> Date = { Date() },
        onReport: (@Sendable (BackgroundRunReport) -> Void)? = nil,
        work: @escaping @Sendable () async throws -> Void
    ) {
        self.identifier = identifier
        self.kind = kind
        self.interval = interval
        self.budget = budget
        self.scheduler = scheduler
        self.now = now
        self.onReport = onReport
        self.work = work
    }

    /// A processing job that drains an outbox: `drain` delivers what is
    /// pending and returns, or throws if it could not.
    ///
    /// Needs the network by default, since an outbox is waiting to send.
    /// The drain should be bounded by the deadline the job gives it
    /// (`Deadline.current`), as any Stoic retry or wait inside it is.
    public static func drainingOutbox(
        identifier: String,
        every interval: Duration,
        budget: Duration? = nil,
        requiresNetworkConnectivity: Bool = true,
        requiresExternalPower: Bool = false,
        scheduler: any BackgroundTaskScheduling,
        now: @escaping @Sendable () -> Date = { Date() },
        onReport: (@Sendable (BackgroundRunReport) -> Void)? = nil,
        drain: @escaping @Sendable () async throws -> Void
    ) -> BackgroundJob {
        BackgroundJob(
            identifier: identifier,
            kind: .processing(
                requiresNetworkConnectivity: requiresNetworkConnectivity, requiresExternalPower: requiresExternalPower),
            every: interval, budget: budget, scheduler: scheduler, now: now, onReport: onReport, work: drain)
    }

    /// Registers the identifier with the system. Call it once, before the
    /// app finishes launching.
    ///
    /// - Throws: ``BackgroundTaskError/alreadyRegistered`` the second time;
    ///   ``BackgroundTaskError/registrationRejected`` if the system refuses
    ///   (after which `register()` may be tried again).
    public func register() throws(BackgroundTaskError) {
        let first = registered.withLock { registered in
            defer { registered = true }
            return !registered
        }
        guard first else { throw .alreadyRegistered }
        let accepted = scheduler.register(identifier: identifier) { [self] task in
            Task { await run(task) }
        }
        if !accepted {
            registered.withLock { $0 = false }
            throw .registrationRejected
        }
    }

    /// Asks the system to launch the task `interval` from now.
    public func schedule() async throws(BackgroundTaskError) {
        try await scheduler.submit(
            BackgroundTaskRequest(
                identifier: identifier, kind: kind,
                earliestBeginDate: now().addingTimeInterval(interval.seconds)))
    }

    /// What the launch handler does with the system's `task`: the steps in
    /// the type's description. Public so a test can run it and read the report.
    @discardableResult
    public func run(_ task: any BackgroundTaskHandle) async -> BackgroundRunReport {
        let expiring = ExpiringWork()
        let completion = Completion(task)
        // Before anything that can suspend, so an expiry cannot be missed.
        task.setExpirationHandler {
            expiring.expire()
            completion.complete(success: false, expired: true)
        }
        let reschedule: Result<Void, BackgroundTaskError>
        do throws(BackgroundTaskError) {
            try await schedule()
            reschedule = .success(())
        } catch {
            reschedule = .failure(error)
        }
        let result: Result<Void, any Error>
        do {
            try await expiring.run(within: budget, label: "background.\(identifier)", work)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        let succeeded: Bool
        if case .success = result { succeeded = true } else { succeeded = false }
        completion.complete(success: succeeded, expired: false)
        let outcome = completion.outcome
        let report = BackgroundRunReport(
            work: result, expired: outcome.expired, reportedSuccess: outcome.success ?? succeeded, reschedule: reschedule)
        onReport?(report)
        return report
    }
}

/// Completes a task exactly once, and remembers how.
private final class Completion: Sendable {
    struct Outcome {
        var success: Bool?
        var expired = false
    }

    private let task: any BackgroundTaskHandle
    private let state = Mutex(Outcome())

    init(_ task: any BackgroundTaskHandle) {
        self.task = task
    }

    var outcome: Outcome { state.withLock { $0 } }

    /// Tells the system, unless something already has. An expiry is recorded
    /// even when the task was completed first.
    func complete(success: Bool, expired: Bool) {
        let first = state.withLock { state -> Bool in
            if expired { state.expired = true }
            guard state.success == nil else { return false }
            state.success = success
            return true
        }
        if first { task.setTaskCompleted(success: success) }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

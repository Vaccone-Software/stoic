/// Every event Stoic emits: its stable name, its usual level, and what it
/// means.
///
/// Event names are API. Dashboards, log queries and alerts are built on
/// them, so a name is never renamed or removed in a minor release, and the
/// test suite fails if a source file emits a name missing from this catalog
/// or the catalog lists a name nothing emits.
public enum EventCatalog {
    /// One documented event.
    public struct Entry: Sendable, Hashable {
        public let name: EventName
        public let level: Event.Level
        public let meaning: String
    }

    /// Every event, sorted by name.
    public static let entries: [Entry] = [
        Entry(name: "abandoned.completed", level: .notice, meaning: "Abandoned work finally finished; reports how late it was."),
        Entry(name: "abandoned.started", level: .warning, meaning: "Work ignored its deadline or its caller's cancellation and was abandoned, still running."),
        Entry(name: "abandoned.wedged", level: .error, meaning: "A label reached its limit of abandoned work and refused a new call."),
        Entry(name: "breaker.closed", level: .info, meaning: "A circuit breaker closed: its probes succeeded, or it was forced closed."),
        Entry(name: "breaker.defect", level: .error, meaning: "A call through a breaker failed with a defect: a bug, not counted against the dependency."),
        Entry(name: "breaker.half_open", level: .info, meaning: "A circuit breaker's open period ended; it admits probe calls."),
        Entry(name: "breaker.ignored", level: .debug, meaning: "A call's outcome was not counted: cancelled, a defect, a rejection, or stale."),
        Entry(name: "breaker.opened", level: .warning, meaning: "A circuit breaker opened: the failure or slow-call rate crossed its threshold, or a probe failed."),
        Entry(name: "breaker.recorded", level: .debug, meaning: "A call's outcome was counted in a breaker's window."),
        Entry(name: "breaker.rejected", level: .info, meaning: "A circuit breaker refused a call while open or out of probe permits."),
        Entry(name: "breaker.reset", level: .info, meaning: "A circuit breaker was reset or forced into a state."),
        Entry(name: "bulkhead.rejected", level: .info, meaning: "A bulkhead refused a call: every slot and queue place was taken."),
        Entry(name: "channel.dropped", level: .debug, meaning: "A channel's overflow policy discarded an element."),
        Entry(name: "deadline.expired", level: .notice, meaning: "A deadline passed before its operation finished; reports the budget, the overrun and how the operation ended."),
        Entry(name: "hedge.all_failed", level: .notice, meaning: "Every attempt of a hedged call failed; the first failure was thrown."),
        Entry(name: "hedge.attempt_failed", level: .debug, meaning: "One attempt of a hedged call failed."),
        Entry(name: "hedge.budget_exhausted", level: .notice, meaning: "A hedge was not started because the retry budget had no token."),
        Entry(name: "hedge.deadline_skip", level: .notice, meaning: "A hedge was not started because it could not finish before the deadline."),
        Entry(name: "hedge.started", level: .debug, meaning: "A hedged call started another attempt alongside the slow one."),
        Entry(name: "hedge.won", level: .debug, meaning: "An attempt of a hedged call succeeded first."),
        Entry(name: "lifecycle.terminate_completed", level: .info, meaning: "A Mac app's shutdown finished before its deadline; the app quits."),
        Entry(name: "lifecycle.terminate_overran", level: .error, meaning: "A Mac app's shutdown overran its deadline; the app quits anyway."),
        Entry(name: "lifecycle.terminate_started", level: .info, meaning: "A Mac app began its graceful shutdown."),
        Entry(name: "race.all_failed", level: .notice, meaning: "Every operation in a race failed; the first failure was thrown."),
        Entry(name: "race.won", level: .debug, meaning: "An operation won a race; reports which and how long it took."),
        Entry(name: "ratelimiter.oversized", level: .error, meaning: "A request asked for more permits than the limiter's burst can ever hold."),
        Entry(name: "ratelimiter.rejected", level: .info, meaning: "A rate limiter refused a request: its queue was full or the wait would outlive the deadline."),
        Entry(name: "ratelimiter.waited", level: .debug, meaning: "A request waited for rate-limiter permits."),
        Entry(name: "recur.ended", level: .debug, meaning: "A recurring loop ended: stopped, schedule ended, or cancelled."),
        Entry(name: "retry.after_capped", level: .notice, meaning: "A retryAfter request exceeded five minutes and was capped."),
        Entry(name: "retry.attempt_failed", level: .info, meaning: "An attempt failed and another will follow after the reported delay."),
        Entry(name: "retry.budget_exhausted", level: .warning, meaning: "A retry was refused because its budget had no token left."),
        Entry(name: "retry.cancelled", level: .debug, meaning: "A retry stopped because the task running it was cancelled."),
        Entry(name: "retry.deadline_skip", level: .notice, meaning: "A retry was skipped because it could not finish before the deadline."),
        Entry(name: "retry.defect", level: .error, meaning: "A retry stopped because the failure is a defect: a bug, not a fault."),
        Entry(name: "retry.exhausted", level: .notice, meaning: "A retry's schedule allowed no further attempt."),
        Entry(name: "retry.nested", level: .notice, meaning: "A retry inside another retry's attempt made a single attempt."),
        Entry(name: "retry.permanent", level: .info, meaning: "A retry stopped because the failure was classified as permanent."),
        Entry(name: "retry.succeeded", level: .info, meaning: "An operation succeeded after at least one retry."),
        Entry(name: "scope.child_failed", level: .error, meaning: "A task scope's fork failed; the body and the other forks were cancelled."),
        Entry(name: "scope.finalizer_abandoned", level: .error, meaning: "A finalizer overran its allowance and was abandoned."),
        Entry(name: "scope.finalizer_failed", level: .error, meaning: "A finalizer threw; the scope's outcome was unchanged."),
        Entry(name: "scope.finalizer_slow", level: .notice, meaning: "A finalizer used more than half its allowance."),
        Entry(name: "scope.fork_after_exit", level: .error, meaning: "Work tried to fork into a task scope that had already ended."),
        Entry(name: "semaphore.reentrant", level: .error, meaning: "A task asked for a permit of a semaphore it already holds: a possible self-deadlock."),
        Entry(name: "semaphore.rejected", level: .info, meaning: "A semaphore waiter left without a permit: cancelled or past its deadline."),
        Entry(name: "service.started", level: .debug, meaning: "A service in a service graph finished starting."),
        Entry(name: "singleflight.abandoned", level: .info, meaning: "Every caller left a flight, so its operation was cancelled."),
        Entry(name: "singleflight.joined", level: .debug, meaning: "A caller joined a flight already in progress."),
        Entry(name: "slot.superseded", level: .debug, meaning: "A task slot's work was superseded by newer work."),
        Entry(name: "slot.superseded_late", level: .info, meaning: "Superseded work finished anyway; its result was dropped."),
        Entry(name: "statemachine.invalid", level: .error, meaning: "An event arrived in a state that declares it invalid."),
        Entry(name: "statemachine.stale_event", level: .info, meaning: "An event from an earlier visit to a state was dropped."),
        Entry(name: "statemachine.transition", level: .debug, meaning: "A state machine changed state."),
        Entry(name: "supervisor.child_abandoned", level: .error, meaning: "A child ignored its stop and was abandoned after its shutdown timeout."),
        Entry(name: "supervisor.child_exited", level: .info, meaning: "A supervised child stopped, normally or with an error (warning)."),
        Entry(name: "supervisor.child_hung", level: .error, meaning: "A supervised child stopped beating and was treated as hung."),
        Entry(name: "supervisor.child_restarting", level: .info, meaning: "A supervised child will restart after the reported delay."),
        Entry(name: "supervisor.child_started", level: .debug, meaning: "A supervised child started."),
        Entry(name: "supervisor.escalated", level: .error, meaning: "Restarts exceeded the supervisor's intensity; it stopped every child and gave up."),
        Entry(name: "supervisor.stopped", level: .info, meaning: "A supervisor stopped: all children finished, or it was cancelled."),
    ]

    /// The entry for `name`, if Stoic emits it.
    public static func entry(for name: EventName) -> Entry? {
        entries.first { $0.name == name }
    }
}

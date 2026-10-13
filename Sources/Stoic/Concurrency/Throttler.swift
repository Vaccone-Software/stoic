/// Lets at most one call run per interval, and says what became of the rest.
///
/// A scroll handler or a progress callback may fire a hundred times a second;
/// the view wants to hear at most a few times. Unlike a ``RateLimiter``, which
/// delays every caller until a permit is free, a throttler *drops* calls that
/// arrive too soon, and its callers learn that at once.
///
///     let save = Throttler(interval: .seconds(1), label: "autosave")
///     try await save.execute { try await document.save() }
///
/// The interval is a window that opens when a call runs.
///
/// - **Leading** runs the call that opens a window at once. Calls inside the
///   window throw `.rejected` with ``Rejection/Reason/suppressed``, unless
///   `trailing` is on.
/// - **Trailing** keeps the *latest* call that arrives inside the window and
///   runs it when the window ends, which opens the next window. Each call it
///   replaces throws ``Rejection/Reason/superseded`` at once. With `leading`
///   off, the call that would open a window waits for the window to end, so
///   nothing runs sooner than `interval` after the first call.
/// - **Cancellation withdraws a call.** A cancelled waiter throws
///   `.rejected(.cancelled)` (`.deadlineExceeded` when its deadline did it);
///   the window it was waiting out stays open.
///
/// Waits are bounded by `interval`. Time is measured on the clock the
/// throttler is created with. A dropped call is reported as `throttle.dropped`.
public final class Throttler: Policy {
    public let label: String
    public let interval: Duration
    public let leading: Bool
    public let trailing: Bool
    private let shaper: CallShaper

    /// - Parameters:
    ///   - interval: The window's length. Positive.
    ///   - leading: Run the call that opens a window at once.
    ///   - trailing: Run the latest call of a window when it ends. At least
    ///     one of `leading` and `trailing` must be on.
    ///   - label: Names the throttler in events and rejections.
    ///   - clock: The clock to measure on; by default the ambient clock when
    ///     the throttler is created.
    public init(interval: Duration, leading: Bool = true, trailing: Bool = false, label: String, clock: AnyClock? = nil) {
        self.label = label
        self.interval = interval
        self.leading = leading
        self.trailing = trailing
        shaper = CallShaper(mode: .throttle, period: interval, leading: leading, trailing: trailing, label: label, clock: clock, dropped: "throttle.dropped")
    }

    /// Runs `operation` if this call is let through.
    ///
    /// - Throws: `.failed` with the operation's error, or `.rejected`:
    ///   `.suppressed`, `.superseded`, `.cancelled` or `.deadlineExceeded`.
    ///   A rejected call's operation never ran.
    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        try await shaper.execute(operation)
    }

    /// Makes a call from a task the scope owns, for callers that do not wait
    /// for the answer. See ``Debouncer/submit(in:label:_:)``.
    public func submit(
        in scope: borrowing TaskScope,
        label: String? = nil,
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        shaper.submit(in: scope, label: label ?? self.label, operation)
    }
}

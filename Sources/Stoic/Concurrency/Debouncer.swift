/// Runs the latest of a burst of calls, once the burst has gone quiet.
///
/// A search box that fires on every keystroke wants one request, for the text
/// that is there when the typing stops. By hand that is a timer, a generation
/// counter and a cancelled task per keystroke; here it is a call whose answer
/// is "run" or "someone newer took over".
///
///     let search = Debouncer(quiet: .milliseconds(300), label: "search")
///     let hits = try await search.execute { try await api.search(text) }
///
/// Each call waits for `quiet` on the debouncer's clock. A newer call before
/// that resets the wait and takes the call's place; the replaced call
/// returns at once by throwing `.rejected` with ``Rejection/Reason/superseded``,
/// so no caller is left waiting on a call that will never run. The call that
/// outlasts the quiet period runs `operation` in its own task and returns its
/// result.
///
/// - **Leading** runs the first call of a burst at once, without waiting.
///   With `trailing` off as well, calls inside the burst are not run at all:
///   they throw ``Rejection/Reason/suppressed`` and each extends the burst.
///   With `trailing` on, the last call after the leading one still runs when
///   the burst ends; a burst of one call runs once.
/// - **Cancellation withdraws a call.** A cancelled waiter throws
///   `.rejected(.cancelled)` (or `.deadlineExceeded` when its deadline did
///   it); if it was the latest, nothing runs for the burst, because the
///   earlier calls were already replaced.
/// - Operations are not serialised: a call that arrives after the quiet
///   period starts a new burst while the previous operation may still run.
///
/// Time is measured on the clock the debouncer is created with, so a test on
/// a `TestClock` decides when the quiet period ends. A dropped call is
/// reported as `debounce.dropped`.
public final class Debouncer: Policy {
    public let label: String
    public let quiet: Duration
    public let leading: Bool
    public let trailing: Bool
    private let shaper: CallShaper

    /// - Parameters:
    ///   - quiet: How long calls must stop before the latest runs. Positive.
    ///   - leading: Run the first call of a burst at once.
    ///   - trailing: Run the last call of a burst when it ends. At least one
    ///     of `leading` and `trailing` must be on.
    ///   - label: Names the debouncer in events and rejections.
    ///   - clock: The clock to measure on; by default the ambient clock when
    ///     the debouncer is created.
    public init(quiet: Duration, leading: Bool = false, trailing: Bool = true, label: String, clock: AnyClock? = nil) {
        self.label = label
        self.quiet = quiet
        self.leading = leading
        self.trailing = trailing
        shaper = CallShaper(mode: .debounce, period: quiet, leading: leading, trailing: trailing, label: label, clock: clock, dropped: "debounce.dropped")
    }

    /// Runs `operation` if this call is the one the burst settles on.
    ///
    /// - Throws: `.failed` with the operation's error, or `.rejected`:
    ///   `.superseded`, `.suppressed`, `.cancelled` or `.deadlineExceeded`.
    ///   A rejected call's operation never ran.
    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        try await shaper.execute(operation)
    }

    /// Makes a call from a task the scope owns, for callers that do not wait
    /// for the answer (a text field's change handler).
    ///
    /// The fork lives until the call's fate is decided, and no longer than
    /// the scope: ending the scope withdraws every waiting call. Replaced,
    /// suppressed and cancelled calls are ordinary outcomes and end quietly;
    /// an error from `operation` fails the scope, as any fork's does.
    public func submit(
        in scope: borrowing TaskScope,
        label: String? = nil,
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        shaper.submit(in: scope, label: label ?? self.label, operation)
    }
}

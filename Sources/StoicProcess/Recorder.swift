#if os(macOS)
internal import Stoic

/// The ambient a child was started under, kept for the work done on its
/// behalf elsewhere.
///
/// A child's exit is heard on a Dispatch queue, and its output read, its
/// input written and its stop run in tasks of their own: none of them is
/// the task that started it, and a Dispatch queue carries no task-local
/// values. Each child keeps the ambient of the call that started it, so its
/// events reach the instrumentation (and its waits run on the clock) that
/// call had, a test's included.
struct Recorder: Sendable {
    let ambient: Ambient

    init() { ambient = Ambient.current }

    func record(_ event: @autoclosure () -> Event) {
        let instrumentation = ambient.instrumentation
        let made = event()
        guard instrumentation.isEnabled(made.level) else { return }
        instrumentation.record(made)
    }

    var clock: AnyClock { ambient.clock }

    /// Waits `duration` on the child's clock, however the task is
    /// cancelled: for the waits of a stop, which is shielded, and of the
    /// output's grace, which no caller owns.
    func pause(for duration: Duration) async {
        let clock = ambient.clock
        let until = clock.now.advanced(by: duration)
        // A shielded wait: its task is never cancelled (it is made and
        // owned here, and nothing cancels it), so the sleep ends at `until`.
        await Task { () async -> Void in
            do {
                try await clock.sleep(until: until, tolerance: nil)
            } catch {
                // Only cancellation throws, and nothing can cancel this task.
                return
            }
        }.value
    }
}
#endif

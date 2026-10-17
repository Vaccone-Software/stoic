internal import Synchronization

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#else
#error("StoicSettings needs Darwin or Glibc")
#endif

/// What a *synchronous* wait for a lock is measured and paced with.
///
/// The ambient clock cannot do this. Its `sleep` is `async`, so a synchronous
/// caller cannot use it; and its `now` is the wrong thing to count a blocked
/// thread's wait by, because the ambient clock may be a test clock, which does
/// not advance while a thread is blocked on it: a loop that waited for a virtual
/// deadline on a thread that nothing can advance the clock from would never end.
/// So a synchronous wait counts real time (the monotonic clock, which does not
/// jump with the wall clock) and sleeps the thread.
///
/// It is a value so that a test can stand in for it, with a pause that advances
/// a made-up time and hands the lock over, and nothing in the test ever sleeps.
struct BlockingWait: Sendable {
    /// How long a lock is polled for, between tries.
    static let pollInterval = Duration.milliseconds(25)

    /// The time since some fixed moment; only differences are meaningful.
    var now: @Sendable () -> Duration

    /// Blocks the calling thread for about `duration`.
    var pause: @Sendable (Duration) -> Void

    /// Real time: the monotonic clock, and `nanosleep`.
    static let real = BlockingWait(
        now: { BlockingWait.origin.duration(to: ContinuousClock.now) },
        pause: { duration in
            let parts = duration.components
            var request = timespec(tv_sec: Int(parts.seconds), tv_nsec: Int(parts.attoseconds / 1_000_000_000))
            // An interrupted sleep returns early, which is harmless: the caller
            // tries the lock again and works out what is left of its wait.
            _ = unsafe nanosleep(&request, nil)
        })

    private static let origin = ContinuousClock.now
}

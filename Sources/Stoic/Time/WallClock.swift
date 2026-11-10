#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif
#if !canImport(Darwin) && canImport(SwiftOverlayShims)
// Off Apple platforms the toolchain can attribute `timespec` to the standard
// library's own shim module, when the kernel's other imports load it before
// the C library's; member visibility then asks for it by name here.
internal import SwiftOverlayShims
#endif

/// The clock that says when: what time it is on the world's timeline, as a
/// ``Moment``.
///
/// One of three clocks, each for one question. The continuous clock
/// measures (deadlines, retries) and the suspending clock judges liveness;
/// both are monotonic, and neither says what time it is. This one does, and
/// so it can jump: a person sets it, the network corrects it. Nothing is
/// measured on it.
///
/// Code reads it as ``Moment/now``, which takes it from the ambient context
/// (``Ambient/wallClock``), so a test replaces it once and every "now"
/// beneath follows, the way the ambient clocks do for deadlines.
///
///     try await withAmbient({ $0.wallClock = WallClock { fixed } }) {
///         try await recordCheckIn()        // checkedInAt == fixed
///     }
public struct WallClock: Sendable {
    private let read: @Sendable () -> Moment

    /// A wall clock that reads `now`. It is called on every read, from any
    /// task, so it must be cheap and must not block.
    public init(now: @escaping @Sendable () -> Moment) {
        read = now
    }

    /// The time now on this clock.
    public var now: Moment { read() }

    /// The system's real-time clock (`CLOCK_REALTIME`): what the device
    /// believes the time is, to the nanosecond. The default.
    public static let system = WallClock(now: readSystemClock)

    /// A wall clock that always says `moment`.
    public static func fixed(_ moment: Moment) -> WallClock {
        WallClock { moment }
    }
}

/// `CLOCK_REALTIME`, read without Foundation.
@Sendable
private func readSystemClock() -> Moment {
    var spec = timespec()
    // clock_gettime fills the struct whose address it is given, which lives
    // for the call; with CLOCK_REALTIME it cannot fail on any platform Stoic
    // supports.
    _ = unsafe clock_gettime(CLOCK_REALTIME, &spec)
    return Moment(sinceEpoch: .seconds(Int64(spec.tv_sec)) + .nanoseconds(Int64(spec.tv_nsec)))
}

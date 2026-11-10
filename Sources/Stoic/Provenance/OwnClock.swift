/// Evidence that this process's own wall clock read a moment (design/28).
///
///     try await waivers.accept(waiverID, at: Moment.stamped(), by: parent)
///
/// A function that records when something happened, with legal or
/// financial weight, takes `Verified<Moment, OwnClock>`: a moment a device
/// sent (`Claimed<Moment>`) does not compile there, and the claim may be
/// kept beside it as what the device said.
///
/// It proves the reading, not the clock: a wrong clock reads a wrong moment,
/// as the type says. It is neither content nor principal evidence, so it has
/// no `deriving`: a stamped moment plus a day is not what the clock read.
public struct OwnClock: Evidence, Hashable {
    /// Constructible only in this file, by ``Moment/stamped()``.
    public struct Mint: Sendable {
        fileprivate init() {}
    }

    public static let proves = "this process's wall clock read this moment when the value was made"

    fileprivate init() {}
}

/// `Moment.stamped()`'s authority, private to this file.
private let ownClockMinter = Minter<OwnClock>(OwnClock.Mint())

extension Moment {
    /// The ambient wall clock's moment now (``Moment/now``), proved to be
    /// this process's own reading.
    ///
    /// Under a test's ambient context it is the test clock's moment, and
    /// `jumpWallClock` moves it, as it moves `Moment.now`.
    public static func stamped() -> Verified<Moment, OwnClock> {
        ownClockMinter.verified(Ambient.current.wallClock.now, OwnClock())
    }
}

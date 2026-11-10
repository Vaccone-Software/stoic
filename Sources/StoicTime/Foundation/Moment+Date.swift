public import Foundation
public import Stoic

extension Moment {
    /// Seconds from 1970-01-01 to 2001-01-01, the instant `Date` counts from.
    private static let referenceDate = Moment(sinceEpoch: .seconds(978_307_200))

    /// The instant `date` names, as exactly as a `Date` holds it.
    ///
    /// For an API that speaks `Date`. Counted from `Date`'s own reference
    /// instant (2001), not through `timeIntervalSince1970`, which rounds
    /// once more.
    public init(_ date: Date) {
        self = Self.referenceDate + .seconds(date.timeIntervalSinceReferenceDate)
    }

    /// This instant as a `Date`, for Foundation's formatters and APIs.
    ///
    /// A `Date` is a `Double` of seconds since 2001: to about a tenth of a
    /// microsecond today, coarser further away, so the conversion rounds to
    /// what it can hold. A `Date` made from a moment reads back as the same
    /// `Date`.
    public var date: Date {
        let (seconds, attoseconds) = Self.referenceDate.duration(to: self).components
        return Date(timeIntervalSinceReferenceDate: Double(seconds) + Double(attoseconds) * 1e-18)
    }
}

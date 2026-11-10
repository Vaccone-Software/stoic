/// Why a date, a time or a zoned value could not be made.
///
/// Every case is an expected failure, of input or of the rules: a date
/// someone typed, a zone another device knew, a local time a government
/// skipped. None is retried, and none is a defect.
public enum TimeError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The value does not exist, or the text does not spell one: 30
    /// February, month 13, hour 24, `2027-3-14`. The reason, in words.
    case invalid(String)

    /// The value is outside the years 0001 to 9999, the range the text
    /// forms can write. The reason, in words.
    case outOfRange(String)

    /// The zone rules in force (``ZoneRules/current``) do not know the zone:
    /// a misspelling, or a zone newer than this device's rules.
    case unknownZone(TimeZoneID)

    /// The local time does not exist in the zone: the clocks sprang forward
    /// over it. Thrown only under ``Disambiguation/reject``.
    case inGap(PlainDateTime, TimeZoneID)

    /// The local time happens twice in the zone: the clocks fell back over
    /// it. Thrown only under ``Disambiguation/reject``.
    case inOverlap(PlainDateTime, TimeZoneID)

    public var description: String {
        switch self {
        case .invalid(let reason): reason
        case .outOfRange(let reason): reason
        case .unknownZone(let zone): "the zone rules do not know the zone \(zone)"
        case .inGap(let local, let zone): "\(local) does not exist in \(zone): the clocks sprang forward over it"
        case .inOverlap(let local, let zone): "\(local) happens twice in \(zone): the clocks fell back over it"
        }
    }
}

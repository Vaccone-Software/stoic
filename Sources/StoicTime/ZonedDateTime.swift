public import Stoic

/// When something is planned, and where: a local date and time in a named
/// zone, with the instant they meant when they were resolved.
///
///     let start = try ZonedDateTime(PlainDate(2027, 3, 14), PlainTime(9, 0), in: "America/New_York")
///     events.sorted { $0.start.moment < $1.start.moment }      // sorts like UTC
///     Text("\(start.local.time) \(start.zone)")                // always 09:00, New York time
///
/// **The local time and the zone are the truth; the instant is derived.** A
/// future meeting stored as an instant is an hour wrong once a government
/// moves its clocks; one stored as a local time with no zone names no
/// instant at all. This keeps what the organiser meant (``local``, ``zone``)
/// and, beside it, the ``moment`` the rules made of it when it was
/// resolved, so a list of zoned values sorts and filters as a list of UTC
/// instants does, with no rule consulted on a read.
///
/// **A cache with its inputs kept.** When the rules change, the instant of a
/// future value may no longer be what its local time and zone give: it is
/// *stale* (``isStale(now:)``), and ``refreshed(now:resolving:)`` derives the
/// instant again, keeping the local time and zone. A value in the past is
/// final. A stale value sorts by its old instant until it is refreshed, but
/// its local time and zone, which display and decisions read, are never
/// wrong. ``ZoneRulesSweep`` refreshes an app's values once per change of
/// the rules.
///
/// **Gaps and overlaps.** A local time the clocks sprang forward over does
/// not exist, and one they fell back over exists twice. A ``Disambiguation``
/// policy decides which instant is meant, and ``resolution`` says what
/// happened, so an app can tell an organiser that 02:30 does not exist that
/// night.
///
/// Its text is RFC 9557's, an RFC 3339 timestamp with the zone's name after
/// it: `2027-03-14T09:00:00-04:00[America/New_York]`. The offset is the
/// instant, so the text carries all three.
public struct ZonedDateTime: Sendable {
    /// The date and time on the zone's wall clocks: what was meant.
    public let local: PlainDateTime

    /// The place whose rules the local time is read by.
    public let zone: TimeZoneID

    /// The instant the rules gave ``local`` in ``zone`` when this value was
    /// resolved: for sorting, filtering and comparing.
    public let moment: Moment

    /// How ``moment`` was derived from ``local``: exactly, or by the policy
    /// for a gap or an overlap. Not part of the value's identity or its
    /// text: two values with the same local time, zone and instant are
    /// equal however each was made.
    public let resolution: Resolution

    init(local: PlainDateTime, zone: TimeZoneID, moment: Moment, resolution: Resolution) {
        self.local = local
        self.zone = zone
        self.moment = moment
        self.resolution = resolution
    }

    /// `date` at `time` in `zone`, resolved by the zone rules in force.
    ///
    /// - Parameter resolving: Which instant a local time in a gap or an
    ///   overlap means; ``Disambiguation/compatible`` by default.
    /// - Throws: ``TimeError/unknownZone(_:)`` if the rules do not know
    ///   `zone`; ``TimeError/inGap(_:_:)`` or ``TimeError/inOverlap(_:_:)``
    ///   under ``Disambiguation/reject``.
    public init(
        _ date: PlainDate, _ time: PlainTime, in zone: TimeZoneID, resolving: Disambiguation = .compatible
    ) throws(TimeError) {
        try self.init(PlainDateTime(date, time), in: zone, resolving: resolving)
    }

    /// `local` in `zone`, resolved by the zone rules in force; see
    /// ``init(_:_:in:resolving:)``.
    public init(_ local: PlainDateTime, in zone: TimeZoneID, resolving: Disambiguation = .compatible) throws(TimeError) {
        let (moment, resolution) = try ZoneRules.current.resolve(local, in: zone, resolving)
        self.init(local: local, zone: zone, moment: moment, resolution: resolution)
    }

    /// What the zone's clocks read minus UTC, when this value was resolved:
    /// what the rules said then.
    public var offset: Duration {
        local.asIfUTC - moment.sinceEpoch
    }

    /// Whether the rules in force now give ``local`` in ``zone`` another
    /// instant than ``moment``, for a value still in the future: a rule
    /// changed since it was resolved.
    ///
    /// The local time is resolved again by the policy its ``resolution``
    /// records: the side of a gap or the occurrence of an overlap it took,
    /// and ``Disambiguation/compatible`` for one that was exact (so an exact
    /// time a rule change moved into a gap is stale). A value read from text
    /// does not say which policy made it, so it is stale only when no policy
    /// gives its instant. A value at or before `now` is final, never stale.
    ///
    /// - Throws: ``TimeError/unknownZone(_:)`` if the rules in force do not
    ///   know the zone.
    public func isStale(now: Moment = .now) throws(TimeError) -> Bool {
        guard moment > now else { return false }
        let rules = ZoneRules.current
        guard let policy = resolution.policy else {
            return try !rules.instants(for: local, in: zone).contains(moment)
        }
        return try rules.resolution(of: local, in: zone, policy).moment != moment
    }

    /// This value resolved again by the rules in force, if it is still in
    /// the future: the same local time and zone, and the instant they give
    /// now. A value at or before `now` is final and comes back unchanged.
    ///
    /// If a rule change moved the local time into a gap or an overlap,
    /// `resolving` decides, and ``resolution`` says so.
    ///
    /// - Throws: ``TimeError/unknownZone(_:)`` if the rules in force do not
    ///   know the zone; ``TimeError/inGap(_:_:)`` or
    ///   ``TimeError/inOverlap(_:_:)`` under ``Disambiguation/reject``.
    public func refreshed(now: Moment = .now, resolving: Disambiguation = .compatible) throws(TimeError) -> ZonedDateTime {
        guard moment > now else { return self }
        return try ZonedDateTime(local, in: zone, resolving: resolving)
    }
}

extension ZonedDateTime: Hashable {
    /// Equal when the local time, the zone and the instant are; how each was
    /// resolved does not matter.
    public static func == (lhs: ZonedDateTime, rhs: ZonedDateTime) -> Bool {
        lhs.local == rhs.local && lhs.zone == rhs.zone && lhs.moment == rhs.moment
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(local)
        hasher.combine(zone)
        hasher.combine(moment)
    }
}

extension Moment {
    /// This moment as it is seen from `zone`: the local date and time there,
    /// by the zone rules in force.
    ///
    ///     let checkedIn = try commitment.checkedInAt.in(event.zone)
    ///     Text("\(checkedIn.local.time)")
    ///
    /// The zoned value's precision is its local time's, the nanosecond: a
    /// finer moment is taken to the nanosecond before it.
    ///
    /// - Throws: ``TimeError/unknownZone(_:)`` if the rules do not know
    ///   `zone`; ``TimeError/outOfRange(_:)`` if the local date there is
    ///   outside the years 0001 to 9999.
    public func `in`(_ zone: TimeZoneID) throws(TimeError) -> ZonedDateTime {
        let rules = ZoneRules.current
        let (nanoseconds, _) = floorDivision(sinceEpoch.attoseconds, by: 1_000_000_000)
        let instant = Moment(sinceEpoch: Duration(attoseconds: nanoseconds * 1_000_000_000))
        let offset = try rules.offsetSeconds(of: zone, atSecond: ZoneRules.wholeSeconds(instant.sinceEpoch))
        let local = try PlainDateTime(asIfUTC: instant.sinceEpoch + .seconds(offset))
        var resolution = Resolution.exact
        if case .overlap(let earlier, _) = try rules.kind(of: local, in: zone) {
            resolution = .overlap(chose: offset == earlier ? .earlier : .later)
        }
        return ZonedDateTime(local: local, zone: zone, moment: instant, resolution: resolution)
    }
}

/// Which instant a local time means when the zone's clocks skipped it (a
/// gap) or showed it twice (an overlap).
public enum Disambiguation: Sendable, Hashable {
    /// Temporal's default, and what most calendars do: in a gap, the time
    /// after it, moved forward by the gap's length (02:30 becomes 03:30); in
    /// an overlap, the first of the two.
    case compatible
    /// The earlier instant: in a gap, the time before it, moved back by the
    /// gap's length (02:30 becomes 01:30); in an overlap, the first.
    case earlier
    /// The later instant: in a gap, the time after it; in an overlap, the
    /// second.
    case later
    /// Neither: ``TimeError/inGap(_:_:)`` or ``TimeError/inOverlap(_:_:)``,
    /// so the caller asks the person.
    case reject
}

/// How a zoned value's instant was derived from its local time.
public enum Resolution: Sendable, Hashable {
    /// The local time happens exactly once in the zone.
    case exact
    /// The local time does not exist: the clocks sprang forward over it.
    /// The instant is the one the zone's clocks show `shiftedBy` from it:
    /// an hour later (positive) or earlier (negative), for an hour's gap.
    case gap(shiftedBy: Duration)
    /// The local time happens twice: the clocks fell back over it. The
    /// instant is the occurrence the policy chose.
    case overlap(chose: Occurrence)
    /// Read from text, which carries the instant (the offset) but not how
    /// it was first resolved. ``ZonedDateTime/refreshed(now:resolving:)``
    /// resolves it again, and says.
    case decoded

    /// Which of a twice-shown local time's instants.
    public enum Occurrence: Sendable, Hashable {
        /// The first, before the clocks fell back.
        case earlier
        /// The second, after.
        case later
    }

    /// The policy that gives this resolution again under the same rules, or
    /// `nil` for a value read from text, whose policy is not known.
    var policy: Disambiguation? {
        switch self {
        case .exact: .compatible
        case .gap(let shift): shift < .zero ? .earlier : .later
        case .overlap(.earlier): .earlier
        case .overlap(.later): .later
        case .decoded: nil
        }
    }
}

// MARK: - Resolution

/// What a local time is in a zone under some rules, as offsets in seconds.
enum LocalTimeKind {
    /// It happens once, at this offset.
    case unique(offset: Int)
    /// It does not exist: the clocks went from `before` to `after` over it.
    case gap(before: Int, after: Int)
    /// It happens twice: first at `earlier` (the larger offset), then at
    /// `later`.
    case overlap(earlier: Int, later: Int)
}

extension ZoneRules {
    /// What `local` is in `zone`: once, never, or twice.
    ///
    /// An instant at which `local` is read in the zone is `local - offset`
    /// for an offset the zone uses then. Offsets are within a day of UTC, so
    /// the offsets in force a day either side of `local` (read as UTC) are
    /// every candidate; each that gives itself back is an instant. None is a
    /// gap, two an overlap. This is the method of Temporal's reference code,
    /// and needs nothing from the rules but the offset at an instant.
    func kind(of local: PlainDateTime, in zone: TimeZoneID) throws(TimeError) -> LocalTimeKind {
        if let fixed = zone.fixedOffset { return .unique(offset: fixed) }
        let second = Self.wholeSeconds(local.asIfUTC)
        let before = try offsetSeconds(of: zone, atSecond: second - 86_400)
        let middle = try offsetSeconds(of: zone, atSecond: second)
        let after = try offsetSeconds(of: zone, atSecond: second + 86_400)
        var valid: [Int] = []
        for candidate in Set([before, middle, after]) {
            if try offsetSeconds(of: zone, atSecond: second - Int64(candidate)) == candidate { valid.append(candidate) }
        }
        // A larger offset reads the same wall time at an earlier instant.
        valid.sort(by: >)
        switch valid.count {
        case 0 where after > before:
            return .gap(before: before, after: after)
        case 0:
            // Two transitions within the two days, cancelling out: no real
            // zone does this, and the nearest reading is the middle one.
            return .unique(offset: middle)
        case 1:
            return .unique(offset: valid[0])
        default:
            return .overlap(earlier: valid[0], later: valid[valid.count - 1])
        }
    }

    /// Every instant some policy makes of `local` in `zone`: one, or the two
    /// sides of a gap or overlap.
    func instants(for local: PlainDateTime, in zone: TimeZoneID) throws(TimeError) -> [Moment] {
        let wall = local.asIfUTC
        func at(_ offset: Int) -> Moment { Moment(sinceEpoch: wall - .seconds(offset)) }
        switch try kind(of: local, in: zone) {
        case .unique(let offset): return [at(offset)]
        case .gap(let before, let after): return [at(after), at(before)]
        case .overlap(let earlier, let later): return [at(earlier), at(later)]
        }
    }

    /// The instant `local` means in `zone` under `policy`, and how it was
    /// found, as ``resolution(of:in:_:)`` gives it; a gap is reported as
    /// `time.resolved_in_gap`.
    func resolve(
        _ local: PlainDateTime, in zone: TimeZoneID, _ policy: Disambiguation
    ) throws(TimeError) -> (Moment, Resolution) {
        let (moment, resolution) = try self.resolution(of: local, in: zone, policy)
        if case .gap(let shift) = resolution {
            Ambient.record(
                Event(
                    "time.resolved_in_gap", level: .info,
                    fields: [
                        Event.Field("zone", .string(zone.identifier), privacy: .public),
                        Event.Field("local", .string(local.description)),
                        Event.Field("shift", .duration(shift)),
                        Event.Field("policy", .string("\(policy)"), privacy: .public),
                    ]))
        }
        return (moment, resolution)
    }

    /// The instant `local` means in `zone` under `policy`, and how it was
    /// found; nothing recorded.
    func resolution(
        of local: PlainDateTime, in zone: TimeZoneID, _ policy: Disambiguation
    ) throws(TimeError) -> (moment: Moment, resolution: Resolution) {
        let wall = local.asIfUTC
        func at(_ offset: Int) -> Moment { Moment(sinceEpoch: wall - .seconds(offset)) }
        switch try kind(of: local, in: zone) {
        case .unique(let offset):
            return (at(offset), .exact)
        case .overlap(let earlier, let later):
            switch policy {
            case .compatible, .earlier: return (at(earlier), .overlap(chose: .earlier))
            case .later: return (at(later), .overlap(chose: .later))
            case .reject: throw .inOverlap(local, zone)
            }
        case .gap(let before, let after):
            let length = Duration.seconds(after - before)
            switch policy {
            // The offset from before the gap, which lands after it.
            case .compatible, .later: return (at(before), .gap(shiftedBy: length))
            case .earlier: return (at(after), .gap(shiftedBy: .zero - length))
            case .reject: throw .inGap(local, zone)
            }
        }
    }
}

// MARK: - Text

extension ZonedDateTime: CustomStringConvertible {
    /// RFC 9557: `2027-03-14T09:00:00-04:00[America/New_York]`. The offset
    /// is written `±hh:mm`, or `±hh:mm:ss` for an offset with seconds (local
    /// mean time, before a zone kept standard time), which RFC 3339 cannot
    /// write and Temporal reads.
    public var description: String {
        let offsetSeconds = Int(ZoneRules.wholeSeconds(offset))
        let time = local.time
        return "\(local.date)T\(TimeTextWriter.padded(time.hour, 2)):\(TimeTextWriter.padded(time.minute, 2)):\(time.secondsText)"
            + TimeTextWriter.offset(seconds: offsetSeconds) + "[\(zone.identifier)]"
    }

    /// Reads RFC 9557's form: an RFC 3339 timestamp with the offset the
    /// zone gave, then the zone in brackets.
    ///
    /// No rules are consulted: the local time and the zone are read as
    /// written, and the instant from the offset, so an offset the zone does
    /// not give now is read as written and the value is stale (RFC 9557's
    /// inconsistent offset: the text was written under other rules). The
    /// zone may be marked critical (`[!America/New_York]`); further tags
    /// are read as RFC 9557 says (an unknown elective one is ignored, an
    /// unknown critical one refused), and the calendar, if named, must be
    /// `iso8601`. The ``resolution`` of a value read is
    /// ``Resolution/decoded``.
    ///
    /// - Throws: ``TimeError/invalid(_:)`` with the reason, including for
    ///   an offset of `Z`: it says the local time is unknown, and a zoned
    ///   value's local time is its truth.
    public init(parsing text: String) throws(TimeError) {
        switch Self.parse(text) {
        case .success(let value): self = value
        case .failure(let failure): throw .invalid("\"\(text)\" is not a zoned date-time: \(failure.message)")
        }
    }

    static func parse(_ text: String) -> Result<ZonedDateTime, TimeTextFailure> {
        var scanner = TimeTextScanner(text)
        let date: PlainDate
        switch scanner.date() {
        case .success(let value): date = PlainDate(unchecked: value.year, value.month, value.day)
        case .failure(let failure): return .failure(failure)
        }
        guard scanner.take("Tt") != nil else {
            return .failure(TimeTextFailure("it needs a time, an offset and a zone after the date, such as `T09:00:00-04:00[America/New_York]`"))
        }
        let time: PlainTime
        switch scanner.time(requireSeconds: true, fractionDigits: 9) {
        case .success(let value): time = PlainTime(value)
        case .failure(let failure): return .failure(failure)
        }
        if scanner.take("Zz") != nil {
            return .failure(
                TimeTextFailure("its offset is `Z`, which says the local time is unknown; write the offset the zone gave, such as `-04:00`"))
        }
        let offset: Int
        switch scanner.offset(allowZ: false, allowSeconds: true) {
        case .success(let value): offset = value
        case .failure(let failure): return .failure(failure)
        }
        guard scanner.take("[") != nil else {
            return .failure(TimeTextFailure("it has no zone in brackets, such as `[America/New_York]`; without one it is a moment"))
        }
        _ = scanner.take("!")
        guard let name = scanner.take(until: UInt8(ascii: "]")) else {
            return .failure(TimeTextFailure("the zone's bracket is not closed"))
        }
        _ = scanner.take("]")
        if name.contains("=") { return .failure(TimeTextFailure("the first bracket must be the zone, not a tag")) }
        if let problem = TimeZoneID.problem(with: name) { return .failure(TimeTextFailure(problem)) }
        while !scanner.isAtEnd {
            guard scanner.take("[") != nil else { return .failure(TimeTextFailure("it goes on after the zone")) }
            let critical = scanner.take("!") != nil
            guard let tag = scanner.take(until: UInt8(ascii: "]")) else {
                return .failure(TimeTextFailure("a tag's bracket is not closed"))
            }
            _ = scanner.take("]")
            if let failure = Self.check(tag: tag, critical: critical) { return .failure(failure) }
        }
        let local = PlainDateTime(date, time)
        let moment = Moment(sinceEpoch: local.asIfUTC - .seconds(offset))
        return .success(
            ZonedDateTime(local: local, zone: TimeZoneID(unchecked: name), moment: moment, resolution: .decoded))
    }

    /// Why an RFC 9557 suffix tag (`u-ca=iso8601`) cannot be accepted, or
    /// `nil` if it can.
    private static func check(tag: String, critical: Bool) -> TimeTextFailure? {
        let parts = tag.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].utf8.first,
            (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z")) || first == UInt8(ascii: "_"),
            !parts[1].isEmpty
        else {
            return TimeTextFailure("`[\(tag)]` is not a tag of the form key=value")
        }
        if parts[0] == "u-ca" {
            return parts[1] == "iso8601"
                ? nil : TimeTextFailure("it names the calendar \(parts[1]); a zoned date-time here is in ISO 8601's")
        }
        return critical ? TimeTextFailure("it has the critical tag `[!\(tag)]`, which is not understood here") : nil
    }
}

extension ZonedDateTime: Codable {
    /// Reads the RFC 9557 text, `2027-03-14T09:00:00-04:00[America/New_York]`.
    public init(from decoder: any Decoder) throws {
        self = try decodeText(from: decoder, kind: "a zoned date-time", parse: Self.parse)
    }

    /// Writes the RFC 9557 text, `2027-03-14T09:00:00-04:00[America/New_York]`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public import Stoic
internal import Synchronization

/// The rules that turn a zone's name into offsets: which offset a place's
/// clocks had at an instant, and so which instants a local time names.
///
/// The seam between StoicTime and the world. In an app the rules are the
/// system's (``system``): the IANA database the OS ships, through
/// Foundation, updated with the OS a few times a year, sometimes with days of
/// notice. In a test they are scripted (``ScriptedZoneRules``): zones whose
/// offsets and transitions the test writes, and whose rules and version it
/// can change halfway, as an OS update would. Everything that needs an
/// offset reads ``current``, so a test sets the rules once, with
/// `withZoneRules(_:operation:)`.
///
/// The rules are asked for one thing, the offset of a zone at an instant,
/// and everything else (gaps, overlaps, staleness) is derived from it here,
/// the same way for every source of rules.
public struct ZoneRules: Sendable {
    let source: any ZoneRulesSource

    init(source: any ZoneRulesSource) {
        self.source = source
    }

    /// The rules in force for the current task: those of the nearest
    /// `withZoneRules(_:operation:)`, else the ``system``'s.
    public static var current: ZoneRules { stored ?? .system }

    @TaskLocal static var stored: ZoneRules?

    /// The version of the rules: the IANA release, such as `2026a`, for
    /// the system's. A change of version is one cause of stale zoned values,
    /// which `Reconciler.zonedValues(name:reads:writes:values:write:)` refreshes.
    public var version: String { source.version }

    /// The zone the device is set to, which ``TimeZoneID/device`` reads.
    public var deviceZone: TimeZoneID { source.deviceZone }

    /// The offset from UTC of `zone`'s clocks at `moment`: what their wall
    /// clocks read minus UTC. Whole seconds.
    ///
    /// - Throws: ``TimeError/unknownZone(_:)`` if these rules do not know
    ///   the zone.
    public func offset(of zone: TimeZoneID, at moment: Moment) throws(TimeError) -> Duration {
        .seconds(try offsetSeconds(of: zone, atSecond: Self.wholeSeconds(moment.sinceEpoch)))
    }

    /// The offset in seconds at the whole second `second` since the epoch.
    func offsetSeconds(of zone: TimeZoneID, atSecond second: Int64) throws(TimeError) -> Int {
        if let fixed = zone.fixedOffset { return fixed }
        guard let offset = source.offset(of: zone.identifier, atSecond: second) else { throw .unknownZone(zone) }
        return offset
    }

    /// The whole seconds of `duration`, rounded towards the past, clamped to
    /// what an `Int64` holds: offsets change only on whole seconds, and no
    /// zone has rules past the year 9999.
    static func wholeSeconds(_ duration: Duration) -> Int64 {
        let (seconds, _) = floorDivision(duration.attoseconds, by: 1_000_000_000_000_000_000)
        return Int64(clamping: seconds)
    }
}

/// A source of zone offsets: the system's or a test's.
protocol ZoneRulesSource: Sendable {
    var version: String { get }
    var deviceZone: TimeZoneID { get }
    /// Seconds east of UTC in the zone named `identifier` at the whole
    /// second `second` since the epoch, or `nil` if the zone is unknown.
    func offset(of identifier: String, atSecond second: Int64) -> Int?
}

/// Runs `operation` with `rules` as the zone rules in force
/// (``ZoneRules/current``), for it and every task it starts.
///
///     let rules = ScriptedZoneRules(version: "2026a")
///     rules.define("America/New_York", offset: .seconds(-5 * 3600), transitions: …)
///     try await withZoneRules(rules.rules) {
///         try await schedule(event)
///     }
@discardableResult
public nonisolated(nonsending) func withZoneRules<R, Failure: Error>(
    _ rules: ZoneRules,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Failure) -> R {
    try await ZoneRules.$stored.withValueTyped(rules, operation: operation)
}

/// Runs a synchronous `operation` with `rules` as the zone rules in force.
@discardableResult
@_disfavoredOverload
public func withZoneRules<R, Failure: Error>(
    _ rules: ZoneRules,
    operation: () throws(Failure) -> R
) throws(Failure) -> R {
    try ZoneRules.$stored.withValueTyped(rules, operation: operation)
}

// MARK: - Scripted rules

/// Zone rules a test writes: each zone's offsets and the instants they
/// change, and a version, all of which the test can change while it runs.
///
///     let rules = ScriptedZoneRules(version: "2026a", deviceZone: "America/New_York")
///     rules.define("America/New_York", offset: .seconds(-5 * 3600), transitions: [
///         .init(at: Moment(rfc3339: "2027-03-14T07:00:00Z")!, offset: .seconds(-4 * 3600)),
///         .init(at: Moment(rfc3339: "2027-11-07T06:00:00Z")!, offset: .seconds(-5 * 3600)),
///     ])
///     try await withZoneRules(rules.rules) { … }
///     rules.version = "2026b"     // an OS update
///
/// A test never depends on the machine's own zone database, nor on the zone
/// the machine is set to: both are written here. The ``rules`` value reads
/// this object live, so a change made later is seen by every value resolved
/// after it, as an OS update is.
public final class ScriptedZoneRules: Sendable {
    /// A change of a zone's offset: from `at` on, the clocks are `offset`
    /// from UTC.
    public struct Transition: Sendable, Hashable {
        public var at: Moment
        public var offset: Duration

        public init(at: Moment, offset: Duration) {
            self.at = at
            self.offset = offset
        }
    }

    private struct Zone {
        var initialOffset: Int
        /// Sorted by instant: (the whole second it starts, its offset).
        var transitions: [(second: Int64, offset: Int)]
    }

    private struct State {
        var version: String
        var deviceZone: TimeZoneID
        var zones: [String: Zone] = [:]
    }

    private let state: Mutex<State>

    /// Rules that know no zone yet but `UTC` and fixed offsets.
    public init(version: String = "scripted", deviceZone: TimeZoneID = .utc) {
        state = Mutex(State(version: version, deviceZone: deviceZone))
    }

    /// These rules, for `withZoneRules(_:operation:)`.
    public var rules: ZoneRules { ZoneRules(source: Source(owner: self)) }

    /// The version the rules report; set it to play an update.
    public var version: String {
        get { state.withLock { $0.version } }
        set { state.withLock { $0.version = newValue } }
    }

    /// The zone the device is set to; set it to play travel.
    public var deviceZone: TimeZoneID {
        get { state.withLock { $0.deviceZone } }
        set { state.withLock { $0.deviceZone = newValue } }
    }

    /// Defines `zone`, or replaces its rules: `offset` until the first
    /// transition, then each transition's from its instant on.
    ///
    /// Offsets are whole seconds, as every real zone's are, within a day of
    /// UTC.
    public func define(_ zone: TimeZoneID, offset: Duration, transitions: [Transition] = []) {
        let entries = transitions.sorted { $0.at < $1.at }.map { ((second: ZoneRules.wholeSeconds($0.at.sinceEpoch), offset: Self.seconds($0.offset))) }
        let defined = Zone(initialOffset: Self.seconds(offset), transitions: entries)
        state.withLock { $0.zones[zone.identifier] = defined }
    }

    /// Forgets `zone`: it becomes unknown, as a name these rules never had.
    public func remove(_ zone: TimeZoneID) {
        _ = state.withLock { $0.zones.removeValue(forKey: zone.identifier) }
    }

    private static func seconds(_ offset: Duration) -> Int {
        let (seconds, attoseconds) = offset.components
        precondition(attoseconds == 0, "a zone's offset is a whole number of seconds")
        precondition(abs(seconds) < 86_400, "a zone's offset is less than a day")
        return Int(seconds)
    }

    private func offset(of identifier: String, atSecond second: Int64) -> Int? {
        state.withLock { state in
            guard let zone = state.zones[identifier] else { return nil }
            // The last transition at or before `second`.
            var low = 0
            var high = zone.transitions.count
            while low < high {
                let middle = (low + high) / 2
                if zone.transitions[middle].second <= second { low = middle + 1 } else { high = middle }
            }
            return low == 0 ? zone.initialOffset : zone.transitions[low - 1].offset
        }
    }

    private struct Source: ZoneRulesSource {
        let owner: ScriptedZoneRules
        var version: String { owner.version }
        var deviceZone: TimeZoneID { owner.deviceZone }
        func offset(of identifier: String, atSecond second: Int64) -> Int? {
            owner.offset(of: identifier, atSecond: second)
        }
    }
}

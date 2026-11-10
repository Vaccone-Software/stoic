public import Stoic

/// Refreshes an app's future zoned values once each time the zone rules
/// change, and remembers the version it last ran under.
///
///     // Kept with the app's settings, which persist it.
///     var sweep = settings.zoneRulesSweep
///     try await sweep.run(values: { try await store.upcomingStarts() }) { moved in
///         try await store.update(starts: moved)        // and tell the organisers
///     }
///     settings.zoneRulesSweep = sweep
///
/// Staleness needs no version stamped on each value: asking is a comparison,
/// microseconds each (``ZonedDateTime/isStale(now:)``). What is versioned is
/// the sweep. When the rules' version is the one it last swept under, it
/// does nothing and does not ask for the values. When it differs (an OS
/// update; the first run), it asks for them, refreshes the future ones whose
/// instant changed, hands those to `apply` once, and then records the new
/// version. Most rule releases touch one or two countries, so most sweeps
/// move nothing.
///
/// It is a value, `Codable`, so the app keeps it wherever it keeps settings;
/// if `apply` throws, the version is not recorded, and the next run tries
/// again. A missed sweep is never a wrong time on screen: display and "is it
/// time?" read the local time and zone (design/26).
public struct ZoneRulesSweep: Sendable, Hashable, Codable {
    /// The version of the rules the last completed sweep ran under; `nil`
    /// before the first.
    public private(set) var lastSweptVersion: String?

    public init(lastSweptVersion: String? = nil) {
        self.lastSweptVersion = lastSweptVersion
    }

    /// Whether the rules in force are of another version than the last
    /// sweep's, so ``run(now:resolving:values:apply:)`` would sweep.
    public var isDue: Bool {
        lastSweptVersion != ZoneRules.current.version
    }

    /// What one sweep did.
    public struct Report: Sendable, Hashable {
        /// The version swept under before; `nil` on the first sweep.
        public let previousVersion: String?
        /// The version swept under now.
        public let version: String
        /// How many values the app gave.
        public let given: Int
        /// How many were future values whose instant changed, and were
        /// handed to `apply`.
        public let moved: Int
        /// How many could not be resolved under the new rules (a zone they
        /// do not know, or a gap under ``Disambiguation/reject``), and were
        /// left as they were.
        public let unresolved: Int
    }

    /// If the zone rules in force are of another version than the last
    /// sweep's, refreshes the stale ones among the app's values and hands
    /// them to `apply`, once; then records the version.
    ///
    /// - Parameters:
    ///   - now: Values at or before it are final, and never moved.
    ///   - resolving: The policy for a local time a rule change moved into a
    ///     gap or an overlap.
    ///   - values: The app's zoned values, by any key it can find them by
    ///     again. Asked only when the version changed.
    ///   - apply: Receives the refreshed values that moved, by key, to store
    ///     (and, if the app wishes, to tell people about). Not called when
    ///     nothing moved.
    /// - Returns: What the sweep did, or `nil` if the version was the one
    ///   last swept, and nothing was asked or done.
    /// - Throws: Whatever `values` or `apply` throws; the version is then
    ///   not recorded.
    @discardableResult
    public mutating func run<Key: Hashable & Sendable, Failure: Error>(
        now: Moment = .now,
        resolving: Disambiguation = .compatible,
        values: () async throws(Failure) -> [Key: ZonedDateTime],
        apply: ([Key: ZonedDateTime]) async throws(Failure) -> Void
    ) async throws(Failure) -> Report? {
        let version = ZoneRules.current.version
        guard version != lastSweptVersion else { return nil }
        let given = try await values()
        var moved: [Key: ZonedDateTime] = [:]
        var unresolved = 0
        for (key, value) in given {
            do throws(TimeError) {
                guard try value.isStale(now: now) else { continue }
                moved[key] = try value.refreshed(now: now, resolving: resolving)
            } catch {
                // Left as it was, and counted: one zone these rules do not
                // know must not hold up every other value.
                unresolved += 1
            }
        }
        if !moved.isEmpty { try await apply(moved) }
        let report = Report(
            previousVersion: lastSweptVersion, version: version, given: given.count, moved: moved.count, unresolved: unresolved)
        lastSweptVersion = version
        Ambient.record(
            Event(
                "time.zone_rules_changed", level: .notice,
                fields: [
                    Event.Field("previous", .string(report.previousVersion ?? "none"), privacy: .public),
                    Event.Field("version", .string(version), privacy: .public),
                    Event.Field("given", .int(report.given)),
                    Event.Field("moved", .int(report.moved)),
                    Event.Field("unresolved", .int(report.unresolved)),
                ]))
        return report
    }
}

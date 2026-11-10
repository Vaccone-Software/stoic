# 26 · Time

> Built: `Moment` and `WallClock` in `Stoic`, the test wall clock in
> `StoicTesting`, the library `StoicTime`, and the lint rule
> `stoic.wall-clock-read`. Where the build departs from the first draft, the
> API below is as built and [As built](#as-built) says why.

"When" is not one question. An app asks at least four, and most date bugs are
one of them answered with another's type: a birthday stored as an instant and
shown a day early west of Greenwich; an event stored as a local-time string with
no zone, so nobody can say when it is; a future meeting stored in UTC, an hour
wrong after a government moves its clocks; a timeout measured on a clock the
user can set; "today" read from the device in the middle of a test. Foundation's
`Date` is an instant with a calendar's name, and `DateComponents` is a bag that
can mean any of them. Stoic gives each question its own type, makes every
conversion between them explicit and zone-aware, and gives "now" one injected
source.

## The ideal scenario

A volunteering app. An event is planned for 9:00 on 14 March in New York;
volunteers check in when they arrive; a minor needs a parent's waiver; the
waiver link expires in seven days.

```swift
// A planned moment: local time and zone are the truth; the instant is derived.
let start = try ZonedDateTime(PlainDate(2027, 3, 14), PlainTime(9, 0), in: "America/New_York")
events.sorted { $0.start.moment < $1.start.moment }        // sorts like UTC
Text("\(start.local.time) \(start.zone)")                        // always 09:00, New York time

// Something that happened: a moment, from the injected wall clock.
commitment.checkedInAt = Moment.now

// A day: no zone, no instant.
let isMinor = profile.dateOfBirth.age(on: try PlainDate.today(in: start.zone)) < 18

// An expiry: seven calendar days from a moment is a decision about zones; seven
// days of elapsed time is not.
waiver.expiresAt = Moment.now + .seconds(7 * 86_400)

// After an OS update changes New York's rules: one sweep, future values only.
for event in upcoming where try event.start.isStale() {
    event.start = try event.start.refreshed()    // same 9:00, new instant; the app can tell people
}
```

## Origin

- **TC39 Temporal** (JavaScript, shipping 2025–26): `Instant`, `PlainDate`,
  `PlainTime`, `PlainDateTime`, `ZonedDateTime`, with disambiguation of gaps and
  overlaps as a named policy. The taxonomy here is its taxonomy.
- **java.time / JSR-310**: `Instant`, `LocalDate`, `ZonedDateTime`, `Period`
  apart from `Duration`: calendar amounts and elapsed time are different types.
- **RFC 3339 and RFC 9557**: the text forms. RFC 9557 adds the zone name to a
  timestamp (`2027-03-14T09:00:00-04:00[America/New_York]`) and says what an
  offset that disagrees with its zone means: exactly a zoned value resolved
  under older rules.
- **The IANA time zone database**: a handful of releases a year, most touching
  one or two countries, some with days of notice (Lebanon 2023; Mexico's
  abolition of daylight saving in 2022). Foundation reports the installed
  version (`TimeZone.timeZoneDataVersion`).
- **Kindora**: event times as local-time strings with no zone; a start-before-end
  check comparing minutes; age arithmetic in three copies; 39 direct reads of the
  clock and no test that could control one.
- **Stoic itself**: `HTTPPolicy.wallClock` and the outbox's `Expiry.wallClock`
  are two private wall clocks, because the kernel has none.

## The types

| Type               | The question it answers              | Text form                                     | Lives in    |
| ------------------ | ------------------------------------ | --------------------------------------------- | ----------- |
| `AnyClock.Instant` | how long has it been? (exists)       | none: never stored                            | `Stoic`     |
| `Moment`        | when did it happen?                  | `2026-11-09T18:34:12.425Z`                    | `Stoic`     |
| `PlainDate`        | which day?                           | `2027-03-14`                                  | `StoicTime` |
| `PlainTime`        | what time of day?                    | `09:00`, `09:00:30.5`                         | `StoicTime` |
| `PlainDateTime`    | which day and time, wherever it is?  | `2027-03-14T09:00`                            | `StoicTime` |
| `ZonedDateTime`    | when is it planned, and where?       | `2027-03-14T09:00:00-04:00[America/New_York]` | `StoicTime` |
| `Period`           | how many calendar days/months/years? | `P1M`, `P7D`                                  | `StoicTime` |
| `TimeZoneID`       | which place's rules?                 | `America/New_York`                            | `StoicTime` |

**Names.** Swift already says `Instant` for a clock's instant (`ContinuousClock.Instant`,
`InstantProtocol`), so the point on the world's timeline needs another word, and
"timestamp" suggests a zone it does not have. It is a `Moment`: when something
happened, the same everywhere. The plain and zoned names are Temporal's.

**Where they live.** `Moment` and the wall clock join the kernel: a lifecycle,
an event and an expiry all need "when", and the kernel needs nothing new to hold
it (a `Duration` since the Unix epoch). The calendar types are a domain of their
own: a new library, `StoicTime` ← `Stoic`, `StoicSchema`, portable. Zone rules
come from Foundation, in `Sources/StoicTime/Foundation`, as `StoicSchema`'s
Foundation leaves do.

## API

```swift
// Kernel
public struct Moment: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {   // Unix time, no leap seconds
    public init(sinceEpoch: Duration)
    public let sinceEpoch: Duration
    public static let epoch: Moment
    public static var now: Moment { get }                           // Ambient.current.wallClock.now
    public static func + (Moment, Duration) -> Moment               // and -, +=, -=
    public func duration(to other: Moment) -> Duration
    public init?(rfc3339: String);  public var rfc3339: String? { get }   // nil outside 0001–9999
}
public struct WallClock: Sendable {
    public init(now: @escaping @Sendable () -> Moment)
    public var now: Moment { get }
    public static let system: WallClock                             // CLOCK_REALTIME
    public static func fixed(_ moment: Moment) -> WallClock
}
extension Ambient { public var wallClock: WallClock }               // .system by default

// StoicTesting
extension TestClock {
    public static let wallClockStart: Moment                        // 2026-01-01T00:00:00Z
    public init(wallClockStart: Moment)
    public var wallClock: WallClock { get };  public var wallClockNow: Moment { get }
    public func jumpWallClock(by: Duration);  public func jumpWallClock(to: Moment)
}

// StoicTime
public struct PlainDate: Sendable, Hashable, Comparable, Codable {    // ISO 8601 calendar, 0001–9999
    public init(_ year: Int, _ month: Int, _ day: Int) throws(TimeError)
    public init(parsing text: String) throws(TimeError)
    public let year, month, day: Int;  public var weekday: Weekday;  public var daysInMonth: Int
    public static func today(in zone: TimeZoneID) throws(TimeError) -> PlainDate
    public func adding(_ period: Period, overflow: Overflow = .constrain) throws(TimeError) -> PlainDate
    public func period(to other: PlainDate) -> Period;  public func days(to other: PlainDate) -> Int
    public func age(on day: PlainDate, leapDayBirthday: LeapDayRule = .marchFirst) -> Int
    public enum Overflow { case constrain, reject }
    public enum LeapDayRule { case marchFirst, februaryLast }
}
public struct PlainTime: Sendable, Hashable, Comparable, Codable {    // 00:00 ..< 24:00, nanoseconds
    public init(_ hour: Int, _ minute: Int, _ second: Int = 0, nanosecond: Int = 0) throws(TimeError)
    public var hour, minute, second, nanosecond: Int { get };  public static let midnight, noon: PlainTime
}
public struct PlainDateTime: Sendable, Hashable, Comparable, Codable { public var date: PlainDate; public var time: PlainTime }
public struct Period: Sendable, Hashable, Codable { public var years, months, days: Int }   // .days(7), .weeks(2), .months(1), -p
public enum Weekday: Int { case monday = 1, …, sunday }
public struct TimeZoneID: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public init(_ identifier: String) throws(TimeError)             // a literal with a malformed name is a precondition failure
    public let identifier: String
    public static let utc: TimeZoneID;  public static var device: TimeZoneID { get }   // from ZoneRules.current
}

public struct ZonedDateTime: Sendable, Hashable, Codable {           // equal by local, zone and moment
    public init(_ date: PlainDate, _ time: PlainTime, in zone: TimeZoneID, resolving: Disambiguation = .compatible) throws(TimeError)
    public init(_ local: PlainDateTime, in zone: TimeZoneID, resolving: Disambiguation = .compatible) throws(TimeError)
    public init(parsing text: String) throws(TimeError)              // RFC 9557; no rules consulted
    public let local: PlainDateTime          // the truth
    public let zone: TimeZoneID              // the truth
    public let moment: Moment                // derived when resolved: for sorting, filtering, comparing
    public var offset: Duration { get }      // what the rules said then
    public let resolution: Resolution        // .exact, .gap(shiftedBy:), .overlap(chose:), .decoded
    public func isStale(now: Moment = .now) throws(TimeError) -> Bool
    public func refreshed(now: Moment = .now, resolving: Disambiguation = .compatible) throws(TimeError) -> ZonedDateTime
}
extension Moment { public func `in`(_ zone: TimeZoneID) throws(TimeError) -> ZonedDateTime }   // an instant, seen from a place

public enum Disambiguation: Sendable { case compatible, earlier, later, reject }
public enum Resolution: Sendable, Hashable {
    case exact, gap(shiftedBy: Duration), overlap(chose: Occurrence), decoded
    public enum Occurrence { case earlier, later }
}
public enum TimeError: Error { case invalid(String), outOfRange(String), unknownZone(TimeZoneID),
                               inGap(PlainDateTime, TimeZoneID), inOverlap(PlainDateTime, TimeZoneID) }
public struct ZoneRules: Sendable {          // the seam: .system (Foundation), or scripted in tests
    public static var current: ZoneRules { get }                    // the nearest withZoneRules, else .system
    public var version: String { get };  public var deviceZone: TimeZoneID { get }
    public func offset(of zone: TimeZoneID, at moment: Moment) throws(TimeError) -> Duration
}
public final class ScriptedZoneRules: Sendable {                     // zones, transitions, version and device zone a test writes
    public init(version: String = "scripted", deviceZone: TimeZoneID = .utc)
    public var rules: ZoneRules { get };  public var version: String;  public var deviceZone: TimeZoneID
    public func define(_ zone: TimeZoneID, offset: Duration, transitions: [Transition] = []);  public func remove(_ zone: TimeZoneID)
}
public func withZoneRules<R, Failure>(_ rules: ZoneRules, operation: () async throws(Failure) -> R) async throws(Failure) -> R   // and a synchronous form
public struct ZoneRulesSweep: Sendable, Hashable, Codable {          // a value the app persists with its settings
    public private(set) var lastSweptVersion: String?;  public var isDue: Bool { get }
    public mutating func run<Key, Failure>(now: Moment = .now, resolving: Disambiguation = .compatible,
        values: () async throws(Failure) -> [Key: ZonedDateTime],
        apply: ([Key: ZonedDateTime]) async throws(Failure) -> Void) async throws(Failure) -> Report?
}
// Schema leaves: Schema<Moment>.moment, .plainDate, .plainTime, .plainDateTime, .zonedDateTime, .period, .timeZoneID;
// each type is Schematic.

// StoicTime/Foundation
extension ZoneRules { public static let system: ZoneRules }        // TimeZone, TimeZone.timeZoneDataVersion
extension Moment { public init(_ date: Date); public var date: Date { get } }
extension TimeZone { public init?(_ id: TimeZoneID) };  extension TimeZoneID { public init(_ zone: TimeZone) }
```

## Semantics

**Three clocks.** The continuous clock measures (`Deadline`, retries); the
suspending clock judges liveness; the wall clock says when. A wall clock can
jump — a person sets it, the network corrects it — so nothing is measured on
it, and a monotonic instant means nothing after a reboot, so nothing stores
one. The types keep the two apart: there is no conversion between
`AnyClock.Instant` and `Moment`.

**One "now".** `Moment.now` reads `Ambient.current.wallClock`. Under
`withTestAmbient` the wall clock is the test clock's: it starts at a fixed,
stated instant and moves with `advance(by:)`, and a test can also jump it alone
(a person changing the clock) without moving the monotonic clocks. The lint
rule `stoic.wall-clock-read` refuses `Date()`, `Date.now` and
`Calendar.current`/`TimeZone.current` (and `NSDate()`, `Date.init()` and the
`autoupdatingCurrent` twins) outside `StoicTime`'s Foundation folder,
as `bare-task-sleep` refuses `Task.sleep`. `HTTPPolicy.wallClock` and the
outbox's `Expiry.wallClock` are replaced by the ambient one.

**No ambient zone.** "Today" is a question about a place, and the type makes
the caller say which: `PlainDate.today(in: event.zone)`, or `.device` when the
person's own day is what is meant. A viewer's zone is never used by default.

**A zoned value is a cache with its inputs kept.** `local` and `zone` are what
the organiser meant. `moment` is what the rules made of them when the value
was resolved, kept so that a list of events sorts and filters exactly as a list
of UTC instants does, with no rule consulted on a read. Its text form carries
all three (RFC 9557: the offset is the instant). The value is _stale_ when it
is still in the future and resolving `local` in `zone` today, by the policy
its `resolution` records (`.compatible` for an exact one), gives another
instant: a rule changed. A value read from text does not say which policy
made it, so it is stale only when no policy gives its instant. `refreshed()` resolves it again; a value in the past
is final and is returned as it is. Display and "is it time?" decisions read
`local` and `zone`, or `refreshed()`, never a stale instant: so a missed sweep
can put one event an hour out of order in a list, and can never show or act on
a wrong time.

**The sweep.** Staleness needs no per-value version: asking is a comparison,
microseconds each. What is versioned is the sweep: `ZoneRulesSweep` remembers
the rules version it last ran under and, when the system's differs, hands the
app's future zoned values to a closure once. Most releases change nothing an
app holds.

**Gaps and overlaps.** A local time that does not exist (clocks sprang forward
over it) or exists twice (they fell back) is resolved by a named policy:
`.compatible` (Temporal's default: after the gap; the first of two), `.earlier`,
`.later`, or `.reject`. The result says which happened (`resolution`), so an
app can tell an organiser that 2:30 does not exist that night. A rule change
can move a stored time into a gap; `refreshed()` reports it the same way.

**Calendar arithmetic is not elapsed time.** `PlainDate + Period` moves on the
calendar, with the overflow named (31 January + 1 month is 28 February under
`.constrain`, an error under `.reject`). `Moment + Duration` moves on the
timeline. "Seven days from now" is one or the other, and the code says which;
there is no `Moment + Period` without a zone.

**The calendar** is ISO 8601's (proleptic Gregorian). Other calendars are a
question of display, which stays Foundation's.

## Failure modes

| What happens if…                                                | Then                                                                                           |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| a date that does not exist is made (30 February, month 13)      | `TimeError.invalid`, at construction; never a silently rolled-over date                        |
| a plain date is decoded from a moment's text, or the reverse | a schema issue: the forms do not overlap                                                       |
| a birthday is read in a zone west of UTC                        | the same day: a `PlainDate` has no zone to shift it                                            |
| a person born on 29 February is aged in a non-leap year         | the named rule decides (`.marchFirst` or `.februaryLast`)                                      |
| a month is added to the 31st                                    | the named overflow decides: the month's last day, or an error                                  |
| a local time falls in a gap                                     | the policy decides; `resolution` says `.gap`; `.reject` throws                                 |
| a local time falls in an overlap                                | the policy decides; `resolution` says `.overlap`                                               |
| a zone name is unknown to the rules                             | `TimeError.unknownZone`, at resolution                                                         |
| the zone's rules change for a future zoned value                | it is stale; `refreshed()` keeps the local time and zone and derives the new instant           |
| the zone's rules change for a past zoned value                  | it is final: not stale, and `refreshed()` returns it unchanged                                 |
| a rule change moves a stored local time into a gap              | `refreshed()` resolves it by the policy and reports `.gap`                                     |
| a stale value is sorted before it is refreshed                  | it sorts by its old instant; its displayed time is still right                                 |
| a zoned value's text has an offset its zone does not give       | it decodes, stale; it is not refused (RFC 9557's inconsistent offset)                          |
| the rules version changes between launches                      | the sweep runs once and records the new version                                                |
| the rules version is unchanged                                  | the sweep does nothing                                                                         |
| the wall clock jumps backwards during a timeout                 | the timeout is unaffected: it is on the continuous clock                                       |
| a test advances its clock                                       | `Moment.now` and `PlainDate.today` move with it                                             |
| a test jumps the wall clock alone                               | moments jump; deadlines and sleeps do not                                                   |
| code reads `Date()` directly                                    | the lint rule refuses it, with the fix                                                         |
| a moment is before 1970 or far in the future                 | it is represented exactly; RFC 3339 text covers years 0001–9999, beyond which encoding refuses |

## Events

`time.zone_rules_changed` (notice: the old and new versions; how many values
the sweep was given and how many moved), `time.resolved_in_gap` (info).

## Testing

- Every row, on the test wall clock and scripted `ZoneRules` (a zone whose rule
  changes between versions; a gap; an overlap).
- Properties: text round-trips for every type; `PlainDate` arithmetic against
  day counts over 1600–2400; resolving and reading back in a fixed-offset zone
  is the identity.
- The system rules against known transitions (New York 2027, Lord Howe's
  half-hour change, a zone without daylight saving).
- The ideal scenario above, as a test.

## As built

Departures from the first draft, and decisions it left open.

- **Throwing where the draft did not.** `PlainDate.today(in:)`, `Moment.in(_:)`,
  `isStale(now:)` and `refreshed(now:resolving:)` throw `TimeError`: each asks
  the rules about a zone, and a zone the rules do not know (a misspelling, a
  zone newer than this device's rules, a value decoded from another device)
  has no honest default; `refreshed` also throws under `.reject`. The draft's
  "unknown zone at resolution" row is this.
- **`Resolution.decoded`.** The text carries the instant (the offset) but not
  how it was first resolved, so a value read from text says so instead of
  claiming `.exact`. `resolution` is provenance: it is left out of equality and
  hashing, so a value reads back from its text as itself.
- **Staleness by the recorded policy**, not "any policy": an exact time that a
  rule change moved into a gap must be stale, though the gap's earlier side
  is its old instant.
- **Read-only fields.** `PlainDate`'s year, month and day are `let`: a settable
  day would make 30 February. `PlainDateTime`'s parts stay `var` (each is valid
  alone).
- **Text.** Every type has `init(parsing:)` (throwing `TimeError` with the
  reason) and its text as `description`. A zoned value's text refuses `Z`
  (RFC 9557: the local time is unknown) and writes `±hh:mm:ss` for an offset
  with seconds (local mean time; RFC 3339 cannot, Temporal reads it). RFC 9557
  suffix tags are read as the RFC says: `!` on the zone is accepted, an unknown
  elective tag ignored, an unknown critical tag refused, `u-ca` must be
  `iso8601`. Moments read and write fractions to the attosecond; plain times
  to the nanosecond, and a zoned value's precision is its local time's.
  Periods are ISO 8601 date parts (`P1Y2M3D`, `P2W` as days), one leading
  sign when all parts are negative, a sign per part otherwise (as java.time).
- **`period(to:)` adds back in both directions.** Forwards it is java.time's
  `Period.between`; backwards the same rule run the other way, so 31 March to
  28 February is `-P1M` (java.time's `-P1M3D` does not add back).
- **Zones.** `UTC` and RFC 9557 offset names (`+05:30`) are answered without
  the rules. A zone name is checked against IANA's naming rules when made from
  a `String`; a literal with a malformed name is a precondition failure (code,
  not input). `TimeZoneID.device` comes from the rules, so scripted rules
  script the device's zone too, and no test reads the machine's.
- **Gaps and overlaps are found from offsets alone**: the offsets a day either
  side of the local time are the candidates (Temporal's reference method), so
  any source of rules needs to answer only "the offset at an instant".
- **The sweep is a `Codable` value**, persisted with the app's settings, so it
  needs no storage of its own; it asks for the values only when the version
  changed, hands over only the moved ones, records the version only after
  `apply` succeeds, and counts values the new rules cannot resolve rather than
  failing the sweep. The first run (no version recorded) sweeps.
- **Test time.** A test's wall clock starts at 2026-01-01T00:00:00Z
  (`TestClock.wallClockStart`), moves with `advance`, and jumps alone with
  `jumpWallClock(by:)` / `(to:)`. Under `withTestAmbient` with a clock other
  than a `TestClock` it starts there and follows that clock; the `.stoic` trait
  holds it at the start.
- **Schema leaves are static properties** (`.moment`, not `.moment()`): they
  take no parameters, as `.uuid` does.
- **The four other wall-clock reads** moved too: the flight recorder's
  timestamps and `BackgroundJob`'s `earliestBeginDate` read `Moment.now`; HTTP
  dates are read into a `Moment` with the kernel's calendar.

## Not built

- Recurring schedules in calendar terms ("every Tuesday at 9:00"), beside the
  duration-based `Schedule`. `PlainTime` and `Weekday` are its parts.
- Formatting for people (`formatted`): Foundation's, through the conversions.
- Calendars other than ISO 8601's.
- The sweep as a `Reconciler` job, when that exists (planned).

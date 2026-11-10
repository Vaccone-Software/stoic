# 32 · Schema compatibility

> Stoic 0.8.0. Builds on design/06 (schemas, migrations, the JSON Schema
> export, `SchemaSuite`, the time-capsule pattern), design/18 (settings files)
> and design/27 (the fixed format of lifecycle records). The review's
> amendments are folded in; "As built" records what implementing it changed.

A released format is a promise. Once a build has written a settings file, sent a
request body, or stored a record, a later build has to read it. Before that
later build is installed everywhere, an earlier one may also have to read what
the later one writes. Today that promise lives in comments and in people's
heads. Kindora's server keeps a field in a validator because "published
versions of the app still send" it, and nothing would notice the day someone
tidied the field away.

This contract makes the promise a test. Sample payloads from each released
version are kept as fixtures. A test proves that today's schema still reads
every one of them, and says which release, which sample, which path and why
when it does not. Where a release's schema can be kept (its exported JSON
Schema), the same test proves the reverse: that the older reader accepts what
today's writer writes. Recording the fixtures is one command at release time.

## The ideal scenario

> A server reads the report requests that every published app version sends.
> A developer removes `recipient` from the request's schema, because the server
> stopped using it in 2.4. The test fails before the change merges. It says that
> release 2.3.0's request still carries `$.recipient`, and that this object
> refuses unknown keys. The settings file every release wrote still opens, and
> the settings today's build writes still open in 2.3, which people who have not
> updated are still running.

```swift
import StoicSchemaTesting
import Testing

@Suite struct Compatibility {
    // Every request body every released app still in support sent still decodes.
    @Test func reportRequests() {
        expectCompatibility(ReportRequest.schema, format: "report-request",
                            samples: ["typical": .typical, "no-subject": .noSubject],
                            oldestSupported: "2.0.0")
    }

    // Every settings file every release wrote still opens, as the store opens it;
    // and what today writes, 2.3 still opens. 2.2 cannot: version 5 needs 2.3.
    @Test func settings() {
        expectCompatibility(Prefs.schema, format: "settings", samples: ["defaults": Prefs(), "tuned": .tuned],
                            reading: { SettingsStore<Prefs>.read($0, schema: Prefs.schema, format: .handEdited) },
                            olderReadersMayRefuse: ["2.2.0": "settings version 5 is read from 2.3 on"])
    }

    // A record kept on a device, through its Codable form (design/27's fixed format).
    @Test func releaseRecords() {
        expectCompatibility(.codable(LifecycleRecord<ReleaseOnThisMac>.self), format: "lifecycle.lodestar.release",
                            samples: ["staged": .stagedExample, "rolled-back": .rolledBackExample])
    }
}
```

The fixtures sit next to the test file, one folder per format and one per
release:

```text
Tests/ServerTests/
  CompatibilityTests.swift
  Compatibility/
    report-request/
      2.3.0/
        _schema.json          the 2.3.0 reader, as its schema exported it
        typical.json          the bytes 2.3.0 wrote, exactly
        no-subject.json
        captured-ios-17.json  a payload taken from traffic and scrubbed, added by hand
      2.4.0/
        _schema.json
        typical.json
        no-subject.json
```

At release time, one command records the release's fixtures, and they are
committed with the tag:

```text
$ STOIC_RECORD_COMPATIBILITY=2.4.0 swift test --filter Compatibility
✘ recorded 2 samples and the schema for "report-request" 2.4.0: commit Tests/ServerTests/Compatibility/report-request/2.4.0
$ git add Tests/ServerTests/Compatibility && git commit -m "Compatibility fixtures for 2.4.0"
```

When the promise breaks, the test says where:

```text
✘ "report-request": release 2.3.0's sample "typical" no longer reads (written by 2.3.0, read by today's schema)
    1:2 $.recipient: [unknown_key] <the issue's message, as StoicSchema reports it>
✘ "settings": today's sample "tuned" is refused by release 2.3.0's reader (written today, read by 2.3.0)
    $.network.retries: [additionalProperties] not a key 2.3.0 allows
```

## Origin

- **Kindora**, `packages/database/src/convex/report/actions.ts:7-8`: "Published
  versions of the app still send a recipient, so it stays in the validator, but
  the address always comes from the signed-in account." `recipient: v.string()`
  stays required (`:10`) and is ignored (`:28-32`). Clients still send it
  (`apps/mobile/app/(main)/commitments.tsx:264`, `send-verification-email.tsx:88`,
  `attendance.tsx:212`). Nothing checks the comment. Other validators are loose
  for reasons nobody wrote down. For example, `expo_push_token` admits `null`
  because sign-up sends one (`lib/validators.ts:175`).
- **Lodestar**, the pilot, keeps several formats that older and newer builds
  must both read: the state file's `lift` chain (`Sources/LodestarCore/Version.swift:99-111`),
  the version-1 clipboard history that "an older build downgraded to still"
  writes (`ClipboardV1.swift:4-22`), and `Rollup.swift:949-971`'s probe, which
  leaves a newer schema's file exactly as it is. Each is tested by hand, as a
  release reaches it.
- **Stoic itself**, design/06's time capsule: golden documents, one per readable
  _schema_ version, decoded under today's schema (`PrefsCapsule` in
  `Tests/StoicSchemaTests/VersionedFixtures.swift`). design/27 proved the
  outbox's flag against "0.5.0's decoder kept verbatim in the test". This
  contract makes the capsule a library feature, and it keys it by _release_.
  The promise is to the builds that people run, not to the version numbers the
  schema declares.
- **Consumer-driven contract tests** (Pact; from prior knowledge): the reader
  keeps what the writer sends as recorded examples and checks them on every
  change. Here the recorded examples are the writer's real bytes, kept per
  release.
- **Snapshot testing's record mode** (from prior knowledge): an environment
  variable records instead of comparing, and a recording run fails, so it is
  never mistaken for a pass.

## API

```swift
// MARK: StoicSchema (pure: no files, no test framework)

/// A release of the app: one to four dot-separated numbers and an optional
/// pre-release, ordered as semantic versions are ("2.10.0" after "2.9.1";
/// "2.4.0-beta.1" before "2.4.0"; a missing number is 0).
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public init?(_ text: String)
}

/// One payload a release wrote, as bytes.
public struct CompatibilityFixture: Sendable, Hashable {
    public init(release: ReleaseVersion, name: String, bytes: [UInt8])
    public let release: ReleaseVersion
    public let name: String               // the file's name without `.json`
    public let bytes: [UInt8]
}

/// Every fixture of one format, and each release's reader where it was kept.
public struct CompatibilitySet: Sendable {
    public init(format: String, fixtures: [CompatibilityFixture], readers: [ReleaseVersion: JSONValue] = [:],
                problems: [CompatibilityFinding] = [])
    public let format: String
    public let fixtures: [CompatibilityFixture]
    public let readers: [ReleaseVersion: JSONValue]  // each release's `_schema.json`
    public let problems: [CompatibilityFinding]      // what was wrong with the files as they were found
    public var releases: [ReleaseVersion] { get }    // ascending
}

/// What to check a schema against a set with.
public struct CompatibilityCheck<Value: Sendable>: Sendable {
    public init(_ schema: Schema<Value>, options: DecodeOptions = .strict)
    /// How the real reader reads a payload's bytes, when it is more than `schema` and `options`
    /// (a settings file's header). Default: `schema.decodeReporting(bytes, options: options)`.
    public var reading: (@Sendable ([UInt8]) -> Decoded<Value>)? = nil
    public var samples: [(name: String, value: Value)] = []        // today's values, for the older readers
    public var generated: Int = 50                                  // and today's generated documents
    public var olderReadersMayRefuse: [ReleaseVersion: String] = [:]   // a break, declared, with why
    public var oldestSupported: ReleaseVersion? = nil                  // the floor: below it, retired
    public var verify: (@Sendable (CompatibilityFixture, Value) -> [String])? = nil   // what a value must mean
    public func report(_ set: CompatibilitySet) -> CompatibilityReport
}

public struct CompatibilityReport: Sendable, CustomStringConvertible {
    public let format: String
    public let findings: [CompatibilityFinding]    // by release, then sample, then reading order
    public let read: Int                           // released payloads read by today's schema
    public let offered: Int                        // today's documents offered to older readers
    public var passed: Bool { get }                // no finding is a failure
    public var failures: [CompatibilityFinding] { get }
    public var warnings: [CompatibilityFinding] { get }
}
public struct CompatibilityFinding: Sendable, Hashable, CustomStringConvertible {
    public enum Direction: Sendable, Hashable {
        case olderWriter      // a release's payload, read by today's schema
        case olderReader      // today's document, read by a release's schema
        case fixtures         // the fixtures themselves (a misnamed folder, an empty release, a stale break, a retired release)
    }
    public enum Severity: Sendable, Hashable { case failure, warning }
    public let direction: Direction
    public let severity: Severity
    public let release: ReleaseVersion?
    public let sample: String?
    public let path: JSONPath?        // nil: the whole document
    public let code: String           // an issue code (`unknown_key`, `missing_key`, `version_too_new`, …), a JSON Schema keyword, or the fixtures' own (`stale_break`, …)
    public let message: String
    public let location: String?      // `line:column` in the payload's text, when the issue knows
}

// The validator's additions: where, and which keyword, beside `accepts`; and
// what it covers, which is exactly what `jsonSchema()` writes.
extension JSONSchemaValidator {
    public func violations(_ instance: JSONValue) -> [JSONSchemaViolation]
    public static let coveredKeywords: Set<String>
    public var uncoveredKeywords: [String] { get }   // the root's keywords it does not evaluate, sorted
}
public struct JSONSchemaViolation: Sendable, Hashable, CustomStringConvertible {
    public let path: JSONPath
    public let keyword: String        // "additionalProperties", "required", "const", "type", …
    public let message: String
    public let readsBestEffort: Bool  // a newer version, met by a reader that preserves unknown keys
}

// MARK: StoicSchemaTesting

/// Reads `<directory>/<format>/<release>/*.json` beside the calling test file, checks
/// `schema` against it, and records each failure as a Swift Testing issue at the caller's
/// line. With `STOIC_RECORD_COMPATIBILITY=<release>` set, records that release instead.
@discardableResult
public func expectCompatibility<Value: Sendable>(
    _ schema: Schema<Value>,
    format: String,
    samples: KeyValuePairs<String, Value> = [:],
    options: DecodeOptions = .strict,
    reading: (@Sendable ([UInt8]) -> Decoded<Value>)? = nil,
    reader: JSONValue? = nil,                       // what a recording writes as `_schema.json`, when not `schema.jsonSchema()`
    olderReadersMayRefuse: [String: String] = [:],
    oldestSupported: String? = nil,
    verify: (@Sendable (CompatibilityFixture, Value) -> [String])? = nil,
    warningsFail: Bool = false,
    directory: String = "Compatibility",
    filePath: String = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
) -> CompatibilityReport

/// The files, for a tool that is not a test.
public func loadCompatibilitySet(format: String, from directory: String) throws(CompatibilityLoadError) -> CompatibilitySet
public struct CompatibilityLoadError: Error, Sendable, Hashable, CustomStringConvertible { … }

// MARK: StoicSettings: the one addition

extension SettingsStore {
    /// The store's read of a file's bytes, with no file: its decode options for `format`,
    /// its header keys set aside, its repairs. What `open` would make of these bytes.
    public static func read(_ bytes: [UInt8], schema: Schema<Value>, format: Format = .appOwned,
                            options: Options = Options()) -> Decoded<Value>
}
```

## Semantics

### A format, and who keeps it

A **format** is anything that one build writes and another reads: a request or
response body, a settings file, a stored record, an outbox entry, a webhook. It
has a name (`report-request`, `settings`, `lifecycle.<L.name>`), and its
fixtures live in the **reader's** tests, because the reader is the party that
must keep the promise. When the writer and the reader are the same package (a
settings file, a device's records, a module shared by a Swift app and its Swift
server), one test records and checks. When they are not, the writer's release
produces the folder, and it is copied into the reader's tests. It is plain
files, so a copy is enough.

### The fixtures

- **One folder per format, one per release, one file per payload.** A payload
  file holds the bytes the release wrote, exactly. It is not re-encoded and not
  wrapped in an envelope. Repeated keys, number spellings and key order are
  part of what a reader meets, and design/06 decodes wire data from its bytes for
  that reason.
- **`_schema.json`** in a release's folder is that release's reader, as its
  schema exported it (`jsonSchema()`). The default export closes exactly the
  objects that refuse unknown keys (design/06), which is what the reader did.
  Names beginning with `_` are reserved. Every other `*.json` is a payload.
- **Release folders are named by version** (`ReleaseVersion`), and a folder name
  that does not parse is a finding. A release folder with no payload is a
  finding too, because a promise was recorded with nothing in it.
- **Captured payloads** (taken from traffic or support cases and scrubbed of
  personal data by hand) are dropped into a release's folder under any name.
  They are read like recorded ones. They are often the best fixtures, because
  they are what an old build really sent, quirks and all.
- **Retiring a release** is a declared floor: `oldestSupported: "2.0.0"` names
  the oldest release still promised, in a reviewed change, on the day the app
  stops supporting older ones (a forced update, an end of life). Releases below
  it are not checked, and each is reported as retired (a warning), never
  silently ignored. Their folders may stay, as the record of what was once
  promised. A break declared for a retired release is a stale entry, and a
  failure.

### Recording at release time

With `STOIC_RECORD_COMPATIBILITY=<release>` in the environment,
`expectCompatibility` records instead of checking:

1. Each sample is encoded by `schema` and written as `<release>/<name>.json`, in
   canonical pretty text (design/06's stable bytes), so a re-recording of the
   same values is byte-identical.
2. `schema.jsonSchema()` (or `reader:`, for a reader that admits more than the
   schema, such as a settings file's header) is written as
   `<release>/_schema.json`.
3. If the folder already exists, nothing is overwritten. Files with the same
   bytes are left as they are and pass. Files whose bytes differ are refused with
   a finding: "release 2.4.0 is already recorded; a released promise is not
   rewritten". A release that never shipped is deleted by hand and recorded
   again.
4. A run that wrote anything records an issue ("recorded … commit them"), so a
   recording run always fails, and is never mistaken for a pass. CI never sets
   the variable.

Recording writes today's samples. It is run from the release's own commit,
before anything newer is merged, so the samples are what that release writes.
The release checklist gains one step, and Stoic's own gets the same step (Stoic's
own formats, below).

### Reading what older releases wrote

For each release, in ascending order, and each payload in it:

- The payload's bytes are decoded by today's schema, with the `options` the real
  reader uses: `.strict` for a wire body, and the store's options for a settings
  file. A test that checks with stricter or looser options than production
  proves the wrong thing.
- **Every error is a failure**, reported with the release, the sample, the
  issue's path, its code and its message, in reading order.
- **Every warning is a warning finding.** That includes an unknown key that a
  `.warn` object ignored, and a value a hand-edited file clamped. The exception
  is `migrated`: an old payload is expected to need migration, so that is not a
  finding. `warningsFail: true` makes warnings fail.
- **`verify`** is called with each decoded value, and each string it returns is a
  failure. This is where a change of _meaning_ is caught, since decoding cannot
  see one. An old sparse file that left `scrollSpeed` out meant 600, and a
  release that changed the default must still read it as 600. A schema already
  guards that with `pinDefault` (design/06), and `verify` proves the guard is
  there.

### What today writes, read by older releases

For each release that has `_schema.json` (one without it gets a warning, and
the direction is skipped for it):

- **Today's documents** are each sample encoded by today's schema, plus
  `generated` documents (50) from today's schema's generator. The generator is
  seeded from the format's name, so the documents are the same on every run, and
  it reaches optional fields and union cases that the samples miss.
- Each document goes through `JSONSchemaValidator(release's schema).violations`.
  Each violation is a failure, reported with the release, the sample (or
  `generated-n`), the path and the keyword.
- **A version bump** makes every older reader refuse today's documents, through
  the `const` on its version key. That is true: an older build cannot read a
  newer version. Such a break is **declared**:
  `olderReadersMayRefuse: ["2.2.0": "settings version 5 is read from 2.3 on"]`.
  A declared release is still checked. Its violations are not failures, and if
  it now accepts every document, the entry is stale, which is a failure
  (`stale_break`), so the list stays true.
- **An older reader that preserves unknown keys** reads a newer version
  best-effort, with `version_too_new` as a warning (design/06). Its export marks
  such objects `x-stoic-preserves-unknown`, and on those objects a `const`
  violation on the version key is a warning, not a failure.
- **The validator covers exactly what `StoicSchema` exports.** It evaluates
  every keyword `jsonSchema()` writes, in either draft, and no other: it is not
  a general JSON Schema validator. A reader that holds a keyword it does not
  evaluate (one written by another tool, say) is reported with a `not_covered`
  warning that names the keywords, so a check never looks wider than it was.
- **What a JSON Schema cannot state is not checked.** That covers the rules
  `SchemaSuite` skips by name (grapheme and byte lengths, a `Double`'s precision),
  a custom transform, and a `Schema.codable` leaf, which exports `{}`. An older
  reader's refusal of any of these is not caught. The report does not pretend it
  is: a reader that is `{}` gets a `not_covered` warning. This
  direction is a proxy. Running the old build's own decoder would be the real
  test (Not built).

### `Codable` types, lifecycle records, settings, XPC

- **A `Codable` type** is checked through `Schema.codable(T.self, examples:)`
  (design/06), which has the price that leaf states. The forward direction
  decodes each payload with `JSONDecoder` and reports one failure per payload,
  whose message holds the decoder's reason and coding path, and whose `path` is
  nil. The reverse direction checks nothing, because the leaf exports `{}`. To
  get the reverse direction, give the type a schema.
- **Lifecycle records** (design/27) are `Codable`, in a fixed format.
  `expectCompatibility(.codable(LifecycleRecord<L>.self), format:
"lifecycle.<L.name>")` keeps records, and `.codable(LifecycleEntry<L>.self)`
  with `lifecycle.<L.name>.entry` keeps history entries. The record's
  `lifecycle` key is checked on decode, so a fixture of another lifecycle fails.
  An older build meeting a newer record is design/27's undecodable path (the
  bytes are kept, never overwritten), and these fixtures do not test it.
- **Settings** (design/18) are read as the store reads them: its lenient
  options, its header keys set aside, its repairs. The store's options are
  private today, and a file's header keys are not the schema's, so the schema
  alone cannot read a file the way the store does. `StoicSettings` therefore
  gains one pure function, `SettingsStore.read(_:schema:format:options:)`. It is
  the decoding half of `open`, and the check is given it as `reading:`. A
  check whose options differ from the real reader's proves the wrong thing. The
  recorded `_schema.json` declares the header's keys, as the store's own export
  does (`extraRootProperties`).
- **XPC method payloads** need no fixtures between an app and its bundled
  service. The handshake refuses another build (design/25), so no payload ever
  crosses builds. A service that is not bundled (a launch agent, a Mach service)
  would make its payloads a format (Not built). And XPC's real encoding is XPC's
  own `Codable` encoder, not JSON, so JSON fixtures would not test it anyway.

### Stoic's own formats

From 0.8.0, Stoic keeps fixtures for the formats it promises, each recorded by
the release that wrote it, with that release's own code, beside the tests of
the module that reads it:

- `Tests/StoicSettingsTests/Compatibility/`: a hand-edited settings file with a
  header (`settings.hand-edited`, with its reader, which declares the header),
  and an app-owned one in its envelope (`settings.app-owned`, as `.bin`).
- `Tests/StoicStoreTests/Compatibility/`: a lifecycle record and its entries
  (`lifecycle.lodestar.release`, `lifecycle.lodestar.release.entry`,
  design/27's fixed format), a lifecycle store's journal and effects as the
  store left them (`lifecycle.journal`, `.bin`), and an outbox's log and
  snapshot (`outbox.journal`, `.bin`).
- `Tests/StoicTimeTests/Compatibility/`: `Moment`, `PlainDate`,
  `ZonedDateTime` and `Period` text (design/26).
- `Tests/StoicAppleTests/Compatibility/`: an App Attest key record in every
  phase (`app-attest.record`, design/29).

The definitions they were written from (a settings value, a lifecycle, a
message, and the scenario that drove the lifecycle store) are kept in each
target's `CompatibilityFormats.swift`. They are part of the fixtures: they
change only with them, never to make a reading pass.

The JSON formats with a schema are checked with `expectCompatibility`. The
rest are read by the module's own reader, through `CompatibilityCheck` where
the format is a JSON document, and each must also be *written* as it was. A
`Codable` record, entry or key record must re-encode as the very document it
was read from. A writer that is deterministic (the lifecycle store, an
app-owned settings file) must write the very bytes the release wrote, from the
same values and, for the store, the same scenario. That is the reverse
direction for a format with no reader to offer documents to: what today
writes is what the release wrote, so the release reads it.

`IdempotencyKey`'s text is held by the lifecycle and outbox fixtures, where it
is written. `Presented` (design/31) is new in 0.8.0, and is recorded from 0.8.0
on.

**At each release**, the release's fixtures are recorded from its own commit:
`STOIC_RECORD_COMPATIBILITY=<release> swift test --filter Compatibility` for
the formats `expectCompatibility` records, and the rest by running the
recording the release before it used (a test that writes each format with the
values in `CompatibilityFormats.swift`), at the tag, into the same folders.

### Relation to design/06

The time capsule becomes this. Its golden documents become files, and it is
keyed by release instead of by schema version. `PrefsCapsule` moves to
fixtures, as Stoic's own first user. The migration chain check stays beside it:
it proves the documents that _could_ exist, and this proves the ones that
_did_.

### Where it lives

- **`StoicSchema`**: `ReleaseVersion`, the fixture and set values, `CompatibilityCheck`,
  the report, and `JSONSchemaValidator.violations`. Like `SchemaSuite`, these are
  pure and assert nothing, so a build tool can use them without a test framework.
- **`StoicSchemaTesting`**: `expectCompatibility`, the loader, and record mode. It
  now reads files and the environment through Foundation (`FileManager`,
  `ProcessInfo`), as `StoicSchema`'s Foundation folder already does. Its
  dependencies are `StoicSchema` and `StoicJSON`: the JSON values it records
  and reads are `StoicJSON`'s.
- **`StoicSettings`**: `SettingsStore.read(_:schema:format:options:)`, over
  `StoicStore`'s envelope, which the store reads through a package-level
  `EnvelopedFile` (an envelope's check, and its payload or the reason it is not
  intact).

### Cancellation, isolation, defaults

Nothing here waits or runs concurrently: the checks are pure functions over
bytes, and the loader reads files synchronously, in a test. Defaults:
`.strict` options (a wire body), 50 generated documents, warnings that do not
fail, and the directory `Compatibility` beside the test file.

## Failure modes

| What happens if…                                                                      | Then                                                                                                    |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| a released payload no longer decodes                                                  | a failure: release, sample, path, issue code and message, written by that release and read today        |
| a field that a release still sends is removed, in an object that refuses unknown keys | a failure at that path, `unknown_key`                                                                   |
| a field that a release still sends is removed, in an object that ignores unknown keys | a warning at that path: it still reads                                                                  |
| a field that a release leaves out is made required                                    | a failure, `missing_key`                                                                                |
| a field's type is narrowed                                                            | a failure, `type_mismatch` or the constraint's code                                                     |
| a released payload needs a migration                                                  | it is read; `migrated` is not a finding                                                                 |
| a released payload reads with a warning                                               | a warning finding; a failure under `warningsFail`                                                       |
| a released payload reads, but means something else today                              | only `verify` catches it; each string it returns is a failure                                           |
| a payload file is not JSON                                                            | a failure for the whole document, with the parse issue's line and column                                |
| a `Codable` type no longer decodes a payload                                          | one failure for the payload; the message holds the decoder's coding path                                |
| today's document has a key an older reader refuses                                    | a failure for that release: today's sample, the path, `additionalProperties`                            |
| today's document leaves out a key an older reader requires                            | a failure, `required`                                                                                   |
| the version key is raised                                                             | every older release refuses (`const`), each a failure, unless it is declared in `olderReadersMayRefuse` |
| an older reader that preserves unknown keys meets a newer version                     | a warning, not a failure                                                                                |
| a declared break's release now accepts every document                                 | a failure, `stale_break`: remove the entry                                                              |
| a release folder has no `_schema.json`                                                | the older-reader direction is skipped for it, with a warning                                            |
| a release folder's name is not a version                                              | a failure                                                                                               |
| a release folder has no payload                                                       | a failure                                                                                               |
| a format has no folder at all                                                         | a failure: no release has been recorded                                                                 |
| an older reader's rule cannot be stated in JSON Schema                                | it is not checked, and a `not_covered` warning says so: for a `{}` reader, or a keyword not evaluated    |
| recording a release not yet recorded                                                  | its samples and schema are written; an issue says to commit them; the run fails                         |
| recording a release already recorded, with the same bytes                             | nothing is written; it passes                                                                           |
| recording a release already recorded, with other bytes                                | nothing is written; a failure: a released promise is not rewritten                                      |
| a payload is added to a release by hand                                               | it is read like a recorded one                                                                          |
| a release is older than the oldest supported release                                  | it is not checked; a warning, `retired`, names it; a break declared for it is a failure, `stale_break`  |

## Events

None. Compatibility is checked in tests, and a report is its output.

## Testing

- **Every row above**, in `StoicSchemaTests` against `CompatibilitySet`s built in
  memory, and against folders in a temporary directory, including record mode
  (written, identical, refused) and its issue.
- **`ReleaseVersion`'s order** as properties: a total order; semantic
  versioning's precedence over numbers and pre-releases; "2.10" after "2.9".
- **The messages** as golden text, one per kind of finding, so a changed message
  is a reviewed diff.
- **`SettingsStore.read`** agrees with `open`: for files of both formats (with a
  header, comments, a checksum, a migration and a clamped value), it gives the
  value and issues that `open` reports.
- **`violations`** agrees with `accepts` on every document each schema's
  generator makes and mutates, in every way the exporter writes: no violations
  exactly when the document is accepted.
- **The validator's coverage**: no document the exporter writes, for every kind
  of schema the tests hold and in every option, has a keyword it does not
  evaluate.
- **`PrefsCapsule`** moved to fixtures passes, and the same suite with one
  migration step deleted fails at the release and path that step served.
- **Stoic's own formats**: 0.7.0's, recorded at the tag with 0.7.0's own code,
  checked by 0.8.0, each test made to fail by a break in its format.

## Not built

- **Running an old build's decoder.** The reverse direction uses the release's
  exported JSON Schema as a proxy. Keeping each release's decoder as code, as
  design/27 did for one flag, is the real test, and too heavy to do for every
  format.
- **Binary and non-JSON formats** (property lists, the journal's framing) in this
  API. Stoic's own are fixtures (`.bin`) read by its own tests; the loader
  reads `.json` only.
- **Recording generated documents.** The older-writer direction reads only
  what was recorded or captured.
- **A check that every release tag has fixtures.** That needs the app's version,
  which a test does not know. It belongs to the release script.
- **A scrubbing tool** for captured payloads.
- **Non-bundled XPC services' payloads**, if Stoic ever hosts one.

## Decisions

The review settled the draft's open questions:

1. **Recording is triggered by `STOIC_RECORD_COMPATIBILITY`**, as drafted. A
   recording run always fails, so a variable set by accident cannot pass.
2. **Fixtures live beside the test file** (`#filePath`): no resource
   declaration, any test target (the target excludes the folder).
3. **Generated documents are not recorded** in this release.
4. **Retiring a release is a declared floor**, `oldestSupported`, not a deleted
   folder: retired releases are reported, never silently ignored.
5. **A declared break that is no longer needed is a failure**, as Stoic's
   baselines only shrink.
6. **The validator covers exactly what `StoicSchema` exports**, and says "not
   covered" for anything else.
7. **`SettingsStore.read` is added as drafted.**

## As built

Departures from the reviewed draft, and decisions it left open.

- **`CompatibilitySet` carries what was wrong with the files** (`problems`): a
  folder whose name is not a version, a `_schema.json` that does not parse.
  The loader reports them as findings rather than throwing; it throws only
  when the folder cannot be read at all (`CompatibilityLoadError`).
- **`expectCompatibility` takes `reader:`**, the reader a recording writes when
  it is more than `schema.jsonSchema()`: a settings file's reader declares the
  header's keys (`extraRootProperties`), as the draft's settings scenario
  needs.
- **The codes.** Besides issue codes and JSON Schema keywords, the fixtures'
  own: `no_release`, `retired`, `empty_release`, `no_reader`, `not_covered`,
  `stale_break`, `not_a_version`, `verify`, `parse_error` (a reader that does
  not parse), and `rewritten` (a recording refused). A `Codable` payload that
  does not decode is reported at `$`, the decoder's coding path in its message.
- **A break declared for a release with no reader** is stale too: with no
  reader, nothing can refuse.
- **A version key's `const`, on an object that preserves unknown keys**, is
  marked by the validator (`readsBestEffort`), so the check reports it as a
  warning without knowing the export's conventions.
- **`SettingsStore.read`** gives a torn or unchecked envelope as no value and an
  `invalid_format` issue, never defaults; a plain JSON file from before the
  store is read as `open` adopts it. `StoicStore` gains `EnvelopedFile`
  (package), so `read` and `open` share the envelope's check.
- **`PrefsCapsule` moved to fixtures**, in
  `Tests/StoicSchemaTests/Compatibility/prefs/`. The must-fail variant deletes
  the capsule's `move` step: deleting a rename is invisible to documents that
  spell the key the way the rename's target does.
- **Stoic's own fixtures are beside the readers' tests, not in one
  `StoicCompatibilityTests` target**: each format is read by its module's own
  reader, often internal (`@testable`), and some need their target's helpers
  (the time fixtures were written on `Zones.rules()`). The draft's list grew to
  the formats 0.7.0 writes that carry a promise, binary ones included
  (journals, an envelope), which the draft left where they were.
- **What the older-reader direction cannot see.** A key renamed in an object
  whose fields are all optional is accepted by an older reader, which then
  reads the renamed field as its default: a valid document that means
  something else. The older-writer direction and `verify` catch such a
  rename; the older-reader direction cannot, and says nothing.
- **0.7.0's fixtures were recorded in a worktree at the `0.7.0` tag**, with
  temporary recording tests in that worktree's targets, writing the same
  definitions now kept in `CompatibilityFormats.swift`.

# 06 · Validation and schema

Parse, don't validate. Data that crosses a trust boundary — a config file,
a network response, a document from disk, a deep link — enters the app
through one declaration per type, and that declaration is the single source
of truth for decoding, encoding, defaults, every error message, the JSON
Schema, test generators, UI metadata and migrations. Nothing else repeats
it, so nothing can drift from it.

## Origin

- **Alexis King, "Parse, don't validate."** A value that has been checked
  should have a type that says so; the check and the type are one thing.
- **Effect Schema, Zod, Pydantic.** One declaration drives decode, encode,
  validation, JSON Schema and arbitrary generators. Effect's `toArbitrary`
  makes property tests of any schema free.
- **What goes wrong in apps.** Ranges and defaults repeated in the parser,
  the clamp, the settings UI and the docs. Invalid input silently clamped
  instead of reported. `Codable` that stops at the first error and points at
  no line. Synthesised enum coding that is unusable on the wire. A changed
  default that silently flips the value of every user who had chosen the old
  one. Older app versions that destroy fields a newer version wrote.

## The rule that makes it credible

**Every constraint is data, never a closure.** A closure validator is
invisible to the JSON Schema exporter, the generator and the UI. Constraints
are values (`.range`, `.length`, `.pattern`, `.oneOf`, `.multipleOf`,
`.unique`, `.custom(id:)`), interpreted by the decoder and the exporter
alike, so the check and the documentation cannot disagree. Closures exist
only behind a labelled escape hatch (`.custom(id:description:check:)`), which
the exporter renders as an annotation and the generator treats as opaque.

## Layers

```text
Layer 0  StoicJSON          strict parser: duplicate keys, exact numbers, positions, limits   (shipped)
Layer 1  Refined<R>         parse-don't-validate leaf types; constraints as data
Layer 2  Schema<Value>      declaration + decoder + encoder; accumulating Issues with paths
Layer 3  Tooling            JSON Schema export · generators · SchemaSuite self-test · migrations
Layer 4  Sugar              @Schema / @Refined macros (separate product) · Codable bridge
```

The macro is last and purely sugar: it emits calls to the Layer 2 API. A
person without macros writes the same schema by hand, and it is just as
checked.

## Layer 1: refined types

```swift
public protocol Refinement: Sendable {
    associatedtype Base: Sendable
    static var constraints: [Constraint] { get }       // data: the only source of truth
}

public struct Refined<R: Refinement>: Sendable {
    public let value: R.Base
    public init(_ raw: R.Base) throws(ValidationFailure)  // the only public way in
    public init(clamping raw: R.Base) where R.Base: Comparable   // the explicit lossy path, for UI
}

// Integer generic parameters give zero-boilerplate integer ranges:
public enum IntRange<let lower: Int, let upper: Int>: Refinement { … }
public typealias Port = Refined<IntRange<1, 65_535>>
```

`Refined` checks by interpreting `constraints`, so the check that admits a
value and the JSON Schema that documents it are the same data.

## Layer 2: the schema value

```swift
public struct Schema<Value: Sendable>: Sendable {
    public var node: SchemaNode                         // inspectable description
    public func decode(_ value: JSONValue, options: DecodeOptions = .strict) -> Decoded<Value>
    public func decode(_ bytes: some Collection<UInt8>, options: DecodeOptions = .strict) throws(ValidationFailure) -> Value
    public func encode(_ value: Value, style: EncodeStyle = .full) -> JSONValue
    public func jsonSchema() -> JSONValue                // Draft 2020-12
}

public struct Decoded<Value> { public var value: Value?; public var issues: [Issue] }

public struct Issue: Sendable, Hashable {
    public enum Severity { case error, repaired, warning }
    public var severity: Severity
    public var path: JSONPath                // "$.network.hosts[3]"
    public var code: IssueCode               // stable, extensible: "out_of_range", "unknown_key", …
    public var message: String               // derived from code and parameters
    public var expected: String?
    public var actual: String?               // never filled for secret fields
    public var suggestion: String?           // did-you-mean
    public var source: SourceRange?          // when decoded from text
}

public struct ValidationFailure: Error { public var issues: [Issue] }
```

**Accumulation.** Decoding never stops at the first problem. Every field is
decoded independently; every issue is collected with its path and, when the
input was text, its line and column. A value is produced only when no issue
is an error (or, under `.lenient`, after repairs).

**Decode options.**

- `.strict` — any error fails. For wire formats.
- `.lenient` — an invalid field falls back to its default and records a
  `repaired` issue; for hand-edited configuration, where the app must still
  launch and tell the user exactly what it ignored.
- `unknownKeys: .reject | .warn | .ignore` per object, with did-you-mean.

**Did-you-mean.** Candidates are declared keys plus aliases. Case and
snake/camel differences are an exact alias match (`scroll_speed` →
`scrollSpeed`, reported as a deprecated spelling, not an unknown key).
Otherwise Damerau–Levenshtein with threshold `min(2, length/3)`, at most
three suggestions, deterministic order. The same machinery serves enum
values and union tags. Type confusion gets its own hint: `"10"` where a
number is expected says "did you mean `10`?".

**Objects, two ways.**

(a) Config-like types with an `init()`: the default instance is the single
source of every default, and of sparse encoding.

```swift
extension Settings {
    static let schema = Schema.object(Settings.self, default: Settings()) {
        Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)), doc: "Pixels per second.", unit: "px/s")
        Field("theme", \.theme, .enumeration(Theme.self))
        Field("hosts", \.hosts, .array(.string(.length(1...253)), count: 0...8), aliases: ["scroll_hosts"])
        Field("apiToken", \.apiToken, .string(), secret: true)
    }
}
```

(b) Types without defaults, built from decoded fields once all of them
decoded: a builder that gathers every field's issues before calling the
initialiser.

**Encoding.** `.full` writes every field; `.sparse` omits fields equal to
their default — the shape of a hand-edited config file. Canonical byte
output is StoicJSON's canonical encoding.

**Secrets.** A secret field never appears in `actual`, in `description`,
or in sparse output unless asked for.

**Numbers.** A JSON integer above 2^53 aimed at a `Double` field is an
issue (`precision_loss`), not a silent rounding. `1.0` for an `Int` field is
accepted only under `.lenient`. NaN and infinities do not exist in JSON and
cannot be produced.

## Layer 3: tooling

- **JSON Schema export**, Draft 2020-12: ranges, lengths, patterns, enums,
  defaults, `description` from `doc`, `additionalProperties: false` for
  rejecting objects, `x-stoic-unit` and `x-stoic-secret` metadata. What
  cannot be expressed (cross-field constraints, `.custom`) is exported as an
  `x-stoic-constraint` annotation and listed in the export's summary.
- **Generators.** Every schema derives valid values biased to boundaries
  (lower, lower+1, upper−1, upper, empty and full collections, astral and
  combining Unicode) and _invalid documents_ — a valid one with one minimal
  violation and the expected `(path, code)` recorded.
- **SchemaSuite.** A one-line self-test per schema: round trip, sparse
  fixed point, every generated mutation yields exactly the expected issue at
  the expected path, every typo'd key yields the right suggestion, and the
  JSON Schema export agrees with `decode` on every generated document.
- **Migrations** operate on `JSONValue`, as a closed set of declarative
  operations (`rename`, `move`, `delete`, `setIfAbsent`, `mapEnum`,
  `pinDefault`, `custom(id:)`). Defaults are versioned: when a release
  changes a default, a document from the older version that omitted the
  field gets the _old_ default written in explicitly by the migration, so
  nobody's chosen value flips silently. A golden document from every
  released version is kept and must still migrate to the latest.
  Documents newer than the app are read-only unless the schema preserves
  unknown fields.

## Layer 4: sugar

`@Schema` on a struct with defaults emits form (a) from the stored
properties, their default values, attribute constraints (`@Range`,
`@Length`, `@Secret`, `@Key`) and doc comments; `@Refined` emits a named
refinement. The macros live in a separate `StoicMacros` product and only
call the public runtime. A `Codable` bridge lets a schema-backed type sit
inside `Codable` code: its `init(from:)` decodes the subtree through the
schema and throws one `DecodingError` listing every issue.

## Failure modes

| What happens if…                             | Behaviour                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------------- |
| three fields are invalid                     | Three issues, each with its path (and line/column from text); no value    |
| a key is misspelt                            | `unknown_key` with "did you mean"; rejected, warned or ignored per policy |
| a key uses the snake_case spelling           | Accepted as an alias; `deprecated_key` warning                            |
| a number is out of range under `.strict`     | `out_of_range` error with the bounds                                      |
| the same under `.lenient`                    | Default used; `repaired` issue saying so                                  |
| an integer exceeds 2^53 for a `Double` field | `precision_loss` error                                                    |
| a secret field is invalid                    | Issue without `actual`                                                    |
| the input has duplicate keys                 | Rejected by StoicJSON with both locations                                 |
| a default changed between releases           | Old documents keep the value they had, via a `pinDefault` migration       |

## Testing

SchemaSuite runs on every schema in the test target. The decoder's
accumulation is checked by the mutation generator: N independent mutations
must produce exactly N issues at exactly their paths. The exporter is
checked differentially against a small JSON Schema validator in the test
target. Encoding is checked for round trips and sparse fixed points over
generated values.

## As built: phase 1 (StoicSchema)

Layers 1 and 2 and the JSON Schema exporter of Layer 3 are implemented in
`StoicSchema`, which depends on `StoicJSON` alone. The decisions the sketches
above left open:

- **Constraints are a struct over a `Kind` enum**, so `Constraint.range(…)`
  reads as in the examples while exporters switch over `constraint.kind`.
  Bounds are `JSONNumber`s and are compared as exact decimals (up to 38
  digits), so `2^53 + 1` is above `2^53` and `0.3` is a multiple of `0.1`.
  A constraint is silent about kinds of value it is not about, as JSON
  Schema's keywords are.
- **String length has a unit.** `.characters` is Unicode scalars, the only
  unit JSON Schema counts; `.graphemes` and `.utf8Bytes` export as
  `x-stoic-length`. A pattern is skipped when a length constraint on the
  same value already failed.
- **Patterns are stored as source** and compiled with `Regex` per decode
  (`Regex` is not `Sendable`), with scalar matching semantics.
- **`Refinement` also names `baseSchema`** (automatic for any `Schematic`
  base), because checking a value means interpreting the constraints on its
  JSON form. `init(clamping:)` exists for integer and `Double` bases and
  clamps range constraints only.
- **`Optional` has three states.** Absent means the field's default (or
  `nil` where there is no default); `null` is a value only for
  `nullable: true`; otherwise `nil` is written by omitting the key.
- **Object form (b) reads fields into `Slot`s** and builds through a `Values`
  token, so every field's issues exist before the initialiser runs; see the
  note in `Schema+ReadObject.swift`. Form (a) defaults to `unknownKeys:
  .warn`, form (b) to `.reject`.
- **Respelled keys** (case and snake_case, plus declared aliases) are
  accepted with a `deprecated_key` warning; the same field under two
  spellings is `duplicate_key`.
- **Encoding.** `EncodeStyle.sparse` leaves out secrets unless asked; `.full`
  includes them. Sparse compares encoded JSON, not values. Deprecated
  fields are written only when they differ from their default.
- **Export.** `jsonSchema()` and `jsonSchemaExport()` (which also lists the
  rules that were only annotated). Recursive schemas use `$defs`/`$ref`;
  named non-recursive types are inlined.

## As built: phase 2 (StoicSchema)

Phase 2 completes Layer 3 and the bridge of Layer 4. What was decided, in
the order it was built:

### Custom schemas

- **`Schema.transform(base:decode:encode:describe:name:examples:)`** reads
  the base schema first and then converts, so the base's constraints hold
  (and all its issues are reported) before the closure runs. The closure
  throws a `TransformFailure` (message, code, expectation, suggestions),
  which becomes one `invalid_value` issue at the value's path. `encode` is
  total.
- **The tree describes it** as `SchemaNode.transformed(TransformNode)`: the
  base node, the Swift type's name, a description and `examples`. The export
  is the base's keywords plus `x-stoic-transform {name, description}`. The
  rule "constraints are data" survives in the only way it can for code:
  put everything the base can say _in_ the base.
- **Examples exist for the generators.** A generator cannot look inside a
  closure, so a transform declares encoded values it is known to accept;
  without them the generator tries base values and the suite says so.
- **`Schema.custom(describing:description:decode:encode:)`** is the escape
  hatch for shapes no composition describes. Its decoder reports through a
  `DecodingContext`, which knows the path (`context.report(…, at: ["low"])`
  records `$.range.low`, with line and column when the input was text) and
  decodes sub-values with other schemas (`context.decode(_, as:, at:)`).
  A decoder that returns `nil` without reporting still fails with
  `invalid_value`; one that returns a value after reporting an error fails.
- **`Schema.enumeration(_:)` also takes `Int` raw values**
  (`SchemaNode.integerEnumeration`, with the Swift case names kept for
  documentation): `type: integer`, `enum: [...]`, `x-stoic-enum-names`.

### Tagged unions

- **`Schema.union(discriminator:) { Case(…) … }`** declares an enumeration
  with payloads. Each `Case` names its tag, its payload schema, how to build
  the enumeration from a payload (the case's own name, which is a function)
  and how to take a payload back out (a closure returning `nil` for every
  other case). Swift has no case paths, so each case says it twice; a macro
  will write the pair. A case without a payload is
  `Case("point", Shape.point) { if case .point = $0 { true } else { false } }`.
- **Flat or keyed.** An object payload is written flat, beside the
  discriminator (`{"type": "circle", "radius": 5}`), which is how wire
  formats look and what `oneOf` + `const` validates. Any other payload is
  written under a value key (`{"type": "label", "value": "Hello"}`). A
  `lazy` payload counts as not an object, since looking inside would
  recurse while the schema is built.
- **Decoding** reads the discriminator first, because until it is known
  nothing else can be: not an object is `type_mismatch`; absent is
  `missing_key` at `$.type`; a non-string is `type_mismatch` there; an
  unknown tag is `not_one_of` there with the tags listed and the nearest
  suggested. The payload then decodes as any schema does, accumulating, and
  sees the object without its discriminator, so a payload that rejects
  unknown keys does not reject `type`.
- **Export** is `oneOf` with one branch per case, each pinning the
  discriminator with `const` and requiring it, plus `x-stoic-discriminator`.
- **Declaration errors trap**: a tag twice, a flat payload that declares the
  discriminator itself, a value key equal to the discriminator. A value that
  is none of the declared cases is found by `validate(_:)`.

### Versions and migrations

- **Declared on the object**, in both forms: `version: 4, migrations: […]`
  (plus `versionKey:`, default `"version"`, and `missingVersion:`). The
  version lives in a reserved key that is not a field (declaring a field
  with that key traps), is removed before the fields see it, and is written
  first on every encode, sparse included. The node records it as
  `ObjectNode.versioning`.
- **Migrations are `Migration.from(1, to: 2, ops…)`** over `JSONValue`, with
  a closed set of operations as data: `rename`, `move`, `delete`,
  `setIfAbsent`, `mapEnum`, `pinDefault` and `custom(id:)`. Paths are
  dot-separated keys; a path that is not in the document is skipped; a
  rename or move onto a taken key is a `migration_failed` error, never an
  overwrite. `pinDefault` does what `setIfAbsent` does and says why: it
  writes the old default into a document that omitted the field, so that a
  release changing a default cannot flip what an old sparse file meant.
- **Decoding** reads the version, applies the steps from it to the current
  version one at a time, and records a `migrated` warning per step
  (`from`, `to`, the operations in words) before validating the migrated
  object, so errors are at the new paths. A version that is not a positive
  integer is `type_mismatch`/`out_of_range`; one no step reads is
  `version_unsupported`; a step that cannot be applied is `migration_failed`.
  A document with no version key means the oldest version
  (`.oldest`, the default, for a format that gained its key late),
  the current one (`.current`, for hand-written files) or an error.
- **Positions are coarse after a migration.** A migrated object has been
  rewritten, so the text no longer shows what its issues are about: they
  point at the whole object, not at a line that may now mean something else.
  Documents that needed no migration keep exact positions.
- **Newer documents.** A version above the schema's is `version_too_new`, an
  error, unless the object preserves unknown keys: `unknownKeys: .preserve`
  with `preservingUnknownKeysIn: \Type.extra` (form a) or
  `f.unknownKeys(\.extra)` (form b) keeps every key the schema does not
  declare in a `JSONObject` property and writes it back. The document is then
  read best-effort with a `version_too_new` _warning_, the newer version
  number is kept with the unknown keys, and encoding writes it back rather
  than the schema's own: an old release never downgrades or truncates a
  newer one's file. (A preserved typo is not noticed; prefer `.warn` for a
  hand-edited file.)
- **Export** states the current version (`const`), makes the key required
  unless a missing key means current, and lists the history under
  `x-stoic-version`. The document describes the current format only: a
  validator rejects an old document that the decoder would migrate.
- **Time capsule.** The pattern, in the test target, is a table of golden
  documents, one per readable version, each with the value it meant, decoded
  under today's schema; a second test fails when the history grows without a
  capsule entry. See `PrefsCapsule` in `VersionedFixtures.swift`.

### Reading order

Issues decoded from text are returned, and printed by `ValidationFailure`,
sorted by position in the file (line, then column; stable, so issues at one
position keep the order they were found in). A schema declares fields in the
order that suits the type, and a report that jumps up and down the file is
one people stop reading. Issues without a position (a value that was never
text) keep the order found, which is declaration order within an object and
element order within an array; there is no better "path order" for them,
since sorting paths alphabetically would be worse than the declaration.
A missing key sorts with the object that lacks it.

## Non-goals

Formats other than JSON in the first version (property lists and YAML can
map onto `JSONValue` later); remote schema registries; validation that needs
I/O (it belongs in an async second stage that reports the same `Issue` type).

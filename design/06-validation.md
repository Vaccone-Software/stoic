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
`@Length`, `@Secret`, `@Key`) and doc comments; on an enumeration it emits
the enumeration or, when cases carry values, the tagged union with the two
closures per case; `@Refined` emits a named refinement. The macros live in a
separate `StoicMacros` product, behind the `Macros` trait, and only call the
public runtime (see "As built: Layer 4"). A `Codable` bridge lets a schema-backed type sit
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
| a date-time is not RFC 3339                  | `invalid_format` saying what is wrong (no month 13, no offset); no value  |
| a decimal is not a number                    | `invalid_format` saying why (a comma, a `+`, no digit before the point); more digits than a `Decimal` holds is `out_of_range`, never rounded |
| an enumeration with an unknown case meets a value it does not know | Read as that case; an `unknown_case` warning naming the value and the case, with the nearest known spelling; the document is still accepted |
| an element of a lossy array is invalid       | Dropped, with a `dropped_element` warning carrying its input index and the first reason; the rest are kept, and the element's own errors are not reported |
| a Codable leaf's value is refused by JSONDecoder | One `invalid_value` issue at the field, with the decoder's reason and the coding path inside it (no reason inside a secret); nothing below it is reported |
| a required field's key is missing            | `missing_key` naming the key, beside every other issue; no value (never a zero in its place) |

## Testing

SchemaSuite runs on every schema in the test target. The decoder's
accumulation is checked by the mutation generator: N independent mutations
must produce exactly N issues at exactly their paths. The exporter is
checked differentially against a small JSON Schema validator in the test
target. Encoding is checked for round trips and sparse fixed points over
generated values.

## As built: phase 1 (StoicSchema)

Layers 1 and 2 and the JSON Schema exporter of Layer 3 are implemented in
`StoicSchema`, which depends on `StoicJSON` (and, for Foundation's own types
only, on Foundation; see "As built: wire models"). The decisions the sketches
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
  other case). Swift has no case paths, so each case says it twice; the
  `@Schema` macro writes the pair. A case without a payload is
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

### The Codable bridge

- **Inbound.** `schema.decode(from: decoder)` reads whatever the decoder
  holds into a `JSONValue` (`JSONValue(reading:)`: a keyed container walked
  with a `DynamicKey: CodingKey`, else an unkeyed one, else a single value,
  tried in that order), runs the schema, and returns the value or throws
  **one** `DecodingError.dataCorrupted` whose description lists every issue
  with its full path from the document root (the decoder's coding path, then
  the schema's) and whose `underlyingError` is the `ValidationFailure`.
  Accumulation survives inside the subtree; the surrounding `Codable` code
  still stops at its first error, as it must.
- **Outbound.** `schema.encode(value, to: encoder)` writes the schema's JSON
  through the encoder (`JSONValue.write(to:)`): objects as keyed containers,
  arrays as unkeyed, integers as `Int64`/`UInt64`, other numbers as `Double`.
  A value the schema cannot write (NaN) is an `EncodingError`.
- **`SchemaCoded<T: Schematic>`** is the wrapper (`Codable`, `Equatable` and
  `Hashable` when `T` is) for a property, an element or a top-level value;
  `decodeSchema`/`decodeSchemaIfPresent`/`encodeSchema` on the containers
  serve hand-written `init(from:)`. `CodingUserInfoKey.schemaDecodeOptions`
  and `.schemaEncodeStyle` choose lenient decoding or sparse encoding through
  `userInfo`, without touching any conformance.
- **What `Decodable` costs.** A `Decoder` hides the source text: numbers
  arrive as `Int64`, `UInt64` or `Double` (so `1.0` is `1` and a negative
  zero is `0`, and a non-integer is as precise as a `Double`), object members
  arrive sorted by key, and `JSONDecoder` cannot tell `"é"` from `"e\u{301}"`
  in a key. There are no source ranges. The schema's own text entry points
  keep all of that; use them for files and the bridge for `Codable` graphs.
- **Not provided:** `Schema.codable(T.self)` (wrapping an existing `Codable`
  type as a leaf) and the `userInfo` collector that lets a generated
  `init(from:)` continue after a failed field (both are in the review's 3.9;
  neither is needed without macros).
- **Tested** against a minimal `Decoder`/`Encoder` over `JSONValue` written
  in the test target with no Foundation, and, in the one test file that
  imports Foundation, against `JSONDecoder`/`JSONEncoder` and
  `PropertyListDecoder`/`PropertyListEncoder`. A test also scans the sources
  of `StoicSchema` and `StoicJSON` for `import Foundation`.

### SchemaSuite

`try SchemaSuite(Settings.schema).run(seed: 1, cases: 500)` is the
one-line self-test. It generates valid documents and checks: round trip (as
JSON, canonical text and pretty text; `validate` agrees); sparse fixed point
(with and without secrets); that every minimal mutation yields exactly the
expected errors at exactly the expected paths and the expected warnings;
that two to four independent mutations yield exactly that many errors; that a
misspelt key or tag is answered with the spelling it came from; that the
exported JSON Schema and the decoder agree on the valid and the mutated
documents; that an empty document decodes to the declared defaults and the
defaults are valid; that every field has documentation (a warning); and the
migration chain.

- **It lives in `StoicSchema`, and asserts nothing.** `report(seed:cases:)`
  returns a `SchemaSuiteReport` (a tally per check, the first findings of each
  with the seed that reproduces them and a shrunk document); `run` throws
  `SchemaSuiteFailure` if any check failed. A throw fails a Swift Testing or
  XCTest test and prints every finding, and the library apps ship never links
  a test framework.
- **The Swift Testing glue is a separate tiny target, `StoicSchemaTesting`**
  (`expectSchemaSuite(_:seed:cases:)`, which records each finding as an issue
  at the caller's line, warnings as warnings). It is not in `StoicTesting`
  because that would make every user of virtual clocks link the schema layer.
- **The differential validator moved into the library** as
  `JSONSchemaValidator` (public, deliberately small, only the keywords the
  exporter writes), because the suite needs it. Rules a JSON Schema cannot
  state are skipped _by name_ in the agreement check: precision loss and
  overflow of a `Double`, and lengths counted in graphemes or bytes.
- **Failures are shrunk** where the property is about a value (round trip),
  so the report shows the smallest document that still fails.
- **A transform with no examples** makes the generator guess, so the suite
  says so (a warning) and skips samples the conversion refuses, counting them
  as `skipped`.

### The migration chain check

`schema.migrationChainCheck(cases:seed:)` returns a `MigrationChainReport`.
The old schemas are gone (that is the point of migrating JSON), so it does
not generate old documents from them. It generates valid _current_ documents,
runs the history **backwards** (the inverse of a rename is the rename back; of
a move, the move back; of `pinDefault` and `setIfAbsent`, a delete, so the old
document omits the field and the pin must supply it; of a `mapEnum`, the
reversed mapping if it is injective; of a `delete`, restoring its `example`;
of a `custom`, its `inverse`), and decodes the result with the full schema:
every old document must come out valid, with one `migrated` notice per step.
A step is _untested_, not passed, if something after it has no inverse, and a
`delete` with no example is reported as a gap. It also fails a step whose
rename or move writes a path no generated document of the next version has,
since such a step names a field the schema does not have and nothing in the
backwards documents would reveal it.

The check is the complement of the time capsule: the capsule proves the files
that exist; the chain proves the ones that could.

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

### Generators

- **`schema.generator`** is a `SchemaGenerator<Value>` derived from the node
  tree alone; it decodes what it makes, so a `Sample` (the document and the
  value) is accepted by definition, and a schema it cannot satisfy raises a
  `GenerationFailure` that says where, instead of returning a bad sample.
  Randomness is a seeded `SplitMix64` (public), drawn from the caller's own
  `RandomNumberGenerator` or from `sample(seed:)`.
- **Valid values are candidate-and-filter.** The generator proposes the edges
  (bounds, the values beside them, `lower+1`, `upper-1`, zero, negative zero,
  2^53, the smallest and largest `Double`, empty and full collections,
  strings of the shortest and longest length) mixed with uniform draws, and
  the real constraint interpreter keeps what satisfies every constraint.
  That is how `custom` and `multipleOf` and an unsupported pattern are met
  without the generator knowing them: the checker is the judge.
- **Strings are measured in the constraint's unit** (scalars, graphemes or
  UTF-8 bytes) from pieces whose costs in all three units are known: ASCII,
  accented letters, CJK, astral characters, combining sequences, a skin-tone
  modifier, a ZWJ family, a flag, and the ASCII a JSON writer must escape.
  Several units at once get plain text, the only text that counts the same
  in all. Patterns are sampled by a small regex sampler (literals, classes,
  groups, alternation, quantifiers; anything else declines) whose output is
  verified with `Regex`.
- **Documents come sparse, dense and mixed**, so defaults, omitted keys and
  explicit values all occur; versioned objects carry their current version.
  Recursion is bounded by depth _and_ a per-document node budget (without the
  budget a union with eight recursive terms makes millions of nodes); past
  either, collections are as small as allowed and options are left out.
- **Transforms are met by their `examples`.** A closure cannot be proposed
  against, so the generator draws from the encodings of the examples the
  schema declares; `transformsWithoutExamples` lists the ones that have none.
- **Shrinking is structural.** `shrink(_:)` proposes simpler documents,
  simplest first (numbers toward zero or the nearest bound, strings toward
  the minimum length, collections toward their minimum count, fields toward
  their defaults or absence) and keeps those the schema accepts;
  `minimize(_:whileFailing:)` greedily follows them to a local minimum.
- **Invalid documents.** `mutations(of:)` walks the document against the
  tree and lists every minimal violation with the issue it must cause
  (`ExpectedIssue`: path, code, severity, and for a misspelling the key or
  tag to suggest): below, above, wrong type, fractional, `null`, missing
  required key, unknown key, misspelt key, too long, too short, too many, too
  few, repeated element, not a multiple, pattern mismatch, bad enumeration
  case, bad union tag, misspelt tag, missing discriminator, lost precision,
  not finite, future version. Every candidate is run through the constraint
  interpreter first so that "exactly one issue" is a property of the
  mutation. `mutation(of:combining:)` applies several whose parts of the
  document do not overlap (a wrong container hides what is inside it, so a
  mutation's _location_ is its whole subtree where that is true, and a
  mutation in a `unique` array makes the array one unit).
- **Not generated:** duplicate keys (the JSON layer refuses them before a
  schema exists), a depth bomb (the parser's limit), and violations of
  `custom` constraints (opaque).

## As built: Layer 4 (StoicMacros)

`@Schema` and `@Refined` are implemented in the `StoicMacros` product, which
needs the `Macros` package trait. The rule of the layer is kept: **a macro
expansion is calls to the public StoicSchema API and nothing else.** There
is no runtime support type, no hidden protocol, no generated code a person
could not have written. The test target proves it by declaring types with the
macros, declaring the same schemas by hand, and requiring the two to be
indistinguishable (same node tree, same JSON Schema, same verdict, value and
issues on every generated and mutated document, same bytes from every
encoding style); `SchemaSuite` then runs on the macro's schemas.

### The product and the trait

- **`Macros` is a package trait**, arranged exactly as `Lint` is: the
  swift-syntax dependency stays declared, its products are conditioned on the
  trait, and the sources of `StoicMacrosPlugin` (the compiler plugin) compile
  to a stub without `STOIC_MACROS`. A consumer that does not enable the trait
  never fetches swift-syntax (checked with a scratch package and an empty
  SwiftPM cache: no checkout, no `Package.resolved`, nothing in the cache but
  manifests). `import StoicMacros` without the trait is an empty module, and
  `@Schema` is then an unknown attribute, which is the honest answer.
- **Three targets.** `StoicMacrosPlugin` (`.macro`, swift-syntax, host
  only), `StoicMacros` (the attribute declarations; depends on `StoicSchema`
  and the plugin) and two test targets: `StoicMacrosTests` (expansion text and
  diagnostics, with swift-syntax's generic macro test support recording into
  Swift Testing) and `StoicMacrosUsageTests` (behaviour).
- **The consumer imports `StoicSchema` and `StoicMacros`** and nothing else
  for the generated code. The expansion names the library through module
  selectors (`StoicSchema::Schema`, `StoicSchema::Field`), so a type of the
  consumer's own called `Schema` or `Field` cannot change what it means.
  `Secret<T>` fields name `Secret`, which the consumer's own property type
  already needs. A `public` type needs `public import StoicSchema`, as any
  public API built on it does; the macro does not re-export.
- **Names.** The attributes are named for what they say, and several are
  also the names of types (`Range` in the standard library, `Unit` in
  Foundation, `Secret` in Stoic, `Schema` and `Refined` in StoicSchema).
  Macros and types are looked up apart in attribute position, so
  `@Range(1...5) var r: Range<Int>` works in one file with Foundation
  imported; `NamingTests` is the proof.

### `@Schema` on a struct

```swift
/// Application settings.
@Schema
struct Settings {
    /// Pixels per second.
    @Range(200...4000) @Unit("px/s") var scrollSpeed: Double = 1200
    var theme: Theme = .system
    @Key("api_token") @Secret @Length(...128) var apiToken: String = ""
    @Length(1...253) @Count(0...8) @Unique var hosts: [String] = []
    var network = Network()
    @Aliases("legacy") @Deprecated("Use `theme`.") var legacyMode = false
    @Ignored var cache: [String: Int] = [:]
}
```

expands to `static let schema = Schema.object(Settings.self, default:
Settings(), doc: …) { Field(…) … }`, one `Field` per stored property in
declaration order, and `extension Settings: Schematic {}` (added only if the
type does not conform already), so `Settings.schema` is what other schemas
write when they hold a `Settings`.

- **Form (a) when every property has a default.** The default instance is
  `Settings()`, so a type that declares initialisers must declare `init()`.
  The macro does not read defaults to copy them (the instance is the single
  source of every default, which is the point of form (a)); it reads them to
  check them, below.
- **Form (b) when any property has none.** A stored property with no default
  is *required*: the key must be there, and a missing key is a `missing_key`
  issue beside the rest, not a zero. The macro then emits the reader form,
  `Schema.object(T.self) { f in … }`, one `f.field(…)` per property, and
  builds the value with the memberwise initialiser, `T(id: v[slot0], …)`.
  Properties that have defaults keep them: the default is copied, as
  written, into the field's `default:`, and the property is optional on the
  wire. A `T?` with nothing written is "none" whether its key is missing or
  `null` (the schema is `.optional(…, nullable: true)`, so `nil` is written
  as `null` in full output and left out of sparse output). Properties left
  out with `@Ignored` keep their default, so they need one; a `let` is
  allowed, since the initialiser fills it (a `let` with a value is not a
  parameter, so it is refused). The memberwise initialiser exists only while
  the type declares no initialiser, so form (b) needs the type to declare
  none (put initialisers in an extension). Unknown keys default to `.reject`
  as in the hand-written form (b); `@Schema(unknownKeys: .ignore)` is the
  usual choice for a model of someone else's API.
- **Types are read as written.** The macro sees syntax. `Bool`, `Int`,
  `Int64`, `UInt64`, `Double`, `String`, `JSONValue` and the other fixed-width
  integers (`.integer(Int32.self)`) are the library's primitives; `[T]` and
  `[String: T]` are `.array(of:)` and `.dictionary(of:)`; `T?` is
  `.optional` (`@Nullable` adds `nullable: true`); `Secret<T>` is a
  `.transform` over `T`'s schema that reads and reveals, and makes the field
  secret; any other name, including a typealias such as `Port` and a generic
  such as `Refined<IntRange<1, 9>>`, is `Name.schema`, and the compiler says
  if it has none. The type's own name, anywhere inside a collection or an
  optional, is `.lazy { Name.schema }`, so a recursive type works. A type with
  no schema that the macro can recognise (`Set`, `Date`, `URL`, `UUID`,
  `Float`, a tuple, a function, an existential, a dictionary with non-`String`
  keys) is refused by name, with what to use instead.
- **A property without a type annotation** is typed from a literal default
  (`1` is `Int`, `1.5` is `Double`, a string, a boolean) or from a
  `Name(…)` initialiser call; anything else is refused ("write the type").
- **Doc comments** are the fields' `doc:`, and the type's is the object's
  `doc:`. Lines of a paragraph are joined by a space; a blank `///` line
  starts a new paragraph.
- **`@Schema`'s arguments** are copied to `Schema.object` unread:
  `name`, `unknownKeys`, `version`, `versionKey`, `missingVersion`,
  `migrations`. `@PreserveUnknownKeys` marks the `JSONObject` property that
  becomes `preservingUnknownKeysIn:` and is not a field.
- **Access.** `public` and `package` types get a `public`/`package` `schema`,
  because the conformance needs a witness as visible as the type.

### Constraint attributes

| Attribute | Is | Applies to |
| --- | --- | --- |
| `@Range(200...4000)` | `.range(…)` | numbers |
| `@GreaterThan(0)`, `@LessThan(1)` | `.greaterThan`, `.lessThan` | numbers |
| `@MultipleOf(5)` | `.multipleOf` | numbers |
| `@Length(1...64, unit:)` | `.length(…, unit:)` | strings |
| `@Pattern("^[a-z]+$")` | `.pattern` | strings |
| `@Count(0...8)` | `.count` | the outermost array or dictionary |
| `@Unique` | `.unique` | the outermost array |

Each is written beside its property, in the order written. **Scalar
constraints reach the innermost value** through optionals, arrays,
dictionaries and secrets (`@Length(1...253) var hosts: [String]` bounds each
host; `@Count(0...8)` bounds the list), because that is the only reading that
lets both be said with one attribute each. A constraint cannot reach inside a
named type the macro cannot see (a typealias, a struct); that is an error that
says to put it in the type's own schema.

The other markers: `@Key("wire")`, `@Secret`, `@Unit("px/s")`,
`@Aliases("a", "b")`, `@Deprecated("why")`, `@Nullable`, `@Ignored` (the
property stays in the default instance and out of the schema),
`@PreserveUnknownKeys`. All of them are peer macros that expand to nothing:
`@Schema` reads them from the syntax of the members it is given, and each one
used outside a `@Schema` type is an error, not silence.

### `@Schema` on an enumeration

- **A `String` or `Int` raw type** gives `Schema.enumeration(T.self)`, and
  the `CaseIterable` conformance it needs if the enumeration lacks it (the
  extension macro adds only what is missing).
- **Cases that carry values** give `Schema.union(T.self, discriminator:)`,
  with the pair of closures per case that phase 2 had each case say by hand: `Case("circle", Circle.schema, Shape.circle) { if case
  .circle(let payload) = $0 { payload } else { nil } }`. A case with no
  values is `Case("point", Shape.point) { if case .point = $0 { true } else
  { false } }`. One associated value, labelled or not, is the payload; its
  schema is the type's (written `Schema<T>.…` so the compiler has a type to
  infer from). Several labelled values are an object of their own, read with
  the form (b) reader over a labelled tuple, `Shape.rect(width: 3, height: 4)`
  being `{"type": "rect", "width": 3, "height": 4}`. `@Key("pt")` on a case
  renames its tag. `@Schema(discriminator:, valueKey:, name:)` are passed on.
- **Constraints on payloads** have nowhere to be written (Swift has no
  attributes on associated values), so a payload's constraints live in its
  type's schema.
- A plain enumeration with neither raw type nor values is refused, with a
  fix-it that adds `: String`.

### `@Refined`

`@Refined(Double.self, .range(0.1...10), .finite) enum ScrollSpeedRule {}`
adds `typealias Base`, `static var constraints` and the `Refinement`
conformance. The constraints are the library's own `Constraint` values, copied
unchanged; they are checked with the same code as the attributes (does each fit
the base, is a range empty, do they contradict), but, as in a refinement, they
are about the base value itself: a number constraint does not reach inside
`[Int].self`. The value type stays `Refined<ScrollSpeedRule>`.

### Diagnostics

A macro that finds an error reports it at the node that is wrong, with a
fix-it where one is safe, and expands to nothing (no `schema`, no
conformance), so the person sees the cause and not a cascade of "type has no
member `schema`". Every diagnostic has a test with its line and column.

| Where | Mistake |
| --- | --- |
| the type | not a struct or enum; generic; an enum with no cases; already declares `schema`; initialisers but no `init()` |
| a property | `@Lossy` on anything but an array, `@Codable` on a type that has a schema of its own (fix-it removes it); a `let` in form (a) or one with a value (fix-it: `var`); an `@Ignored` property with no default when the value is built by the initialiser; type not visible (no annotation, non-literal default); type with no schema, by name; a pattern binding (`var (a, b)`) |
| use of markers | any marker on a static or computed property, on an `@Ignored` property, or outside a `@Schema` type; the same marker twice (fix-it removes the second); `@Key("")`; a non-literal key, alias or deprecation message |
| keys | a key or alias used twice (the runtime precondition, moved to compile time); an alias equal to its own key; the version key used by a field |
| constraints | one that does not fit the type (`@Length` on `Int`, `@Range` on `String` or on a named type, `@Count` on a scalar, `@Unique` on a dictionary; fix-it removes it); an empty range (`10...1`); a negative length or count; `@MultipleOf(0)`; constraints that exclude each other; a pattern that does not compile; a literal default that breaks its own constraint |
| nullable and secret | `@Nullable` on a non-optional (fix-it removes); `@Secret` on a `Secret<T>` (warning) |
| arguments | `discriminator:` or `valueKey:` on a struct, `unknownKeys:` or `version:` on an enum (fix-it removes); `migrations:`, `versionKey:` or `missingVersion:` without `version:`; a version below 1; `unknownKeys:` together with `@PreserveUnknownKeys`; `.preserve` with no preserving property; a preserving property that is not a `JSONObject`, or a second one |
| an enum | `@UnknownCase` twice, in a tagged union, or on a case carrying anything but one `String` (or any value, with a raw type); on a property; no raw type and no values (fix-it adds `: String`); a raw type other than `String` or `Int`; a marker on a raw-valued case; a marker other than `@Key` on a union case; a tag used twice; the discriminator equal to the value key; several associated values without labels; an associated value of a type with no schema |
| `@Refined` | on anything but an enum or struct; no base type or constraints; a base that is not `T.self`; a constraint that does not fit the base, an empty range, contradictions |

A non-literal default is *not* an error: the default instance carries it, and
the macro checks only what it can see (a literal number against `@Range`, a
literal string against `@Length`, a literal array against `@Count` and
`@Unique`). What it cannot see, `SchemaSuite` checks ("the defaults are
valid").

### Decisions

- **Sugar means the tests compare against hand-written schemas**, not against
  expected text alone. The expansion text is also tested, for review.
- **`Secret<T>` is a transform**, not a new schema in StoicSchema, because
  StoicSchema does not depend on Stoic and `Secret` lives there.
- **Self-reference is lazy, other references are direct.** A `.lazy` payload
  of a union counts as "not an object" (phase 2), which would change the wire
  shape of every nested payload, so only the type's own name is lazy.
- **Checks are literal arithmetic.** The macro evaluates integer, floating
  point, string, array and dictionary literals and range expressions, and
  passes everything else through, so `@Range(Self.limits)` is legal and
  unchecked until the schema is built.

### Cost

On 40 structs of 8 fields each (320 fields, constraints on half of them),
building the module with the macros and with the same schemas written by hand
took the same time within noise (3.2–4.2 s against 2.9–4.9 s per debug build
of the target, including the link), so expansion is about ten milliseconds per
type. The one-time cost is building the plugin: a fresh consumer package
(StoicJSON, StoicSchema, StoicMacros, the plugin, and swift-syntax's prebuilt
macro support, 0.7 s to download) built in 7 s. Without the prebuilt (an older
toolchain, a locked-down machine) SwiftPM builds swift-syntax from source,
which takes minutes; that is the price of the trait and the reason it is a
trait.

### Open problems

- **Form (b) relies on the memberwise initialiser.** A type that declares
  an initialiser has none, so it must give every property a default and
  declare `init()`. An initialiser written in an extension is invisible to
  the macro and does not suppress the memberwise one, which is what it
  calls.
- **Mutual recursion** (`A` holds `[B]`, `B` holds `A?`) is not detected;
  both `static let`s then wait for each other and trap on first use. Only a
  type's own name is made lazy. A `@Recursive` marker that wraps a field in
  `.lazy` is the likely fix.
- **Type aliases and other opaque names** are `Name.schema`. A constraint on
  one is refused rather than guessed.
- **Documentation of enumeration cases** is not exported: `Schema.enumeration`
  has nowhere to put it (union cases do take `doc:`).
- **A union's recursive payload is keyed** under the value key (`.lazy` is not
  an object), which differs from its non-recursive siblings' flat form; this
  is phase 2's rule showing through.
- **A non-literal constraint argument is unchecked** at compile time and traps
  (the library's own precondition) when the schema is first built.
- **Property wrappers, `lazy` properties and observed macros** such as
  `@Observable` are not understood; a macro that rewrites stored properties
  before `@Schema` sees them is outside what it reads.
- **Linux and Windows** are outside the platform floor, as for the rest of
  Stoic; the plugin itself has no platform dependency.

## As built: wire models

Phases 1 and 2 were written for configuration. An API's models need more:
Foundation's types as fields, fields that must be present, enumerations a
server may extend, collections that survive one bad element, and models that
cannot be rewritten yet. This section records what was added for them, in
the order it was built.

### Foundation's types

- **`Schema.date(_:)`, `.url(_:)`, `.uuid`, `.data(_:)`**, and `Date`,
  `URL`, `UUID` and `Data` conform to `Schematic` (so `[UUID].schema` and the
  macro's `Name.schema` work). Each is a `.transformed` node over a plain
  string (or number, for the epoch dates), so every tool that knows
  transforms knows them without a case of its own.
- **Formats.** `DateFormat`: `.iso8601` (RFC 3339, the default: fractions of
  any length, any offset, `t`/`z`/space accepted, a time without an offset
  refused because it names no instant), `.epochSeconds` (a number, which may
  have a fraction) and `.epochMilliseconds` (an integer). `URLFormat`:
  `.absolute` (has a scheme; the default) or `.relative` (any reference).
  `DataFormat`: `.base64` (padded, the default) or `.base64url` (read with or
  without padding, written without). A UUID is read in either case and
  written in lower case.
- **RFC 3339 is parsed by hand**, not by a formatter: a formatter is locale
  and calendar machinery and rolls February 30th into March. Every format
  covers the years 0000 to 9999 in UTC, the range RFC 3339 can write, so a
  date read in one format can be written in any other; a date outside it is
  `out_of_range` from `validate` and is written as `null`.
- **Precision.** A `Date` is written in UTC with the fewest fractional digits
  that read back as exactly the same `Date` (none for whole seconds, three
  for milliseconds), found by trying each length; that is "the original
  precision" as far as a `Date` remembers it, and it makes every date a
  fixed point of encode-then-decode. The offset a date was written with is
  not kept.
- **A URL is never repaired.** Foundation's `URL(string:)` percent-encodes
  invalid characters by default, which would read `"a b"` as a different URL
  from the one sent; the schema refuses it with the reason.
- **Issues.** A string that does not parse is `invalid_format` (new), with
  `format` and a `message` saying what is wrong (`there is no month 13`, `it
  is a relative reference`, `its length, 7, is not a multiple of 4`) and,
  where there is one, a suggestion (the hyphenated form of a UUID written
  without hyphens). Inside a secret the reason is dropped with the value,
  since it is derived from it.
- **Export and generation.** `TransformNode` gained `format` (exported as
  JSON Schema's `format`: `date-time`, `uri`, `uri-reference`, `uuid`,
  `byte`), `keywords` (more keywords, here `contentEncoding`) and
  `counterexamples`: values of the base that the conversion refuses, with the
  issue each raises. The generator draws valid values from `examples` (which
  include offsets, fractions, upper-case UUIDs, the first and last
  representable dates) and the mutator offers each counterexample as a
  `refusedByConversion` mutation, which `SchemaSuite` checks yields exactly
  that issue; the agreement check skips those, since `format` is an
  annotation to a JSON Schema validator.

- **`Schema.decimal(_:acceptingStrings:)`**, and `Decimal` is `Schematic`. It
  reads a JSON number from the digits StoicJSON kept (`ExactDecimal` has them
  already for range checks), so `19.99` is exactly that and no `Double` is
  involved; it writes a number, with the digits `Decimal` prints. A number
  with more than 38 significant digits (trailing zeros are not digits) or a
  power of ten outside -128...127 is `out_of_range`, never rounded: the
  conversion is checked by reading the `Decimal` back and comparing digits,
  so a Foundation that rounded would be caught. `acceptingStrings: true` also
  reads text under JSON's number grammar and no other: `"1,5"`, `"+1"`,
  `".5"`, `"5."` and a string with spaces are `invalid_format`, each with the
  reason and, where one is obvious, the number that was meant (`1.5`). The
  constraints (`.range`, `.greaterThan`, `.multipleOf`) are checked on the
  digits, so `.multipleOf(0.05)` accepts `0.15`. The export says `number`
  with the constraints and `format: decimal`; with strings accepted it is an
  `anyOf` of that and a string with the number grammar as its `pattern`
  (JSON Schema cannot constrain a string by its value, so the constraints
  are on the number alternative only). `TransformNode.readsNumberDigits`
  tells the mutator that 2^53 + 1 and 1e400, which a `Double` refuses, are
  not refused here; the conversion's own `counterexamples` (`1e200`, a
  39-digit number, the bad strings) say what is.

### Enumerations a server may extend

- **`Schema.enumeration(T.self, unknownCase: .unknown)`** (raw values of
  `String` or `Int`) and **`Schema.openEnumeration(T.self, cases:, fallback:,
  read:, write:)`** (for a case that keeps the string it did not understand,
  `case unknown(String)`). A string that names no known case is read as the
  unknown case and reported as an `unknown_case` *warning* with the value,
  the case it was read as and the nearest known spelling; so a response
  that mentions a case added after this client shipped decodes, and the
  warning is how the app finds out. A value of the wrong kind (a number
  where a string belongs) is still a `type_mismatch` error. The unknown
  case is a case like another when it is written: a plain one is written as
  its raw value (the original is not kept), `unknown(String)` as what it
  holds.
- **Representation.** The node is a `.transformed` over a plain string (or
  integer), whose examples are the known cases, so exporters, generators and
  the suite need no case of their own. The export is `{"type": "string",
  "examples": […]}`: it accepts any string, because the schema does, and
  says which ones are known.
- **`@UnknownCase`** marks the case, on an enumeration with a raw type
  (plain case) or without one (plain cases, with the unknown case plain or
  carrying one `String`). A tagged union has no unknown case yet: an unknown
  discriminator stays an error.

### Lossy arrays

- **`Schema.lossyArray(of:_:)`** (and `@Lossy` on an array property). Each
  element that does not decode is left out and answered with one
  `dropped_element` warning at its place in the *input* (`$.ids[3]` is the
  fourth element the server sent), with the `index` and the first reason in
  its parameters; the errors the element would have raised are removed, so
  an object element with three problems is one warning. Warnings the element
  raised are removed with them. Everything outside the array is read as
  before, and an array that is not an array is still a `type_mismatch`.
- **The array's own constraints** (`.count`, `.unique`) are checked on what
  is kept, so a list that falls under its minimum after dropping is an error.
- **Representation.** A `.transformed` node over the array, with
  `dropsInvalidElements` set and the keyword `x-stoic-lossy` exported; the
  element schema stays in `items`, as documentation of what is kept. The
  mutator expects the warning, not the error, for a mutation inside an
  element (and leaves the element alone where the list would fall under its
  minimum); because a JSON Schema validator rejects the element, such
  mutations are marked `isTolerated` and the agreement check skips them.

### A Codable leaf

- **`Schema.codable(T.self, examples:, decoding:, encoding:)`** and `@Codable`
  on a property whose type is a name the macro cannot look into (through an
  optional, array or dictionary). The JSON is handed to a fresh
  `JSONDecoder` as text, so numbers keep their digits; a fresh `JSONEncoder`
  writes the value, and the bytes are parsed back to JSON. `decoding:` and
  `encoding:` configure the two (date strategy, key strategy).
- **The price is stated.** A failure is *one* `invalid_value` issue at the
  field: the decoder stops at its first problem and says it in words, with
  the coding path inside the value, so there is no path of the schema's kind
  below the field and no accumulation. Inside a secret the reason is dropped,
  since it is made of the value. There are no constraints, no documentation
  of the inside, and the export is `{}` (accepts anything; the transform
  annotation is left out because there is nothing on the wire to describe).
- **Generation needs help.** The node is a `.transformed` over any JSON whose
  `examples` are the encoded `examples:`. Without them a generator draws
  arbitrary JSON, which a typed value refuses, so `SchemaSuite` on a schema
  with a Codable leaf wants examples (the macro cannot supply them; write the
  field by hand for the suite, or leave the leaf out of it).

### Decisions

- **Foundation, deliberately, and only where its types are.** `Date`, `URL`,
  `UUID`, `Data` and `Decimal` are Foundation's, so a schema for them needs
  Foundation; so does the `Codable` leaf, which runs `JSONDecoder`. The
  choice was between importing it in StoicSchema and a separate
  `StoicSchemaFoundation` target. A separate target would make every file
  that uses `@Schema` with a `Date` import a second module (the macro's
  expansion names `Date.schema`, which only resolves where the conformance
  is visible), and buys nothing on the platforms Stoic supports, where
  Foundation is part of the OS. So StoicSchema imports it, in the files under
  `Sources/StoicSchema/Foundation/` and nowhere else (a test enforces it):
  the parser, the decoder, the encoder and every tool stay written against
  the standard library, and StoicJSON stays Foundation-free entirely. (The
  files import `FoundationEssentials` where it exists, for a later Linux
  port.)

## Non-goals

Formats other than JSON in the first version (property lists and YAML can
map onto `JSONValue` later); remote schema registries; validation that needs
I/O (it belongs in an async second stage that reports the same `Issue` type).

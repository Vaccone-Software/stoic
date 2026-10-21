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
    public init(clamping raw: R.Base) where R: ClampableRefinement   // the explicit lossy path, for UI
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
    public func decode(_ bytes: some Collection<UInt8>, options: DecodeOptions = .strict,
                       warnings: (Issue) -> Void) throws(ValidationFailure) -> Value
    public func encode(_ value: Value, style: EncodeStyle = .full) -> JSONValue
    public func jsonSchema() -> JSONValue                // Draft 2020-12
}

public struct Decoded<Value> {
    public var value: Value?; public var issues: [Issue]
    public func get(warnings: (Issue) -> Void) throws(ValidationFailure) -> Value
}

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

**No silent lossy path.** A warning or a repair is a decision the decoder
made for the app: an element dropped from a lossy array, a case the server
added read as the unknown case, a newer document read best effort, a field
replaced by its default. So no entry point hands over the value alone
without being told where those go: `decode(text, warnings:)` and
`Decoded.get(warnings:)` take the handler as a required argument, and
`{ _ in }` is how a caller says it drops them, in a line a reviewer reads.
`decodeReporting(_:)` returns everything as a `Decoded`. A sink in
`DecodeOptions` was the alternative and was refused: an optional sink
defaults to nowhere, which is the silent path again, and a closure would
cost `DecodeOptions` its `Hashable`. Through `Codable`, where `init(from:)`
has no one to hand a warning to, `SchemaCoded` keeps its warnings beside its
value.

**Decode options.**

- `.strict` — any error fails. For wire formats.
- `.lenient` — an invalid field falls back to its default and records a
  `repaired` issue; for hand-edited configuration, where the app must still
  launch and tell the user exactly what it ignored.
- `unknownKeys: .reject | .warn | .ignore` per object, with did-you-mean.

**Did-you-mean.** Candidates are declared keys plus aliases. In an object
that forgives respellings (configuration; see "Respelled keys" below), ASCII
case and snake/camel differences are an exact alias match (`scroll_speed` →
`scrollSpeed`, reported as a deprecated spelling, not an unknown key); in a
wire model they are an unknown key whose first suggestion is the declared
spelling. Otherwise Damerau–Levenshtein with threshold `min(2, length/3)`, at most
three suggestions, deterministic order. The same machinery serves enum
values and union tags. Type confusion gets its own hint: `"10"` where a
number is expected says "did you mean `10`?".

A suggestion is an explanation, and explaining is kept apart from detecting:
it is computed only for an issue that is recorded (past `maxIssues` an issue
is counted, not explained), from names a schema normalises once when it is
built, and with a distance that cannot be expensive. Candidates whose
letters alone are too far apart are ruled out by one merge of sorted
scalars; the rest get the table in a band two cells wide either side of its
diagonal, saturating at the threshold. Before this, an object of 8,000
near-miss keys took 160 s to decode in a debug build (4 s in release, and a
100,000-member object about 50 s); it now takes under a second in debug, the
worst case being keys that are anagrams of every declared name.

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
issue (`precision_loss`), not a silent rounding. So is any number whose
`Double` breaks a constraint its digits kept: `9.99999999999999999999`
satisfies `.lessThan(10)` and is `10.0`, which does not. **Constraints hold
for the value the caller receives**, not only for the text that was sent:
after a conversion that can change a value (a `Double`, a refinement's base)
they are checked again on what it produced. `1.0` for an `Int` field is
accepted only under `.lenient`. NaN and infinities do not exist in JSON and
cannot be produced, and neither can a number outside a `Double`'s range:
StoicJSON refuses `1e400` (and `1e-400`, which would round to zero) in text
and in `JSONNumber(lexeme:)` alike, judged by the number's exponent and never
by how long its text is, so every number that exists encodes to text that
parses back.

## Layer 3: tooling

- **JSON Schema export**, Draft 2020-12: ranges, lengths, patterns, enums,
  defaults, `description` from `doc`, `additionalProperties: false` for
  rejecting objects, `x-stoic-unit` and `x-stoic-secret` metadata. What
  cannot be expressed (cross-field constraints, `.custom`) is exported as an
  `x-stoic-constraint` annotation and listed in the export's summary. So is
  the one place Draft 2020-12 is looser than the decoder by definition: its
  `integer` is any number with no fractional part, so a validator admits
  `5.0`, which `.strict` refuses for an integer; every integer (and integer
  enumeration) carries `x-stoic-integer-spelling` and an `integer-spelling`
  entry in the summary.
  `JSONSchemaOptions` (`jsonSchema(options:)`) writes the same document for an
  editor: Draft-07, every object closed, a file header admitted (see "A JSON
  Schema for an editor").
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
| a key uses the snake_case spelling           | In an object with defaults, accepted as an alias; `deprecated_key` warning |
| a wire model meets another spelling of a key | `unknown_key`, the declared spelling suggested first; it reads its keys and aliases exactly unless declared `spellings: .forgiving`. Only ASCII case is ever folded: `\u{212A}ind` (a Kelvin sign) is never `kind` |
| a number is out of range under `.strict`     | `out_of_range` error with the bounds                                      |
| the same under `.lenient`                    | Default used; `repaired` issue saying so                                  |
| an integer exceeds 2^53 for a `Double` field | `precision_loss` error                                                    |
| a number rounds, as a `Double`, across one of its constraints | `precision_loss` naming the constraint and the value it became; no value, so a `Refined` is never decoded holding a value its own initialiser refuses |
| a secret field is invalid                    | Issue without `actual`                                                    |
| the input has duplicate keys                 | Rejected by StoicJSON with both locations                                 |
| a repeated key is accepted by `.lastWins` or `.firstWins` | The value holds the occurrence the policy keeps; `JSONDocument.repeatedKeys` lists each repeat after the first (path, key, where it was first said, where it is said again, which was kept; at most 1,000) |
| a default changed between releases           | Old documents keep the value they had, via a `pinDefault` migration       |
| a date-time is not RFC 3339                  | `invalid_format` saying what is wrong (no month 13, no offset); no value  |
| a decimal is not a number                    | `invalid_format` saying why (a comma, a `+`, no digit before the point); more digits than a `Decimal` holds is `out_of_range`, never rounded |
| an enumeration with an unknown case meets a value it does not know | Read as that case; an `unknown_case` warning naming the value and the case, with the nearest known spelling; the document is still accepted |
| a tagged union with an unknown case meets a tag it does not know | The object is read as that case; an `unknown_case` warning at the discriminator naming the tag and the case, with the nearest known tag; the payload is handed over unread (kept, if the case holds it, and written back as it came); the document is still accepted |
| an element of a lossy array is invalid       | Dropped, with a `dropped_element` warning carrying its input index and the first reason; the rest are kept, and the element's own errors are not reported |
| a number outside a clamped range is read    | `clampingToRange()`: the nearest inclusive bound is the value, and an `out_of_range` *warning* (`repair`: "clamped to 4000") says so, in every mode; an exclusive bound, `.multipleOf` and the rest still refuse; a non-number is still `type_mismatch` |
| an entry of a lossy dictionary is invalid    | Dropped, with a `dropped_entry` warning at the entry's own path carrying its `key` and the first reason; the rest are kept, and the entry's own errors are not reported (`Schema.dictionary` still fails the whole table) |
| a section that may be null is null          | `readingNullAsEmpty()`: read as `{}`, every field its default, no issue, in every mode; nothing remembers the null, so a sparse write omits the section. Without it, `null` is a `type_mismatch` |
| a document is read that a schema's normalization rewrites | `normalizing(_:)`: the raw JSON is tidied before it is decoded, on every read, silently (an old key becomes the new, the new winning if both are there; an old enumeration spelling the new; a custom edit); `retired` paths vanish with no `unknown_key`; an operation that fails is `normalization_failed`. Issues point at the text, not the whole object |
| a JSON Schema is exported for an editor | `jsonSchema(options:)`: `draft07` writes `definitions`, `#/definitions/…` and a `$ref` with neighbours as `allOf`; `closesObjects` says `additionalProperties: false` on every described object whatever its policy (not on a dictionary's free keys); `extraRootProperties` declares the header keys at the top. The default options are the document that was always written |
| a field with a list or an object as its default is repaired | Under `.lenient` the default stands in and the issue says "used the default", with no rendering of a composite (a scalar default is said: "used the default 1200") |
| a string is not one of a closed list | `not_one_of` with the list as the expectation and the nearest spellings as suggestions (up to three, as for an enumeration's cases); none for a secret, and none for a value that is not a string |
| a json field carries a JSON Schema fragment for export | `Schema.json(jsonSchema:)`: the fragment is written into the field's schema over `{}` (with the field's `description`); decoding is `json()`'s; a `$ref` into `#/$defs/` is repointed, and wrapped beside its neighbours, in Draft-07 |
| a Codable leaf's value is refused by JSONDecoder | One `invalid_value` issue at the field, with the decoder's reason and the coding path inside it (no reason inside a secret); nothing below it is reported |
| SchemaSuite meets a Codable leaf that has no examples | A warning naming the leaf and how to fix it (`examples:`, `@Codable(examples:)`); the cases that need a value of it are skipped, and if every case was skipped the suite fails with that reason instead of passing having checked nothing |
| a required field's key is missing            | `missing_key` naming the key, beside every other issue; no value (never a zero in its place) |
| a decode that succeeds with warnings is asked only for its value | The warnings go to the `warnings:` handler every value-only entry point requires, or stay beside the value in `SchemaCoded`; none is dropped unless the caller wrote `{ _ in }` |
| a value is clamped into a refinement with a step | Moved into every range, then to the nearest multiple (the lower on a tie); never a trap on the input. A refinement with no nearest value has no `init(clamping:)` |
| a value read through the Codable bridge nests deeper than `maxDepth` | One `DecodingError.dataCorrupted` naming the limit, before the schema runs; the walk keeps its own stack, so no depth exhausts the thread's (`maxStringBytes` and `maxContainerCount` are enforced the same way) |
| a value read through the Codable bridge repeats a key | Not seen: the `Decoder` resolved it before the schema was asked (`JSONDecoder` keeps the first value). Wire data and files go through the schema's text entry points, which refuse it with both locations |
| two documents differ inside an array | One `JSONChange` at the array, holding both whole arrays: arrays are leaves, never matched element by element |
| a change is applied to a value that has moved on | `ApplyError.conflict` with what is there; nothing changes, unless the caller says `overwriting` |
| a change's path leads through the wrong kind of value | `ApplyError.blocked` at the step that cannot be taken; with `overwriting`, missing objects on the way are made, anything else still blocks |
| a change adds or removes an element of an array | `ApplyError.arrayElement`: an array changes as one whole value (an element can be replaced) |
| a value is set at a path whose objects are not there | The objects on the way are made; a member that exists keeps its place and a new one is appended |
| a value is set where a value that is not an object is in the way | `JSONPathError.blocked` at the path of what is there, with it (`null` and arrays block too: a value someone wrote is not replaced to make room); nothing changes |
| a value is set at an index past the end of an array | `JSONPathError.arrayElement` at that index: an element that exists can be replaced, none can be added |
| a value is removed that is not there | The value, unchanged (so a removal can be repeated), whatever is in the way |
| the last member of an object is removed with `pruning` | The objects the removal left empty are removed too, up to but not including the root, and not past an array; an object that was already empty is not touched |
| an element of an array is removed | `JSONPathError.arrayElement`; the root is `.root`. Nothing changes |
| a dotted address has a free key with dots in it | The shape decides: a free key takes the fewest segments that leave a remainder the shape reads (`web.routes.github.com` is `routes` / `github.com`; `web.links.my.site.url` is `links` / `my.site` / `url`), else all of them |
| a dotted address names what the shape does not describe | Read as plain keys from there, one per segment, and still a path: saying the key is unknown is the validator's work |
| a dotted address has an empty segment | `nil`: no key can be addressed by it. The empty address is the root |
| a comment is met with `allowComments` off | `comment_not_allowed` at the `/` that begins it (line and column), saying "comments are not allowed in this file" and naming no option, so an app may show it as it is; trailing commas and the rest of the dialect are unaffected, and a `/` inside a string is not a comment |
| the text repeats a key and the options accept it | A `repeated_key` warning at each repeat after the first (its key's line and column; `firstLine`, `firstColumn` and `kept` in the parameters), from every decode of a document that remembers one; an app may add a `note` to the parameters and the message ends with it. The decode succeeds: the warning says which of two values the value is |
| a schema that wants any object meets another kind of value | `Schema.jsonObject()` is `type_mismatch`, "expected an object, found an array" (or a number, a string, null, a boolean), at the position of the value, and no value; `Schema.json()` would have admitted it and failed the app at its first lookup. It exports as `{"type": "object"}` and generates objects |

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
  Bounds are `JSONNumber`s, which order and divide on their digits at any
  precision (`JSONNumber` is `Comparable` and has `isMultiple(of:)`), so
  `2^53 + 1` is above `2^53`, `0.3` is a multiple of `0.1`, and a sender
  cannot slip past `.range(0...10)` with forty digits that a `Double` would
  round to `10`.
  A constraint is silent about kinds of value it is not about, as JSON
  Schema's keywords are. An infinite bound on its own side is no bound; a
  bound that admits nothing (`.greaterThan(.infinity)`, `Double.infinity...`,
  any NaN, a non-finite step) traps where it is written, where it used to
  become no bound and admit everything.
- **String length has a unit.** `.characters` is Unicode scalars, the only
  unit JSON Schema counts; `.graphemes` and `.utf8Bytes` export as
  `x-stoic-length`. A pattern is skipped when a length constraint on the
  same value already failed.
- **Patterns are stored as source** and compiled with `Regex` per decode
  (`Regex` is not `Sendable`), with scalar matching semantics.
- **`Refinement` also names `baseSchema`** (automatic for any `Schematic`
  base), because checking a value means interpreting the constraints on its
  JSON form.
- **Clamping is offered only where it cannot fail.** `init(clamping:)`
  exists for integer and `Double` bases of a `ClampableRefinement`: one whose
  constraints are ranges, `.finite` and at most one `.multipleOf`. The value
  is clamped into every range and moved to the nearest multiple inside them
  (`7` under `.range(0...100), .multipleOf(10)` is `10`; a tie goes down; a
  `Double` multiple is built from its decimal digits, so `0.3` and never
  `0.30000000000000004`). It used to clamp ranges only and trap when the
  result broke another constraint, so a text field could crash the app with
  a `7`. A pattern, a list of values or a custom check has no nearest value,
  so a refinement with one does not conform and the compiler refuses the
  call: unavailable rather than failable, because a failable initialiser
  would make every `Port(clamping: 8080)` default handle a `nil` that
  cannot happen. The conformance is a promise the compiler cannot check
  (constraints are values); one that is broken, or a refinement that admits
  no value, traps on the first clamp whatever the input, so the first test
  finds it and no user's input can. `IntRange` conforms, and `@Refined` adds
  the conformance when its constraints qualify.
- **`Optional` has three states.** Absent means the field's default (or
  `nil` where there is no default); `null` is a value only for
  `nullable: true`; otherwise `nil` is written by omitting the key.
- **Object form (b) reads fields into `Slot`s** and builds through a `Values`
  token, so every field's issues exist before the initialiser runs; see the
  note in `Schema+ReadObject.swift`. Form (a) defaults to `unknownKeys:
  .warn`, form (b) to `.reject`.
- **Respelled keys** (ASCII case and snake_case, plus declared aliases) are
  accepted with a `deprecated_key` warning; the same field under two
  spellings is `duplicate_key`. Respelling is `KeySpellings.forgiving`, the
  default of form (a), whose documents people type; form (b), the wire
  model, defaults to `.exact` (aliases still count, being declared). A
  reader that accepts spellings no other reader of the same message accepts
  reads it differently from them, and that disagreement is what
  parser-differential attacks are made of: a gateway that checks `isAdmin`
  while the service behind it also takes `is_admin`. Case is folded in ASCII
  only for the same reason, since Unicode case mapping turns the Kelvin sign
  into `k`. The table of normalised
  spellings that finds them is built per object, and only when a field's
  key is missing *and* some member has a key the object does not declare;
  a document that merely leaves out keys whose defaults it accepts never
  pays for it (20,000 rows missing six of nine keys: 124 ms to 104 ms, release).
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
  `context.hasErrors` counts the errors since this decoder started, never
  a sibling's, so a decoder that gives up on it gives up only on its own
  value.
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
  transparent wrapper is not another kind of payload: `documented(_:)` (and
  any transform that converts nothing) is looked through, so wrapping an
  object does not move its fields under the value key. A `lazy` payload
  counts as not an object, since looking inside would recurse while the
  schema is built.
- **Decoding** reads the discriminator first, because until it is known
  nothing else can be: not an object is `type_mismatch`; absent is
  `missing_key` at `$.type`; a non-string is `type_mismatch` there; an
  unknown tag is `not_one_of` there with the tags listed and the nearest
  suggested (unless the union has an unknown case; see "Enumerations a
  server may extend"). The payload then decodes as any schema does, accumulating, and
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
  overwrite. A move with one path inside the other (`a` to `a.b`) would put
  the value inside itself and delete it with its old place; it traps where
  it is declared, as migrations are static. `pinDefault` does what `setIfAbsent` does and says why: it
  writes the old default into a document that omitted the field, so that a
  release changing a default cannot flip what an old sparse file meant.
- **Decoding** reads the version, applies the steps from it to the current
  version one at a time, and records a `migrated` warning per step
  (`from`, `to`, the operations in words) before validating the migrated
  object, so errors are at the new paths. A version that is not a positive
  integer is `type_mismatch`/`out_of_range`, and one spelt `2.0` is read as
  an `Int` field reads it (refused under `.strict`, a warning under
  `.lenient`); one no step reads is
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

- **Inbound.** `schema.decode(from: decoder, warnings:)` reads whatever the decoder
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
  `Hashable` when `T` is, on the value alone) for a property, an element or
  a top-level value; it keeps the warnings of the decode that made it in
  `warnings`, with their full paths. `decodeSchema`/`decodeSchemaIfPresent`
  (each with a required `warnings:` handler)/`encodeSchema` on the containers
  serve hand-written `init(from:)`. `CodingUserInfoKey.schemaDecodeOptions`
  and `.schemaEncodeStyle` choose lenient decoding or sparse encoding through
  `userInfo`, without touching any conformance.
- **What `Decodable` costs.** A `Decoder` hides the source text: numbers
  arrive as `Int64`, `UInt64` or `Double` (so `1.0` is `1` and a negative
  zero is `0`, and a non-integer is as precise as a `Double`), object members
  arrive sorted by key, and `JSONDecoder` cannot tell `"é"` from `"e\u{301}"`
  in a key. A repeated key never arrives at all: the decoder chose one value
  (`JSONDecoder` the first) before the schema was asked, so the refusal
  StoicJSON makes of such a document cannot be made, and two systems reading
  the same bytes can disagree about it. There are no source ranges. The
  schema's own text entry points keep all of that, so **wire data and files
  are decoded from their bytes** (`decodeReporting(_:)`, as `StoicHTTP`
  decodes responses and `StoicSettings` reads files); the bridge is for a
  value that already lives in a `Codable` graph.
- **Limits, and no recursion.** The walk into a `JSONValue` enforces the
  options' `parse.maxDepth`, `maxStringBytes` and `maxContainerCount` (not
  `maxBytes`: a `Decoder` has no bytes to count) and fails with one
  `DecodingError.dataCorrupted` naming the limit. It keeps its own stack of
  open containers and descends with `superDecoder`, never by nesting
  `decode` calls: the recursive walk it replaced was crashed, in an ordinary
  task on a 512 KiB stack, by 250 levels of nesting (about 3.5 KB of JSON)
  under a key the schema did not declare, which plain `Codable` decoded
  without trouble.
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
  state are skipped _by name_ in the agreement check: precision loss of a
  `Double`, an integer spelt with a fraction, and lengths counted in
  graphemes or bytes.
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

**Detecting is apart from explaining.** A column is a walk along its line,
and a minified response is one line, so finding each issue's line and column
as it was found made a thousand issues after a megabyte cost a thousand
megabyte walks (4.6 s in release for one 1 MB document that parsed in 4 ms).
A decode records each issue's byte offsets (a path walk) and resolves them
all at the end with `JSONDocument.ranges(ofOffsets:)`, one pass over the
text. `offsets(of:)` and `keyOffsets(of:)` are the same split for any code
that reports many positions.

### Changes between documents

`JSONChange.between(old, new)` is the list of differences between two JSON
values, each at the deepest path that holds it (`path`, `old?`, `new?`), and
`JSONValue.applying(_:overwriting:)` makes one. They are what an app needs to
keep a history of edits and to undo one: the history is a list of changes
(an edit's `inverted` is its undo), and undo is an application. They live in
StoicJSON because they are pure functions of two values, and a schema layer or
a store can build on them without either knowing the other.

- **Objects recurse, everything else is a leaf.** Members are compared by key
  while both sides are objects. A member on one side only is one change at that
  member holding the whole value; removing `{"b": 1, "c": 2}` is one change,
  not two. A value that changes kind is one change.
- **Arrays are leaves.** Two arrays that differ are one change with both whole
  arrays. Matching their elements is a guess (inserted at the front, or every
  element changed?), and a history that guessed wrong would undo what nobody
  did. Applying a change cannot add or remove an element either; it can replace
  one.
- **Order does not depend on how the objects were written.** Changes come in
  the order of their keys (compared as the canonical encoding compares them),
  so equal pairs give equal lists.
- **Undo is checked.** Applying a change requires the value at its path to be
  the one it replaces, so undoing an edit that was changed again since is a
  `conflict` for the app to decide, not a silent overwrite. `overwriting` is
  the explicit "make it so", and creates the objects on the way.

### Paths: setting, removing and addresses

`JSONValue.value(at:)` reads the value at a `JSONPath`; `setting(_:at:)` and
`removing(at:pruning:)` write one, as pure functions that return the new
document, for an app that keeps its settings as one JSON value (a `json`
schema) and changes them by address.

- **Setting makes the objects on the way**, and nothing else: where something
  that is not an object is in the way (a number, a string, `null`, an array)
  the call throws `JSONPathError.blocked` at that value, with it, and the
  document is unchanged. A member that exists keeps its place, so a file's
  order does not move; a new one is appended. An index replaces an element that
  exists; arrays change as a whole, as they do for `JSONChange`, so one past the
  end, or removing an element, is `.arrayElement`.
- **Removing what is not there is not an error**, so unsetting is repeatable.
  With `pruning` it also removes the objects it left empty on the way up (an
  `unset` of the last route should not leave `"routes": {}` and `"web": {}`
  in a file a person reads), never the root and never past an array, and never
  an object that was empty before.
- **A dotted address** (`web.routes.github.com`) is read into a path with
  `JSONPath(address:shape:)`, where a `JSONPath.Shape` says which levels hold
  fixed keys (`.fields`), which hold the person's (`.freeKeys`, a dictionary:
  the key may contain dots), and which are arrays (`.elements`, a segment of
  digits is an index). A free key takes the fewest segments that leave a
  remainder the shape can read, else all of them; what the shape does not
  describe is read as plain keys, because reporting an unknown key is the
  validator's job. An empty segment is `nil`. `SchemaNode.pathShape` makes the
  shape from a schema (`schema.path(forAddress:)` is the two together): an
  object's fields are fixed keys, a dictionary's are free, an array is read by
  index, a recursive schema is read as far as the address goes, and a tagged
  union is the object of its discriminator and every case's fields (the first
  case's where two share a key).
- **Repeated keys can be accepted, and are then reported.** The default is to
  refuse them (`.reject`: RFC 8259 says only that names "SHOULD be unique",
  and parsers disagree about which wins). A reader of a file a person edits may
  choose `.lastWins` (or `.firstWins`); `JSONDocument.repeatedKeys` then lists
  each repeat after the first (at most 1,000), and a schema decode reports each
  as a `repeated_key` warning, so a value that is one of two is never silently
  so. `Issue.parseCode` is the parser's code of a `parse_error` issue
  (`.invalidUTF8`, `.duplicateKey`, `.commentNotAllowed`), typed, where a reader
  would otherwise dig it out of `parameters`.
- **Comments can be refused.** `JSONParseOptions.allowComments` is on by
  default; with the `.jsonc` dialect and `allowComments` off, a comment is
  `comment_not_allowed` at its `/`, and trailing commas stay allowed. A store
  whose writer cannot keep a comment says no to one where the person sees it,
  instead of dropping it at the next save (design/18).

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
  an integer spelt with a fraction, future version. Every candidate is run
  through the constraint
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
  and spellings to `.exact`
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
  `name`, `unknownKeys`, `spellings`, `version`, `versionKey`,
  `missingVersion`, `migrations`. `@PreserveUnknownKeys` marks the `JSONObject` property that
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
| a property | `@Lossy` on anything but an array, `@Codable` on a type that has a schema of its own (fix-it removes it); a `let` in form (a) or one with a value (fix-it: `var`); an `@Ignored` property with no default when the value is built by the initialiser; type not visible (no annotation, non-literal default); type with no schema, by name; a pattern binding (`var (a, b)`); a `lazy` property, or one under a property wrapper or any other attribute that is not a marker (it stores something other than its declared type), unless `@Ignored` |
| use of markers | any marker on a static or computed property, on an `@Ignored` property, or outside a `@Schema` type; the same marker twice (fix-it removes the second); `@Key("")`; a non-literal key, alias or deprecation message |
| keys | a key or alias used twice (the runtime precondition, moved to compile time); an alias equal to its own key; the version key used by a field |
| constraints | one that does not fit the type (`@Length` on `Int`, `@Range` on `String` or on a named type, `@Count` on a scalar, `@Unique` on a dictionary; fix-it removes it); an empty range (`10...1`); a negative length or count; `@MultipleOf(0)`; constraints that exclude each other; a pattern that does not compile; a literal default that breaks its own constraint |
| nullable and secret | `@Nullable` on a non-optional (fix-it removes); `@Secret` on a `Secret<T>` (warning) |
| arguments | `discriminator:` or `valueKey:` on a struct, `unknownKeys:` or `version:` on an enum (fix-it removes); `migrations:`, `versionKey:` or `missingVersion:` without `version:`; a version below 1; `unknownKeys:` together with `@PreserveUnknownKeys`; `.preserve` with no preserving property; a preserving property that is not a `JSONObject`, or a second one |
| an enum | `@UnknownCase` twice, or on a case carrying anything but one `String` (in a union also `(tag: String, payload: JSONObject)`; with a raw type, nothing); on a property; no raw type and no values (fix-it adds `: String`); a raw type other than `String` or `Int`; a marker on a raw-valued case; a marker other than `@Key` on a union case; a tag used twice; the discriminator equal to the value key; several associated values without labels; an associated value of a type with no schema |
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
- **Property wrappers, `lazy` properties and attached macros** are refused,
  not understood: each stores something other than the type the macro reads
  (a lazy property nothing until used, a wrapped one its wrapper), so reading
  them as plain would describe one value and decode another. `@Ignored`
  keeps such a property out of the schema. A macro that rewrites stored
  properties before `@Schema` sees them, such as `@Observable` (which needs
  a class, and `@Schema` refuses classes), is still outside what it reads.
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
  tells the mutator that 2^53 + 1, which a `Double` refuses, is not refused
  here; the conversion's own `counterexamples` (`1e200`, a
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
  carrying one `String`), and on a tagged union (below).

**Tagged unions** take the same answer: `Schema.union(…, unknown:)` with an
`UnknownTag`, and `@UnknownCase` on one case of a union written with `@Schema`.

- **Reading.** A tag that names no case reads as the unknown case, with one
  `unknown_case` *warning* at the discriminator (`$.type`: the tag, the case it
  was read as, the nearest known tag; the same code and wording as an
  enumeration's). The rest of the object is not read at all: nothing is known
  about its shape, so it raises no issue, and it is handed to the case as a
  `JSONObject` (the discriminator removed). A tag of the wrong kind, or a
  missing one, is still an error, and a known tag keeps its payload's rules.
- **Three forms,** by how much the case keeps, which is how much comes back out:
  `UnknownTag.plain(value, name:, matches:)` (`case unknown`: keeps nothing, is
  written as `{"type": "unknown"}`, like an enumeration's plain case writes its
  own raw value); `.keepingTag` (`case unknown(String)`: the tag, no other
  member); `.keepingPayload` (`case unknown(tag: String, payload: JSONObject)`:
  the tag and every other member, written back with the discriminator first, so
  a record the client only half understands passes through intact). `@UnknownCase`
  recognises exactly these three shapes.
- **Representation.** `UnionNode.unknownCase` holds the case's name (`nil` for a
  closed union). The export gains one `oneOf` branch, an object whose
  discriminator is a string that `not` any known tag (`x-stoic-unknown-case`), so
  the branches stay mutually exclusive and `oneOf` still means exactly one; the
  small validator in the suite learned `not`. The mutator's `badUnionTag` and
  `typoUnionTag` expect the warning where the union is open, not `not_one_of`.
  The generator never draws an unknown tag.

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
  with a Codable leaf wants examples: `Schema.codable(T.self, examples:)`, or
  `@Codable(examples: [T(…)])` (the values are handed to the leaf as written,
  and are values of the named type, also inside an optional, array or
  dictionary). Without them the suite does not crash and does not pass quietly:
  it warns at each such leaf (`$.geo (Geo) is a Codable leaf with no examples`,
  with the remedy), skips the cases whose value reached it, and *fails* if that
  was every case, since a suite that checked nothing is not clean.

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

## As built: files people edit

The additions that let a typed schema stand in for a hand-written reader of a
configuration file, which repairs, forgives and renames where a wire model
would refuse. Each is opt-in per schema and changes nothing for one that does
not ask.

### Clamping

- **`clampingToRange()`** on a `Double` or integer schema. A number outside a
  `.range` is read as the nearest bound, with an `out_of_range` *warning* at
  the number whose `repair` parameter says what it became, so
  `.double(.range(200...4000)).clampingToRange()` reads `99999` as `4000` and
  the message is "99999 is out of range, expected a number between 200 and
  4000; clamped to 4000". (`Issue.message` now ends with the `repair`
  parameter whenever there is one, whatever the severity; before, only a
  `repaired` issue had one.) Without it a range can only refuse, or, under
  `.lenient`, repair to the field's default.
- **A warning, not a `repaired` issue, and in every mode.** `repaired` means
  the default stood in for a value the schema refused, and a settings store
  carries such a value back into the file so that an older build never
  destroys what a newer one wrote; a clamped number is a value the schema
  decided on, written back as the number it became. Clamping is declared by
  the schema, so `.strict` does it too: a wire format that wants 99999
  refused does not ask.
- **Only an inclusive bound has a nearest value.** The value is moved into
  every inclusive bound of every `.range` of the schema, in turn. An exclusive
  bound (`.greaterThan(0)`) and every other constraint are checked after, and
  still refuse. The digits sent decide, as for every number: `1e30` is above
  4000, and a number too wide for an `Int` is clamped, not wrapped. A schema
  with no inclusive bound traps where it is declared.
- **Representation.** A `.transformed` node over the number, `isTransparent`
  (it converts nothing, so the suite asks for no `examples`) and
  `clampsToRange`, with the keyword `x-stoic-clamp` in the export. The export
  keeps `minimum` and `maximum`, which a validator enforces, so an editor
  flags 99999 while the decoder accepts it with a warning. The mutator
  expects that warning, and no error, for a number a bound moves (and for one
  that would have been `precision_loss`, because the clamp comes first), and
  marks the mutation tolerated so the agreement check skips it.

### Lossy dictionaries and documented values

- **`Schema.lossyDictionary(of:_:valueDoc:)`** is `lossyArray` for a table a
  person fills in. Each entry whose value does not decode is left out and
  answered with one `dropped_entry` warning at the entry's own path
  (`$.apps["com.example.Foo"]`), with its `key` and the first reason in the
  parameters; the errors the entry would have raised are removed with it, so
  an entry with three problems is one warning. The good entries survive, where
  `Schema.dictionary` fails the whole table (and `.lenient` repairs it to
  empty). A value that is not an object is still a `type_mismatch`; a key
  spelt two ways Swift reads as one (`"é"` and `"e\u{301}"`), which the strict
  form refuses as `duplicate_key`, drops the second, with a warning, where it
  cannot be lost silently.
- **A hand-edited settings file keeps what was dropped.** The entry is not in the
  value, but it is the person's text: a settings store writes it back, in place,
  until the app sets that key or empties the table (design/18).
- **The table's own constraints** (`.count`) are checked on what is kept, so
  a table that falls under its minimum after dropping is an error.
- **A new code, `dropped_entry`,** rather than `dropped_element` with a key:
  a reader that handles `dropped_element` reads an `index` from its
  parameters, which an entry does not have. The family and the severity are
  the same.
- **Representation.** A transparent `.transformed` node over the dictionary
  with `dropsInvalidElements` and the keyword `x-stoic-lossy`; the value
  schema stays in `additionalProperties`. The mutator expects the warning for a
  mutation inside an entry (and leaves entries alone where the table would fall
  under its minimum); a JSON Schema validator rejects the entry, so those
  mutations are marked `isTolerated`.
- **`documented(_:)`** gives any schema a description for the export, and
  nothing else: `.dictionary(of: .bool, valueDoc: "true to never record clips
  from this app")` writes it as the `description` of `additionalProperties`,
  which a field's own `doc:` cannot reach. It is a transparent
  `.transformed` node carrying the keyword `description` and no
  `x-stoic-transform`, so decoding, generation and every constraint are the
  schema's own, and a union still writes an object payload flat. `valueDoc:`
  on `dictionary(of:)` (an overload) and `lossyDictionary(of:)` is
  `documented` on the value schema.

### A `json` field that carries a schema

`Schema.json(jsonSchema: fragment)` is `json()` whose export is the fragment: the
shape of a value the app owns outside the schema (a graph another tool checks)
reaches the editor without a hand-patched document. The fragment's members are
written over `{}`, so a `$ref`, a `type` or a `maxLength` stands as written, and
the field's `description` beside them; Stoic enforces none of it, and a transparent
`.transformed` node (no `x-stoic-transform`, no examples needed) carries it as
`keywords`. The Draft-07 pass treats it as any schema: `#/$defs/` becomes
`#/definitions/` and a `$ref` with neighbours is wrapped. Definitions it points at
are the app's to add.

### An object read from `null`

- **`readingNullAsEmpty()`** on an object schema (either form). `null` is read
  as `{}`: every field takes its default, silently, in every mode. Without
  it `null` is a `type_mismatch`, and under `.lenient` a repair to the default,
  which a settings store would then carry back into the file as a value to
  preserve. It is for a section of a file people edit that is left as
  `"scroll": null` once what was inside is deleted.
- **The null is not a value.** Nothing in the Swift value remembers it, so a
  write is sparse: the section is omitted when it equals its default, and the
  store does not carry the `null` back (it is not an object whose unknown keys
  could be carried). A form (b) object, whose fields may have no default,
  reports their `missing_key` errors as for `{}`.
- **Only the object reads it**: a `null` for a field inside is as strict as it
  was, and a section that did not ask still refuses `null`.
- **Representation.** `ObjectNode.readsNullAsEmpty`. The export admits `null`
  for the object (`"type": ["object", "null"]`), the mutator does not offer
  `null` as a violation of it, and the library's own validator reads a list
  of types.

### Normalization and retired keys

The versioned `Migration` is for a format that counts its changes. A file a
person has edited for years often has no version and never will, and its old
reader forgave each past spelling by hand on every read. `normalizing(_:)`
is that, declared.

- **`Schema.normalizing(_:retired:)`** on an object schema (or
  `normalizing(_ normalization:)` with a `Normalization`). Operations are a
  closed set over the raw `JSONValue`: `rename`, `move`, `delete`,
  `setIfAbsent`, `mapEnum` and `custom(id:description:apply:)`, paths dotted
  from the object. It runs in that object's decode before anything else (before
  the version is read, before a key is looked up), **on every read**, and
  raises no issue: the file may be as it has always been, and the value is the
  same under the old spelling as under the new.
- **The target that exists wins.** A `rename` or `move` onto a key that is
  taken drops the old key and keeps the value that is there (a migration
  refuses with `migration_failed`; here the newer writer's key is the one that
  counts). That, a `mapEnum` that is not a chain (a spelling both mapped and
  the image of another traps where it is written), and `setIfAbsent` make the
  declarative operations **idempotent by construction**: the result of a
  normalization normalizes to itself, which a normalization on every read must
  be. A `custom` operation is the author's to keep idempotent, and
  `Schema.normalized(_:)` (or `Normalization.applying(to:)`) is the one
  expression a test needs: `normalized(normalized(x)) == normalized(x)`. A
  custom operation that throws `MigrationFailure` is one `normalization_failed`
  error at the object.
- **Retired keys.** `retired: ["old-flag", "observations.legacy"]` are paths
  removed after the operations, so they are not unknown keys (no warning, and
  not under `.reject` either), and are not in the document a write carries: a
  settings store puts back the keys a schema does not declare from the
  document it read, and it reads `Schema.normalized(_:)` of the file, so a key
  that was renamed or retired is not written back in its old place. (Were it
  written back beside the new name, resetting the new key to its default would
  revive the old one on the next read.) A retired path may not be a declared
  field or alias; this traps where it is declared.
- **Positions.** The decoder looks an issue's text up by the path of the node
  in the *input*. Normalization does not disturb the paths of nodes it leaves
  alone, so an issue about one points at it in the file exactly (the "positions
  are coarse" rule of a migration does not apply: that rewrites the whole
  object and cannot say what moved). A value a `rename` or `move` relocated is
  found where the text wrote it (an issue at `$.searcher` points at the
  `"hyper":` line); a value an operation created has no text and points at the
  nearest object that has; and a custom operation's moves are not followed (an
  issue about a node it rearranged points at the text where that path was in
  the file). The moves of declarative operations are recorded as
  `Relocation`s in the decode and undone, latest first, when a position is
  looked up.
- **One normalization per object**, written in one call, since the order the
  operations run in is the order they are written. It is `ObjectNode.normalization`.
  A nested object declares its own and runs it on its own part. `normalized(_:)`
  finds objects through fields, optionals, arrays, dictionaries and transparent
  wrappers (not a union's payloads) and leaves one whose normalization fails
  as it was.
- **The suite** does not hold a schema to documents its normalization
  rewrites: such a mutation is no longer a violation of the current format
  (the normalization may be what forgives it, and the export, which describes
  the current format, rightly rejects it), so mutations and accumulations the
  normalization changes are skipped.

### A JSON Schema for an editor

`jsonSchema()` describes the wire format in Draft 2020-12 and closes an
object only if it *rejects* unknown keys. A settings file is read with `.warn`
(the app starts and says what it ignored), and an editor that is to underline
`scrol_speed` as the person types it needs the closed form and a draft it
reads. `jsonSchema(options:)` and `jsonSchemaExport(options:)` take a
`JSONSchemaOptions`, whose defaults write exactly what `jsonSchema()` has
always written.

- **`closesObjects`** writes `additionalProperties: false` on every object the
  schema describes, **whatever its unknown-key policy**: the document is for the
  editor, the policy is the app's, and the decoder still answers an unknown
  key under `.warn` with a warning. A dictionary's or `json` value's free keys
  are not closed; an object that preserves unknown keys is, and keeps its
  `x-stoic-preserves-unknown` annotation. A flat union branch is closed with
  its discriminator among the properties.
- **`extraRootProperties`** (key, schema) are declared in the root's
  `properties` when the root is an object: the keys of a file header
  (`"$schema"`, a `version` the schema does not manage) that the app writes and
  a closed document would otherwise flag, and that the store ignores on read
  (design/18). A key the schema declares keeps the schema's own entry.
  StoicSettings makes them from a header, `SettingsFileHeader.jsonSchemaProperties`,
  each admitting the *kind* of value the header holds and no more, since a file
  an earlier release wrote has another version's header.
- **`draft`**: `.draft2020_12` (the default) or `.draft07`. The Draft-07 document
  is the 2020-12 one with four things said its way, in a final pass over the
  schema-valued keywords: `$schema` is Draft-07's URI, `$defs` is `definitions`,
  every `#/$defs/X` is `#/definitions/X`, and a `$ref` that has neighbours
  (a `description` or `default` written beside a reference) becomes
  `allOf: [{"$ref": …}]` beside them, because Draft-07 ignores what sits beside a
  `$ref`. Nothing else Stoic writes differs (`const`, `anyOf`/`oneOf`, `type`
  lists, the exclusive bounds as numbers, `deprecated` and the `x-stoic-`
  annotations, which are unknown keywords there and ignored). The library's own
  validator checks both drafts against the decoder on generated documents.

## Non-goals

Formats other than JSON in the first version (property lists and YAML can
map onto `JSONValue` later); remote schema registries; validation that needs
I/O (it belongs in an async second stage that reports the same `Issue` type).

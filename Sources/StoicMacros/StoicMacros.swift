#if STOIC_MACROS
public import StoicSchema

// The macros of Layer 4 (design/06). Each is a declaration here and an
// implementation in StoicMacrosPlugin, the compiler plugin that SwiftPM
// builds for the host.

/// Writes a type's schema from its declaration.
///
/// On a struct whose properties all have defaults it declares
/// `static let schema`, an object with a default instance, one field per
/// stored property; the type then conforms to `Schematic`, so other schemas
/// can refer to it. See the attributes below for what a property can add.
///
/// On an enumeration with a `String` or `Int` raw type it declares the
/// enumeration schema; on one whose cases carry values, a tagged union.
///
/// The arguments are passed to the schema as written. A struct takes
/// `name`, `unknownKeys`, `spellings`, `version`, `versionKey`,
/// `missingVersion` and `migrations`; a union takes `name`, `discriminator`
/// and `valueKey`. The defaults shown are those of a struct whose properties
/// all have defaults; one with a required property is a wire model, and
/// defaults to `unknownKeys: .reject` and `spellings: .exact`.
@attached(member, names: named(schema))
@attached(extension, conformances: Schematic, CaseIterable)
public macro Schema(
    name: String? = nil,
    unknownKeys: UnknownKeyPolicy = .warn,
    spellings: KeySpellings = .forgiving,
    version: Int? = nil,
    versionKey: String = "version",
    missingVersion: MissingVersion = .oldest,
    migrations: [Migration] = [],
    discriminator: String = "type",
    valueKey: String = "value"
) = #externalMacro(module: "StoicMacrosPlugin", type: "SchemaMacro")

/// The key a property is written under, instead of its name.
@attached(peer)
public macro Key(_ key: String) = #externalMacro(module: "StoicMacrosPlugin", type: "KeyMacro")

/// Never echoed in an issue, never in the export's default, left out of
/// sparse output.
@attached(peer)
public macro Secret() = #externalMacro(module: "StoicMacrosPlugin", type: "SecretMacro")

/// The unit of a number, for the export's `x-stoic-unit` and for a UI.
@attached(peer)
public macro Unit(_ unit: String) = #externalMacro(module: "StoicMacrosPlugin", type: "UnitMacro")

/// Other spellings accepted on input, each with a `deprecated_key` warning.
@attached(peer)
public macro Aliases(_ aliases: String...) = #externalMacro(module: "StoicMacrosPlugin", type: "AliasesMacro")

/// Still read, with a warning whenever a document uses it.
@attached(peer)
public macro Deprecated(_ message: String = "") = #externalMacro(module: "StoicMacrosPlugin", type: "DeprecatedMacro")

/// An optional that is written as `null` rather than by leaving the key out.
@attached(peer)
public macro Nullable() = #externalMacro(module: "StoicMacrosPlugin", type: "NullableMacro")

/// Leaves a property out of the schema. It keeps the default instance's value.
@attached(peer)
public macro Ignored() = #externalMacro(module: "StoicMacrosPlugin", type: "IgnoredMacro")

/// Names the case that stands for every value of an enumeration that the
/// schema does not know: an API that adds a case does not break a client
/// that has not heard of it. Decoding succeeds with an `unknown_case`
/// warning. The case may be plain (`case unknown`) or keep what it read
/// (`case unknown(String)`, on an enumeration of plain cases).
@attached(peer)
public macro UnknownCase() = #externalMacro(module: "StoicMacrosPlugin", type: "UnknownCaseMacro")

/// An array that survives its bad elements: each one that does not decode
/// is left out, with a `dropped_element` warning, and the rest are kept.
/// Applies to the outermost array (through an optional); `@Count` and
/// `@Unique` are checked on what is kept.
@attached(peer)
public macro Lossy() = #externalMacro(module: "StoicMacrosPlugin", type: "LossyMacro")

/// Reads the property's type with `JSONDecoder` and writes it with
/// `JSONEncoder`, for a `Codable` type that has no schema: `Schema.codable`.
/// A failure is one issue at the property, and its JSON Schema is `{}`.
/// Reaches the named type inside an optional, array or dictionary.
///
/// `SchemaSuite` can only generate values for the property from `examples`
/// (`@Codable(examples: [Payload(kind: "a", weight: 1)])`, values of the named
/// type); without them it says so and skips the cases that reach the property.
@attached(peer)
public macro Codable() = #externalMacro(module: "StoicMacrosPlugin", type: "CodableMacro")

/// ``Codable()``, with values of the named type for `SchemaSuite` to generate from.
@attached(peer)
public macro Codable<Element>(examples: [Element]) = #externalMacro(module: "StoicMacrosPlugin", type: "CodableMacro")

/// Marks the `JSONObject` property that keeps the keys the schema does not
/// declare and writes them back, so that an older release never destroys
/// what a newer one wrote.
@attached(peer)
public macro PreserveUnknownKeys() = #externalMacro(module: "StoicMacrosPlugin", type: "PreserveUnknownKeysMacro")

/// How a `Date` is written: `@DateFormat(.epochSeconds)`. RFC 3339 without
/// it. Reaches the `Date` inside an optional, array or dictionary.
@attached(peer)
public macro DateFormat(_ format: DateFormat) = #externalMacro(module: "StoicMacrosPlugin", type: "DateFormatMacro")

/// Which URLs are accepted: `@URLFormat(.relative)`. Absolute ones without it.
@attached(peer)
public macro URLFormat(_ format: URLFormat) = #externalMacro(module: "StoicMacrosPlugin", type: "URLFormatMacro")

/// How bytes are spelt: `@DataFormat(.base64url)`. Standard base64 without it.
@attached(peer)
public macro DataFormat(_ format: DataFormat) = #externalMacro(module: "StoicMacrosPlugin", type: "DataFormatMacro")

/// A named refinement: a checked type whose constraints are data.
///
///     @Refined(Double.self, .range(0.1...10), .finite)
///     enum ScrollSpeedRule {}
///     typealias ScrollSpeed = Refined<ScrollSpeedRule>
///
/// The macro writes `Base` and `constraints`, and the conformance to
/// `Refinement`; the constraints are the library's own, checked here for
/// what the macro can see.
@attached(member, names: named(Base), named(constraints))
@attached(extension, conformances: Refinement)
public macro Refined<Base: Sendable>(_ base: Base.Type, _ constraints: Constraint...) =
    #externalMacro(module: "StoicMacrosPlugin", type: "RefinedMacro")

// MARK: Constraints
//
// Each is the `Constraint` of the same name, written beside the property it
// is about. They apply to the innermost value (the `Int` of `[Int]?`),
// except `@Count` and `@Unique`, which are about the outermost array or
// dictionary.

/// A number within `bounds`: `@Range(200...4000)`.
@attached(peer)
public macro Range<Bounds: NumberBounds>(_ bounds: Bounds) = #externalMacro(module: "StoicMacrosPlugin", type: "RangeMacro")

/// A number strictly above `bound`.
@attached(peer)
public macro GreaterThan<Bound: NumericBound>(_ bound: Bound) = #externalMacro(module: "StoicMacrosPlugin", type: "GreaterThanMacro")

/// A number strictly below `bound`.
@attached(peer)
public macro LessThan<Bound: NumericBound>(_ bound: Bound) = #externalMacro(module: "StoicMacrosPlugin", type: "LessThanMacro")

/// A number that is a whole multiple of `step`.
@attached(peer)
public macro MultipleOf<Step: NumericBound>(_ step: Step) = #externalMacro(module: "StoicMacrosPlugin", type: "MultipleOfMacro")

/// A string whose length, in `unit`, is within `bounds`.
@attached(peer)
public macro Length<Bounds: CountBounds>(_ bounds: Bounds, unit: LengthUnit = .characters) =
    #externalMacro(module: "StoicMacrosPlugin", type: "LengthMacro")

/// A string matching the regular expression, found anywhere in it.
@attached(peer)
public macro Pattern(_ regex: String) = #externalMacro(module: "StoicMacrosPlugin", type: "PatternMacro")

/// An array with `bounds` elements, or a dictionary with `bounds` entries.
@attached(peer)
public macro Count<Bounds: CountBounds>(_ bounds: Bounds) = #externalMacro(module: "StoicMacrosPlugin", type: "CountMacro")

/// An array whose elements are pairwise different.
@attached(peer)
public macro Unique() = #externalMacro(module: "StoicMacrosPlugin", type: "UniqueMacro")
#endif

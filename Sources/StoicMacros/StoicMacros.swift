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
@attached(member, names: named(schema))
@attached(extension, conformances: Schematic)
public macro Schema(
    unknownKeys: UnknownKeyPolicy = .warn
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

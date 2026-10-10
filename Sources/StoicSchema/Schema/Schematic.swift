/// A type that knows its own schema.
///
/// This is how a refined type finds its base's schema, and how `@Schema`
/// (StoicMacros) refers to the schema of a stored property whose type it can
/// see only as a name: it writes `T.schema` and lets the compiler resolve it.
/// The built-in types conform, and so does a type `@Schema` declares; a type
/// with a schema declared by hand conforms in one line:
///
///     extension Settings: Schematic { static var schema: Schema<Settings> { Settings.schema } }
public protocol Schematic: Sendable {
    static var schema: Schema<Self> { get }
}

extension Bool: Schematic { public static var schema: Schema<Bool> { .bool } }
extension Int: Schematic { public static var schema: Schema<Int> { .int() } }
extension Int64: Schematic { public static var schema: Schema<Int64> { .int64() } }
extension UInt64: Schematic { public static var schema: Schema<UInt64> { .uint64() } }
extension Double: Schematic { public static var schema: Schema<Double> { .double() } }
extension String: Schematic { public static var schema: Schema<String> { .string() } }

extension Array: Schematic where Element: Schematic {
    public static var schema: Schema<[Element]> { .array(of: Element.schema) }
}

extension Dictionary: Schematic where Key == String, Value: Schematic {
    public static var schema: Schema<[String: Value]> { .dictionary(of: Value.schema) }
}

extension Optional: Schematic where Wrapped: Schematic {
    public static var schema: Schema<Wrapped?> { .optional(Wrapped.schema) }
}

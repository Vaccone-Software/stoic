/// A rule that turns a plain type into a checked one, stated as data.
///
/// This is "parse, don't validate" at the smallest scale. `Int` says nothing
/// about ports; `Refined<IntRange<1, 65_535>>` can only be built from an
/// integer that was checked, so every function that takes one may rely on
/// it and none of them re-checks. The check and the type are one thing.
///
/// A refinement is an empty type that names its rules, usually an `enum`:
///
///     enum ScrollSpeedRule: Refinement {
///         typealias Base = Double
///         static var constraints: [Constraint] { [.range(0.1...10), .finite] }
///     }
///     typealias ScrollSpeed = Refined<ScrollSpeedRule>
///
/// The constraints are the only source of truth: ``Refined`` checks a value
/// by interpreting them, the schema decodes by interpreting the same list,
/// and the JSON Schema export writes the same list into `minimum` and
/// `maximum`. Whole numbers need no type of their own, because
/// ``IntRange`` takes its bounds as generic parameters.
public protocol Refinement: Sendable {
    /// The type being narrowed.
    associatedtype Base: Sendable

    /// The rules a value of `Base` must satisfy. Interpreted against the
    /// value's JSON form, so a rule means the same for a Swift `Double`
    /// and for the number in a file.
    static var constraints: [Constraint] { get }

    /// How `Base` is written as JSON and read back. Automatic when `Base`
    /// is ``Schematic`` (every built-in type is); a base that is not
    /// supplies it.
    static var baseSchema: Schema<Base> { get }
}

extension Refinement where Base: Schematic {
    public static var baseSchema: Schema<Base> { Base.schema }
}

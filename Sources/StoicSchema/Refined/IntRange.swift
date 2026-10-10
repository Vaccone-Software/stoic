/// Integers from `lower` through `upper`, inclusive: the refinement for the
/// common case, with no boilerplate.
///
///     typealias Port = Refined<IntRange<1, 65_535>>
///
/// The bounds are integer generic parameters (SE-0452), so `Port` and
/// `Refined<IntRange<0, 100>>` are different types and the compiler will not
/// let one stand in for the other. Floating-point bounds cannot be generic
/// parameters; declare a ``Refinement`` for those.
///
/// `lower` greater than `upper` is a programmer error, and traps the first
/// time the type is used.
public enum IntRange<let lower: Int, let upper: Int>: Refinement {
    public typealias Base = Int

    public static var constraints: [Constraint] {
        [.range(lower...upper)]
    }
}

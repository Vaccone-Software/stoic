internal import StoicJSON

/// A value that has been checked against its refinement's constraints, and
/// carries the proof in its type.
///
/// There is no way to make one from an unchecked value except
/// ``init(_:)``, which throws, and ``init(clamping:)``, which says in its
/// name that it changes the value. The schema decoder builds them through a
/// private initialiser, after running the same constraints and recording
/// issues, so a decoded `Refined` is as trustworthy as one made by hand.
public struct Refined<R: Refinement>: Sendable {
    /// The checked value.
    public let value: R.Base

    /// Checks `raw` against ``Refinement/constraints``.
    ///
    /// Throws every constraint it violates (and, for a `Double`, a
    /// `not_finite` if it is NaN or infinite), with the root path.
    public init(_ raw: R.Base) throws(ValidationFailure) {
        let issues = Self.issues(in: raw)
        guard issues.isEmpty else { throw ValidationFailure(issues: issues) }
        value = raw
    }

    /// For the decoder, which has checked.
    init(trusted value: R.Base) {
        self.value = value
    }

    /// What is wrong with `raw`, empty if nothing.
    ///
    /// The value is turned into JSON first and the constraints run on that,
    /// which is the form every consumer of the constraints sees: one rule,
    /// one interpretation. Only errors refuse a value: a base that reads its
    /// own encoding with a warning (an open enumeration's unknown case) is
    /// still valid.
    static func issues(in raw: R.Base) -> [Issue] {
        var encoding = EncodeState(style: .full)
        let json = R.baseSchema.encoder(raw, &encoding) ?? .null
        guard encoding.problems.isEmpty else { return encoding.problems }
        var state = DecodeState(options: .strict)
        _ = R.baseSchema.decoder(json, &state)
        _ = state.apply(R.constraints, to: json)
        return state.issues.filter { $0.severity == .error }
    }
}

extension Refined: Equatable where R.Base: Equatable {}
extension Refined: Hashable where R.Base: Hashable {}
extension Refined: Comparable where R.Base: Comparable {
    public static func < (lhs: Refined, rhs: Refined) -> Bool { lhs.value < rhs.value }
}
extension Refined: CustomStringConvertible where R.Base: CustomStringConvertible {
    public var description: String { value.description }
}

extension Refined: Schematic {
    public static var schema: Schema<Refined<R>> { .refined(R.self) }
}

// MARK: - Clamping

extension Refined where R.Base: FixedWidthInteger {
    /// The value nearest `raw` that the refinement admits: the explicit
    /// lossy path, for a text field that must hold something while the
    /// user is still typing. Prefer ``init(_:)``, which tells the user.
    ///
    /// Only range constraints can be clamped to. If the nearest value
    /// still violates another constraint (a `multipleOf` the range
    /// bounds do not respect), the refinement cannot be clamped and this
    /// traps with the issues, because returning an unchecked value would
    /// break what a `Refined` promises.
    public init(clamping raw: R.Base) {
        var low = R.Base.min
        var high = R.Base.max
        for constraint in R.constraints {
            guard case .range(let range) = constraint.kind else { continue }
            if let bound = range.lower { low = max(low, Self.smallest(admitted: bound)) }
            if let bound = range.upper { high = min(high, Self.largest(admitted: bound)) }
        }
        precondition(low <= high, "\(R.self) admits no value")
        let clamped = min(max(raw, low), high)
        let issues = Self.issues(in: clamped)
        precondition(issues.isEmpty, "\(R.self) cannot be clamped: \(ValidationFailure(issues: issues))")
        self.init(trusted: clamped)
    }

    /// The least integer a lower bound admits.
    private static func smallest(admitted bound: NumberBound) -> R.Base {
        let number = bound.value
        if number.hasIntegralValue, let whole = Self.integer(number) {
            if bound.isInclusive { return whole }
            return whole == R.Base.max ? whole : whole + 1
        }
        let ceiling = (Double(number.lexeme) ?? 0).rounded(.up)
        return R.Base(exactly: ceiling) ?? (ceiling > 0 ? R.Base.max : R.Base.min)
    }

    /// The greatest integer an upper bound admits.
    private static func largest(admitted bound: NumberBound) -> R.Base {
        let number = bound.value
        if number.hasIntegralValue, let whole = Self.integer(number) {
            if bound.isInclusive { return whole }
            return whole == R.Base.min ? whole : whole - 1
        }
        let floor = (Double(number.lexeme) ?? 0).rounded(.down)
        return R.Base(exactly: floor) ?? (floor > 0 ? R.Base.max : R.Base.min)
    }

    private static func integer(_ number: JSONNumber) -> R.Base? {
        number.integralInt64.flatMap { R.Base(exactly: $0) } ?? number.integralUInt64.flatMap { R.Base(exactly: $0) }
    }
}

extension Refined where R.Base == Double {
    /// The value nearest `raw` that the refinement admits; see the integer
    /// form. An exclusive bound clamps to the nearest `Double` inside it.
    /// NaN clamps to the lower bound (or the upper, or zero) because it is
    /// not near anything.
    public init(clamping raw: Double) {
        var low = -Double.infinity
        var high = Double.infinity
        for constraint in R.constraints {
            guard case .range(let range) = constraint.kind else { continue }
            if let bound = range.lower, let value = Double(bound.value.lexeme) {
                low = max(low, bound.isInclusive ? value : value.nextUp)
            }
            if let bound = range.upper, let value = Double(bound.value.lexeme) {
                high = min(high, bound.isInclusive ? value : value.nextDown)
            }
        }
        precondition(low <= high, "\(R.self) admits no value")
        var clamped = raw
        if clamped.isNaN { clamped = low.isFinite ? low : (high.isFinite ? high : 0) }
        clamped = min(max(clamped, low), high)
        let issues = Self.issues(in: clamped)
        precondition(issues.isEmpty, "\(R.self) cannot be clamped: \(ValidationFailure(issues: issues))")
        self.init(trusted: clamped)
    }
}

// MARK: - Schema

extension Schema {
    /// The schema of a refined type: its base's schema, then its
    /// constraints. Decoding a value that satisfies the base but not the
    /// constraints is an issue at the value's path, exactly as for any other
    /// schema with constraints, and the export lists them as keywords.
    public static func refined<R: Refinement>(_ type: R.Type) -> Schema<Refined<R>> where Value == Refined<R> {
        Schema<Refined<R>>(
            node: R.baseSchema.node.adding(R.constraints),
            decoder: { json, state in
                guard let base = R.baseSchema.decoder(json, &state) else { return nil }
                guard state.apply(R.constraints, to: json) else { return nil }
                // The base may have changed what was sent (a Double rounds), and
                // the value carried is the one ``init(_:)`` must accept.
                var encoding = EncodeState(style: .full)
                if let received = R.baseSchema.encoder(base, &encoding),
                    !state.received(received, from: json, keeps: R.constraints)
                {
                    return nil
                }
                return Refined(trusted: base)
            },
            encoder: { refined, state in R.baseSchema.encoder(refined.value, &state) },
            absent: { R.baseSchema.absent().map { Refined(trusted: $0) } })
    }
}

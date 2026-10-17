internal import StoicJSON

/// A value that has been checked against its refinement's constraints, and
/// carries the proof in its type.
///
/// There is no way to make one from an unchecked value except
/// ``init(_:)``, which throws, and ``init(clamping:)-(R.Base)``, which says in its
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

/// A refinement whose every value has a nearest admitted one that arithmetic
/// can find, so `Refined.init(clamping:)` exists for it.
///
/// That is a refinement whose constraints are ranges (`.range`,
/// `.greaterThan`, `.lessThan`), at most one `.multipleOf` and `.finite`,
/// over an integer or a `Double`. A pattern, a list of allowed values or a
/// custom check has no "nearest" value, so a refinement with one of those
/// does not conform, and the compiler refuses `init(clamping:)` on it.
///
/// The conformance is a promise the compiler cannot check, since constraints
/// are values. A refinement that conforms and breaks it (or admits no value
/// at all) traps on the first `init(clamping:)`, whatever is passed: a
/// mistake in a declaration, found by the first test that clamps, never one
/// a user's input can reach. ``IntRange`` conforms; so does a refinement
/// written with `@Refined` whose constraints qualify.
public protocol ClampableRefinement: Refinement {}

extension IntRange: ClampableRefinement {}

/// What a ``ClampableRefinement`` clamps to: the bounds of every range and
/// at most one step. Traps if the refinement says anything else.
private struct Clamp {
    var lower: [NumberBound] = []
    var upper: [NumberBound] = []
    var step: JSONNumber?

    init(_ constraints: [Constraint], of refinement: Any.Type) {
        for constraint in constraints {
            switch constraint.kind {
            case .range(let range):
                if let bound = range.lower { lower.append(bound) }
                if let bound = range.upper { upper.append(bound) }
            case .multipleOf(let step):
                precondition(
                    self.step == nil && step > JSONNumber(0),
                    "\(refinement) is a ClampableRefinement with a second or non-positive multipleOf")
                self.step = step
            case .finite:
                continue
            case .length, .count, .pattern, .oneOf, .unique, .custom:
                preconditionFailure(
                    "\(refinement) is a ClampableRefinement but has \(constraint), which has no nearest admitted value")
            }
        }
    }
}

extension Refined where R: ClampableRefinement, R.Base: FixedWidthInteger {
    /// The admitted value nearest `raw`: the explicit lossy path, for a text
    /// field that must hold something while the user is still typing. Prefer
    /// ``init(_:)``, which tells the user.
    ///
    /// The value is clamped into every range, then moved to the nearest
    /// multiple of the step inside them (the lower one on a tie). It never
    /// traps on `raw`; see ``ClampableRefinement`` for the declaration
    /// mistakes it traps on, whatever `raw` is.
    public init(clamping raw: R.Base) {
        let clamp = Clamp(R.constraints, of: R.self)
        var low = R.Base.min
        var high = R.Base.max
        for bound in clamp.lower { low = max(low, Self.smallest(admitted: bound)) }
        for bound in clamp.upper { high = min(high, Self.largest(admitted: bound)) }
        precondition(low <= high, "\(R.self) admits no value")
        var candidates = [min(max(raw, low), high)]
        if let step = clamp.step {
            guard let unit = Self.integerUnit(of: step) else {
                preconditionFailure("\(R.self) admits no value: no integer of \(R.Base.self) is a multiple of \(step)")
            }
            // Whether any multiple lies in the range decides, for every input
            // alike, whether the refinement admits a value.
            precondition(!Self.multiples(of: unit, near: low, within: low...high).isEmpty, "\(R.self) admits no value")
            candidates = Self.multiples(of: unit, near: candidates[0], within: low...high)
        }
        guard let found = candidates.first(where: { Self.issues(in: $0).isEmpty }) else {
            preconditionFailure("\(R.self) cannot be clamped: \(ValidationFailure(issues: Self.issues(in: candidates[0])))")
        }
        self.init(trusted: found)
    }

    /// The least integer a lower bound admits.
    private static func smallest(admitted bound: NumberBound) -> R.Base {
        let number = bound.value
        if number.hasIntegralValue, let whole = Self.integer(number) {
            if bound.isInclusive { return whole }
            return whole == R.Base.max ? whole : whole + 1
        }
        let ceiling = (number.double ?? 0).rounded(.up)
        return R.Base(exactly: ceiling) ?? (ceiling > 0 ? R.Base.max : R.Base.min)
    }

    /// The greatest integer an upper bound admits.
    private static func largest(admitted bound: NumberBound) -> R.Base {
        let number = bound.value
        if number.hasIntegralValue, let whole = Self.integer(number) {
            if bound.isInclusive { return whole }
            return whole == R.Base.min ? whole : whole - 1
        }
        let floor = (number.double ?? 0).rounded(.down)
        return R.Base(exactly: floor) ?? (floor > 0 ? R.Base.max : R.Base.min)
    }

    private static func integer(_ number: JSONNumber) -> R.Base? {
        number.integralInt64.flatMap { R.Base(exactly: $0) } ?? number.integralUInt64.flatMap { R.Base(exactly: $0) }
    }

    /// The least positive integer that is a multiple of `step`: `step` when
    /// it is whole, else the numerator of `step` in lowest terms (the
    /// integers that are multiples of 2.5 are those of 5). `nil` if that
    /// does not fit `R.Base`.
    private static func integerUnit(of step: JSONNumber) -> R.Base? {
        guard let exact = ExactDecimal(step) else { return nil }
        var numerator = exact.coefficient
        var denominator: UInt128 = 1
        for _ in 0..<abs(exact.exponent) {
            if exact.exponent > 0 {
                let (next, overflow) = numerator.multipliedReportingOverflow(by: 10)
                if overflow { return nil }
                numerator = next
            } else {
                let (next, overflow) = denominator.multipliedReportingOverflow(by: 10)
                if overflow { return nil }
                denominator = next
            }
        }
        var (a, b) = (numerator, denominator)
        while b != 0 { (a, b) = (b, a % b) }
        return R.Base(exactly: numerator / a)
    }

    /// The multiples of `unit` in `range` beside `value` (the nearest below
    /// it and above it), nearest first, the lower one on a tie.
    private static func multiples(of unit: R.Base, near value: R.Base, within range: ClosedRange<R.Base>) -> [R.Base] {
        let truncated = value - value % unit
        var found: [R.Base] = []
        for offset in [-1, 0, 1] {
            let shift = offset < 0 ? truncated.subtractingReportingOverflow(unit) : truncated.addingReportingOverflow(offset == 0 ? 0 : unit)
            if !shift.overflow, range.contains(shift.partialValue) { found.append(shift.partialValue) }
        }
        func distance(_ candidate: R.Base) -> R.Base { candidate >= value ? candidate - value : value - candidate }
        return found.sorted { distance($0) < distance($1) }
    }
}

extension Refined where R: ClampableRefinement, R.Base == Double {
    /// The admitted value nearest `raw`; see the integer form. An exclusive
    /// bound clamps to the nearest `Double` inside it, and a step to the
    /// nearest multiple built from its decimal digits (`0.3`, never
    /// `0.30000000000000004`). NaN clamps to the lower bound (or the upper,
    /// or zero) because it is not near anything.
    public init(clamping raw: Double) {
        let clamp = Clamp(R.constraints, of: R.self)
        var low = -Double.infinity
        var high = Double.infinity
        for bound in clamp.lower {
            if let value = bound.value.double { low = max(low, bound.isInclusive ? value : value.nextUp) }
        }
        for bound in clamp.upper {
            if let value = bound.value.double { high = min(high, bound.isInclusive ? value : value.nextDown) }
        }
        precondition(low <= high, "\(R.self) admits no value")
        var clamped = raw
        if clamped.isNaN { clamped = low.isFinite ? low : (high.isFinite ? high : 0) }
        clamped = min(max(clamped, low), high)
        var candidates = [clamped]
        if let step = clamp.step {
            // Beside the value first; then the multiples just inside each
            // bound, for a value whose neighbours fall outside the range.
            candidates = Self.multiples(of: step, near: clamped) + Self.multiples(of: step, near: low)
                + Self.multiples(of: step, near: high)
            candidates = candidates.filter { (low...high).contains($0) }
        }
        guard let found = candidates.first(where: { Self.issues(in: $0).isEmpty }) else {
            preconditionFailure("\(R.self) admits no value near \(clamped) that arithmetic can reach")
        }
        self.init(trusted: found)
    }

    /// Multiples of `step` beside `value`, nearest first, each the `Double`
    /// of its exact decimal (`3 × 0.1` is read from `3e-1`), so the checker,
    /// which divides digits, agrees that it is one.
    private static func multiples(of step: JSONNumber, near value: Double) -> [Double] {
        guard let exact = ExactDecimal(step), let size = step.double, value.isFinite else { return [] }
        let nearest = (value / size).rounded()
        guard nearest.magnitude < 1e15 else { return [] }
        var found: [Double] = []
        for offset in [0.0, -1, 1] {
            let (product, overflow) = Int128(Int64(nearest + offset)).multipliedReportingOverflow(by: Int128(exact.coefficient))
            if !overflow, let multiple = Double("\(product)e\(exact.exponent)") { found.append(multiple) }
        }
        return found.sorted { abs($0 - value) < abs($1 - value) }
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

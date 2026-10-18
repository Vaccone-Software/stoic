public import StoicJSON

extension Schema where Value == Double {
    /// This number schema, repairing a value outside its `.range` to the
    /// nearest bound instead of refusing it.
    ///
    ///     Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)).clampingToRange())
    ///
    /// For a setting a person types, where 99999 means "as fast as it goes"
    /// and an error that discards it (or, under `.lenient`, a repair to the
    /// default) is the wrong answer. A value outside a range becomes the
    /// bound it is nearest to, and the decode says so with an
    /// ``IssueCode/outOfRange`` **warning** at the field, whose `repair`
    /// parameter names the bound it became (`99999 is out of range, expected
    /// a number between 200 and 4000; clamped to 4000`). It is a warning in
    /// every mode, `.strict` included: clamping is declared by the schema,
    /// not granted by the caller, so a schema that wants a wire format
    /// refused simply does not ask for it.
    ///
    /// Only an inclusive bound has a nearest value. Where the schema has
    /// several ranges the value is moved into each in turn; an exclusive
    /// bound (`.greaterThan(0)`), and every other constraint (`.multipleOf`,
    /// `.custom`), is checked afterwards and still refuses what it refuses.
    /// A value that is not a number is a `type_mismatch` as before.
    ///
    /// The JSON Schema export is unchanged (`minimum` and `maximum`, which a
    /// validator enforces, so an editor flags 99999) and carries
    /// `x-stoic-clamp`; generators know that a document outside the range is
    /// tolerated, not refused. Traps if the schema has no inclusive range
    /// bound: there would be nothing to clamp to.
    public func clampingToRange() -> Schema<Double> {
        clamped()
    }
}

extension Schema where Value: FixedWidthInteger {
    /// This integer schema, repairing a value outside its `.range` to the
    /// nearest bound instead of refusing it.
    ///
    /// See `clampingToRange()` on a `Double` schema: the behaviour is the
    /// same, decided on the digits sent, so a number too large for the
    /// integer type, which is `out_of_range` and never wrapped, is clamped
    /// when the schema has a bound to clamp it to.
    public func clampingToRange() -> Schema<Value> {
        clamped()
    }
}

extension Schema {
    fileprivate func clamped() -> Schema<Value> {
        let base = node
        let ranges: [NumberRange] = base.constraints.compactMap {
            if case .range(let range) = $0.kind { range } else { nil }
        }
        let hasInclusiveBound = ranges.contains { $0.lower?.isInclusive == true || $0.upper?.isInclusive == true }
        precondition(hasInclusiveBound, "clampingToRange() needs a schema with a .range that has an inclusive bound to clamp to")
        var transform = TransformNode(
            base: base, name: "clamped number", description: base.expectation,
            keywords: ["x-stoic-clamp": true], isAnnotated: false)
        transform.isTransparent = true
        transform.clampsToRange = true
        let inner = self
        return Schema(
            node: .transformed(transform),
            decoder: { json, state in
                guard case .number(let number) = json, let clamp = ClampedNumber(number, in: ranges) else {
                    return inner.decoder(json, &state)
                }
                let violation = state.checker.violations(
                    of: ranges.map { Constraint(.range($0)) }, in: json
                ).first { $0.code == .outOfRange }
                var parameters = violation?.parameters ?? JSONObject()
                parameters["repair"] = .string("clamped to \(clamp.value.lexeme)")
                parameters["clampedTo"] = .number(clamp.value)
                state.report(
                    .outOfRange, severity: .warning, parameters: parameters,
                    expected: violation?.expected ?? base.expectation, actual: number.lexeme)
                return inner.decoder(.number(clamp.value), &state)
            },
            encoder: inner.encoder,
            absent: inner.absent)
    }
}

/// A number moved into the inclusive bounds of some ranges.
struct ClampedNumber {
    var value: JSONNumber

    /// `nil` if `number` is already inside every inclusive bound.
    init?(_ number: JSONNumber, in ranges: [NumberRange]) {
        var current = number
        var moved = false
        for range in ranges {
            if let lower = range.lower, lower.isInclusive, current < lower.value {
                current = lower.value
                moved = true
            }
            if let upper = range.upper, upper.isInclusive, current > upper.value {
                current = upper.value
                moved = true
            }
        }
        guard moved else { return nil }
        value = current
    }
}

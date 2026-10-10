public import StoicJSON

// MARK: - Booleans, numbers, strings

extension Schema where Value == Bool {
    /// `true` or `false`, and nothing else: not `"true"`, not `1`.
    public static var bool: Schema<Bool> {
        Schema(
            node: .boolean,
            decoder: { json, state in
                guard case .bool(let value) = json else {
                    var hints: [String] = []
                    if case .string(let text) = json, text == "true" || text == "false" { hints = [text] }
                    state.typeMismatch(expected: "a boolean", found: json, hints: hints)
                    return nil
                }
                return value
            },
            encoder: { value, _ in .bool(value) })
    }
}

extension Schema where Value == Int {
    /// A whole number that fits an `Int`, written as an integer.
    ///
    /// The number must be spelt as an integer: `1.0` and `1e2` are refused
    /// under `.strict`, because a wire format that sends `1.0` for a count
    /// has a bug the receiver should hear about, and accepted with a warning
    /// under `.lenient`. An integer outside `Int` is `out_of_range`, never
    /// wrapped or clamped.
    public static func int(_ constraints: Constraint...) -> Schema<Int> {
        .integer(Int.self, constraints)
    }
}

extension Schema where Value == Int64 {
    /// Like ``int(_:)``, for an `Int64`.
    public static func int64(_ constraints: Constraint...) -> Schema<Int64> {
        .integer(Int64.self, constraints)
    }
}

extension Schema where Value == UInt64 {
    /// Like ``int(_:)``, for a `UInt64`. A negative number is `out_of_range`.
    public static func uint64(_ constraints: Constraint...) -> Schema<UInt64> {
        .integer(UInt64.self, constraints)
    }
}

extension Schema {
    /// An integer of any fixed width: the engine behind ``int(_:)``,
    /// ``int64(_:)`` and ``uint64(_:)``, public for `Int32`, `UInt8` and the
    /// rest.
    public static func integer<I: FixedWidthInteger & Sendable>(
        _ type: I.Type,
        _ constraints: [Constraint] = []
    ) -> Schema<I> {
        let integerType = IntegerType(I.self)
        return Schema<I>(
            node: .integer(integerType, constraints: constraints),
            decoder: { json, state in
                guard case .number(let number) = json else {
                    var hints: [String] = []
                    if case .string(let text) = json, JSONNumber(lexeme: text) != nil { hints = [text] }
                    state.typeMismatch(expected: "an integer", found: json, hints: hints)
                    return nil
                }
                var exact = number.isInteger
                if !exact {
                    guard number.hasIntegralValue else {
                        state.typeMismatch(expected: "an integer", found: json)
                        return nil
                    }
                    // 1.0 or 1e2: a whole number in a spelling that says "not
                    // an integer".
                    guard state.isLenient else {
                        let canonical = number.integralInt64.map { String($0) } ?? number.integralUInt64.map { String($0) }
                        state.typeMismatch(expected: "an integer", found: json, hints: canonical.map { [$0] } ?? [])
                        return nil
                    }
                    exact = false
                }
                let wide = exact ? number.int64.flatMap { I(exactly: $0) } : number.integralInt64.flatMap { I(exactly: $0) }
                let unsigned = exact ? number.uint64.flatMap { I(exactly: $0) } : number.integralUInt64.flatMap { I(exactly: $0) }
                guard let value = wide ?? unsigned else {
                    state.report(.outOfRange, expected: integerType.expectation, actual: number.lexeme)
                    return nil
                }
                if !exact {
                    state.report(
                        .typeMismatch, severity: .warning, parameters: ["found": .string("number")],
                        expected: "an integer", actual: number.lexeme)
                }
                guard state.apply(constraints, to: json) else { return nil }
                return value
            },
            encoder: { value, _ in .number(JSONNumber(value)) })
    }
}

extension Schema where Value == Double {
    /// A finite `Double`.
    ///
    /// JSON has no NaN or infinity, and a number too large for a `Double`
    /// (`1e400`) is `not_finite` rather than silently becoming one. An
    /// integer the `Double` cannot hold exactly (above 2^53) is
    /// `precision_loss`: `9007199254740993` would read back as
    /// `9007199254740992`, and a validator that lets that pass has changed
    /// the sender's number. Use ``int64(_:)`` for identifiers.
    public static func double(_ constraints: Constraint...) -> Schema<Double> {
        Schema<Double>(
            node: .number(constraints: constraints),
            decoder: { json, state in
                guard case .number(let number) = json else {
                    var hints: [String] = []
                    if case .string(let text) = json, JSONNumber(lexeme: text) != nil { hints = [text] }
                    state.typeMismatch(expected: "a number", found: json, hints: hints)
                    return nil
                }
                guard let value = number.double else {
                    state.report(.notFinite, expected: "a finite number", actual: number.lexeme)
                    return nil
                }
                if number.hasIntegralValue, number.losesDigitsAsDouble {
                    state.report(
                        .precisionLoss, expected: "an integer a Double holds exactly (up to 2^53)",
                        actual: number.lexeme)
                    return nil
                }
                guard state.apply(constraints, to: json) else { return nil }
                return value
            },
            encoder: { value, state in
                guard let number = JSONNumber(value) else {
                    state.notFinite(value)
                    return .null
                }
                return .number(number)
            })
    }
}

extension Schema where Value == String {
    /// A string. The constraints are usually `.length` and `.pattern`.
    public static func string(_ constraints: Constraint...) -> Schema<String> {
        Schema<String>(
            node: .string(constraints: constraints),
            decoder: { json, state in
                guard case .string(let value) = json else {
                    var hints: [String] = []
                    switch json {
                    case .number, .bool: hints = [json.encodedString(style: .compact).quotedAsJSONString]
                    default: break
                    }
                    state.typeMismatch(expected: "a string", found: json, hints: hints)
                    return nil
                }
                guard state.apply(constraints, to: json) else { return nil }
                return value
            },
            encoder: { value, _ in .string(value) })
    }
}

extension JSONNumber {
    /// Whether a whole number is changed by passing through a `Double`.
    ///
    /// Integers that fit 64 bits are judged exactly, in binary: 2^62 is
    /// held exactly and 2^53 + 1 is not. A whole number too big for that
    /// (`1e22`, or thirty digits) is judged by whether its shortest decimal
    /// survives the trip, which is what its writer would call "the same
    /// number".
    fileprivate var losesDigitsAsDouble: Bool {
        if let value = integralInt64 { return Double(exactly: value) == nil }
        if let value = integralUInt64 { return Double(exactly: value) == nil }
        return !isExactlyRepresentableAsDouble
    }
}

extension String {
    fileprivate var quotedAsJSONString: String {
        JSONValue.string(self).encodedString(style: .compact)
    }
}

// MARK: - Any JSON

extension Schema where Value == JSONValue {
    /// Any JSON value, passed through untouched: for a field whose shape
    /// the app does not own (a plug-in's settings, a payload to forward).
    public static func json(_ constraints: Constraint...) -> Schema<JSONValue> {
        Schema<JSONValue>(
            node: .json(constraints: constraints),
            decoder: { json, state in
                guard state.apply(constraints, to: json) else { return nil }
                return json
            },
            encoder: { value, _ in value })
    }
}

// MARK: - Enumerations

extension Schema where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// A string that names a case of `type`, by raw value.
    ///
    /// A value that names no case is `not_one_of`, listing the cases and
    /// suggesting the nearest by spelling: `"Dark"` gets "did you mean
    /// `dark`?". Matching is by Unicode scalars, as JSON compares strings, not
    /// by Swift's canonical equivalence: a case named `"é"` is not matched by
    /// `"e\u{301}"`. The suggestion is the courtesy.
    public static func enumeration(_ type: Value.Type) -> Schema<Value> {
        let cases = Value.allCases.map(\.rawValue)
        var byName: [ExactKey: Value] = [:]
        for value in Value.allCases { byName[ExactKey(value.rawValue)] = value }
        let lookup = byName
        let name = String(describing: Value.self)
        let expectation = "one of " + cases.map { "\"\($0)\"" }.joined(separator: ", ")
        return Schema<Value>(
            node: .enumeration(name: name, cases: cases),
            decoder: { json, state in
                guard case .string(let text) = json else {
                    state.typeMismatch(expected: expectation, found: json)
                    return nil
                }
                guard let value = lookup[ExactKey(text)] else {
                    state.report(
                        .notOneOf, expected: expectation, actual: json.briefDescription,
                        suggestions: Suggestions.nearest(to: text, among: cases))
                    return nil
                }
                return value
            },
            encoder: { value, _ in .string(value.rawValue) })
    }
}

extension Schema where Value: RawRepresentable & CaseIterable, Value.RawValue == Int {
    /// An integer that is the raw value of a case of `type`: a priority
    /// level, a protocol code, anything a wire format numbers.
    ///
    /// The number is read as an `Int` first (so `1.5` and `1e2` are
    /// refused as for any integer), then looked up. One that is no case's
    /// raw value is `not_one_of`, listing the raw values. The cases'
    /// Swift names are kept in the node for documentation and UI, never
    /// on the wire.
    public static func enumeration(_ type: Value.Type) -> Schema<Value> {
        let cases = Value.allCases.map { IntegerCase(name: String(describing: $0), value: $0.rawValue) }
        var byRaw: [Int: Value] = [:]
        for value in Value.allCases { byRaw[value.rawValue] = value }
        let lookup = byRaw
        let expectation = "one of " + cases.map { String($0.value) }.joined(separator: ", ")
        let integer = Schema<Int>.int()
        return Schema<Value>(
            node: .integerEnumeration(name: String(describing: Value.self), cases: cases),
            decoder: { json, state in
                guard let raw = integer.decoder(json, &state) else { return nil }
                guard let value = lookup[raw] else {
                    state.report(.notOneOf, expected: expectation, actual: json.briefDescription)
                    return nil
                }
                return value
            },
            encoder: { value, _ in .number(JSONNumber(value.rawValue)) })
    }
}

// MARK: - Optional

extension Schema {
    /// A value that may be `nil`.
    ///
    /// Three situations are kept apart, because conflating them is how
    /// configuration silently changes meaning:
    ///
    /// - *Absent.* The key is not there. Inside an object that has a
    ///   default for the field, the default applies (so a field whose
    ///   default is `nil` stays `nil`). In an object without defaults,
    ///   an optional field is `nil`.
    /// - *Null*, when `nullable` is true: `null` is the spelling of `nil`,
    ///   and `nil` is written as `null`.
    /// - *Null*, when `nullable` is false (the default): not a value.
    ///   `null` is a `type_mismatch` like any other wrong kind, and `nil`
    ///   is written by leaving the key out. Choose `nullable: true` for a
    ///   field whose default is not `nil` and which must be able to say
    ///   "none" explicitly, since leaving it out would bring the default
    ///   back.
    ///
    /// An optional element of an array has no key to leave out, so it is
    /// written as `null`; declare such arrays `nullable: true`.
    public static func optional<Wrapped: Sendable>(
        _ wrapped: Schema<Wrapped>,
        nullable: Bool = false
    ) -> Schema<Wrapped?> where Value == Wrapped? {
        Schema<Wrapped?>(
            node: .optional(wrapped.node, nullable: nullable),
            decoder: { json, state in
                if nullable, case .null = json { return .some(nil) }
                guard let inner = wrapped.decoder(json, &state) else { return nil }
                return .some(.some(inner))
            },
            encoder: { value, state in
                guard let inner = value else { return nullable ? .null : nil }
                return wrapped.encoder(inner, &state)
            },
            absent: { .some(nil) })
    }
}

// MARK: - Recursion

extension Schema {
    /// A schema defined in terms of itself, for recursive types:
    ///
    ///     struct Node: Sendable {
    ///         var children: [Node] = []
    ///         static let schema = Schema.object(Node.self, default: Node()) {
    ///             Field("children", \.children, .array(of: .lazy { Node.schema }))
    ///         }
    ///     }
    ///
    /// `make` runs when a value is decoded or encoded, never while the
    /// schema is being declared, which is what lets it mention the schema
    /// that is still being initialised. `name` identifies the schema in the
    /// JSON Schema export, where it becomes a `$defs` entry; it defaults to
    /// the Swift type's name, so two different recursive schemas for one
    /// type must be named apart.
    ///
    /// A document nested deeper than the parser's `maxDepth` never reaches
    /// the schema, so recursion is bounded by that limit.
    public static func lazy(
        _ name: String? = nil,
        _ make: @escaping @Sendable () -> Schema<Value>
    ) -> Schema<Value> {
        Schema(
            node: .lazy(name: name ?? String(describing: Value.self), resolve: { make().node }),
            decoder: { json, state in make().decoder(json, &state) },
            encoder: { value, state in make().encoder(value, &state) },
            absent: { make().absent() })
    }
}

internal import StoicJSON

// Enumerations that a server may extend.
//
// A closed enumeration is the right default: a value that names no case is
// a mistake worth reporting. A client of someone else's API cannot afford
// it. The server adds a case in a release the client has not shipped yet,
// and every response that mentions it would fail to decode, including the
// ones that are otherwise fine. So an enumeration may name one case as the
// answer to "I do not know that one". Decoding then succeeds, with a
// warning that says which value was read as it, and the warning is the
// only trace: nothing is kept of the value unless the case carries it.

extension Schema {
    /// A string enumeration that reads any string it does not know as one
    /// case of its own, with an ``IssueCode/unknownCase`` warning.
    ///
    ///     enum Status: Sendable {
    ///         case active, suspended
    ///         case unknown(String)
    ///     }
    ///
    ///     static let schema = Schema.openEnumeration(
    ///         Status.self, cases: ["active", "suspended"], fallback: "unknown",
    ///         read: { switch $0 { case "active": .active; case "suspended": .suspended; default: .unknown($0) } },
    ///         write: { switch $0 { case .active: "active"; case .suspended: "suspended"; case .unknown(let raw): raw } })
    ///
    /// A value that is not a string is still a `type_mismatch`: only a
    /// string that names no known case is tolerated. The unknown case writes
    /// what it holds, so a value that passes through the client comes out
    /// as it went in.
    ///
    /// - Parameters:
    ///   - cases: The strings that are known, in documentation order.
    ///   - fallback: The unknown case's name, for the warning.
    ///   - read: Makes the value for any string, known or not.
    ///   - write: The string a value is written as.
    public static func openEnumeration(
        _ type: Value.Type,
        cases: [String],
        fallback: String = "unknown",
        read: @escaping @Sendable (String) -> Value,
        write: @escaping @Sendable (Value) -> String
    ) -> Schema<Value> {
        let known = Set(cases.map { ExactKey($0) })
        let expectation = "one of " + cases.map { "\"\($0)\"" }.joined(separator: ", ") + ", or any other string"
        let node = TransformNode(
            base: .string(constraints: []), name: String(describing: Value.self),
            description: expectation + ", read as `\(fallback)`",
            examples: cases.map { .string($0) },
            keywords: ["examples": .array(cases.map { .string($0) })])
        return Schema(
            node: .transformed(node),
            decoder: { json, state in
                guard case .string(let text) = json else {
                    state.typeMismatch(expected: expectation, found: json)
                    return nil
                }
                if !known.contains(ExactKey(text)) {
                    state.report(
                        .unknownCase, severity: .warning, parameters: ["fallback": .string(fallback)],
                        expected: expectation, actual: json.briefDescription,
                        suggestions: Suggestions.nearest(to: text, among: cases))
                }
                return read(text)
            },
            encoder: { value, _ in .string(write(value)) })
    }
}

extension Schema where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// A string enumeration with a case for the values it does not know.
    /// Any string that is not the raw value of a case is read as
    /// `unknownCase`, with an ``IssueCode/unknownCase`` warning; see
    /// ``openEnumeration(_:cases:fallback:read:write:)``.
    ///
    ///     enum Status: String, CaseIterable, Sendable { case active, suspended, unknown }
    ///     let schema = Schema.enumeration(Status.self, unknownCase: .unknown)
    ///
    /// The unknown case is a case like another: its own raw value is known,
    /// and it is written as that.
    public static func enumeration(_ type: Value.Type, unknownCase: Value) -> Schema<Value> {
        var byName: [ExactKey: Value] = [:]
        for value in Value.allCases { byName[ExactKey(value.rawValue)] = value }
        let lookup = byName
        return .openEnumeration(
            type, cases: Value.allCases.map(\.rawValue), fallback: String(describing: unknownCase),
            read: { lookup[ExactKey($0)] ?? unknownCase }, write: { $0.rawValue })
    }
}

extension Schema where Value: RawRepresentable & CaseIterable, Value.RawValue == Int {
    /// An integer enumeration with a case for the values it does not know:
    /// any integer that is no case's raw value is read as `unknownCase`,
    /// with an ``IssueCode/unknownCase`` warning. A value that is not an
    /// integer is still refused.
    ///
    /// The unknown case is written as its own raw value, so the number that
    /// was read is not kept.
    public static func enumeration(_ type: Value.Type, unknownCase: Value) -> Schema<Value> {
        let cases = Value.allCases.map { IntegerCase(name: String(describing: $0), value: $0.rawValue) }
        var byRaw: [Int: Value] = [:]
        for value in Value.allCases { byRaw[value.rawValue] = value }
        let lookup = byRaw
        let fallback = String(describing: unknownCase)
        let expectation = "one of " + cases.map { String($0.value) }.joined(separator: ", ") + ", or any other integer"
        let integer = Schema<Int>.int()
        let node = TransformNode(
            base: .integer(.int, constraints: []), name: String(describing: Value.self),
            description: expectation + ", read as `\(fallback)`",
            examples: cases.map { .number(JSONNumber($0.value)) },
            keywords: ["examples": .array(cases.map { .number(JSONNumber($0.value)) })])
        return Schema(
            node: .transformed(node),
            decoder: { json, state in
                guard let raw = integer.decoder(json, &state) else { return nil }
                guard let value = lookup[raw] else {
                    state.report(
                        .unknownCase, severity: .warning, parameters: ["fallback": .string(fallback)],
                        expected: expectation, actual: json.briefDescription)
                    return unknownCase
                }
                return value
            },
            encoder: { value, _ in .number(JSONNumber(value.rawValue)) })
    }
}

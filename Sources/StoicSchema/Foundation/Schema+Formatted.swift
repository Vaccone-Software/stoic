internal import StoicJSON

/// Why a string is not in the format a leaf schema reads: what is wrong, if
/// it can be said, and what was probably meant.
struct FormatFailure: Error {
    /// A clause about the value: `there is no month 13`. `nil` when there
    /// is nothing better to say than the expectation.
    var message: String?
    var suggestions: [String] = []

    init(_ message: String? = nil, suggestions: [String] = []) {
        self.message = message
        self.suggestions = suggestions
    }
}

extension Schema {
    /// A leaf read from a JSON string in a named format: a date-time, a URL,
    /// a UUID, base64.
    ///
    /// The node is a ``SchemaNode/transformed(_:)`` over a plain string, so
    /// every tool that knows transforms knows these: the export writes
    /// `"type": "string"` and the `format`, the generator draws from the
    /// examples, and the mutator offers the counterexamples, each of which
    /// must raise exactly one ``IssueCode/invalidFormat``.
    ///
    /// A string that does not parse is one `invalid_format` issue, with the
    /// format and (outside a secret, since it is derived from the value) the
    /// reason in its parameters. `print` returns `nil` for a Swift value the
    /// format cannot spell (a date in the year 10000), which `validate`
    /// reports and `encode` writes as `null`.
    static func formatted(
        name: String,
        format: String?,
        describe: String,
        keywords: JSONObject = JSONObject(),
        examples: [String],
        counterexamples: [String],
        parse: @escaping @Sendable (String) -> Result<Value, FormatFailure>,
        print: @escaping @Sendable (Value) -> String?
    ) -> Schema<Value> {
        let formatName = format ?? name
        let node = TransformNode(
            base: .string(constraints: []), name: name, description: describe,
            examples: examples.map { .string($0) }, format: format, keywords: keywords,
            counterexamples: counterexamples.map { TransformNode.Counterexample(.string($0), code: .invalidFormat) })
        return Schema(
            node: .transformed(node),
            decoder: { json, state in
                guard case .string(let text) = json else {
                    state.typeMismatch(expected: describe, found: json)
                    return nil
                }
                switch parse(text) {
                case .success(let value):
                    return value
                case .failure(let failure):
                    var parameters: JSONObject = ["format": .string(formatName)]
                    // The reason is about the value, so a secret keeps it.
                    if let message = failure.message, state.secretDepth == 0 {
                        parameters["message"] = .string(message)
                    }
                    state.report(
                        .invalidFormat, parameters: parameters, expected: describe, actual: json.briefDescription,
                        suggestions: failure.suggestions)
                    return nil
                }
            },
            encoder: { value, state in
                guard let text = print(value) else {
                    state.unrepresentable(expected: describe)
                    return .null
                }
                return .string(text)
            })
    }
}

extension EncodeState {
    /// A Swift value that the schema's wire format has no spelling for.
    mutating func unrepresentable(expected: String, actual: String? = nil) {
        problems.append(Issue(path: path, code: .outOfRange, expected: expected, actual: actual))
    }
}

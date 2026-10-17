public import StoicJSON

/// Why a conversion refused a value that already had the right shape.
///
/// Thrown from the `decode` closure of ``Schema/transform(base:decode:encode:describe:name:examples:format:)``,
/// which turns it into an ``Issue`` at the value's path. It carries the
/// parts of an issue a conversion can know: what is wrong, what would have
/// been accepted, and what was probably meant.
public struct TransformFailure: Error, Sendable, Hashable {
    /// What is wrong, as a short clause that follows the value: `is not a
    /// calendar date`. It becomes the issue's `message` parameter.
    public var message: String
    /// The kind of problem. ``IssueCode/invalidValue`` unless the failure
    /// is better described by a code of its own.
    public var code: IssueCode
    /// What would have been accepted; the transform's own description if
    /// left out.
    public var expected: String?
    /// Likely intended values, best first.
    public var suggestions: [String]

    public init(
        _ message: String,
        code: IssueCode = .invalidValue,
        expected: String? = nil,
        suggestions: [String] = []
    ) {
        self.message = message
        self.code = code
        self.expected = expected
        self.suggestions = suggestions
    }
}

extension Schema {
    /// A schema for a type of your own, defined by how it is spelled on the
    /// wire and how to convert to and from that spelling.
    ///
    ///     struct Timestamp: Sendable, Equatable { var secondsSinceEpoch: Int64 }
    ///
    ///     extension Timestamp {
    ///         static let schema: Schema<Timestamp> = .transform(
    ///             base: .string(.length(20...20), .pattern(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#)),
    ///             decode: { text throws(TransformFailure) in try Timestamp(parsing: text) },
    ///             encode: { $0.rfc3339 },
    ///             describe: "an RFC 3339 UTC timestamp",
    ///             examples: [Timestamp(secondsSinceEpoch: 0)])
    ///     }
    ///
    /// Decoding reads the base schema first, so its constraints hold (and
    /// its issues are reported, all of them) before `decode` runs;
    /// `decode` then only has the rules the base cannot state. A throw from
    /// it becomes one ``IssueCode/invalidValue`` issue at the value's path,
    /// with the failure's message, expectation and suggestions. Encoding is
    /// `encode` followed by the base's encoder, so the two stay inverse as
    /// long as `encode` is (SchemaSuite checks that they are).
    ///
    /// **What the tree says.** The node is the base's node wrapped in a
    /// ``TransformNode``: the JSON Schema export writes the base and adds
    /// `x-stoic-transform` with `describe`, because a conversion written as
    /// code cannot be exported as keywords. Put whatever the base can
    /// express *in* the base (a pattern, a length) so that the export, the
    /// generators and the UI see it; the closure is for the rest.
    ///
    /// **Examples.** A generator cannot look inside a closure. `examples`
    /// are values the conversion is known to accept; the generator draws
    /// from their encodings. Without them it falls back to base values,
    /// which the conversion may refuse.
    ///
    /// - Parameters:
    ///   - base: The wire spelling.
    ///   - decode: The conversion from the base value. Must not have side
    ///     effects: a schema is declared once and used from anywhere.
    ///   - encode: The conversion back. Total, because every `Value` must be
    ///     writable.
    ///   - describe: The accepted values in words, an issue's `expected`.
    ///   - name: The type's name in the export; defaults to `Value`'s.
    ///   - examples: Values that are known to be accepted.
    ///   - format: The JSON Schema `format` of the wire value, if it has one
    ///     (`date-time`, `email`), for the export.
    public static func transform<Base: Sendable>(
        base: Schema<Base>,
        decode: @escaping @Sendable (Base) throws(TransformFailure) -> Value,
        encode: @escaping @Sendable (Value) -> Base,
        describe: String,
        name: String? = nil,
        examples: [Value] = [],
        format: String? = nil
    ) -> Schema<Value> {
        let name = name ?? String(describing: Value.self)
        let encodedExamples = examples.map { example -> JSONValue in
            var state = EncodeState(style: .full)
            return base.encoder(encode(example), &state) ?? .null
        }
        return Schema(
            node: .transformed(
                TransformNode(
                    base: base.node, name: name, description: describe, examples: encodedExamples, format: format)),
            decoder: { json, state in
                guard let decoded = base.decoder(json, &state) else { return nil }
                do throws(TransformFailure) {
                    return try decode(decoded)
                } catch {
                    state.report(
                        error.code, parameters: ["message": .string(error.message)],
                        expected: error.expected ?? describe, actual: json.briefDescription,
                        suggestions: error.suggestions)
                    return nil
                }
            },
            encoder: { value, state in base.encoder(encode(value), &state) },
            // A base with a meaning for absence (an optional's nil) lends it
            // to the transform if the conversion accepts it.
            absent: {
                guard let absent = base.absent() else { return nil }
                return try? decode(absent)
            })
    }

    /// The escape hatch: a schema written as code against the JSON itself,
    /// for a shape no combination of the built-in schemas describes (a
    /// string that is either a number of seconds or a duration word, an
    /// object whose keys are validated against each other).
    ///
    ///     Schema<Frequency>.custom(
    ///         describing: .json(constraints: []), description: "a number of hertz, or \"50Hz\"",
    ///         decode: { json, context in
    ///             switch json {
    ///             case .number: return context.decode(json, as: Schema<Double>.double(.greaterThan(0))).map(Frequency.init)
    ///             case .string(let text): return Frequency(parsing: text) ?? context.fail("is not a frequency")
    ///             default: return context.fail("is not a number or a string")
    ///             }
    ///         },
    ///         encode: { .number(JSONNumber($0.hertz) ?? 0) })
    ///
    /// The ``DecodingContext`` is how a custom decoder reports: problems
    /// land at the value's path or at a path below it, and a sub-value is
    /// decoded by another schema through the context, which keeps the path
    /// and the accumulation going. A decoder that returns `nil` without
    /// having reported gets a generic ``IssueCode/invalidValue`` issue; one
    /// that returns a value after reporting an error is treated as failed.
    ///
    /// Everything said under ``transform(base:decode:encode:describe:name:examples:format:)``
    /// about the tree holds here: `describing` is the node an exporter
    /// should write, and a custom schema is opaque to the generators except
    /// through `examples`.
    ///
    /// - Parameters:
    ///   - base: What an exporter should say the wire format is.
    ///   - description: The accepted values in words.
    ///   - name: The type's name in the export; defaults to `Value`'s.
    ///   - examples: JSON that the decoder is known to accept.
    ///   - decode: Reads the value, reporting through the context.
    ///   - encode: Writes it.
    public static func custom(
        describing base: SchemaNode = .json(constraints: []),
        description: String,
        name: String? = nil,
        examples: [JSONValue] = [],
        decode: @escaping @Sendable (JSONValue, inout DecodingContext) -> Value?,
        encode: @escaping @Sendable (Value) -> JSONValue
    ) -> Schema<Value> {
        Schema(
            node: .transformed(
                TransformNode(
                    base: base, name: name ?? String(describing: Value.self), description: description,
                    examples: examples)),
            decoder: { json, state in
                let errorsBefore = state.errorCount
                var context = DecodingContext()
                swap(&context.state, &state)
                context.errorsBefore = context.state.errorCount
                let value = decode(json, &context)
                swap(&context.state, &state)
                if state.errorCount > errorsBefore { return nil }
                guard let value else {
                    // A decoder that gives up without saying why must still
                    // leave an error, or the caller would take nil for success.
                    state.report(
                        .invalidValue, parameters: ["message": .string("was refused")], expected: description,
                        actual: json.briefDescription)
                    return nil
                }
                return value
            },
            encoder: { value, _ in encode(value) })
    }
}

/// What a ``Schema/custom(describing:description:name:examples:decode:encode:)``
/// decoder reports through and decodes sub-values with.
///
/// It is the decode in progress: it knows where in the document the value
/// being decoded sits, so a problem reported at `["port"]` below a value at
/// `$.server` is recorded at `$.server.port`, with a line and column when
/// the input was text.
public struct DecodingContext {
    var state: DecodeState
    /// The errors the whole decode had recorded when this decoder started:
    /// its siblings' are not its own.
    var errorsBefore = 0

    init() {
        state = DecodeState(options: .strict)
    }

    /// Where the value being decoded sits in the document.
    public var path: JSONPath { state.path }

    /// Whether the decode is lenient, so an invalid optional part may be
    /// replaced by a default instead of failing the whole.
    public var isLenient: Bool { state.isLenient }

    /// Whether an error has been reported since this decoder started, by it
    /// or by a schema it decoded with: an error elsewhere in the document
    /// does not count, so a decoder that gives up on `hasErrors` gives up
    /// only on its own value.
    public var hasErrors: Bool { state.errorCount > errorsBefore }

    /// Records a problem.
    ///
    /// - Parameters:
    ///   - code: The kind of problem.
    ///   - message: What is wrong, as a clause that follows the value; the
    ///     issue's `message` parameter.
    ///   - relativePath: Where, below the value being decoded.
    ///   - severity: Whether the value is refused.
    ///   - expected: What would have been accepted.
    ///   - actual: What was found. Dropped inside a secret field.
    ///   - suggestions: Likely intended values.
    public mutating func report(
        _ message: String,
        code: IssueCode = .invalidValue,
        at relativePath: JSONPath = .root,
        severity: Issue.Severity = .error,
        expected: String? = nil,
        actual: String? = nil,
        suggestions: [String] = []
    ) {
        state.report(
            code, severity: severity,
            path: JSONPath(state.path.components + relativePath.components),
            sourcePath: JSONPath(state.inputPath.components + relativePath.components),
            parameters: ["message": .string(message)], expected: expected, actual: actual,
            suggestions: suggestions)
    }

    /// Reports an error at the value itself and returns `nil`, so a decoder
    /// can end with `return context.fail("is not a frequency")`.
    public mutating func fail<Value>(_ message: String, expected: String? = nil) -> Value? {
        report(message, expected: expected)
        return nil
    }

    /// Decodes `json`, which is the value being decoded or a part of it
    /// that has no key of its own, with another schema.
    public mutating func decode<Other: Sendable>(_ json: JSONValue, as schema: Schema<Other>) -> Other? {
        schema.decoder(json, &state)
    }

    /// Decodes a part of the value, found under `component`, with another
    /// schema, so its issues are recorded at the right path.
    public mutating func decode<Other: Sendable>(
        _ json: JSONValue,
        as schema: Schema<Other>,
        at component: JSONPath.Component
    ) -> Other? {
        switch component {
        case .key(let key): state.push(key: key)
        case .index(let index): state.push(index: index)
        }
        defer { state.pop() }
        return schema.decoder(json, &state)
    }
}

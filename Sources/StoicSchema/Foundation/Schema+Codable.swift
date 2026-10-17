#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif
internal import StoicJSON

// A type that already has a Codable conformance, used as a field.
//
// Some models are not worth a schema: a payload one SDK already decodes, a
// type that is another team's, a hundred-field response of which the app
// reads three. This leaf lets them sit in a schema without writing one, at a
// price that is stated rather than hidden. Everything the schema layer gives
// is gone below it: one issue and no path to the field that was wrong, no
// constraints, no documentation, no JSON Schema (it exports `{}`), no
// generator unless you supply examples.

extension Schema where Value: Codable {
    /// A value read and written by `JSONDecoder` and `JSONEncoder`.
    ///
    ///     Field("payload", \.payload, .codable(Payload.self))
    ///
    /// The JSON is handed to a fresh `JSONDecoder` as text, exactly as it
    /// was parsed (numbers keep their digits). If the decoder throws, the
    /// result is **one** `invalid_value` issue at the field, whose `message`
    /// is the decoder's reason and the coding path inside the value; unlike a
    /// schema it cannot report several problems at once. Encoding goes
    /// through a fresh `JSONEncoder` and is parsed back into JSON; an
    /// encoder that throws is reported by ``Schema/validate(_:)``.
    ///
    /// The export is `{}`: any JSON value.
    ///
    /// - Parameters:
    ///   - type: The `Codable` type the leaf holds.
    ///   - examples: Values a generator may use. Without them a generator
    ///     can only draw arbitrary JSON, which a typed value will almost
    ///     always refuse, so ``SchemaSuite`` wants examples for a schema that
    ///     holds this leaf.
    ///   - configureDecoder: Configures the decoder (date strategy, key strategy).
    ///   - configureEncoder: Configures the encoder the same way, so that a value
    ///     reads back as it was written.
    public static func codable(
        _ type: Value.Type,
        examples: [Value] = [],
        decoding configureDecoder: @escaping @Sendable (JSONDecoder) -> Void = { _ in },
        encoding configureEncoder: @escaping @Sendable (JSONEncoder) -> Void = { _ in }
    ) -> Schema<Value> {
        let name = String(describing: Value.self)
        @Sendable func write(_ value: Value) -> JSONValue? {
            let encoder = JSONEncoder()
            configureEncoder(encoder)
            do {
                return try JSONDocument(parsing: Array(encoder.encode(value))).value
            } catch {
                // The caller reports the value as unwritable; the reason adds nothing to it.
                return nil
            }
        }
        let exemplars = examples.compactMap { write($0) }
        return Schema(
            node: .transformed(
                TransformNode(
                    base: .json(constraints: []), name: name, description: "a value that JSONDecoder reads as \(name)",
                    examples: exemplars, isAnnotated: false)),
            decoder: { json, state in
                let decoder = JSONDecoder()
                configureDecoder(decoder)
                do {
                    return try decoder.decode(Value.self, from: Data(json.encodedString(style: .compact).utf8))
                } catch {
                    // The reason is made of the value, so a secret keeps it to itself.
                    let reason = state.secretDepth > 0 ? nil : describe(error)
                    var parameters: JSONObject = ["format": .string(name)]
                    if let reason { parameters["message"] = .string(reason) }
                    state.report(
                        .invalidValue, parameters: parameters, expected: "a value that JSONDecoder reads as \(name)")
                    return nil
                }
            },
            encoder: { value, state in
                guard let written = write(value) else {
                    state.problems.append(
                        Issue(
                            path: state.path, code: .invalidValue,
                            parameters: ["message": .string("JSONEncoder could not write this \(name)")],
                            expected: "a \(name) that JSONEncoder can write"))
                    return .null
                }
                return written
            })
    }
}

/// What `JSONDecoder` said, with where in the value it said it.
private func describe(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return String(describing: error) }
    let context: DecodingError.Context
    var reason: String
    switch error {
    case .typeMismatch(_, let found):
        context = found
        reason = found.debugDescription
    case .valueNotFound(_, let found):
        context = found
        reason = found.debugDescription
    case .keyNotFound(let key, let found):
        context = found
        reason = "there is no key \"\(key.stringValue)\""
    case .dataCorrupted(let found):
        context = found
        reason = found.debugDescription
    @unknown default:
        return String(describing: error)
    }
    let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined()
    if !path.isEmpty { reason += " (at \(path.hasPrefix(".") ? String(path.dropFirst()) : path))" }
    return reason
}

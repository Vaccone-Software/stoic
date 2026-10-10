#if STOIC_MACROS
import StoicJSON
import StoicSchema
import Testing

/// The value at a path of object keys.
func at(_ value: JSONValue, _ path: String...) -> JSONValue? {
    var current: JSONValue? = value
    for key in path { current = current?.object?[key] }
    return current
}

/// The macro is sugar, so a macro-written schema and the same schema written
/// by hand must be indistinguishable: the same tree, the same JSON Schema,
/// and the same verdict, value and issues on every document either accepts
/// or refuses.
///
/// "Every document" is the generator's: valid ones, and each valid one with
/// every minimal violation applied, decoded strictly and leniently, and
/// encoded in every style.
func expectEquivalent<Value: Sendable & Equatable>(
    _ macro: Schema<Value>, _ hand: Schema<Value>, seeds: Range<UInt64> = 0..<12,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    #expect(
        String(describing: macro.node) == String(describing: hand.node), "the node trees differ",
        sourceLocation: sourceLocation)
    #expect(macro.jsonSchema() == hand.jsonSchema(), "the exported JSON Schemas differ", sourceLocation: sourceLocation)

    var documents: [JSONValue] = [[:]]
    for seed in seeds {
        guard let sample = try? macro.generator.sample(seed: seed) else {
            Issue.record("the generator could not make a sample for seed \(seed)", sourceLocation: sourceLocation)
            continue
        }
        documents.append(sample.document)
        documents.append(contentsOf: macro.generator.mutations(of: sample.document, seed: seed).map(\.document))
    }
    #expect(documents.count > 20, "too few documents to say anything", sourceLocation: sourceLocation)

    for document in documents {
        for options in [DecodeOptions.strict, .lenient] {
            let left = macro.decode(document, options: options)
            let right = hand.decode(document, options: options)
            #expect(left.value == right.value, "values differ for \(document.encodedString())", sourceLocation: sourceLocation)
            #expect(left.issues == right.issues, "issues differ for \(document.encodedString())", sourceLocation: sourceLocation)
            guard let value = left.value else { continue }
            for style in [EncodeStyle.full, .fullWithoutSecrets, .sparse, .sparse(includeSecrets: true)] {
                #expect(
                    macro.encode(value, style: style) == hand.encode(value, style: style),
                    "encodings differ in \(style) for \(document.encodedString())", sourceLocation: sourceLocation)
            }
        }
    }
}
#endif

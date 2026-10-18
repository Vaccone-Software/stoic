internal import StoicJSON

extension Schema {
    /// This object schema, also reading `null` as an empty object.
    ///
    ///     Field("scroll", \.scroll, Scroll.schema.readingNullAsEmpty())
    ///
    /// For a section of a file people edit, where `"scroll": null` is what is
    /// left after deleting the settings inside it and means "nothing set
    /// here". The object is read as if its members were all absent: every field
    /// takes its default, silently, with no issue, where a `null` is otherwise
    /// a `type_mismatch` (or, under `.lenient`, a repair to the default that a
    /// settings store carries back into the file). A form (b) object, which
    /// has fields with no default, reports their `missing_key` errors at the
    /// object as for `{}`.
    ///
    /// The `null` is not a value: nothing in the Swift value remembers it, so
    /// a write is sparse and omits the section when it equals the default (the
    /// `null` is not carried back into the file). The JSON Schema export
    /// admits `null` for the object (`"type": ["object", "null"]`), and
    /// generators do not offer `null` as a violation. Only the object itself
    /// reads it: a field inside is as strict as it was.
    ///
    /// Traps if the schema is not an object schema.
    public func readingNullAsEmpty() -> Schema<Value> {
        guard case .object(var object) = node else {
            preconditionFailure("readingNullAsEmpty() applies to an object schema, not \(node.expectation)")
        }
        object.readsNullAsEmpty = true
        let inner = self
        return Schema(
            node: .object(object),
            decoder: { json, state in
                guard case .null = json else { return inner.decoder(json, &state) }
                return inner.decoder(.object(JSONObject()), &state)
            },
            encoder: inner.encoder,
            absent: inner.absent)
    }
}

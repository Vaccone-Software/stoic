public import StoicJSON

extension Schema {
    /// This object schema, normalizing the raw JSON on every read, before it
    /// is decoded. See ``Normalization`` for what a normalization is and why it
    /// must be idempotent.
    ///
    ///     static let schema = Schema.object(Prefs.self, default: Prefs()) { … }
    ///         .normalizing(
    ///             .rename("hyper", to: "searcher"),
    ///             .mapEnum("mode", ["raw-hyper": "hyper"]),
    ///             retired: ["old-flag"])
    ///
    /// **When it runs.** In the decode of this object, first: before the
    /// version is read and migrated, before any key is looked up. A nested
    /// object that is declared with its own normalization runs it on its own
    /// part. It raises no issue, and the decoded value is the same whether the
    /// file says the old spelling or the new.
    ///
    /// **Positions stay where the text is.** An issue about a node the
    /// normalization did not touch points at that node in the file, as ever;
    /// one about a value a `rename` or `move` relocated points at where the
    /// text wrote it (`$.searcher` at the `hyper` line). A value that
    /// something else created, or that a custom operation rearranged, has no
    /// text of its own, and an issue about it points at the nearest object
    /// that does. (A versioned migration, by contrast, makes every issue point
    /// at the whole migrated object.)
    ///
    /// **Declared once.** The schema has one normalization: every operation
    /// and retired path goes in one call, because the order they run in is the
    /// order they are written. Traps if the schema is not an object schema,
    /// already has a normalization, or retires a key it declares as a field.
    public func normalizing(_ normalization: Normalization) -> Schema<Value> {
        guard case .object(var object) = node else {
            preconditionFailure("normalizing(_:) applies to an object schema, not \(node.expectation)")
        }
        precondition(object.normalization == nil, "\(object.name) already declares a normalization; give every step in one call")
        let declared = Set(object.fields.flatMap { [$0.key] + $0.aliases })
        for path in normalization.retired {
            let keys = PathEdit.split(path)
            precondition(
                keys.count > 1 || !declared.contains(path),
                "\(object.name): `\(path)` is retired and also a field or alias; one of them is wrong")
        }
        object.normalization = normalization
        let inner = self
        return Schema(
            node: .object(object),
            decoder: { json, state in
                guard case .object = json else { return inner.decoder(json, &state) }
                var document = json
                let moved: [Relocation]
                do throws(MigrationFailure) {
                    moved = try normalization.apply(to: &document)
                } catch {
                    state.report(.normalizationFailed, parameters: ["message": .string(error.message)])
                    return nil
                }
                let outer = state.relocations.count
                defer { state.relocations.removeSubrange(outer...) }
                for move in moved { state.relocations.append((state.inputPath, move)) }
                return inner.decoder(document, &state)
            },
            encoder: inner.encoder,
            absent: inner.absent)
    }

    /// ``normalizing(_:)`` with the operations written in a list:
    /// `.normalizing(.rename("hyper", to: "searcher"), retired: ["old-flag"])`.
    public func normalizing(
        _ operations: Normalization.Operation...,
        retired: [String] = []
    ) -> Schema<Value> {
        normalizing(Normalization(operations, retired: retired))
    }

    /// `document` as this schema reads it: the normalization of every object
    /// it describes applied (see ``normalizing(_:)``), nothing else changed.
    ///
    /// For what must hold the document as the decode saw it: a settings store
    /// puts back the keys a schema does not declare when it writes, and must
    /// put back those of the normalized document, or a key the normalization
    /// renamed would be written back beside its new name and one it retired
    /// would never go. And for a test: a normalization is idempotent if
    /// `schema.normalized(schema.normalized(x)) == schema.normalized(x)`.
    ///
    /// Objects are found through fields, optionals, arrays, dictionaries and
    /// transparent wrappers; a union's payloads are not searched. An object
    /// whose normalization fails is left as it was (decoding reports why).
    public func normalized(_ document: JSONValue) -> JSONValue {
        node.normalizing(document)
    }
}

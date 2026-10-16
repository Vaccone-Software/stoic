public import StoicJSON

extension Schema {
    /// An object whose every field has a default: configuration.
    ///
    ///     static let schema = Schema.object(Settings.self, default: Settings()) {
    ///         Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)),
    ///               doc: "Pixels per second.", unit: "px/s")
    ///         Field("theme", \.theme, .enumeration(Theme.self))
    ///         Field("apiToken", \.apiToken, .string(), secret: true)
    ///     }
    ///
    /// The default instance is the single source of every default: a key
    /// that is missing takes its value from it, a field that is invalid
    /// under `.lenient` falls back to it, sparse encoding omits fields equal
    /// to it, and the JSON Schema export writes it as `default`. Nothing is
    /// restated per field, so nothing can disagree.
    ///
    /// **Accumulation.** Every field is read whatever happened to the ones
    /// before, so a document with four bad fields has four issues, each at
    /// its own path.
    ///
    /// **Unknown keys** default to ``UnknownKeyPolicy/warn``, the right
    /// answer for a file a person edits: the app starts, and the user is
    /// told that `scrol_speed` was ignored and `scrollSpeed` was probably
    /// meant. Choose `.reject` for a wire format.
    ///
    /// **Spellings** default to ``KeySpellings/forgiving``: `scroll_speed`
    /// is read as `scrollSpeed`, with a `deprecated_key` warning, because a
    /// person typed it. Choose `.exact` for a document other programs read.
    ///
    /// **Versions.** `version:` makes the object a versioned document: its
    /// version is written to the reserved `versionKey` on every encode, and a
    /// document that states an older one is migrated, step by step through
    /// `migrations`, before it is read. See ``Migration`` for the steps and
    /// the guarantee they exist for, and ``Versioning`` for the rest. A field
    /// may not use the reserved key.
    ///
    /// **Keeping what is not understood.** `preservingUnknownKeysIn` names a
    /// property of type `JSONObject` that receives the keys the schema does
    /// not declare and writes them back on encode: the object then never
    /// destroys what a newer release put there. It sets the policy to
    /// ``UnknownKeyPolicy/preserve`` and replaces `unknownKeys`. A document
    /// newer than `version` is read (best effort) only by such an object.
    ///
    /// A key or alias declared twice is a mistake in the schema and traps
    /// when the schema is first built, so it is found by the first test
    /// that touches the schema rather than by a user.
    ///
    /// **Nested objects** decode relative to their own default, not the
    /// outer one: a partial nested object fills its missing keys from the
    /// nested type's `init()`.
    public static func object(
        _ type: Value.Type,
        name: String? = nil,
        default defaultValue: Value,
        unknownKeys: UnknownKeyPolicy = .warn,
        spellings: KeySpellings = .forgiving,
        doc: String? = nil,
        version: Int? = nil,
        versionKey: String = "version",
        missingVersion: MissingVersion = .oldest,
        migrations: [Migration] = [],
        preservingUnknownKeysIn preserved: (any WritableKeyPath<Value, JSONObject> & Sendable)? = nil,
        @FieldsBuilder<Value> fields makeFields: () -> [Field<Value>]
    ) -> Schema<Value> {
        let name = name ?? String(describing: Value.self)
        let fields = makeFields()
        let keys = DeclaredKeys(
            fields.map { DeclaredKey(key: $0.key, aliases: $0.aliases) }, spellings: spellings, in: name)
        let versioning = makeVersioning(
            version: version, key: versionKey, missing: missingVersion, migrations: migrations,
            declared: keys.declared, in: name)
        let codecs = fields.map(\.codec)
        let policy: UnknownKeyPolicy = preserved == nil ? unknownKeys : .preserve
        let preservedReader = readPreserved(preserved)
        let node = ObjectNode(
            name: name, doc: doc, fields: fields.map { $0.makeNode(defaultValue) }, unknownKeys: policy,
            versioning: versioning)
        return Schema(
            node: .object(node),
            decoder: { json, state in
                guard case .object(var object) = json else {
                    state.typeMismatch(expected: "an object", found: json)
                    return nil
                }
                let outerRegion = state.migratedRegion
                defer { state.migratedRegion = outerRegion }
                if let versioning {
                    guard let gate = versioning.gate(object, preservesUnknown: policy == .preserve, state: &state)
                    else { return nil }
                    object = gate.object
                    if gate.migrated { state.migratedRegion = state.inputPath }
                }
                var scan = ObjectScan(object: object, keys: keys)
                var result = defaultValue
                let errorsBefore = state.errorCount
                for field in fields {
                    _ = field.read(&result, defaultValue, &scan, &state)
                }
                if let preserved { result[keyPath: preserved] = scan.takePreserved() }
                scan.finish(policy: policy, state: &state)
                return state.errorCount == errorsBefore ? result : nil
            },
            encoder: { value, state in
                encodeObject(
                    value, codecs: codecs, defaults: defaultValue, versioning: versioning,
                    preserved: preservedReader, state: &state)
            })
    }
}

/// The versioning an object declares, or `nil` if it declares none, after
/// checking that nothing contradicts it.
func makeVersioning(
    version: Int?,
    key: String,
    missing: MissingVersion,
    migrations: [Migration],
    declared: [DeclaredKey],
    in name: String
) -> Versioning? {
    guard let version else {
        precondition(migrations.isEmpty, "\(name): migrations need a `version:` to lead to")
        return nil
    }
    for declaration in declared {
        precondition(
            !([declaration.key] + declaration.aliases).contains { ExactKey($0) == ExactKey(key) },
            "\(name): \"\(key)\" holds the document's version and cannot be a field")
    }
    return Versioning(current: version, key: key, missing: missing, migrations: migrations)
}

/// How an object reads back the unknown keys it preserved.
private func readPreserved<Root: Sendable>(
    _ keyPath: (any WritableKeyPath<Root, JSONObject> & Sendable)?
) -> (@Sendable (Root) -> JSONObject)? {
    guard let keyPath else { return nil }
    return { root in root[keyPath: keyPath] }
}

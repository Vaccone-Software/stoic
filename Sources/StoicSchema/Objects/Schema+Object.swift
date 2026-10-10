internal import StoicJSON

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
        doc: String? = nil,
        @FieldsBuilder<Value> fields makeFields: () -> [Field<Value>]
    ) -> Schema<Value> {
        let name = name ?? String(describing: Value.self)
        let fields = makeFields()
        let declared = fields.map { DeclaredKey(key: $0.key, aliases: $0.aliases) }
        checkDeclaredKeys(declared, in: name)
        let known = Set(declared.flatMap { [ExactKey($0.key)] + $0.aliases.map(ExactKey.init) })
        let codecs = fields.map(\.codec)
        let node = ObjectNode(
            name: name, doc: doc, fields: fields.map { $0.makeNode(defaultValue) }, unknownKeys: unknownKeys)
        return Schema(
            node: .object(node),
            decoder: { json, state in
                guard case .object(let object) = json else {
                    state.typeMismatch(expected: "an object", found: json)
                    return nil
                }
                var scan = ObjectScan(object: object, known: known)
                var result = defaultValue
                let errorsBefore = state.errorCount
                for field in fields {
                    _ = field.read(&result, defaultValue, &scan, &state)
                }
                scan.finish(declared: declared, policy: unknownKeys, state: &state)
                return state.errorCount == errorsBefore ? result : nil
            },
            encoder: { value, state in
                encodeObject(value, codecs: codecs, defaults: defaultValue, state: &state)
            })
    }
}

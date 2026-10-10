internal import StoicJSON

/// How one field of an object writes itself, for both object forms.
struct FieldCodec<Root: Sendable>: Sendable {
    var key: String
    var isSecret: Bool
    var isDeprecated: Bool
    /// The field's JSON in the object's current style, or `nil` to leave the
    /// key out.
    var encode: @Sendable (Root, inout EncodeState) -> JSONValue?
    /// The field's JSON in full style with secrets, for comparison with the
    /// default.
    var encodeFull: @Sendable (Root) -> JSONValue?
    /// The field's default in the same form: `nil` if the field has none,
    /// `.some(nil)` if its default is to be absent.
    var baseline: @Sendable (Root?) -> JSONValue??
}

/// Writes an object's fields, honouring the style.
///
/// Sparse output leaves out each field whose value, encoded in full, equals
/// its default encoded in full. (A deprecated field is held to the same rule
/// in the full style too: it is written only when it carries a value other
/// than its default, so a document written today does not trip the warning
/// it would draw when read back.) Comparing encodings, rather than values,
/// needs no `Equatable` on any field type and compares exactly what would be
/// written. It is also what makes sparse a fixed point of decoding then
/// encoding: a key is written exactly when reading it back changes the
/// result.
func encodeObject<Root: Sendable>(
    _ value: Root,
    codecs: [FieldCodec<Root>],
    defaults: Root?,
    state: inout EncodeState
) -> JSONValue {
    var object = JSONObject()
    let sparse = state.style.density == .sparse
    for codec in codecs {
        if codec.isSecret && !state.style.includeSecrets { continue }
        if sparse || codec.isDeprecated,
            let baseline = codec.baseline(defaults), codec.encodeFull(value) == baseline
        {
            continue
        }
        state.push(key: codec.key)
        if let encoded = codec.encode(value, &state) { object[codec.key] = encoded }
        state.pop()
    }
    return .object(object)
}

/// Rejects a declaration that names a key twice, as a key or an alias.
/// That is a mistake in the schema, found when the schema is first used.
func checkDeclaredKeys(_ declared: [DeclaredKey], in name: String) {
    var seen: Set<ExactKey> = []
    for declaration in declared {
        for spelling in [declaration.key] + declaration.aliases {
            precondition(
                seen.insert(ExactKey(spelling)).inserted,
                "\(name): the key or alias \"\(spelling)\" is declared twice")
        }
    }
}

/// One field of an object declared with a default instance (form (a)):
/// its key, how to reach it, how it is written, and what it means.
///
/// The key path is a `WritableKeyPath`, so the object is built by setting
/// fields on the default instance rather than by calling an initialiser, and
/// no memberwise-init coupling exists: adding a field to the type is adding
/// one line here.
///
/// **Key paths and `Sendable`.** A schema is `Sendable`, so its key paths
/// must be. Swift 6 does not make `WritableKeyPath` itself `Sendable`;
/// instead (SE-0418) a key path *literal* is inferred to be
/// `any WritableKeyPath<Root, V> & Sendable` when everything it captures is
/// `Sendable`, which for `\.scrollSpeed` is nothing. So callers write the
/// plain literal and the parameter type below asks for the sendable form.
/// A key path built at run time, or one that goes through a non-`Sendable`
/// subscript argument, will not convert: that is the compiler saying the
/// schema could not be shared safely.
public struct Field<Root: Sendable>: Sendable {
    let key: String
    let aliases: [String]
    let makeNode: @Sendable (Root) -> FieldNode
    let codec: FieldCodec<Root>
    /// Reads this field from `scan` into `result`; `defaults` is the object's
    /// default instance. Returns whether it succeeded.
    let read: @Sendable (inout Root, Root, inout ObjectScan, inout DecodeState) -> Bool

    /// - Parameters:
    ///   - key: The key in JSON.
    ///   - keyPath: The property it maps to.
    ///   - schema: How the value is read and written.
    ///   - doc: Documentation, for the JSON Schema `description` and UI help.
    ///   - unit: The unit of a number, for the export's `x-stoic-unit` and UI.
    ///   - aliases: Other spellings accepted on input, each with a
    ///     `deprecated_key` warning. Case and snake_case spellings of `key`
    ///     are accepted without being listed.
    ///   - secret: Never echoed in an issue, never in the export's default,
    ///     left out of sparse output.
    ///   - deprecated: Still read, with a warning whenever a document uses it.
    public init<V: Sendable>(
        _ key: String,
        _ keyPath: any WritableKeyPath<Root, V> & Sendable,
        _ schema: Schema<V>,
        doc: String? = nil,
        unit: String? = nil,
        aliases: [String] = [],
        secret: Bool = false,
        deprecated: Deprecation? = nil
    ) {
        self.key = key
        self.aliases = aliases
        makeNode = { defaults in
            FieldNode(
                key: key, aliases: aliases, node: schema.node, doc: doc, unit: unit, isSecret: secret,
                deprecation: deprecated, isRequired: false,
                defaultProvider: {
                    var state = EncodeState(style: .full)
                    return schema.encoder(defaults[keyPath: keyPath], &state)
                })
        }
        codec = FieldCodec(
            key: key, isSecret: secret, isDeprecated: deprecated != nil,
            encode: { root, state in schema.encoder(root[keyPath: keyPath], &state) },
            encodeFull: { root in
                var state = EncodeState(style: .full)
                return schema.encoder(root[keyPath: keyPath], &state)
            },
            baseline: { defaults in
                guard let defaults else { return nil }
                var state = EncodeState(style: .full)
                return .some(schema.encoder(defaults[keyPath: keyPath], &state))
            })
        read = { result, defaults, scan, state in
            let spec = FieldSpec(
                key: key, aliases: aliases, schema: schema, isSecret: secret, deprecation: deprecated,
                defaultValue: defaults[keyPath: keyPath])
            guard let value = readField(spec, scan: &scan, state: &state) else { return false }
            result[keyPath: keyPath] = value
            return true
        }
    }
}

/// Collects the `Field`s written in an object's body.
@resultBuilder
public struct FieldsBuilder<Root: Sendable> {
    public static func buildExpression(_ field: Field<Root>) -> [Field<Root>] { [field] }
    public static func buildExpression(_ fields: [Field<Root>]) -> [Field<Root>] { fields }
    public static func buildBlock(_ parts: [Field<Root>]...) -> [Field<Root>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Field<Root>]?) -> [Field<Root>] { part ?? [] }
    public static func buildEither(first part: [Field<Root>]) -> [Field<Root>] { part }
    public static func buildEither(second part: [Field<Root>]) -> [Field<Root>] { part }
    public static func buildArray(_ parts: [[Field<Root>]]) -> [Field<Root>] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ part: [Field<Root>]) -> [Field<Root>] { part }
}

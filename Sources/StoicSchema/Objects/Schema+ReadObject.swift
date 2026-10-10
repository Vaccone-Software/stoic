public import StoicJSON

// Objects without a default instance (form (b)).
//
// Why this shape. A type with no `init()` can only be built by calling an
// initialiser with every field in hand, and Swift gives a builder only two
// ways to hold a field that failed to decode: stop (throw) or substitute a
// value of the field's type, which does not exist for an arbitrary type. A
// `try ctx.field(...)` style therefore stops at the first bad field, which
// is exactly the behaviour this layer exists to avoid.
//
// So the declaration is split in two steps that cannot be confused. Step
// one *reads* each field and returns a `Slot`, a handle that is not the
// value: it cannot be used as one, and a failed read is just an empty slot,
// so reading carries on. Step two, `build`, is a closure that turns the
// slots into the value, and the only way to get a slot's value is through
// the `Values` token that `build` passes in, which exists only when every
// slot is full. The framework runs `build` if and only if nothing failed,
// so a missing value cannot be observed, and every field's issues have been
// collected before the initialiser is called.
//
// The same closure runs once at declaration time with a reader that
// describes instead of decoding, which is how the schema learns its own
// shape (keys, documentation, requiredness) without a second declaration.
// The closure must therefore be a pure description: read the fields, call
// `build`, do nothing else.

/// What a field read produced: a value, or nothing because the read failed.
///
/// A slot is deliberately not the value. It is a receipt, redeemed through
/// ``Values`` inside ``ObjectReader/build(_:)``.
public struct Slot<Value: Sendable>: Sendable {
    let value: Value?
}

/// Proof that every slot is full, handed to the closure of
/// ``ObjectReader/build(_:)``. Subscript a slot with it to get its value.
public struct Values: Sendable {
    init() {}

    public subscript<V: Sendable>(slot: Slot<V>) -> V {
        guard let value = slot.value else {
            preconditionFailure("a Slot was read outside the build closure of its own object")
        }
        return value
    }
}

/// The recipe for building the object once its fields have been read; made
/// by ``ObjectReader/build(_:)``.
public struct Construction<Root: Sendable>: Sendable {
    let make: @Sendable (Values) throws(ValidationFailure) -> Root
}

/// Reads the fields of an object that has no default instance; see
/// ``Schema/object(_:name:unknownKeys:doc:declare:)``.
public final class ObjectReader<Root: Sendable> {
    private enum Mode {
        case describing
        case decoding
    }

    private let mode: Mode
    var state: DecodeState
    var scan: ObjectScan
    var succeeded = true
    var nodes: [FieldNode] = []
    var codecs: [FieldCodec<Root>] = []
    /// What the object declared, for deciding which keys are unknown.
    private var declared: [DeclaredKey] = []
    /// Set by ``unknownKeys(_:)`` while describing.
    var preserved: (@Sendable (Root) -> JSONObject)?

    /// A reader that records the declaration and decodes nothing.
    init() {
        mode = .describing
        state = DecodeState(options: .strict)
        scan = ObjectScan(object: JSONObject(), known: [])
    }

    /// A reader that decodes `object`. The state is a placeholder until the
    /// caller swaps the real one in.
    init(object: JSONObject, known: Set<ExactKey>, declared: [DeclaredKey], options: DecodeOptions) {
        self.declared = declared
        mode = .decoding
        state = DecodeState(options: options)
        scan = ObjectScan(object: object, known: known)
    }

    /// Reads one field. Never stops the object: a field that fails leaves an
    /// empty slot and records its issues.
    ///
    /// - Parameters:
    ///   - key: The key in JSON.
    ///   - keyPath: How to read the property back, for encoding. Read-only:
    ///     the object is built by `build`, not by assignment.
    ///   - schema: How the value is read and written.
    ///   - default: Used when the key is absent and, under `.lenient`, when
    ///     the value is invalid. A field with no default is required, unless
    ///     its type is optional.
    ///   - doc: Documentation for the JSON Schema `description`.
    ///   - unit: The unit of a number, for `x-stoic-unit`.
    ///   - aliases: Other accepted spellings, each with a `deprecated_key` warning.
    ///   - secret: Never echoed in an issue; left out of sparse output.
    ///   - deprecated: Still read, with a warning whenever a document uses it.
    public func field<V: Sendable>(
        _ key: String,
        _ keyPath: any KeyPath<Root, V> & Sendable,
        _ schema: Schema<V>,
        default defaultValue: V? = nil,
        doc: String? = nil,
        unit: String? = nil,
        aliases: [String] = [],
        secret: Bool = false,
        deprecated: Deprecation? = nil
    ) -> Slot<V> {
        switch mode {
        case .describing:
            let required = defaultValue == nil && schema.absent() == nil
            var provider: (@Sendable () -> JSONValue?)? = nil
            if let fallback = defaultValue {
                provider = {
                    var encoding = EncodeState(style: .full)
                    return schema.encoder(fallback, &encoding)
                }
            }
            nodes.append(
                FieldNode(
                    key: key, aliases: aliases, node: schema.node, doc: doc, unit: unit, isSecret: secret,
                    deprecation: deprecated, isRequired: required, defaultProvider: provider))
            codecs.append(
                FieldCodec(
                    key: key, isSecret: secret, isDeprecated: deprecated != nil,
                    encode: { root, state in schema.encoder(root[keyPath: keyPath], &state) },
                    encodeFull: { root in
                        var encoding = EncodeState(style: .full)
                        return schema.encoder(root[keyPath: keyPath], &encoding)
                    },
                    baseline: { _ in
                        // Without an explicit default, absence is the baseline
                        // for a type that has a meaning for it (an optional's
                        // nil); a required field has no baseline and is
                        // always written.
                        guard let fallback = defaultValue ?? schema.absent() else { return nil }
                        var encoding = EncodeState(style: .full)
                        return .some(schema.encoder(fallback, &encoding))
                    }))
            return Slot(value: nil)
        case .decoding:
            let spec = FieldSpec(
                key: key, aliases: aliases, schema: schema, isSecret: secret, deprecation: deprecated,
                defaultValue: defaultValue)
            guard let value = readField(spec, scan: &scan, state: &state) else {
                succeeded = false
                return Slot(value: nil)
            }
            return Slot(value: .some(value))
        }
    }

    /// Reads the keys the object does not declare, so that the value keeps
    /// them and writes them back: the object then never destroys what a
    /// newer release, or another tool, put in the document. Declaring it
    /// sets the object's policy to ``UnknownKeyPolicy/preserve``.
    ///
    ///     let extra = f.unknownKeys(\.extra)
    ///     return f.build { v in Point(x: v[x], y: v[y], extra: v[extra]) }
    ///
    /// - Parameter keyPath: Where the value holds them, for encoding.
    public func unknownKeys(_ keyPath: any KeyPath<Root, JSONObject> & Sendable) -> Slot<JSONObject> {
        switch mode {
        case .describing:
            preserved = { $0[keyPath: keyPath] }
            return Slot(value: nil)
        case .decoding:
            return Slot(value: scan.takePreserved(declared: declared))
        }
    }

    /// Declares how the value is made from the slots. It runs only if every
    /// field was read without error, and may itself throw a
    /// ``ValidationFailure`` for a rule that spans fields (its issues are
    /// placed under the object's own path).
    ///
    ///     return f.build { v in Point(x: v[x], y: v[y]) }
    public func build(_ make: @escaping @Sendable (Values) throws(ValidationFailure) -> Root) -> Construction<Root> {
        Construction(make: make)
    }
}

extension Schema {
    /// An object with no default instance: a type that has to be built by
    /// calling an initialiser with all its fields.
    ///
    ///     static let schema = Schema.object(Point.self) { f in
    ///         let x = f.field("x", \.x, .double())
    ///         let y = f.field("y", \.y, .double())
    ///         return f.build { v in Point(x: v[x], y: v[y]) }
    ///     }
    ///
    /// Every field is read before the initialiser runs, and a field that
    /// fails does not stop the others, so two bad coordinates are two
    /// issues. See the notes above ``Slot`` for why the API is shaped this
    /// way rather than as `try f.field(...)`.
    ///
    /// The closure runs once when the schema is declared, to learn its
    /// shape, and once per decode: it must read fields and call `build` and
    /// do nothing else. Required keys are missing-key errors; give a field
    /// a `default:` (or an optional type) to make it optional.
    ///
    /// Unknown keys default to ``UnknownKeyPolicy/reject``: a type with no
    /// defaults is usually a wire message, where an unrecognised key is a
    /// disagreement about the format, not a typo to forgive.
    public static func object(
        _ type: Value.Type,
        name: String? = nil,
        unknownKeys: UnknownKeyPolicy = .reject,
        doc: String? = nil,
        version: Int? = nil,
        versionKey: String = "version",
        missingVersion: MissingVersion = .oldest,
        migrations: [Migration] = [],
        declare: @escaping @Sendable (ObjectReader<Value>) -> Construction<Value>
    ) -> Schema<Value> {
        let name = name ?? String(describing: Value.self)
        let describer = ObjectReader<Value>()
        _ = declare(describer)
        let nodes = describer.nodes
        let codecs = describer.codecs
        let preserved = describer.preserved
        let policy: UnknownKeyPolicy = preserved == nil ? unknownKeys : .preserve
        let declared = nodes.map { DeclaredKey(key: $0.key, aliases: $0.aliases) }
        checkDeclaredKeys(declared, in: name)
        let versioning = makeVersioning(
            version: version, key: versionKey, missing: missingVersion, migrations: migrations, declared: declared,
            in: name)
        let known = Set(declared.flatMap { [ExactKey($0.key)] + $0.aliases.map(ExactKey.init) })
        let node = ObjectNode(name: name, doc: doc, fields: nodes, unknownKeys: policy, versioning: versioning)
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
                let errorsBefore = state.errorCount
                let reader = ObjectReader<Value>(
                    object: object, known: known, declared: declared, options: state.options)
                // The reader works on the caller's state by holding it for the
                // duration: swapping moves it, where assigning would copy the
                // issue list at every nesting level.
                swap(&reader.state, &state)
                let construction = declare(reader)
                reader.scan.finish(declared: declared, policy: policy, state: &reader.state)
                swap(&reader.state, &state)
                guard reader.succeeded, state.errorCount == errorsBefore else { return nil }
                do throws(ValidationFailure) {
                    return try construction.make(Values())
                } catch {
                    for issue in error.issues {
                        state.report(
                            issue.code, severity: issue.severity,
                            path: JSONPath(state.path.components + issue.path.components),
                            sourcePath: JSONPath(state.inputPath.components + issue.path.components),
                            parameters: issue.parameters, expected: issue.expected, actual: issue.actual,
                            suggestions: issue.suggestions)
                    }
                    // A failure must leave an error behind, or the caller
                    // would take the missing value for success.
                    if state.errorCount == errorsBefore {
                        state.report(
                            .custom, parameters: ["message": .string("rejected while building the value")])
                    }
                    return nil
                }
            },
            encoder: { value, state in
                encodeObject(value, codecs: codecs, defaults: nil, versioning: versioning, preserved: preserved, state: &state)
            })
    }
}

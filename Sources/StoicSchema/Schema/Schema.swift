public import StoicJSON

/// One declaration of a type's wire format: how to decode it, how to encode
/// it, what it accepts, and a description of all that as data.
///
/// Parse, don't validate: data that crosses a trust boundary (a config file,
/// a network response, a document from disk) enters the app through a
/// schema, which either produces a typed value or says exactly what is wrong
/// with the input and where. The same declaration drives
///
/// - ``decode(_:options:)-(JSONDocument,_)``, which accumulates every issue with its path and
///   (for text) its line and column instead of stopping at the first;
/// - ``encode(_:style:)``, including the sparse form of a configuration;
/// - ``jsonSchema()``, so what the decoder accepts and what the documentation
///   says come from one place.
///
/// Compose schemas from the primitives (``bool``, ``int(_:)``,
/// ``double(_:)``, ``string(_:)``, ``array(of:_:)``, ``dictionary(of:_:)``,
/// ``optional(_:nullable:)``, `enumeration(_:)`, ``json(_:)``,
/// ``lazy(_:_:)``) and from objects
/// (``object(_:name:default:unknownKeys:spellings:doc:version:versionKey:missingVersion:migrations:preservingUnknownKeysIn:fields:)``
/// for configuration with defaults,
/// ``object(_:name:unknownKeys:spellings:doc:version:versionKey:missingVersion:migrations:declare:)``
/// for types without them).
///
/// Inside, a schema is two closures and a tree. The closures are
/// `@Sendable` and capture only values, so a schema is safe to keep in a
/// `static let` and use from anywhere.
public struct Schema<Value: Sendable>: Sendable {
    /// The schema as data: what an exporter or a generator reads.
    public let node: SchemaNode

    /// Reads a value, recording issues in the state. Returns `nil` exactly
    /// when it recorded an error.
    let decoder: @Sendable (JSONValue, inout DecodeState) -> Value?

    /// Writes a value. `nil` means "leave this out" (an optional that is
    /// `nil` and has no `null` spelling); the entry points turn it into
    /// `null` where nothing can be left out.
    let encoder: @Sendable (Value, inout EncodeState) -> JSONValue?

    /// The value of a key that is missing and has no default, when absence
    /// is itself a value (an optional's `nil`); `nil` if absence is an error.
    let absent: @Sendable () -> Value?

    init(
        node: SchemaNode,
        decoder: @escaping @Sendable (JSONValue, inout DecodeState) -> Value?,
        encoder: @escaping @Sendable (Value, inout EncodeState) -> JSONValue?,
        absent: @escaping @Sendable () -> Value? = { nil }
    ) {
        self.node = node
        self.decoder = decoder
        self.encoder = encoder
        self.absent = absent
    }

    // MARK: Decoding

    /// Decodes a value that is already JSON. Issues carry paths but no
    /// source ranges, as there is no text.
    public func decode(_ value: JSONValue, options: DecodeOptions = .strict) -> Decoded<Value> {
        run(value, document: nil, options: options)
    }

    /// Decodes a parsed document, so issues also carry the line and column
    /// of the text they are about.
    public func decode(_ document: JSONDocument, options: DecodeOptions = .strict) -> Decoded<Value> {
        run(document.value, document: document, options: options)
    }

    /// Parses `bytes` and decodes them, returning the value or throwing
    /// every issue found. Malformed JSON is one `parse_error` issue at the
    /// parser's position.
    ///
    /// On success the warnings and repairs go to `warnings`, which has no
    /// default: a dropped element, an unknown case read as its fallback or a
    /// repaired field is something the app decided, and the shortest way to
    /// a value must not be the way that hides it (see
    /// ``Decoded/get(warnings:)``). ``decodeReporting(_:options:)-(String,_)`` returns
    /// them with the value instead.
    public func decode(
        _ bytes: some Collection<UInt8>,
        options: DecodeOptions = .strict,
        warnings: (Issue) -> Void
    ) throws(ValidationFailure) -> Value {
        try decodeReporting(bytes, options: options).get(warnings: warnings)
    }

    /// Parses `text` and decodes it; see the bytes overload.
    public func decode(
        _ text: String,
        options: DecodeOptions = .strict,
        warnings: (Issue) -> Void
    ) throws(ValidationFailure) -> Value {
        try decodeReporting(text, options: options).get(warnings: warnings)
    }

    /// Parses `bytes` and decodes them without throwing: the value if there
    /// were no errors, and every issue either way.
    public func decodeReporting(
        _ bytes: some Collection<UInt8>,
        options: DecodeOptions = .strict
    ) -> Decoded<Value> {
        do throws(JSONParseError) {
            let document = try JSONDocument(parsing: bytes, options: options.parse)
            return decode(document, options: options)
        } catch {
            return Decoded(value: nil, issues: [Issue(parsing: error)])
        }
    }

    public func decodeReporting(_ text: String, options: DecodeOptions = .strict) -> Decoded<Value> {
        decodeReporting(text.utf8, options: options)
    }

    private func run(_ json: JSONValue, document: JSONDocument?, options: DecodeOptions) -> Decoded<Value> {
        var state = DecodeState(options: options, document: document)
        let value = decoder(json, &state)
        // The decoder's contract is "nil exactly when an error was recorded";
        // trust the count over the value if the two ever disagree.
        // Text is reported in reading order, whatever order the schema
        // declares its fields in.
        let issues = state.resolvedIssues().inReadingOrder()
        guard state.errorCount == 0 else { return Decoded(value: nil, issues: issues) }
        return Decoded(value: value, issues: issues)
    }

    // MARK: Encoding

    /// The value as JSON.
    ///
    /// A `Double` that is NaN or infinite has no JSON spelling and is
    /// written as `null`, which decoding will then refuse; use
    /// ``validate(_:)`` to find such values before writing them.
    public func encode(_ value: Value, style: EncodeStyle = .full) -> JSONValue {
        var state = EncodeState(style: style)
        return encoder(value, &state) ?? .null
    }

    /// Every way `value` falls outside the schema, found by encoding it and
    /// decoding the result strictly. Empty if it is valid. Only errors are
    /// returned: a deprecated field that holds a value is a notice to the
    /// person editing a file, not a fault in the value.
    ///
    /// Swift values are not checked as they are mutated, so a settings
    /// struct edited in place can hold a speed the schema would never have
    /// decoded. This is the check to run before saving it.
    public func validate(_ value: Value) -> [Issue] {
        var state = EncodeState(style: .full)
        let json = encoder(value, &state) ?? .null
        // A value that cannot be written is encoded as null, which the
        // decode would then report a second time; keep the first report.
        let unwritable = Set(state.problems.map(\.path))
        return state.problems + decode(json, options: .strict).errors.filter { !unwritable.contains($0.path) }
    }
}

extension Issue {
    /// The issue for malformed input.
    init(parsing error: JSONParseError) {
        var parameters: JSONObject = [
            "parseCode": .string(error.code.rawValue),
            "message": .string(error.message),
        ]
        if let related = error.related {
            parameters["related"] = .string(related.description)
        }
        self.init(
            path: error.path, code: .parseError, parameters: parameters,
            source: SourceRange(start: error.location, end: error.location))
    }
}

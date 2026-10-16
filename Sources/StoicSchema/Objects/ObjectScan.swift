internal import StoicJSON

/// A key compared by its Unicode scalars, as JSON compares keys. Swift's
/// `String ==` treats `"é"` and `"e\u{301}"` as one string; as object keys
/// they are two, and a validator that merged them would read a different
/// document than the next parser does.
struct ExactKey: Hashable, Sendable {
    let value: String

    init(_ value: String) { self.value = value }

    static func == (lhs: ExactKey, rhs: ExactKey) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for byte in value.utf8 { hasher.combine(byte) }
        hasher.combine(0xFF as UInt8)
    }
}

/// The keys an object declares, with their aliases, in declaration order.
struct DeclaredKey: Sendable {
    var key: String
    var aliases: [String]
}

/// An object's keys, with everything reading needs to know about them worked
/// out once, when the schema is built: the exact spellings, the normalised
/// ones, and the names a did-you-mean is drawn from.
struct DeclaredKeys: Sendable {
    let declared: [DeclaredKey]
    /// Every key and alias the object declares. A member with one of these
    /// exact spellings belongs to its own field, so the fuzzy matching in
    /// ``ObjectScan`` never hands it to a different one.
    let known: Set<ExactKey>
    /// Each normalised key and alias, and the field key it belongs to.
    let owners: [String: String]
    /// Each alias, and the field key it is an alias of.
    private let canonical: [String: String]
    private let names: SuggestionIndex

    /// Traps on a key or alias declared twice: a mistake in the schema,
    /// found by the first test that touches it.
    init(_ declared: [DeclaredKey], in name: String) {
        checkDeclaredKeys(declared, in: name)
        self.declared = declared
        var known: Set<ExactKey> = []
        var owners: [String: String] = [:]
        var canonical: [String: String] = [:]
        var names: [String] = []
        for declaration in declared {
            known.insert(ExactKey(declaration.key))
            owners[Suggestions.normalized(declaration.key)] = declaration.key
            names.append(declaration.key)
            for alias in declaration.aliases {
                known.insert(ExactKey(alias))
                owners[Suggestions.normalized(alias)] = declaration.key
                canonical[alias] = declaration.key
                names.append(alias)
            }
        }
        self.known = known
        self.owners = owners
        self.canonical = canonical
        self.names = SuggestionIndex(names)
    }

    /// The fields `key` was probably meant to be, nearest first: a
    /// misspelt alias suggests the field's own key.
    func suggestions(for key: String) -> [String] {
        var suggestions: [String] = []
        for name in names.nearest(to: key) {
            let field = canonical[name] ?? name
            if !suggestions.contains(field) { suggestions.append(field) }
        }
        return suggestions
    }
}

/// How a key in the input was matched to a field.
struct KeyHit {
    var value: JSONValue
    /// The key as the input spelled it.
    var spelling: String
    /// Whether the spelling differs from the field's own key.
    var isAlternateSpelling: Bool
}

/// One object being read: which of its members have been claimed by a
/// field, and what is left over.
///
/// Reading is two passes over the same state. Each field asks for its key
/// (``find(key:aliases:state:)``) and decodes what it gets; when all fields
/// have asked, ``finish(policy:state:)`` looks at the members nobody
/// claimed and decides which are unknown keys, which are second spellings of
/// a field already read, and what to suggest for each.
struct ObjectScan {
    let object: JSONObject
    private let keys: DeclaredKeys
    private var claimed: Set<Int> = []
    private var byNormalizedKey: [String: [Int]]?
    /// Whether some member has a key the object does not declare. A
    /// respelling can only be one of those, so without any the table below
    /// is never needed: the common document that simply leaves out the keys
    /// whose defaults it accepts costs no more than the keys it has.
    private var hasUndeclaredMember: Bool?

    init(object: JSONObject, keys: DeclaredKeys) {
        self.object = object
        self.keys = keys
    }

    /// The member for a field: its own key; failing that one of its
    /// aliases; failing that a spelling that differs only in case or word
    /// separators (`scroll_speed` for `scrollSpeed`). The last two are
    /// accepted with a `deprecated_key` warning, which is reported here
    /// because only here is the spelling known.
    mutating func find(key: String, aliases: [String], state: inout DecodeState) -> KeyHit? {
        if let index = object.index(forKey: key) {
            claimed.insert(index)
            return KeyHit(value: object[index].value, spelling: key, isAlternateSpelling: false)
        }
        for alias in aliases {
            if let index = object.index(forKey: alias) {
                claimed.insert(index)
                return alternate(at: index, field: key, state: &state)
            }
        }
        // Spellings that differ only by case or separators. Built once per
        // object, and only if some field is missing its exact key and some
        // member could be a respelling of it.
        if hasUndeclaredMember == nil {
            hasUndeclaredMember = object.contains { !keys.known.contains(ExactKey($0.key)) }
        }
        guard hasUndeclaredMember == true else { return nil }
        if byNormalizedKey == nil {
            var table: [String: [Int]] = [:]
            for index in object.indices {
                table[Suggestions.normalized(object[index].key), default: []].append(index)
            }
            byNormalizedKey = table
        }
        for spelling in [key] + aliases {
            for index in byNormalizedKey?[Suggestions.normalized(spelling)] ?? [] {
                guard !claimed.contains(index), !keys.known.contains(ExactKey(object[index].key)) else { continue }
                claimed.insert(index)
                return alternate(at: index, field: key, state: &state)
            }
        }
        return nil
    }

    private func alternate(at index: Int, field: String, state: inout DecodeState) -> KeyHit {
        let member = object[index]
        state.report(
            .deprecatedKey, severity: .warning,
            path: state.path.appending(key: field),
            sourcePath: state.inputPath.appending(key: member.key),
            target: .key,
            parameters: ["key": .string(member.key), "replacement": .string(field)],
            suggestions: [field], suggestionsAreFromInput: false)
        return KeyHit(value: member.value, spelling: member.key, isAlternateSpelling: true)
    }

    /// Claims, and returns, the members that nothing in the schema accounts
    /// for: neither a declared key, nor an alias, nor a respelling of
    /// either. These are what ``UnknownKeyPolicy/preserve`` keeps.
    ///
    /// The answer does not depend on which fields have been read so far,
    /// because it is decided by the declared names alone, so a reader may
    /// ask at any point.
    mutating func takePreserved() -> JSONObject {
        var kept = JSONObject()
        for index in object.indices where !claimed.contains(index) {
            let member = object[index]
            guard keys.owners[Suggestions.normalized(member.key)] == nil else { continue }
            claimed.insert(index)
            kept[member.key] = member.value
        }
        return kept
    }

    /// Accounts for the members no field claimed.
    ///
    /// - A member that is another spelling of a field that was already read
    ///   (so the field appears twice) is a `duplicate_key` error: which
    ///   spelling wins would be a guess, and a guess that differs between
    ///   two readers is the kind of ambiguity attacks live in.
    /// - Anything else is an unknown key, handled per `policy`, with up to
    ///   three suggestions from the declared keys and aliases.
    mutating func finish(policy: UnknownKeyPolicy, state: inout DecodeState) {
        guard claimed.count < object.count else { return }
        for index in object.indices where !claimed.contains(index) {
            let key = object[index].key
            let path = state.path.appending(key: key)
            let sourcePath = state.inputPath.appending(key: key)
            if let owner = keys.owners[Suggestions.normalized(key)] {
                state.report(
                    .duplicateKey, path: path, sourcePath: sourcePath, target: .key,
                    parameters: ["key": .string(key), "other": .string(owner)],
                    suggestions: [], suggestionsAreFromInput: false)
                continue
            }
            switch policy {
            case .ignore, .preserve:
                continue
            case .reject, .warn:
                // Under lenient decoding a rejected key is ignored and
                // reported as such: the file is still read.
                let severity: Issue.Severity
                var parameters: JSONObject = ["key": .string(key)]
                if policy == .warn {
                    severity = .warning
                } else if state.isLenient {
                    severity = .repaired
                    parameters["repair"] = .string("ignored it")
                } else {
                    severity = .error
                }
                state.report(
                    .unknownKey, severity: severity, path: path, sourcePath: sourcePath, target: .key,
                    parameters: parameters, suggestions: keys.suggestions(for: key), suggestionsAreFromInput: false)
            }
        }
    }
}

/// What a field needs to be read from an object: where to look, how to
/// decode, and what to fall back to.
struct FieldSpec<V: Sendable> {
    var key: String
    var aliases: [String]
    var schema: Schema<V>
    var isSecret: Bool
    var deprecation: Deprecation?
    var defaultValue: V?
}

/// Reads one field of an object, for both object forms.
///
/// - Present: decoded by the field's schema. If that fails and the decode is
///   lenient and the field has a default, the errors become `repaired`
///   issues and the default is the result.
/// - Absent: the default, else the schema's own meaning of absence (an
///   optional's `nil`), else a `missing_key` error.
///
/// Returns `nil` exactly when it recorded an error.
func readField<V: Sendable>(
    _ spec: FieldSpec<V>,
    scan: inout ObjectScan,
    state: inout DecodeState
) -> V? {
    guard let hit = scan.find(key: spec.key, aliases: spec.aliases, state: &state) else {
        if let value = spec.defaultValue { return value }
        if let value = spec.schema.absent() { return value }
        state.report(
            .missingKey, path: state.path.appending(key: spec.key), sourcePath: state.inputPath,
            parameters: ["key": .string(spec.key)], expected: spec.schema.node.expectation)
        return nil
    }
    state.push(key: spec.key, spelledAs: hit.spelling)
    defer { state.pop() }
    if let deprecation = spec.deprecation {
        var parameters: JSONObject = ["key": .string(spec.key)]
        if !deprecation.message.isEmpty { parameters["reason"] = .string(deprecation.message) }
        state.report(.deprecatedKey, severity: .warning, target: .key, parameters: parameters)
    }
    if spec.isSecret { state.secretDepth += 1 }
    defer { if spec.isSecret { state.secretDepth -= 1 } }
    let mark = state.issues.count
    let errorsBefore = state.errorCount
    if let value = spec.schema.decoder(hit.value, &state) { return value }
    if state.isLenient, let fallback = spec.defaultValue {
        var scratch = EncodeState(style: .full)
        let shown = spec.isSecret ? nil : spec.schema.encoder(fallback, &scratch)?.briefDescription
        state.repair(since: mark, errorsBefore: errorsBefore, using: shown)
        return fallback
    }
    return nil
}

internal import StoicJSON

extension Schema {
    /// A tagged union: a Swift enumeration with payloads, written as an
    /// object whose `discriminator` key names the case.
    ///
    ///     {"type": "circle", "radius": 5}
    ///     {"type": "rect", "width": 3, "height": 4}
    ///     {"type": "point"}
    ///
    /// Swift's own coding of such an enumeration (`{"circle": {"_0": …}}`)
    /// is unusable on a wire: no other language reads it, no schema
    /// describes it, and an error in it points at `_0`. This is the shape
    /// everyone else uses (it is `oneOf` with a `const` discriminator in
    /// JSON Schema, a discriminated union in TypeScript, an internally
    /// tagged enum in serde), declared once; see ``Case`` for how a case is
    /// declared.
    ///
    /// **Decoding** looks at the discriminator first, because until it is
    /// known nothing else can be:
    ///
    /// - not an object is a `type_mismatch`;
    /// - a missing discriminator is `missing_key` at `$.type`;
    /// - a discriminator that is not a string is a `type_mismatch` there;
    /// - one that names no case is `not_one_of` there, listing the tags and
    ///   suggesting the nearest by spelling, as for an enumeration; unless
    ///   the union has an ``UnknownTag``: then the object is read as that
    ///   case, with an `unknown_case` *warning* there (the same nearest-tag
    ///   suggestion), and its other members are handed over unread.
    ///
    /// Once the case is known, its payload is decoded as any schema is,
    /// accumulating: a `circle` with a bad radius and a stray key reports
    /// both, at `$.radius` and `$.radus`. The payload sees the object
    /// without its discriminator, so an object payload that rejects unknown
    /// keys does not reject `type`.
    ///
    /// **Encoding** finds the case the value is, writes its payload, and
    /// puts the discriminator first so a person reading the file sees what
    /// kind of thing it is before the details. A value that is none of the
    /// declared cases (nor the unknown case) is a mistake in the declaration
    /// and is reported by ``validate(_:)``. The unknown case writes the tag
    /// and members it holds, none if it kept none.
    ///
    /// **A payload that is not an object** is written under `valueKey`:
    /// `{"type": "label", "value": "Hello"}`. A transparent wrapper around
    /// an object is still that object. (A `lazy` payload counts as not an
    /// object, because looking inside it while the schema is being built
    /// would recurse.)
    ///
    /// A tag declared twice, a discriminator that a flat payload also
    /// declares as a field, or a value key equal to the discriminator is a
    /// mistake in the schema and traps when the schema is first built.
    ///
    /// - Parameters:
    ///   - type: The enumeration, to let the compiler infer the cases'
    ///     root type; may be left out when the cases make it clear.
    ///   - discriminator: The key that names the case.
    ///   - name: The type's name in the export; defaults to `Value`'s.
    ///   - doc: Documentation of the union.
    ///   - valueKey: Where a payload that is not an object is written.
    ///   - unknown: What a tag that names no case is read as; `nil` (the
    ///     default) keeps the union closed. A plain unknown case is written
    ///     under its name, so the name should not be a declared tag; see
    ///     ``UnknownTag``.
    ///   - makeCases: Builds the alternatives, in the order they are documented.
    public static func union(
        _ type: Value.Type? = nil,
        discriminator: String = "type",
        name: String? = nil,
        doc: String? = nil,
        valueKey: String = "value",
        unknown: UnknownTag<Value>? = nil,
        @CasesBuilder<Value> cases makeCases: () -> [Case<Value>]
    ) -> Schema<Value> {
        let name = name ?? String(describing: Value.self)
        let cases = makeCases()
        precondition(!cases.isEmpty, "\(name): a union needs at least one case")
        precondition(discriminator != valueKey, "\(name): the discriminator and the value key are both \"\(discriminator)\"")
        var byTag: [ExactKey: Int] = [:]
        for (index, entry) in cases.enumerated() {
            precondition(
                byTag.updateValue(index, forKey: ExactKey(entry.tag)) == nil,
                "\(name): the tag \"\(entry.tag)\" is declared twice")
            if let payload = entry.node.objectUnderTransparentWrappers {
                let spellings = payload.fields.flatMap { [$0.key] + $0.aliases }
                precondition(
                    !spellings.contains(where: { ExactKey($0) == ExactKey(discriminator) }),
                    "\(name): the payload of \"\(entry.tag)\" declares \"\(discriminator)\", which the union writes itself")
            }
        }
        let lookup = byTag
        let node = UnionNode(
            name: name, doc: doc, discriminator: discriminator, valueKey: valueKey,
            cases: cases.map { UnionCaseNode(tag: $0.tag, doc: $0.doc, node: $0.node, isFlat: $0.isFlat) },
            unknownCase: unknown?.name)
        let tagList = JSONValue.array(node.tags.map { .string($0) })
        let tagNames = SuggestionIndex(node.tags)
        let memberNames = SuggestionIndex([discriminator, valueKey])
        let tagExpectation = node.tagExpectation
        return Schema(
            node: .union(node),
            decoder: { json, state in
                guard case .object(let object) = json else {
                    state.typeMismatch(expected: node.expectation, found: json)
                    return nil
                }
                guard let tagJSON = object[discriminator] else {
                    state.report(
                        .missingKey, path: state.path.appending(key: discriminator), sourcePath: state.inputPath,
                        parameters: ["key": .string(discriminator)], expected: tagExpectation)
                    return nil
                }
                state.push(key: discriminator)
                guard case .string(let tag) = tagJSON else {
                    state.typeMismatch(expected: tagExpectation, found: tagJSON)
                    state.pop()
                    return nil
                }
                guard let index = lookup[ExactKey(tag)] else {
                    if let unknown {
                        // The shape of what follows is unknown, so none of it
                        // is read: it is handed over as it came.
                        state.report(
                            .unknownCase, severity: .warning, parameters: ["fallback": .string(unknown.name)],
                            expected: tagExpectation, actual: tagJSON.briefDescription,
                            suggestions: tagNames.nearest(to: tag))
                        state.pop()
                        var rest = JSONObject()
                        for member in object where !ExactKey(member.key).isEqual(to: discriminator) {
                            rest[member.key] = member.value
                        }
                        return unknown.read(tag, rest)
                    }
                    state.report(
                        .notOneOf, parameters: ["tags": tagList],
                        expected: tagExpectation, actual: tagJSON.briefDescription,
                        suggestions: tagNames.nearest(to: tag))
                    state.pop()
                    return nil
                }
                state.pop()
                let entry = cases[index]
                if entry.isFlat {
                    var rest = JSONObject()
                    for member in object where !ExactKey(member.key).isEqual(to: discriminator) {
                        rest[member.key] = member.value
                    }
                    return entry.decode(.object(rest), &state)
                }
                return decodeKeyed(entry, object: object, node: node, memberNames: memberNames, state: &state)
            },
            encoder: { value, state in
                for entry in cases {
                    guard let written = entry.encode(value, &state) else { continue }
                    var members: [JSONObject.Member] = [
                        JSONObject.Member(key: discriminator, value: .string(entry.tag))
                    ]
                    if entry.isFlat {
                        if case .object(let payload)? = written {
                            members.append(contentsOf: payload.filter { !ExactKey($0.key).isEqual(to: discriminator) })
                        }
                    } else if let payload = written {
                        members.append(JSONObject.Member(key: valueKey, value: payload))
                    }
                    return .object(JSONObject(members))
                }
                if let (tag, payload) = unknown?.write(value) {
                    var members: [JSONObject.Member] = [JSONObject.Member(key: discriminator, value: .string(tag))]
                    members.append(contentsOf: payload.filter { !ExactKey($0.key).isEqual(to: discriminator) })
                    return .object(JSONObject(members))
                }
                state.problems.append(
                    Issue(
                        path: state.path, code: .invalidValue,
                        parameters: ["message": .string("is none of the cases the union declares")],
                        expected: tagExpectation))
                return .null
            })
    }
}

/// Decodes a case whose payload sits under the value key: the object may
/// hold the discriminator and the value key and nothing else.
private func decodeKeyed<Root: Sendable>(
    _ entry: Case<Root>,
    object: JSONObject,
    node: UnionNode,
    memberNames: SuggestionIndex,
    state: inout DecodeState
) -> Root? {
    let errorsBefore = state.errorCount
    var payload: Root?
    if let value = object[node.valueKey] {
        state.push(key: node.valueKey)
        payload = entry.decode(value, &state)
        state.pop()
    } else {
        state.report(
            .missingKey, path: state.path.appending(key: node.valueKey), sourcePath: state.inputPath,
            parameters: ["key": .string(node.valueKey)], expected: entry.node.expectation)
    }
    for member in object where !ExactKey(member.key).isEqual(to: node.discriminator) && !ExactKey(member.key).isEqual(to: node.valueKey) {
        state.report(
            .unknownKey, severity: state.isLenient ? .repaired : .error,
            path: state.path.appending(key: member.key), sourcePath: state.inputPath.appending(key: member.key),
            target: .key,
            parameters: state.isLenient
                ? ["key": .string(member.key), "repair": .string("ignored it")] : ["key": .string(member.key)],
            suggestions: memberNames.nearest(to: member.key),
            suggestionsAreFromInput: false)
    }
    return state.errorCount == errorsBefore ? payload : nil
}

extension ExactKey {
    /// Whether this key is the same string as `other`, by scalars.
    func isEqual(to other: String) -> Bool {
        self == ExactKey(other)
    }
}

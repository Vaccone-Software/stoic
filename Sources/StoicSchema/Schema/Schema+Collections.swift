internal import StoicJSON

extension Schema {
    /// An array whose elements all follow `element`.
    ///
    /// Every element is decoded, so three bad elements are three issues, at
    /// `$.hosts[1]`, `$.hosts[4]` and `$.hosts[5]`. Constraints are about
    /// the array: `.count(0...8)`, `.unique`. Count and uniqueness are
    /// checked even when elements failed, so the issue list is complete.
    public static func array<Element: Sendable>(
        of element: Schema<Element>,
        _ constraints: Constraint...
    ) -> Schema<[Element]> where Value == [Element] {
        arraySchema(of: element, constraints)
    }

    /// An array with a count: `.array(of: .string(), count: 0...8)`.
    public static func array<Element: Sendable>(
        of element: Schema<Element>,
        count: some CountBounds,
        _ constraints: Constraint...
    ) -> Schema<[Element]> where Value == [Element] {
        arraySchema(of: element, [.count(count)] + constraints)
    }

    private static func arraySchema<Element: Sendable>(
        of element: Schema<Element>,
        _ constraints: [Constraint]
    ) -> Schema<[Element]> {
        Schema<[Element]>(
            node: .array(element: element.node, constraints: constraints),
            decoder: { json, state in
                guard case .array(let items) = json else {
                    state.typeMismatch(expected: "an array", found: json)
                    return nil
                }
                var values: [Element] = []
                values.reserveCapacity(items.count)
                var failed = false
                for (index, item) in items.enumerated() {
                    state.push(index: index)
                    if let value = element.decoder(item, &state) {
                        values.append(value)
                    } else {
                        failed = true
                    }
                    state.pop()
                }
                // Check the array's own rules even if an element failed, so
                // the caller sees the whole list of problems at once.
                let satisfied = state.apply(constraints, to: json)
                return failed || !satisfied ? nil : values
            },
            encoder: { values, state in
                var items: [JSONValue] = []
                items.reserveCapacity(values.count)
                for (index, value) in values.enumerated() {
                    state.push(index: index)
                    items.append(element.encoder(value, &state) ?? .null)
                    state.pop()
                }
                return .array(items)
            })
    }

    /// An array that survives its bad elements: one that does not decode is
    /// left out, and the rest are kept.
    ///
    /// For a response from a server you do not control, where one malformed
    /// element should cost that element and not the whole list. Each dropped
    /// element is one `dropped_element` warning at its place in the input
    /// (so the index is the one the server sent), carrying the `index` and
    /// the first reason as parameters; the element's own errors are not
    /// reported. A value that is not an array at all is still a
    /// `type_mismatch`.
    ///
    /// The array's own constraints (`.count`, `.unique`) are checked on what
    /// is kept, so a list that falls below its minimum after dropping is
    /// still an error, and an element that repeats an earlier one is
    /// reported at its place among the kept ones.
    public static func lossyArray<Element: Sendable>(
        of element: Schema<Element>,
        _ constraints: Constraint...
    ) -> Schema<[Element]> where Value == [Element] {
        let strict = arraySchema(of: element, constraints)
        let inner = strict.node
        return Schema<[Element]>(
            node: .transformed(
                TransformNode(
                    base: inner, name: "lossy array",
                    description: "an array whose invalid elements are dropped",
                    keywords: ["x-stoic-lossy": true], dropsInvalidElements: true)),
            decoder: { json, state in
                guard case .array(let items) = json else {
                    state.typeMismatch(expected: "an array", found: json)
                    return nil
                }
                var values: [Element] = []
                var kept: [JSONValue] = []
                values.reserveCapacity(items.count)
                for (index, item) in items.enumerated() {
                    let mark = state.issues.count
                    let errorsBefore = state.errorCount
                    state.push(index: index)
                    if let value = element.decoder(item, &state) {
                        values.append(value)
                        kept.append(item)
                    } else {
                        state.dropElement(at: index, since: mark, errorsBefore: errorsBefore)
                    }
                    state.pop()
                }
                return state.apply(constraints, to: .array(kept)) ? values : nil
            },
            encoder: strict.encoder)
    }

    /// An object with arbitrary string keys, every value following `value`.
    ///
    /// Constraints are about the entries: `.count(1...100)`. Keys are
    /// written in sorted order, so the same dictionary always encodes to the
    /// same text (Swift's own order changes from run to run).
    ///
    /// A Swift `String` key cannot tell `"é"` from `"e\u{301}"`, which JSON
    /// keeps apart. A document with both would silently lose one entry, so
    /// the second is a `duplicate_key` error instead.
    public static func dictionary<Entry: Sendable>(
        of value: Schema<Entry>,
        _ constraints: Constraint...
    ) -> Schema<[String: Entry]> where Value == [String: Entry] {
        dictionarySchema(of: value, constraints)
    }

    private static func dictionarySchema<Entry: Sendable>(
        of value: Schema<Entry>,
        _ constraints: [Constraint]
    ) -> Schema<[String: Entry]> {
        Schema<[String: Entry]>(
            node: .dictionary(value: value.node, constraints: constraints),
            decoder: { json, state in
                guard case .object(let object) = json else {
                    state.typeMismatch(expected: "an object", found: json)
                    return nil
                }
                var entries: [String: Entry] = [:]
                entries.reserveCapacity(object.count)
                var spelledFirst: [String: String] = [:]
                var failed = false
                for member in object {
                    if let first = spelledFirst[member.key] {
                        // Distinct in JSON, one key to Swift: refuse rather than
                        // let the later entry replace the earlier.
                        state.report(
                            .duplicateKey, path: state.path.appending(key: member.key),
                            sourcePath: state.inputPath.appending(key: member.key), target: .key,
                            parameters: ["key": .string(member.key), "other": .string(first)],
                            suggestionsAreFromInput: false)
                        failed = true
                        continue
                    }
                    spelledFirst[member.key] = member.key
                    state.push(key: member.key)
                    if let decoded = value.decoder(member.value, &state) {
                        entries[member.key] = decoded
                    } else {
                        failed = true
                    }
                    state.pop()
                }
                let satisfied = state.apply(constraints, to: json)
                return failed || !satisfied ? nil : entries
            },
            encoder: { entries, state in
                var object = JSONObject()
                for key in entries.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    guard let entry = entries[key] else { continue }
                    state.push(key: key)
                    if let encoded = value.encoder(entry, &state) { object[key] = encoded }
                    state.pop()
                }
                return .object(object)
            })
    }

    /// ``dictionary(of:_:)`` whose values carry a description, so the JSON
    /// Schema export can say what each entry means.
    ///
    ///     .dictionary(of: .bool, valueDoc: "true to never record clips from this app")
    ///
    /// The description is written beside the values' schema (`additionalProperties`
    /// is `{"type": "boolean", "description": "…"}`); decoding is unchanged.
    /// It is ``documented(_:)`` on the value schema, for a dictionary.
    public static func dictionary<Entry: Sendable>(
        of value: Schema<Entry>,
        _ constraints: Constraint...,
        valueDoc: String
    ) -> Schema<[String: Entry]> where Value == [String: Entry] {
        dictionarySchema(of: value.documented(valueDoc), constraints)
    }

    /// A dictionary that survives its bad entries: an entry whose value does
    /// not decode is left out, and the rest are kept.
    ///
    /// For a table a person fills in by hand (a per-app override, a list of
    /// routes), where one wrong value should cost that entry and not the
    /// whole table (which ``dictionary(of:_:)`` repairs to empty under
    /// `.lenient`). Each dropped entry is one `dropped_entry` warning at its
    /// own path (`$.apps["com.example.Foo"]`) carrying its `key` and the
    /// first reason in the parameters; the entry's own errors are not
    /// reported. A value that is not an object at all is still a
    /// `type_mismatch`, and a key spelt two ways that Swift reads as one
    /// (`"é"` and `"e\u{301}"`) drops the second, with a warning, where the
    /// strict form refuses the document.
    ///
    /// The dictionary's own constraints (`.count`) are checked on what is
    /// kept, so a table that falls under its minimum after dropping is still
    /// an error. `valueDoc` describes the values in the export, as for
    /// ``dictionary(of:_:valueDoc:)``.
    public static func lossyDictionary<Entry: Sendable>(
        of value: Schema<Entry>,
        _ constraints: Constraint...,
        valueDoc: String? = nil
    ) -> Schema<[String: Entry]> where Value == [String: Entry] {
        let value = valueDoc.map { value.documented($0) } ?? value
        let strict = dictionarySchema(of: value, constraints)
        var transform = TransformNode(
            base: strict.node, name: "lossy dictionary",
            description: "an object whose invalid entries are dropped",
            keywords: ["x-stoic-lossy": true], dropsInvalidElements: true)
        transform.isTransparent = true
        return Schema<[String: Entry]>(
            node: .transformed(transform),
            decoder: { json, state in
                guard case .object(let object) = json else {
                    state.typeMismatch(expected: "an object", found: json)
                    return nil
                }
                var entries: [String: Entry] = [:]
                var kept = JSONObject()
                entries.reserveCapacity(object.count)
                for member in object {
                    let mark = state.issues.count
                    let errorsBefore = state.errorCount
                    state.push(key: member.key)
                    if entries.index(forKey: member.key) != nil {
                        state.report(
                            .duplicateKey, parameters: ["key": .string(member.key), "other": .string(member.key)],
                            suggestionsAreFromInput: false)
                        state.dropEntry(key: member.key, since: mark, errorsBefore: errorsBefore)
                    } else if let decoded = value.decoder(member.value, &state) {
                        entries[member.key] = decoded
                        kept[member.key] = member.value
                    } else {
                        state.dropEntry(key: member.key, since: mark, errorsBefore: errorsBefore)
                    }
                    state.pop()
                }
                return state.apply(constraints, to: .object(kept)) ? entries : nil
            },
            encoder: strict.encoder)
    }

    /// Documents a value's schema: the export writes `doc` as its
    /// `description`, and nothing else changes.
    ///
    /// For a place a field's own `doc:` cannot reach: the values of a
    /// dictionary, the elements of an array.
    ///
    ///     .dictionary(of: Schema.bool.documented("true to never record clips from this app"))
    ///
    /// Decoding, encoding, generation and the constraints are the schema's
    /// own. A `description` the schema already carries is replaced.
    public func documented(_ doc: String) -> Schema<Value> {
        var transform = TransformNode(
            base: node, name: "documented value", description: node.expectation,
            keywords: ["description": .string(doc)], isAnnotated: false)
        transform.isTransparent = true
        return Schema(node: .transformed(transform), decoder: decoder, encoder: encoder, absent: absent)
    }
}

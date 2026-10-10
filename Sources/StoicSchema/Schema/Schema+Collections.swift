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
}

public import StoicJSON

/// A deliberately small JSON Schema (Draft 2020-12) validator: only the
/// keywords ``Schema/jsonSchema()`` writes, following the specification's
/// meaning for each, and nothing else.
///
/// It exists so the exporter can be tested against something that is not
/// the decoder: if the two agree on a document, then the document the
/// schema describes is the document the decoder accepts. ``SchemaSuite``
/// runs that comparison on every generated document. It is not a general
/// validator and is not a substitute for one: it ignores keywords it does
/// not know (including every `x-stoic-` annotation) and has no `$ref`
/// beyond local `#/` pointers.
///
/// Numbers are compared by their decimal digits, as the decoder does and not
/// through `Double`, so integer bounds beyond 2^53 are judged correctly.
public struct JSONSchemaValidator: Sendable {
    public let root: JSONValue

    public init(_ root: JSONValue) {
        self.root = root
    }

    /// Whether `instance` is valid against the root schema.
    public func accepts(_ instance: JSONValue) -> Bool {
        accepts(instance, against: root)
    }

    private func accepts(_ instance: JSONValue, against schema: JSONValue) -> Bool {
        if case .bool(let allowed) = schema { return allowed }
        guard let schema = schema.object else { return false }

        if let ref = schema["$ref"]?.string {
            guard let target = resolve(ref), accepts(instance, against: target) else { return false }
        }
        if let branches = schema["allOf"]?.array {
            for branch in branches where !accepts(instance, against: branch) { return false }
        }
        if let branches = schema["anyOf"]?.array {
            guard branches.contains(where: { accepts(instance, against: $0) }) else { return false }
        }
        if let excluded = schema["not"], accepts(instance, against: excluded) { return false }
        if let branches = schema["oneOf"]?.array {
            // Exactly one branch: the discriminator makes that decidable.
            guard branches.filter({ accepts(instance, against: $0) }).count == 1 else { return false }
        }
        if let type = schema["type"]?.string, !matches(type: type, instance) { return false }
        if let allowed = schema["enum"]?.array, !allowed.contains(instance) { return false }
        if let constant = schema["const"], constant != instance { return false }

        switch instance {
        case .number(let number): return acceptsNumber(number, schema)
        case .string(let string): return acceptsString(string, schema)
        case .array(let items): return acceptsArray(items, schema)
        case .object(let object): return acceptsObject(object, schema)
        case .null, .bool: return true
        }
    }

    private func resolve(_ ref: String) -> JSONValue? {
        guard ref.hasPrefix("#/") else { return ref == "#" ? root : nil }
        var current = root
        for token in ref.dropFirst(2).split(separator: "/") {
            let key = token.replacing("~1", with: "/").replacing("~0", with: "~")
            guard let next = current.object?[String(key)] else { return nil }
            current = next
        }
        return current
    }

    private func matches(type: String, _ instance: JSONValue) -> Bool {
        switch (type, instance) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object):
            return true
        case ("number", .number):
            return true
        case ("integer", .number(let number)):
            // Draft 2020-12: any number with a zero fractional part.
            return number.hasIntegralValue
        default:
            return false
        }
    }

    private func acceptsNumber(_ number: JSONNumber, _ schema: JSONObject) -> Bool {
        if let bound = schema["minimum"]?.number, number.compared(to: bound) < 0 { return false }
        if let bound = schema["maximum"]?.number, number.compared(to: bound) > 0 { return false }
        if let bound = schema["exclusiveMinimum"]?.number, number.compared(to: bound) <= 0 { return false }
        if let bound = schema["exclusiveMaximum"]?.number, number.compared(to: bound) >= 0 { return false }
        if let step = schema["multipleOf"]?.number, !number.isMultiple(of: step) { return false }
        return true
    }

    private func acceptsString(_ string: String, _ schema: JSONObject) -> Bool {
        let length = string.unicodeScalars.count
        if let bound = schema["minLength"]?.number?.int64, length < bound { return false }
        if let bound = schema["maxLength"]?.number?.int64, length > bound { return false }
        if let pattern = schema["pattern"]?.string {
            guard let regex = try? Regex(pattern).matchingSemantics(.unicodeScalar) else { return false }
            if string.firstMatch(of: regex) == nil { return false }
        }
        return true
    }

    private func acceptsArray(_ items: [JSONValue], _ schema: JSONObject) -> Bool {
        if let bound = schema["minItems"]?.number?.int64, items.count < bound { return false }
        if let bound = schema["maxItems"]?.number?.int64, items.count > bound { return false }
        if schema["uniqueItems"]?.bool == true, Set(items).count != items.count { return false }
        if let element = schema["items"] {
            for item in items where !accepts(item, against: element) { return false }
        }
        return true
    }

    private func acceptsObject(_ object: JSONObject, _ schema: JSONObject) -> Bool {
        if let bound = schema["minProperties"]?.number?.int64, object.count < bound { return false }
        if let bound = schema["maxProperties"]?.number?.int64, object.count > bound { return false }
        for key in schema["required"]?.array?.compactMap(\.string) ?? [] where !object.contains(key: key) {
            return false
        }
        let properties = schema["properties"]?.object
        for member in object {
            if let property = properties?[member.key] {
                if !accepts(member.value, against: property) { return false }
            } else if let additional = schema["additionalProperties"] {
                if !accepts(member.value, against: additional) { return false }
            }
        }
        return true
    }
}

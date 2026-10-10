public import StoicJSON

/// A JSON Schema document and what it could not say.
public struct JSONSchemaExport: Sendable {
    /// A rule the schema enforces that JSON Schema cannot express: a
    /// ``Constraint/custom(id:description:check:)``. The export carries it as
    /// an `x-stoic-constraint` annotation so a reader sees that it exists,
    /// but a plain JSON Schema validator will not enforce it.
    public struct Unenforced: Sendable, Hashable {
        /// Where, in the instance: `$.network.hosts[]` (`[]` is any element).
        public var location: String
        public var id: String
        public var description: String

        public init(location: String, id: String, description: String) {
            self.location = location
            self.id = id
            self.description = description
        }
    }

    /// The document, Draft 2020-12.
    public var schema: JSONValue

    /// Everything that is enforced by Stoic and only annotated in `schema`.
    public var unenforced: [Unenforced]
}

extension Schema {
    /// The schema as a JSON Schema (Draft 2020-12) document.
    ///
    /// The mapping is direct, because the schema is data: ranges become
    /// `minimum`/`maximum` and their exclusive forms, `multipleOf`,
    /// string lengths `minLength`/`maxLength`, `pattern`, `oneOf` an
    /// `enum`, counts `minItems`/`maxItems` (`minProperties`/`maxProperties`
    /// for an object), `unique` `uniqueItems`, defaults `default` (from the
    /// default instance, encoded; never for a secret), `doc` `description`,
    /// deprecation `deprecated`. An object that rejects unknown keys gets
    /// `additionalProperties: false`, and one built without defaults lists
    /// its required keys. Recursive schemas use `$defs` and `$ref`.
    ///
    /// Stoic's own metadata is under `x-stoic-` keys: `x-stoic-unit`,
    /// `x-stoic-secret`, `x-stoic-aliases`, `x-stoic-deprecation` (the
    /// message), `x-stoic-length` for string lengths not counted in
    /// characters (Unicode scalars, the only unit JSON Schema has), and
    /// `x-stoic-constraint` for custom rules, which no JSON Schema validator
    /// can run.
    ///
    /// The document describes the canonical wire format. A decoder accepts a
    /// little more than a validator will (respellings of keys, with a
    /// warning), and a validator accepts a little more than the decoder
    /// (keys given twice, a custom rule): the decoder is the authority and
    /// the document is its documentation.
    public func jsonSchema() -> JSONValue {
        jsonSchemaExport().schema
    }

    /// ``jsonSchema()`` together with a list of the rules it could only annotate.
    public func jsonSchemaExport() -> JSONSchemaExport {
        var exporter = JSONSchemaExporter()
        let root = exporter.export(node, location: "$")
        var document = JSONObject()
        document["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        for member in root { document[member.key] = member.value }
        if !exporter.definitions.isEmpty { document["$defs"] = .object(exporter.definitions) }
        return JSONSchemaExport(schema: .object(document), unenforced: exporter.unenforced)
    }
}

/// Walks a ``SchemaNode`` and writes JSON Schema.
struct JSONSchemaExporter {
    var definitions = JSONObject()
    var unenforced: [JSONSchemaExport.Unenforced] = []
    private var started: Set<String> = []

    mutating func export(_ node: SchemaNode, location: String) -> JSONObject {
        var out = JSONObject()
        switch node {
        case .boolean:
            out["type"] = "boolean"

        case .integer(let type, let constraints):
            out["type"] = "integer"
            // The Swift type's own bounds are part of what it accepts. They
            // fill any side the constraints leave open.
            var lowerGiven = false
            var upperGiven = false
            for case .range(let range) in constraints.map(\.kind) {
                lowerGiven = lowerGiven || range.lower != nil
                upperGiven = upperGiven || range.upper != nil
            }
            if !lowerGiven { out["minimum"] = .number(type.minimum) }
            if !upperGiven { out["maximum"] = .number(type.maximum) }
            apply(constraints, to: &out, node: node, location: location)

        case .number(let constraints):
            out["type"] = "number"
            apply(constraints, to: &out, node: node, location: location)

        case .string(let constraints):
            out["type"] = "string"
            apply(constraints, to: &out, node: node, location: location)

        case .enumeration(_, let cases):
            out["type"] = "string"
            out["enum"] = .array(cases.map { .string($0) })

        case .integerEnumeration(_, let cases):
            out["type"] = "integer"
            out["enum"] = .array(cases.map { .number(JSONNumber($0.value)) })
            out["x-stoic-enum-names"] = .array(cases.map { .string($0.name) })

        case .transformed(let transform):
            out = export(transform.base, location: location)
            out["x-stoic-transform"] = .object([
                "name": .string(transform.name), "description": .string(transform.description),
            ])

        case .array(let element, let constraints):
            out["type"] = "array"
            out["items"] = .object(export(element, location: location + "[]"))
            apply(constraints, to: &out, node: node, location: location)

        case .dictionary(let value, let constraints):
            out["type"] = "object"
            out["additionalProperties"] = .object(export(value, location: location + ".*"))
            apply(constraints, to: &out, node: node, location: location)

        case .optional(let wrapped, let nullable):
            let inner = export(wrapped, location: location)
            if nullable {
                out["anyOf"] = .array([.object(inner), .object(["type": "null"])])
            } else {
                out = inner
            }

        case .json(let constraints):
            apply(constraints, to: &out, node: node, location: location)

        case .object(let object):
            out = export(object, location: location)

        case .lazy(let name, let resolve):
            if !started.contains(name) {
                started.insert(name)
                // Reserve the slot first so an inner reference finds it.
                definitions[name] = .object(JSONObject())
                let body = export(resolve(), location: location)
                definitions[name] = .object(body)
            }
            out["$ref"] = .string("#/$defs/" + Self.escapePointerToken(name))
        }
        return out
    }

    private mutating func export(_ object: ObjectNode, location: String) -> JSONObject {
        var out = JSONObject()
        out["type"] = "object"
        out["title"] = .string(object.name)
        if let doc = object.doc { out["description"] = .string(doc) }
        var properties = JSONObject()
        var required: [JSONValue] = []
        for field in object.fields {
            var property = export(field.node, location: location + "." + field.key)
            if let doc = field.doc { property["description"] = .string(doc) }
            if let value = field.defaultValue { property["default"] = value }
            if let deprecation = field.deprecation {
                property["deprecated"] = true
                if !deprecation.message.isEmpty { property["x-stoic-deprecation"] = .string(deprecation.message) }
            }
            if let unit = field.unit { property["x-stoic-unit"] = .string(unit) }
            if field.isSecret { property["x-stoic-secret"] = true }
            if !field.aliases.isEmpty { property["x-stoic-aliases"] = .array(field.aliases.map { .string($0) }) }
            properties[field.key] = .object(property)
            if field.isRequired { required.append(.string(field.key)) }
        }
        out["properties"] = .object(properties)
        if !required.isEmpty { out["required"] = .array(required) }
        if object.unknownKeys == .reject { out["additionalProperties"] = false }
        return out
    }

    // MARK: Constraints

    private mutating func apply(
        _ constraints: [Constraint],
        to out: inout JSONObject,
        node: SchemaNode,
        location: String
    ) {
        for constraint in constraints {
            switch constraint.kind {
            case .range(let range):
                if let lower = range.lower {
                    set(lower.isInclusive ? "minimum" : "exclusiveMinimum", .number(lower.value), in: &out)
                }
                if let upper = range.upper {
                    set(upper.isInclusive ? "maximum" : "exclusiveMaximum", .number(upper.value), in: &out)
                }

            case .multipleOf(let step):
                set("multipleOf", .number(step), in: &out)

            case .length(let range, let unit):
                if unit == .characters {
                    if let lower = range.lower { set("minLength", .number(JSONNumber(lower)), in: &out) }
                    if let upper = range.upper { set("maxLength", .number(JSONNumber(upper)), in: &out) }
                } else {
                    var length = JSONObject()
                    length["unit"] = .string(unit.name)
                    if let lower = range.lower { length["minimum"] = .number(JSONNumber(lower)) }
                    if let upper = range.upper { length["maximum"] = .number(JSONNumber(upper)) }
                    append("x-stoic-length", .object(length), in: &out)
                }

            case .count(let range):
                // Each keyword applies to its own kind of value, so a node
                // that could be either (any JSON) gets both pairs.
                var isArray = true
                var isObject = true
                switch node {
                case .array: isObject = false
                case .dictionary, .object: isArray = false
                default: break
                }
                if isArray {
                    if let lower = range.lower { set("minItems", .number(JSONNumber(lower)), in: &out) }
                    if let upper = range.upper { set("maxItems", .number(JSONNumber(upper)), in: &out) }
                }
                if isObject {
                    if let lower = range.lower { set("minProperties", .number(JSONNumber(lower)), in: &out) }
                    if let upper = range.upper { set("maxProperties", .number(JSONNumber(upper)), in: &out) }
                }

            case .pattern(let source):
                set("pattern", .string(source), in: &out)

            case .oneOf(let values):
                set("enum", .array(values), in: &out)

            case .unique:
                set("uniqueItems", true, in: &out)

            case .finite:
                // JSON has no non-finite numbers, so there is nothing to say.
                break

            case .custom(let custom):
                append(
                    "x-stoic-constraint",
                    .object(["id": .string(custom.id), "description": .string(custom.description)]), in: &out)
                unenforced.append(
                    JSONSchemaExport.Unenforced(location: location, id: custom.id, description: custom.description))
            }
        }
    }

    /// Writes a keyword. If the keyword is already there with a different
    /// value (two range constraints on one number), the new one goes in an
    /// `allOf` branch, which is conjunction and so keeps both.
    private func set(_ keyword: String, _ value: JSONValue, in out: inout JSONObject) {
        guard let existing = out[keyword] else {
            out[keyword] = value
            return
        }
        if existing == value { return }
        var branches = out["allOf"]?.array ?? []
        branches.append(.object([keyword: value]))
        out["allOf"] = .array(branches)
    }

    private func append(_ keyword: String, _ value: JSONValue, in out: inout JSONObject) {
        var items = out[keyword]?.array ?? []
        items.append(value)
        out[keyword] = .array(items)
    }

    private static func escapePointerToken(_ token: String) -> String {
        token.replacing("~", with: "~0").replacing("/", with: "~1")
    }
}

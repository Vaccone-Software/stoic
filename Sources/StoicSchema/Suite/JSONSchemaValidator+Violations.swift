public import StoicJSON

/// Where a document breaks a JSON Schema, and which keyword it breaks
/// (design/32).
public struct JSONSchemaViolation: Sendable, Hashable, CustomStringConvertible {
    /// Where in the instance.
    public let path: JSONPath
    /// The keyword it breaks: `"additionalProperties"`, `"required"`,
    /// `"const"`, `"type"`, …
    public let keyword: String
    /// What it breaks, in words.
    public let message: String
    /// Whether the reader would read the document anyway, best effort: a
    /// `const` on the version key of an object that preserves unknown keys
    /// (`x-stoic-preserves-unknown`), which a newer version breaks and an older
    /// reader meets with a `version_too_new` warning (design/06).
    public let readsBestEffort: Bool

    public init(path: JSONPath, keyword: String, message: String, readsBestEffort: Bool = false) {
        self.path = path
        self.keyword = keyword
        self.message = message
        self.readsBestEffort = readsBestEffort
    }

    public var description: String {
        "\(path): [\(keyword)] \(message)"
    }
}

extension JSONSchemaValidator {
    /// The keywords this validator evaluates: exactly those
    /// ``Schema/jsonSchema()`` writes.
    public static let coveredKeywords: Set<String> = [
        "$ref", "allOf", "anyOf", "oneOf", "not", "type", "enum", "const",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "pattern",
        "minItems", "maxItems", "uniqueItems", "items",
        "minProperties", "maxProperties", "required", "properties", "additionalProperties",
    ]

    /// Keywords that assert nothing: annotations, and where definitions live.
    static let annotations: Set<String> = [
        "$schema", "$id", "$defs", "definitions", "$comment", "title", "description", "default", "examples",
        "deprecated", "readOnly", "writeOnly", "format",
    ]

    /// Every keyword of the root schema that this validator does not evaluate,
    /// sorted: what a check against it does **not** cover. It is not a general
    /// validator; a schema another tool wrote may state rules it cannot see.
    /// `x-stoic-` annotations are not counted.
    public var uncoveredKeywords: [String] {
        var found: Set<String> = []
        func walk(_ value: JSONValue, isSchema: Bool) {
            switch value {
            case .object(let object):
                for member in object {
                    if isSchema {
                        let keyword = member.key
                        if !Self.coveredKeywords.contains(keyword), !Self.annotations.contains(keyword), !keyword.hasPrefix("x-stoic-") {
                            found.insert(keyword)
                        }
                        switch keyword {
                        case "properties", "$defs", "definitions":
                            if case .object(let children) = member.value {
                                for child in children { walk(child.value, isSchema: true) }
                            }
                        case "allOf", "anyOf", "oneOf":
                            for branch in member.value.array ?? [] { walk(branch, isSchema: true) }
                        case "items", "additionalProperties", "not":
                            walk(member.value, isSchema: true)
                        default:
                            break
                        }
                    }
                }
            case .array, .string, .number, .bool, .null:
                break
            }
        }
        walk(root, isSchema: true)
        return found.sorted()
    }

    /// Every way `instance` breaks the root schema, in document order: empty
    /// exactly when ``accepts(_:)`` is true.
    ///
    /// Inside a combinator (`anyOf`, `oneOf`, `not`) the combinator is the
    /// violation, not each branch's: which branch was meant is not known.
    public func violations(_ instance: JSONValue) -> [JSONSchemaViolation] {
        var found: [JSONSchemaViolation] = []
        collect(instance, against: root, at: .root, bestEffort: false, into: &found)
        return found
    }

    private func collect(
        _ instance: JSONValue, against schema: JSONValue, at path: JSONPath, bestEffort: Bool, into found: inout [JSONSchemaViolation]
    ) {
        func violate(_ keyword: String, _ message: String, at where: JSONPath? = nil, bestEffort tolerated: Bool = false) {
            found.append(JSONSchemaViolation(path: `where` ?? path, keyword: keyword, message: message, readsBestEffort: tolerated))
        }
        if case .bool(let allowed) = schema {
            if !allowed { violate("false", "no value is allowed here") }
            return
        }
        guard let schema = schema.object else {
            violate("schema", "the schema here is not an object")
            return
        }
        if let ref = schema["$ref"]?.string {
            if let target = resolve(reference: ref) {
                collect(instance, against: target, at: path, bestEffort: bestEffort, into: &found)
            } else {
                violate("$ref", "`\(ref)` points at nothing")
            }
        }
        for branch in schema["allOf"]?.array ?? [] {
            collect(instance, against: branch, at: path, bestEffort: bestEffort, into: &found)
        }
        if let branches = schema["anyOf"]?.array, !branches.contains(where: { accepts(instance, against: $0) }) {
            violate("anyOf", "matches none of its \(branches.count) alternatives")
        }
        if let excluded = schema["not"], accepts(instance, against: excluded) {
            violate("not", "matches what is excluded")
        }
        if let branches = schema["oneOf"]?.array {
            let matching = branches.count { accepts(instance, against: $0) }
            if matching != 1 { violate("oneOf", "matches \(matching) of its \(branches.count) alternatives, not exactly one") }
        }
        if let type = schema["type"]?.string, !matches(type: type, instance) {
            violate("type", "expected \(type), found \(Self.kind(of: instance))")
            return
        }
        if let types = schema["type"]?.array, !types.contains(where: { $0.string.map { matches(type: $0, instance) } ?? false }) {
            violate("type", "expected one of \(types.compactMap(\.string).joined(separator: ", ")), found \(Self.kind(of: instance))")
            return
        }
        if let allowed = schema["enum"]?.array, !allowed.contains(instance) {
            violate("enum", "not one of the \(allowed.count) values allowed")
        }
        if let constant = schema["const"], constant != instance {
            violate("const", "must be \(constant.encodedString())", bestEffort: bestEffort)
        }
        switch instance {
        case .number(let number):
            if let bound = schema["minimum"]?.number, number < bound { violate("minimum", "below \(bound.lexeme)") }
            if let bound = schema["maximum"]?.number, number > bound { violate("maximum", "above \(bound.lexeme)") }
            if let bound = schema["exclusiveMinimum"]?.number, number <= bound { violate("exclusiveMinimum", "not above \(bound.lexeme)") }
            if let bound = schema["exclusiveMaximum"]?.number, number >= bound { violate("exclusiveMaximum", "not below \(bound.lexeme)") }
            if let step = schema["multipleOf"]?.number, !number.isMultiple(of: step) { violate("multipleOf", "not a multiple of \(step.lexeme)") }
        case .string(let string):
            let length = string.unicodeScalars.count
            if let bound = schema["minLength"]?.number?.int64, length < bound { violate("minLength", "shorter than \(bound)") }
            if let bound = schema["maxLength"]?.number?.int64, length > bound { violate("maxLength", "longer than \(bound)") }
            if let pattern = schema["pattern"]?.string {
                if let regex = try? Regex(pattern).matchingSemantics(.unicodeScalar) {
                    if string.firstMatch(of: regex) == nil { violate("pattern", "does not match `\(pattern)`") }
                } else {
                    violate("pattern", "`\(pattern)` is not a pattern this validator reads")
                }
            }
        case .array(let items):
            if let bound = schema["minItems"]?.number?.int64, items.count < bound { violate("minItems", "fewer than \(bound) elements") }
            if let bound = schema["maxItems"]?.number?.int64, items.count > bound { violate("maxItems", "more than \(bound) elements") }
            if schema["uniqueItems"]?.bool == true, Set(items).count != items.count { violate("uniqueItems", "elements repeat") }
            if let element = schema["items"] {
                for (index, item) in items.enumerated() {
                    collect(item, against: element, at: path.appending(index: index), bestEffort: false, into: &found)
                }
            }
        case .object(let object):
            if let bound = schema["minProperties"]?.number?.int64, object.count < bound { violate("minProperties", "fewer than \(bound) keys") }
            if let bound = schema["maxProperties"]?.number?.int64, object.count > bound { violate("maxProperties", "more than \(bound) keys") }
            for key in schema["required"]?.array?.compactMap(\.string) ?? [] where !object.contains(key: key) {
                violate("required", "missing, and required here", at: path.appending(key: key))
            }
            // An object that preserves unknown keys reads a newer version
            // best effort: its version key's `const` is not a refusal.
            let preserves = schema["x-stoic-preserves-unknown"]?.bool == true
            let versionKey = schema["x-stoic-version"]?.object?["key"]?.string
            let properties = schema["properties"]?.object
            for member in object {
                let memberPath = path.appending(key: member.key)
                if let property = properties?[member.key] {
                    collect(member.value, against: property, at: memberPath, bestEffort: preserves && member.key == versionKey, into: &found)
                } else if let additional = schema["additionalProperties"] {
                    if additional == .bool(false) {
                        violate("additionalProperties", "not a key this reader allows", at: memberPath)
                    } else {
                        collect(member.value, against: additional, at: memberPath, bestEffort: false, into: &found)
                    }
                }
            }
        case .null, .bool:
            break
        }
    }

    private static func kind(of value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

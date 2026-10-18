public import StoicJSON

/// How ``Schema/jsonSchema(options:)`` writes its document, for the editor or
/// validator that will read it.
///
/// The defaults are the document ``Schema/jsonSchema()`` has always written, so
/// nothing changes for a caller that does not ask. The options are for a JSON
/// Schema that an editor shows beside a file a person types, where the aim is
/// that a misspelt key is underlined and the keys the app writes itself are
/// not:
///
///     var options = JSONSchemaOptions(draft: .draft07, closesObjects: true)
///     options.extraRootProperties = ["$schema": ["type": "string"]]
///     let document = Prefs.schema.jsonSchema(options: options)
public struct JSONSchemaOptions: Sendable, Hashable {
    /// The version of JSON Schema the document is written in.
    public enum Draft: Sendable, Hashable {
        /// Draft 2020-12 (`$defs`, `$schema` of 2020-12): what ``Schema/jsonSchema()`` writes.
        case draft2020_12
        /// Draft-07, which many editors (VS Code among them) and validators read:
        /// `definitions` for `$defs`, `#/definitions/…` for `#/$defs/…`, and since
        /// Draft-07 ignores whatever sits beside a `$ref`, a reference that carries a
        /// description or a default is written as `allOf: [{"$ref": …}]` beside them.
        /// Everything else Stoic writes (`const`, `anyOf`, `oneOf`, the exclusive
        /// bounds as numbers) means the same in both.
        case draft07
    }

    /// The draft the document is written in. ``Draft/draft2020_12`` by default.
    public var draft: Draft

    /// Whether every object the schema describes says
    /// `additionalProperties: false`, **whatever its unknown-key policy**.
    ///
    /// By default only a `.reject` object does, which suits a wire format. A
    /// file people edit reads with `.warn` (the app starts and says what it
    /// ignored), and an editor that is to underline the typo needs the closed
    /// form all the same: this is the document for the editor, and the policy
    /// is the app's. A dictionary or a `json` value, whose keys are free, is not
    /// closed; an object that preserves unknown keys is, and keeps its
    /// `x-stoic-preserves-unknown` annotation.
    public var closesObjects: Bool

    /// Properties the root object admits beyond the schema's own, each with
    /// the JSON Schema that describes it: the keys of a file header
    /// (`$schema`, a `version` the schema does not manage), which the app
    /// writes and a closed document would otherwise refuse. A key the schema
    /// declares keeps the schema's own description. Used only when the root is
    /// an object; a settings store's header makes these with
    /// `SettingsFileHeader.jsonSchemaProperties`.
    public var extraRootProperties: JSONObject

    public init(
        draft: Draft = .draft2020_12, closesObjects: Bool = false, extraRootProperties: JSONObject = JSONObject()
    ) {
        self.draft = draft
        self.closesObjects = closesObjects
        self.extraRootProperties = extraRootProperties
    }
}

/// Writing Draft-07 from what the exporter wrote in Draft 2020-12: the same
/// document, with the four things that differ said the Draft-07 way.
enum JSONSchemaDraft07 {
    static let uri = "http://json-schema.org/draft-07/schema#"

    /// The root document: `$defs` becomes `definitions`, every `$ref` is
    /// re-pointed, and `$schema` names Draft-07.
    static func root(_ document: JSONObject) -> JSONObject {
        var out = JSONObject()
        for member in document {
            switch member.key {
            case "$schema": out["$schema"] = .string(uri)
            case "$defs":
                out["definitions"] = .object(schemas(in: member.value))
            default: out[member.key] = member.value
            }
        }
        // The rest of the root is a schema like any other.
        let converted = schema(out)
        var result = JSONObject()
        for member in converted { result[member.key] = member.value }
        return result
    }

    private static func schemas(in value: JSONValue) -> JSONObject {
        guard case .object(let members) = value else { return JSONObject() }
        var out = JSONObject()
        for member in members { out[member.key] = object(member.value) }
        return out
    }

    private static func object(_ value: JSONValue) -> JSONValue {
        guard case .object(let members) = value else { return value }
        return .object(schema(members))
    }

    /// One schema, its sub-schemas converted where the keywords that hold them are.
    private static func schema(_ members: JSONObject) -> JSONObject {
        var out = JSONObject()
        for member in members {
            switch member.key {
            case "properties", "definitions", "patternProperties":
                out[member.key] = .object(schemas(in: member.value))
            case "items", "additionalProperties", "not", "contains", "if", "then", "else", "propertyNames":
                if case .array(let each) = member.value {
                    out[member.key] = .array(each.map(object))
                } else {
                    out[member.key] = object(member.value)
                }
            case "anyOf", "oneOf", "allOf":
                out[member.key] = .array((member.value.array ?? []).map(object))
            case "$ref":
                out[member.key] = .string((member.value.string ?? "").replacing("#/$defs/", with: "#/definitions/"))
            default:
                out[member.key] = member.value
            }
        }
        // Draft-07 ignores the keywords beside a `$ref`: say them beside an `allOf`.
        guard let reference = out["$ref"], out.count > 1 else { return out }
        var wrapped = JSONObject()
        for member in out where member.key != "$ref" && member.key != "allOf" { wrapped[member.key] = member.value }
        wrapped["allOf"] = .array([.object(["$ref": reference])] + (out["allOf"]?.array ?? []))
        return wrapped
    }
}

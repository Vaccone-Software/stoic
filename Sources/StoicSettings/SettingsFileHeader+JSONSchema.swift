public import StoicJSON

extension SettingsFileHeader {
    /// The header's keys as JSON Schema properties, for
    /// `JSONSchemaOptions.extraRootProperties` (StoicSchema): a closed document for the
    /// settings file (`closesObjects`) would otherwise
    /// refuse the `"$schema"` the store writes first.
    ///
    ///     var options = JSONSchemaOptions(draft: .draft07, closesObjects: true)
    ///     options.extraRootProperties = header.jsonSchemaProperties
    ///     let document = Prefs.schema.jsonSchema(options: options)
    ///
    /// Each property admits any value of the *kind* the header holds, never
    /// that value alone (`"$schema"` is a string, `"version"` an integer): the
    /// header is whatever the app that wrote the file configured, and a file
    /// written by an older release must not be underlined for the value it had.
    public var jsonSchemaProperties: JSONObject {
        var properties = JSONObject()
        for member in members {
            let kind: String
            switch member.value {
            case .string: kind = "string"
            case .number(let number): kind = number.isInteger ? "integer" : "number"
            case .bool: kind = "boolean"
            case .null: kind = "null"
            case .array: kind = "array"
            case .object: kind = "object"
            }
            properties[member.key] = .object(["type": .string(kind)])
        }
        return properties
    }
}

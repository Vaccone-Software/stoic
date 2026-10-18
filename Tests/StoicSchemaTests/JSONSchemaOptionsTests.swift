import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

/// A chain whose links are described by a reference, with a description beside it.
struct Chain: Sendable, Equatable {
    var name = "link"
    var next: [Chain] = []

    static let schema: Schema<Chain> = Schema.object(Chain.self, default: Chain()) {
        Field("name", \.name, .string(.length(1...20)), doc: "A name.")
        Field("next", \.next, .array(of: Schema<Chain>.lazy { Chain.schema }.documented("A link."), .count(...2)), doc: "The next links.")
    }
}

@Suite("JSON Schema export options")
struct JSONSchemaOptionsTests {
    static func text(_ value: JSONValue) -> String { value.encodedString(style: .compact) }

    @Test func theDefaultsAreTheDocumentThatWasAlwaysWritten() {
        #expect(Sections.schema.jsonSchema(options: JSONSchemaOptions()) == Sections.schema.jsonSchema())
        #expect(Chain.schema.jsonSchema(options: JSONSchemaOptions()) == Chain.schema.jsonSchema())
        let export = Sections.schema.jsonSchemaExport(options: JSONSchemaOptions())
        #expect(export.schema == Sections.schema.jsonSchemaExport().schema)
        #expect(export.unenforced == Sections.schema.jsonSchemaExport().unenforced)
    }

    @Test(.failureMode("design/06", "a JSON Schema is exported for an editor"))
    func closedObjectsSayAdditionalPropertiesFalseWhateverThePolicy() throws {
        let plain = Sections.schema.jsonSchema()
        #expect(plain.object?["additionalProperties"] == nil)  // `.warn`, the policy of configuration
        let closed = Sections.schema.jsonSchema(options: JSONSchemaOptions(closesObjects: true))
        #expect(closed.object?["additionalProperties"] == false)
        let scroll = try #require(closed.object?["properties"]?.object?["scroll"]?.object)
        #expect(scroll["additionalProperties"] == false)
        #expect(scroll["type"] == ["object", "null"])
    }

    @Test func aFreeKeyedValueIsNotClosedAndAPreservingObjectIsClosedButSaysItPreserves() throws {
        let table = Schema<[String: Scroll]>.dictionary(of: Scroll.schema)
        let closed = table.jsonSchema(options: JSONSchemaOptions(closesObjects: true))
        let values = try #require(closed.object?["additionalProperties"]?.object)
        #expect(closed.object?["additionalProperties"] != false)
        #expect(values["additionalProperties"] == false)
        let loose = Loose.schema.jsonSchema(options: JSONSchemaOptions(closesObjects: true))
        #expect(loose.object?["additionalProperties"] == false)
        #expect(loose.object?["x-stoic-preserves-unknown"] == true)
    }

    @Test func theFileHeaderKeysAreDeclaredAtTheTopSoAClosedDocumentAdmitsThem() throws {
        var options = JSONSchemaOptions(closesObjects: true)
        options.extraRootProperties = ["$schema": ["type": "string"], "version": ["type": "integer"], "scroll": ["type": "string"]]
        let document = Sections.schema.jsonSchema(options: options)
        let properties = try #require(document.object?["properties"]?.object)
        #expect(properties["$schema"] == ["type": "string"])
        #expect(properties["version"] == ["type": "integer"])
        // A key the schema declares keeps the schema's own description.
        #expect(properties["scroll"]?.object?["type"] == ["object", "null"])
        // Nested objects are closed and get no header keys.
        #expect(properties["scroll"]?.object?["properties"]?.object?["$schema"] == nil)

        let validator = JSONSchemaValidator(document)
        #expect(validator.accepts(["$schema": "s.json", "version": 3, "scroll": ["speed": 900]]))
        #expect(!validator.accepts(["scrol": ["speed": 900]]))
        #expect(!validator.accepts(["scroll": ["sped": 900]]))
        #expect(!validator.accepts(["$schema": 5]))
        let withoutHeader = JSONSchemaValidator(Sections.schema.jsonSchema(options: JSONSchemaOptions(closesObjects: true)))
        #expect(!withoutHeader.accepts(["$schema": "s.json"]))
    }

    @Test func draft07WritesDefinitionsAndPointsAtThem() throws {
        let document = Chain.schema.jsonSchema(options: JSONSchemaOptions(draft: .draft07))
        let root = try #require(document.object)
        #expect(root["$schema"] == "http://json-schema.org/draft-07/schema#")
        #expect(root["definitions"]?.object?["Chain"] != nil)
        #expect(root["$defs"] == nil)
        #expect(!Self.text(document).contains("$defs"))
        #expect(Self.text(document).contains("#/definitions/Chain"))
        let twenty = Chain.schema.jsonSchema()
        #expect(twenty.object?["$defs"]?.object?["Chain"] != nil)
        #expect(twenty.object?["$schema"] == "https://json-schema.org/draft/2020-12/schema")
    }

    @Test func draft07WrapsAReferenceThatHasNeighboursBecauseItWouldIgnoreThem() throws {
        let document = Chain.schema.jsonSchema(options: JSONSchemaOptions(draft: .draft07))
        let definition = try #require(document.object?["definitions"]?.object?["Chain"]?.object)
        let link = try #require(definition["properties"]?.object?["next"]?.object?["items"]?.object)
        #expect(link["$ref"] == nil)
        #expect(link["description"] == "A link.")
        #expect(link["allOf"] == [["$ref": "#/definitions/Chain"]])
        // 2020-12 says it directly.
        let twenty = try #require(Chain.schema.jsonSchema().object?["$defs"]?.object?["Chain"]?.object)
        #expect(twenty["properties"]?.object?["next"]?.object?["items"]?.object?["$ref"] == "#/$defs/Chain")
    }

    @Test func draft07KeepsWhatMeansTheSameInBoth() throws {
        let numbers = Schema<Double>.double(.greaterThan(0), .lessThan(10))
        let document = numbers.jsonSchema(options: JSONSchemaOptions(draft: .draft07))
        #expect(document.object?["exclusiveMinimum"] == 0)
        #expect(document.object?["exclusiveMaximum"] == 10)
        let nullable = Schema<Int?>.optional(.int(), nullable: true).jsonSchema(options: JSONSchemaOptions(draft: .draft07))
        #expect(nullable.object?["anyOf"]?.array?.count == 2)
    }

    @Test func everyDraftAndOptionAgreesWithTheDecoderOnWhatItDescribes() throws {
        func check<V: Sendable>(_ schema: Schema<V>, _ name: String) throws {
            for draft in [JSONSchemaOptions.Draft.draft2020_12, .draft07] {
                for closes in [false, true] {
                    let options = JSONSchemaOptions(draft: draft, closesObjects: closes)
                    let validator = JSONSchemaValidator(schema.jsonSchema(options: options))
                    let generator = SchemaGenerator(schema)
                    for seed in 0..<12 {
                        let sample = try generator.sample(seed: UInt64(seed))
                        #expect(validator.accepts(sample.document), "\(name) \(draft) closed=\(closes) seed \(seed)")
                    }
                }
            }
        }
        try check(Settings.schema, "settings")
        try check(Shape.schema, "shapes")
        try check(Menu.schema, "menu")
        try check(Chain.schema, "chain")
        try check(Loose.schema, "loose")
        try check(Prefs.schema, "prefs")
        try check(Sections.schema, "sections")
    }

    @Test func aClosedUnionStillAdmitsItsDiscriminator() throws {
        let validator = JSONSchemaValidator(Shape.schema.jsonSchema(options: JSONSchemaOptions(draft: .draft07, closesObjects: true)))
        let generator = SchemaGenerator(Shape.schema)
        let document = try generator.sample(seed: 3).document
        #expect(validator.accepts(document))
        let typo = try #require(document.setting("zzUnknownKey", to: 1, inObjectAt: .root))
        #expect(!validator.accepts(typo))
    }
}

import StoicJSON
import Testing

@testable import StoicSchema

private let settingsGolden = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "title": "Settings",
      "description": "Application settings.",
      "properties": {
        "scrollSpeed": {
          "type": "number",
          "minimum": 200,
          "maximum": 4000,
          "description": "Pixels per second.",
          "default": 1200,
          "x-stoic-unit": "px/s"
        },
        "theme": {
          "type": "string",
          "enum": ["light", "dark", "system"],
          "description": "Colour scheme.",
          "default": "system"
        },
        "apiToken": {
          "type": "string",
          "maxLength": 128,
          "description": "Credential for the sync service.",
          "x-stoic-secret": true
        },
        "network": {
          "type": "object",
          "title": "Network",
          "description": "How the app reaches its servers.",
          "properties": {
            "hosts": {
              "type": "array",
              "items": {"type": "string", "minLength": 1, "maxLength": 253},
              "minItems": 0,
              "maxItems": 8,
              "uniqueItems": true,
              "description": "Server names, tried in order.",
              "default": ["localhost"],
              "x-stoic-aliases": ["servers"]
            },
            "port": {
              "type": "integer",
              "minimum": 1,
              "maximum": 65535,
              "description": "TCP port.",
              "default": 8080
            },
            "timeoutSeconds": {
              "type": "number",
              "exclusiveMinimum": 0,
              "maximum": 600,
              "description": "Request timeout.",
              "default": 30,
              "x-stoic-unit": "s"
            },
            "useTLS": {"type": "boolean", "default": true}
          },
          "default": {"hosts": ["localhost"], "port": 8080, "timeoutSeconds": 30, "useTLS": true}
        },
        "maxHistory": {
          "type": "integer",
          "minimum": 0,
          "maximum": 10000,
          "description": "Entries kept.",
          "default": 100
        },
        "windowTitle": {
          "type": "string",
          "minLength": 1,
          "maxLength": 64,
          "description": "Overrides the title."
        },
        "zoom": {"type": "number", "minimum": 0.5, "maximum": 5, "default": 1, "x-stoic-unit": "×"},
        "shortcuts": {
          "type": "object",
          "additionalProperties": {"type": "string", "minLength": 1, "maxLength": 32},
          "maxProperties": 50,
          "default": {}
        },
        "legacyMode": {
          "type": "boolean",
          "default": false,
          "deprecated": true,
          "x-stoic-deprecation": "Use `theme` instead."
        }
      }
    }
    """#

@Suite("JSON Schema export: golden")
struct GoldenExportTests {
    @Test func settingsExportsExactlyThis() {
        let exported = Settings.schema.jsonSchema()
        #expect(exported == json(settingsGolden))
    }

    @Test func theExportIsDeterministic() {
        let first = Settings.schema.jsonSchema().encodedString(style: .canonical)
        for _ in 0..<5 { #expect(Settings.schema.jsonSchema().encodedString(style: .canonical) == first) }
    }

    @Test func theExportItselfIsValidJSONThatRoundTrips() {
        let text = Settings.schema.jsonSchema().encodedString(style: .pretty())
        #expect(json(text) == Settings.schema.jsonSchema())
    }

    @Test func aSecretsDefaultIsNeverExported() {
        struct Vault: Sendable, Equatable { var key = "do-not-leak-this" }
        let schema = Schema.object(Vault.self, default: Vault()) {
            Field("key", \.key, .string(), secret: true)
        }
        let text = schema.jsonSchema().encodedString()
        #expect(!text.contains("do-not-leak-this"))
        #expect(text.contains("x-stoic-secret"))
    }

    @Test func noCustomConstraintsMeansNothingUnenforced() {
        #expect(Settings.schema.jsonSchemaExport().unenforced.isEmpty)
    }
}

@Suite("JSON Schema export: mapping")
struct ExportMappingTests {
    private func export<V>(_ schema: Schema<V>) -> JSONValue {
        var document = schema.jsonSchema().object ?? JSONObject()
        document["$schema"] = nil
        return .object(document)
    }

    @Test func primitives() {
        #expect(export(Schema.bool) == json(#"{"type":"boolean"}"#))
        #expect(export(Schema.string()) == json(#"{"type":"string"}"#))
        #expect(export(Schema.double()) == json(#"{"type":"number"}"#))
        #expect(export(Schema.json()) == json("{}"))
    }

    @Test func integersStateTheirNaturalBounds() {
        #expect(
            export(Schema.int())
                == json(#"{"type":"integer","minimum":-9223372036854775808,"maximum":9223372036854775807}"#))
        #expect(export(Schema.uint64()) == json(#"{"type":"integer","minimum":0,"maximum":18446744073709551615}"#))
        #expect(
            export(Schema<UInt8>.integer(UInt8.self)) == json(#"{"type":"integer","minimum":0,"maximum":255}"#))
        // A constraint on one side leaves the other to the type.
        #expect(
            export(Schema.int(.range(1...)))
                == json(#"{"type":"integer","minimum":1,"maximum":9223372036854775807}"#))
        #expect(export(Schema.int(.range(1...5))) == json(#"{"type":"integer","minimum":1,"maximum":5}"#))
    }

    @Test func rangesBoundsAndStepsKeepTheirDigits() {
        #expect(
            export(Schema.double(.range(0.1...10), .multipleOf(0.05)))
                == json(#"{"type":"number","minimum":0.1,"maximum":10,"multipleOf":0.05}"#))
        #expect(
            export(Schema.double(.greaterThan(0), .lessThan(1)))
                == json(#"{"type":"number","exclusiveMinimum":0,"exclusiveMaximum":1}"#))
        #expect(
            export(Schema.double(.range(..<100)))
                == json(#"{"type":"number","exclusiveMaximum":100}"#))
    }

    @Test func stringConstraints() {
        #expect(
            export(Schema.string(.length(1...64), .pattern("^[a-z]+$")))
                == json(#"{"type":"string","minLength":1,"maxLength":64,"pattern":"^[a-z]+$"}"#))
        #expect(
            export(Schema.string(.oneOf(["a", "b"]))) == json(#"{"type":"string","enum":["a","b"]}"#))
    }

    @Test func onlyScalarLengthsAreMinLengthAndMaxLength() {
        let bytes = export(Schema.string(.length(...10, unit: .utf8Bytes)))
        #expect(bytes == json(#"{"type":"string","x-stoic-length":[{"unit":"utf8Bytes","maximum":10}]}"#))
        let graphemes = export(Schema.string(.length(1...3, unit: .graphemes)))
        #expect(
            graphemes
                == json(#"{"type":"string","x-stoic-length":[{"unit":"graphemes","minimum":1,"maximum":3}]}"#))
    }

    @Test func arraysAndDictionaries() {
        #expect(
            export(Schema.array(of: .int(.range(0...9)), .count(1...3), .unique))
                == json(
                    #"{"type":"array","items":{"type":"integer","minimum":0,"maximum":9},"minItems":1,"maxItems":3,"uniqueItems":true}"#
                ))
        #expect(
            export(Schema.dictionary(of: .bool, .count(...5)))
                == json(#"{"type":"object","additionalProperties":{"type":"boolean"},"maxProperties":5}"#))
    }

    @Test func enumerations() {
        #expect(
            export(Schema.enumeration(Theme.self)) == json(#"{"type":"string","enum":["light","dark","system"]}"#))
    }

    @Test func optionalsAreNullableOnlyWhenTheyHaveANullSpelling() {
        #expect(export(Schema<Bool?>.optional(.bool)) == json(#"{"type":"boolean"}"#))
        #expect(
            export(Schema<Bool?>.optional(.bool, nullable: true))
                == json(#"{"anyOf":[{"type":"boolean"},{"type":"null"}]}"#))
    }

    @Test func twoConstraintsOnOneKeywordAreBothKept() {
        let exported = export(Schema.double(.range(0...10), .range(2...20)))
        #expect(exported == json(#"{"type":"number","minimum":0,"maximum":10,"allOf":[{"minimum":2},{"maximum":20}]}"#))
        let validator = JSONSchemaValidator(exported)
        #expect(validator.accepts(5))
        #expect(!validator.accepts(1))
        #expect(!validator.accepts(15))
    }

    @Test func customConstraintsAreAnnotatedAndListed() {
        let even = Constraint.custom(id: "even", description: "an even number") { _ in true }
        struct Counter: Sendable, Equatable { var low = 0 }
        let schema = Schema.object(Counter.self, default: Counter(), unknownKeys: .ignore) {
            Field("low", \.low, .int(even))
        }
        let result = schema.jsonSchemaExport()
        #expect(result.unenforced == [.init(location: "$.low", id: "even", description: "an even number")])
        let low = result.schema.value(at: JSONPath([.key("properties"), .key("low")]))
        #expect(
            low?.object?["x-stoic-constraint"] == json(#"[{"id":"even","description":"an even number"}]"#))
    }

    @Test func rejectingObjectsForbidAdditionalProperties() {
        let reject = Schema.object(Point.self) { f in
            let x = f.field("x", \.x, .double())
            let y = f.field("y", \.y, .double(), default: 0)
            return f.build { v in Point(x: v[x], y: v[y]) }
        }
        let exported = reject.jsonSchema()
        #expect(exported.value(at: JSONPath([.key("additionalProperties")])) == false)
        #expect(exported.value(at: JSONPath([.key("required")])) == ["x"])
        let warn = Schema.object(Point.self, unknownKeys: .warn) { f in
            let x = f.field("x", \.x, .double())
            return f.build { v in Point(x: v[x], y: 0) }
        }
        #expect(warn.jsonSchema().value(at: JSONPath([.key("additionalProperties")])) == nil)
    }

    @Test func formBFieldsListedRequiredAreExactlyThoseWithoutDefaults() {
        let exported = Segment.schema.jsonSchema()
        #expect(exported.value(at: JSONPath([.key("required")])) == ["from", "to"])
        #expect(exported.value(at: JSONPath([.key("properties"), .key("width"), .key("default")])) == 1)
        #expect(exported.value(at: JSONPath([.key("properties"), .key("width"), .key("x-stoic-unit")])) == "px")
    }

    @Test func refinedTypesExportTheirConstraints() {
        #expect(
            export(Port.schema) == json(#"{"type":"integer","minimum":1,"maximum":65535}"#))
        #expect(export(ScrollSpeed.schema) == json(#"{"type":"number","minimum":0.1,"maximum":10}"#))
    }

    @Test func recursiveSchemasUseDefsAndRefs() {
        let exported = Menu.schema.jsonSchema()
        #expect(exported.value(at: JSONPath([.key("properties"), .key("items"), .key("items"), .key("$ref")])) == "#/$defs/Menu")
        #expect(exported.value(at: JSONPath([.key("$defs"), .key("Menu"), .key("title")])) == "Menu")
        // The definition refers to itself, not to a copy.
        #expect(
            exported.value(
                at: JSONPath([.key("$defs"), .key("Menu"), .key("properties"), .key("items"), .key("items"), .key("$ref")]))
                == "#/$defs/Menu")
        let validator = JSONSchemaValidator(exported)
        #expect(validator.accepts(json(#"{"title":"a","items":[{"title":"b","items":[{"title":"c"}]}]}"#)))
        #expect(!validator.accepts(json(#"{"title":"a","items":[{"title":""}]}"#)))
        #expect(!validator.accepts(json(#"{"title":"a","items":[{"itmes":[]}]}"#)))  // rejected key
    }

    @Test func aRootThatIsRecursiveIsARef() {
        let schema = Schema<[Int]>.lazy("Ints") { Schema.array(of: .int()) }
        let exported = schema.jsonSchema()
        #expect(exported.value(at: JSONPath([.key("$ref")])) == "#/$defs/Ints")
        #expect(JSONSchemaValidator(exported).accepts([1, 2]))
        #expect(!JSONSchemaValidator(exported).accepts(["a"]))
    }
}

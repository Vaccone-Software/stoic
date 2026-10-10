import StoicJSON
import Testing

@testable import StoicSchema

private func decode<V>(_ schema: Schema<V>, _ text: String, _ options: DecodeOptions = .strict) -> Decoded<V> {
    schema.decodeReporting(text, options: options)
}

@Suite("Tagged unions: decoding")
struct UnionDecodingTests {
    @Test func eachCaseDecodesFromItsTag() {
        #expect(decode(Shape.schema, #"{"type": "circle", "radius": 5}"#).value == .circle(Circle(radius: 5)))
        #expect(decode(Shape.schema, #"{"type": "circle"}"#).value == .circle(Circle()))
        #expect(decode(Shape.schema, #"{"type": "rect", "width": 3, "height": 4}"#).value == .rect(Rect(width: 3, height: 4)))
        #expect(decode(Shape.schema, #"{"type": "label", "value": "Hello"}"#).value == .label("Hello"))
        #expect(decode(Shape.schema, #"{"type": "point"}"#).value == .point)
    }

    @Test func theDiscriminatorMayComeAnywhereInTheObject() {
        #expect(
            decode(Shape.schema, #"{"radius": 2, "type": "circle", "filled": true}"#).value
                == .circle(Circle(radius: 2, filled: true)))
    }

    @Test func aMissingDiscriminatorIsAMissingKey() {
        let result = decode(Shape.schema, #"{"radius": 5}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.type missing_key"])
        #expect(result.issues[0].expected == #"one of "circle", "rect", "label", "point""#)
        #expect(result.issues[0].message == "missing required key `type`")
        #expect(result.issues[0].source?.start.column == 1)  // the object that lacks it
    }

    @Test func aDiscriminatorThatIsNotAStringIsATypeMismatch() {
        for text in ["5", "null", "true", "[]", "{}"] {
            let result = decode(Shape.schema, #"{"type": \#(text)}"#)
            #expect(result.issues.locations == ["$.type type_mismatch"], "\(text)")
            #expect(result.issues[0].expected == #"one of "circle", "rect", "label", "point""#, "\(text)")
        }
    }

    @Test func anUnknownTagListsTheTagsAndSuggestsTheNearest() {
        let result = decode(Shape.schema, #"{"type": "cirlce", "radius": 5}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.type not_one_of"])
        let issue = result.issues[0]
        #expect(issue.suggestions == ["circle"])
        #expect(issue.expected == #"one of "circle", "rect", "label", "point""#)
        #expect(issue.actual == #""cirlce""#)
        #expect(issue.source?.start.column == 10)
        #expect(
            issue.description
                == #"1:10 $.type: "cirlce" is not allowed, expected one of "circle", "rect", "label", "point" (did you mean `circle`?)"#)
        #expect(decode(Shape.schema, #"{"type": "Rect"}"#).issues[0].suggestions == ["rect"])
        #expect(decode(Shape.schema, #"{"type": "hexagon"}"#).issues[0].suggestions.isEmpty)
        #expect(decode(Shape.schema, #"{"type": ""}"#).issues.map(\.code) == [.notOneOf])
    }

    @Test func tagsAreMatchedByScalarsNotCanonicalEquivalence() {
        enum Accent: Sendable, Equatable { case cafe }
        let schema: Schema<Accent> = .union {
            Case("caf\u{E9}", Accent.cafe) { _ in true }
        }
        #expect(decode(schema, #"{"type": "café"}"#).value == .cafe)
        #expect(decode(schema, #"{"type": "café"}"#).issues.map(\.code) == [.notOneOf])
    }

    @Test func anythingButAnObjectIsATypeMismatch() {
        for text in ["5", #""circle""#, "[]", "null", "true"] {
            let result = decode(Shape.schema, text)
            #expect(result.issues.locations == ["$ type_mismatch"], "\(text)")
            #expect(result.issues[0].expected == #"an object whose "type" is one of "circle", "rect", "label", "point""#)
        }
    }

    @Test func issuesInsideTheSelectedCaseAccumulate() {
        let result = decode(Shape.schema, #"{"type": "circle", "radius": -1, "filled": "yes", "radus": 2}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.radius out_of_range", "$.filled type_mismatch", "$.radus unknown_key"])
        // The discriminator is not an unknown key of a payload that rejects unknown keys.
        #expect(decode(Shape.schema, #"{"type": "circle", "radius": 1}"#).issues.isEmpty)
    }

    @Test func missingRequiredFieldsOfAPayloadAreAllReported() {
        let result = decode(Shape.schema, #"{"type": "rect"}"#)
        #expect(result.issues.locations == ["$.width missing_key", "$.height missing_key"])
        let partial = decode(Shape.schema, #"{"type": "rect", "width": 0}"#)
        #expect(partial.issues.locations == ["$.width out_of_range", "$.height missing_key"])
    }

    @Test func aCaseWithoutAPayloadRejectsStrayKeys() {
        let result = decode(Shape.schema, #"{"type": "point", "x": 1}"#)
        #expect(result.issues.locations == ["$.x unknown_key"])
    }

    @Test func aKeyedPayloadLivesUnderTheValueKey() {
        let result = decode(Shape.schema, #"{"type": "label", "value": ""}"#)
        #expect(result.issues.locations == ["$.value too_short"])
        #expect(decode(Shape.schema, #"{"type": "label"}"#).issues.locations == ["$.value missing_key"])
        #expect(decode(Shape.schema, #"{"type": "label", "value": 5}"#).issues.locations == ["$.value type_mismatch"])
        let stray = decode(Shape.schema, #"{"type": "label", "value": "ok", "valeu": "x"}"#)
        #expect(stray.issues.locations == ["$.valeu unknown_key"])
        #expect(stray.issues[0].suggestions == ["value"])
    }

    @Test func aKeyedPayloadsStrayKeysAreRepairedWhenLenient() {
        let result = decode(Shape.schema, #"{"type": "label", "value": "ok", "extra": 1}"#, .lenient)
        #expect(result.value == .label("ok"))
        #expect(result.issues.map(\.severity) == [.repaired])
    }

    @Test func unionsNestInObjectsAndArraysWithFullPaths() {
        let text = """
            {"title": "T", "shapes": [
              {"type": "point"},
              {"type": "circle", "radius": 0},
              {"type": "star"},
              {"radius": 1}
            ], "background": {"type": "rect", "width": 1}}
            """
        let result = decode(Canvas.schema, text)
        #expect(
            result.issues.locations == [
                "$.shapes[1].radius out_of_range", "$.shapes[2].type not_one_of", "$.shapes[3].type missing_key",
                "$.background.height missing_key",
            ])
        #expect(result.issues[0].source?.start.line == 3)
        #expect(result.issues[1].source?.start.line == 4)
    }

    @Test func aDefaultedUnionFieldTakesItsDefault() {
        #expect(decode(Canvas.schema, "{}").value == Canvas())
    }

    @Test func recursiveUnionsDecodeToAnyDepth() {
        let text = #"{"op": "sum", "value": [{"op": "number", "value": 1}, {"op": "negate", "value": {"op": "sum", "value": [{"op": "number", "value": 2.5}]}}]}"#
        let expected = Expression.sum([.number(1), .negate(.sum([.number(2.5)]))])
        #expect(decode(Expression.schema, text).value == expected)
        let bad = #"{"op": "sum", "value": [{"op": "number", "value": "x"}, {"op": "negate", "value": {"op": "mul"}}]}"#
        #expect(
            decode(Expression.schema, bad).issues.locations == [
                "$.value[0].value type_mismatch", "$.value[1].value.op not_one_of",
            ])
    }

    @Test func keysTheJSONLayerRefusesNeverReachTheUnion() {
        let result = decode(Shape.schema, #"{"type": "point", "type": "rect"}"#)
        #expect(result.issues.map(\.code) == [.parseError])
    }
}

@Suite("Tagged unions: encoding and description")
struct UnionEncodingTests {
    @Test func theDiscriminatorIsWrittenFirst() {
        let json = Shape.schema.encode(.circle(Circle(radius: 5, filled: true)))
        #expect(json.object?.keys == ["type", "radius", "filled"])
        #expect(json.encodedString() == #"{"filled":true,"radius":5,"type":"circle"}"#)
        #expect(json.encodedString(style: .compact) == #"{"type":"circle","radius":5,"filled":true}"#)
    }

    @Test func eachCaseRoundTrips() {
        let shapes: [Shape] = [
            .circle(Circle()), .circle(Circle(radius: 0.25, filled: true)), .rect(Rect(width: 1, height: 10_000)),
            .label("x"), .label("naïve 😀"), .point,
        ]
        for shape in shapes {
            for style in [EncodeStyle.full, .sparse] {
                let json = Shape.schema.encode(shape, style: style)
                #expect(Shape.schema.decode(json).value == shape, "\(shape) \(json)")
            }
        }
    }

    @Test func sparseOmitsPayloadDefaultsButNeverTheTag() {
        #expect(Shape.schema.encode(.circle(Circle()), style: .sparse).encodedString(style: .compact) == #"{"type":"circle"}"#)
        #expect(
            Shape.schema.encode(.circle(Circle(radius: 2)), style: .sparse).encodedString(style: .compact)
                == #"{"type":"circle","radius":2}"#)
        #expect(Shape.schema.encode(.point, style: .sparse).encodedString(style: .compact) == #"{"type":"point"}"#)
    }

    @Test func aKeyedPayloadIsWrittenUnderTheValueKey() {
        #expect(Shape.schema.encode(.label("Hi")).encodedString(style: .compact) == #"{"type":"label","value":"Hi"}"#)
    }

    @Test func aValueOfNoDeclaredCaseIsFoundByValidate() {
        enum Open: Sendable { case a, b }
        let schema: Schema<Open> = .union {
            Case("a", Open.a) { if case .a = $0 { true } else { false } }
        }
        let issues = schema.validate(.b)
        #expect(issues.map(\.code) == [.invalidValue])
        #expect(schema.validate(.a).isEmpty)
    }

    @Test func nestedUnionsRoundTripInsideAnObject() {
        let canvas = Canvas(
            title: "Scene", shapes: [.point, .label("a"), .rect(Rect(width: 2, height: 3))], background: .circle(Circle(radius: 9)))
        for style in [EncodeStyle.full, .sparse] {
            #expect(Canvas.schema.decodeReporting(Canvas.schema.encode(canvas, style: style).encodedString()).value == canvas)
        }
    }

    @Test func recursiveUnionsRoundTrip() {
        let expression = Expression.sum([.number(1), .negate(.negate(.number(-2))), .sum([.number(0.5)])])
        #expect(Expression.schema.decode(Expression.schema.encode(expression)).value == expression)
    }

    @Test func theNodeListsTheCases() {
        guard case .union(let node) = Shape.schema.node else { return fail("node") }
        #expect(node.name == "Shape")
        #expect(node.doc == "Something drawable.")
        #expect(node.discriminator == "type")
        #expect(node.valueKey == "value")
        #expect(node.tags == ["circle", "rect", "label", "point"])
        #expect(node.cases.map(\.isFlat) == [true, true, false, true])
        #expect(node.cases[0].doc == "A circle.")
        #expect(Shape.schema.node.expectation == #"an object whose "type" is one of "circle", "rect", "label", "point""#)
    }

    @Test func theExportIsOneOfWithConstDiscriminators() {
        let document = Shape.schema.jsonSchema()
        let object = document.object
        #expect(object?["title"] == "Shape")
        #expect(object?["description"] == "Something drawable.")
        #expect(object?["x-stoic-discriminator"] == "type")
        let branches = object?["oneOf"]?.array ?? []
        #expect(branches.count == 4)
        let circle = branches[0].object
        #expect(circle?["title"] == "circle")
        #expect(circle?["properties"]?.object?["type"] == ["type": "string", "const": "circle"])
        #expect(circle?["properties"]?.object?["radius"]?.object?["exclusiveMinimum"] == 0)
        #expect(circle?["required"] == ["type"])
        #expect(circle?["additionalProperties"] == false)
        #expect(branches[1].object?["required"] == ["type", "width", "height"])
        let label = branches[2].object
        #expect(label?["properties"]?.object?["value"]?.object?["maxLength"] == 40)
        #expect(label?["required"] == ["type", "value"])
        #expect(branches[3].object?["properties"]?.object?.keys == ["type"])
    }

    @Test func theExportAgreesWithTheDecoderOnHandPickedDocuments() {
        let validator = MiniJSONSchema(Shape.schema.jsonSchema())
        let documents: [String] = [
            #"{"type": "circle"}"#, #"{"type": "circle", "radius": 5}"#, #"{"type": "circle", "radius": 0}"#,
            #"{"type": "circle", "radius": 5, "radus": 1}"#, #"{"type": "rect", "width": 1, "height": 2}"#,
            #"{"type": "rect", "width": 1}"#, #"{"type": "rect", "width": 0, "height": 2}"#, #"{"type": "label", "value": "x"}"#,
            #"{"type": "label", "value": ""}"#, #"{"type": "label"}"#, #"{"type": "label", "value": "x", "y": 1}"#,
            #"{"type": "point"}"#, #"{"type": "point", "x": 1}"#, #"{"type": "hexagon"}"#, #"{"radius": 1}"#,
            #"{"type": 5}"#, "5", "null", "[]",
        ]
        for text in documents {
            let document = json(text)
            #expect(validator.accepts(document) == (Shape.schema.decode(document).value != nil), "\(text)")
        }
    }

    @Test func aRecursiveUnionExportsWithReferences() {
        let document = Expression.schema.jsonSchema().object
        #expect(document?["$defs"]?.object?["Expression"] != nil)
        let validator = MiniJSONSchema(Expression.schema.jsonSchema())
        #expect(validator.accepts(json(#"{"op": "sum", "value": [{"op": "number", "value": 1}]}"#)))
        #expect(!validator.accepts(json(#"{"op": "sum", "value": []}"#)))
    }
}

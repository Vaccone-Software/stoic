import StoicJSON
import Testing

@testable import StoicSchema

extension Settings: Schematic {}
extension Network: Schematic {}
extension Shape: Schematic {}

private struct Envelope: Codable, Equatable {
    var id: Int
    var settings: SchemaCoded<Settings>
    var networks: [SchemaCoded<Network>]
}

/// A hand-written conformance using the container helpers.
private struct Handwritten: Codable, Equatable {
    var title: String
    var network: Network
    var shape: Shape?

    enum CodingKeys: String, CodingKey { case title, network, shape }

    init(title: String, network: Network, shape: Shape?) {
        self.title = title
        self.network = network
        self.shape = shape
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        // This fixture keeps no warnings; saying so is the point of the parameter.
        network = try container.decodeSchema(Network.self, forKey: .network) { _ in }
        shape = try container.decodeSchemaIfPresent(Shape.self, forKey: .shape) { _ in }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeSchema(network, forKey: .network)
        if let shape { try container.encodeSchema(shape, forKey: .shape) }
    }
}

@Suite("Codable bridge: reading and writing JSON trees")
struct JSONTreeCodingTests {
    @Test func everyKindOfValueRoundTripsThroughDecoderAndEncoder() throws {
        let documents: [JSONValue] = [
            .null, true, false, 0, -1, 9_223_372_036_854_775_807, .number(JSONNumber(UInt64.max)), 0.5, -2.25,
            "", "héllo 😀 e\u{301}", [], [1, "a", nil, [true]], [:], ["b": 1, "a": ["c": [1, 2]]],
        ]
        for document in documents {
            let written = try encodeToValue(JSONTreeBox(document))
            #expect(written == document, "\(document.encodedString(style: .compact))")
            let read = try decodeFromValue(JSONTreeBox.self, document)
            #expect(read.value == document, "\(document.encodedString(style: .compact))")
        }
    }

    @Test func generatedDocumentsOfEverySchemaSurvive() throws {
        func run<V: Sendable>(_ schema: Schema<V>) throws {
            for seed in 0..<UInt64(40) {
                let document = try schema.generator.sample(seed: seed).document
                #expect(try decodeFromValue(JSONTreeBox.self, document).value == document)
                #expect(try encodeToValue(JSONTreeBox(document)) == document)
            }
        }
        try run(Settings.schema)
        try run(Shape.schema)
        try run(Prefs.schema)
        try run(Menu.schema)
    }

    @Test func negativeZeroAndTinyAndHugeNumbersKeepTheirValue() throws {
        let numbers: [JSONNumber] = [
            JSONNumber(-0.0) ?? JSONNumber(0), JSONNumber(5e-324) ?? JSONNumber(0), JSONNumber(1.7976931348623157e308) ?? JSONNumber(0),
            JSONNumber(0.1) ?? JSONNumber(0),
        ]
        for number in numbers {
            let document = JSONValue.number(number)
            let read = try decodeFromValue(JSONTreeBox.self, document).value
            #expect(read == document, "\(number)")
            // Reading through Decodable asks for an integer first, so the sign of a
            // negative zero is the one thing lost: -0 is equal to 0, and is read as 0.
            if number.lexeme != "-0" { #expect(read.number?.lexeme == number.lexeme) }
        }
    }

    @Test func membersAreReadInKeyOrder() throws {
        let read = try decodeFromValue(JSONTreeBox.self, ["b": 1, "a": 2, "c": 3]).value
        #expect(read.object?.keys == ["a", "b", "c"])
    }
}

/// The carrier the tests use to get a bare JSONValue through Codable.
private struct JSONTreeBox: Codable {
    var value: JSONValue
    init(_ value: JSONValue) { self.value = value }
    init(from decoder: any Decoder) throws { value = try JSONValue(reading: decoder) }
    func encode(to encoder: any Encoder) throws { try value.write(to: encoder) }
}

@Suite("Codable bridge: schemas inside Codable")
struct SchemaCodedTests {
    private let valid: JSONValue = [
        "id": 7,
        "settings": ["scrollSpeed": 900, "theme": "dark", "network": ["port": 8443]],
        "networks": [["port": 80], ["hosts": ["a", "b"]]],
    ]

    @Test func aValidDocumentDecodes() throws {
        let envelope = try decodeFromValue(Envelope.self, valid)
        #expect(envelope.id == 7)
        #expect(envelope.settings.value.scrollSpeed == 900)
        #expect(envelope.settings.value.theme == .dark)
        #expect(envelope.settings.value.network.port.value == 8443)
        #expect(envelope.networks.map(\.value.hosts) == [["localhost"], ["a", "b"]])
    }

    @Test func everyIssueComesBackInOneErrorWithItsFullPath() throws {
        var document = valid
        document = document.replacing(at("settings"), with: [
            "scrollSpeed": 1, "theme": "purple", "network": ["port": 0, "hosts": ["ok", ""]],
        ]) ?? document
        do {
            _ = try decodeFromValue(Envelope.self, document)
            Issue.record("expected an error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["settings"])
            let text = context.debugDescription
            #expect(text.hasPrefix("4 problems in $.settings:"))
            for location in ["$.settings.scrollSpeed", "$.settings.theme", "$.settings.network.port", "$.settings.network.hosts[1]"] {
                #expect(text.contains(location), "\(location)\n\(text)")
            }
            guard let failure = context.underlyingError as? ValidationFailure else { return fail("underlying error") }
            #expect(failure.errors.count == 4)
            #expect(failure.errors.allSatisfy { $0.path.description.hasPrefix("$.settings") })
        }
    }

    @Test func pathsThroughArraysUseIndices() throws {
        let document = valid.replacing(at("networks"), with: [["port": 80], ["port": 0], ["port": 70000, "useTLS": 5]])
        do {
            _ = try decodeFromValue(Envelope.self, document ?? valid)
            Issue.record("expected an error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["networks", "Index 1"])
            // The first bad element stops the surrounding Codable code, as Codable does.
            #expect(context.debugDescription.contains("$.networks[1].port"))
        }
    }

    @Test func aProblemOutsideTheSchemaIsAnOrdinaryDecodingError() {
        let document = valid.replacing(at("id"), with: "seven")
        #expect(throws: DecodingError.self) { try decodeFromValue(Envelope.self, document ?? valid) }
        do {
            _ = try decodeFromValue(Envelope.self, document ?? valid)
        } catch let DecodingError.typeMismatch(_, context) {
            #expect(context.codingPath.map(\.stringValue) == ["id"])
        } catch {
            Issue.record("expected a type mismatch, got \(error)")
        }
    }

    @Test func warningsDoNotThrow() throws {
        let document = valid.setting("surprise", to: 1, inObjectAt: at("settings"))
        let envelope = try decodeFromValue(Envelope.self, document ?? valid)
        #expect(envelope.settings.value.scrollSpeed == 900)
    }

    @Test func userInfoSelectsLenientDecoding() throws {
        let document = valid.replacing(at("settings", "scrollSpeed"), with: 5) ?? valid
        #expect(throws: DecodingError.self) { try decodeFromValue(Envelope.self, document) }
        let lenient = try decodeFromValue(Envelope.self, document, userInfo: [.schemaDecodeOptions: DecodeOptions.lenient])
        #expect(lenient.settings.value.scrollSpeed == 1200)
    }

    @Test func encodingWritesWhatTheSchemaEncodes() throws {
        let envelope = try decodeFromValue(Envelope.self, valid)
        let written = try encodeToValue(envelope)
        #expect(written.object?["settings"] == Settings.schema.encode(envelope.settings.value, style: .full))
        #expect(try decodeFromValue(Envelope.self, written) == envelope)
    }

    @Test func userInfoSelectsSparseEncoding() throws {
        let envelope = try decodeFromValue(Envelope.self, valid)
        let sparse = try encodeToValue(envelope, userInfo: [.schemaEncodeStyle: EncodeStyle.sparse(includeSecrets: true)])
        #expect(sparse.object?["settings"] == Settings.schema.encode(envelope.settings.value, style: .sparse(includeSecrets: true)))
        #expect(try decodeFromValue(Envelope.self, sparse) == envelope)
    }

    @Test func aValueTheSchemaCannotWriteFailsEncoding() {
        var settings = Settings()
        settings.scrollSpeed = .nan
        #expect(throws: EncodingError.self) { try encodeToValue(SchemaCoded(settings)) }
    }

    @Test func containerHelpersReadAndWriteSchemaBackedProperties() throws {
        let document: JSONValue = [
            "title": "T", "network": ["hosts": ["x"]], "shape": ["type": "circle", "radius": 3],
        ]
        let value = try decodeFromValue(Handwritten.self, document)
        #expect(value.shape == .circle(Circle(radius: 3)))
        #expect(value.network.hosts == ["x"])
        #expect(try decodeFromValue(Handwritten.self, encodeToValue(value)) == value)
        let without = try decodeFromValue(Handwritten.self, ["title": "T", "network": [:]])
        #expect(without.shape == nil)
    }

    @Test func aBadPayloadInAHelperReportsThePathOfTheKey() {
        let document: JSONValue = ["title": "T", "network": [:], "shape": ["type": "hexagon"]]
        do {
            _ = try decodeFromValue(Handwritten.self, document)
            Issue.record("expected an error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["shape"])
            #expect(context.debugDescription.contains("$.shape.type"))
            #expect(context.debugDescription.contains("did you mean") == false)  // "hexagon" is far from every tag
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func aTopLevelSchemaCodedValueWorks() throws {
        #expect(try decodeFromValue(SchemaCoded<Int>.self, 5).value == 5)
        do {
            _ = try decodeFromValue(SchemaCoded<Int>.self, "x")
            Issue.record("expected an error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.hasPrefix("1 problem in the document:"))
            #expect(context.debugDescription.contains("$:"))
        }
    }

    @Test func schemaCodedIsEquatableAndHashableWhenItsValueIs() {
        #expect(SchemaCoded(Network()) == SchemaCoded(Network()))
    }
}

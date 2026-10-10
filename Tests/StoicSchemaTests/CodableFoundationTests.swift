// This file, and only this file, imports Foundation: the bridge itself must
// not, and these tests show it works with the decoders that do.
import Foundation
import StoicJSON
import Testing

@testable import StoicSchema

private struct Profile: Codable, Equatable {
    var name: String
    var settings: SchemaCoded<Settings>
    var recent: [SchemaCoded<Network>]
    var pinned: SchemaCoded<Shape>?
}

@Suite("Codable bridge with Foundation's coders")
struct FoundationCoderTests {
    private let text = """
        {
          "name": "work",
          "settings": {"scrollSpeed": 900.5, "theme": "dark", "network": {"hosts": ["a.example"], "port": 8443}},
          "recent": [{"port": 80}, {"hosts": []}],
          "pinned": {"type": "circle", "radius": 2.5, "filled": true}
        }
        """

    @Test func jsonDecoderReadsASchemaBackedProperty() throws {
        let account = try JSONDecoder().decode(Profile.self, from: Data(text.utf8))
        #expect(account.name == "work")
        #expect(account.settings.value.scrollSpeed == 900.5)
        #expect(account.settings.value.network.port.value == 8443)
        #expect(account.recent.map(\.value.hosts) == [["localhost"], []])
        #expect(account.pinned?.value == .circle(Circle(radius: 2.5, filled: true)))
    }

    @Test func jsonEncoderWritesWhatTheSchemaEncodesAndItReadsBack() throws {
        let account = try JSONDecoder().decode(Profile.self, from: Data(text.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(account)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        #expect(back == account)
        let tree = try JSONDecoder().decode(JSONTree.self, from: data).value
        #expect(tree.object?["settings"] == Settings.schema.encode(account.settings.value, style: .full))
    }

    @Test func oneErrorListsEveryIssueWithTheDocumentPath() throws {
        let bad = text.replacing(#""scrollSpeed": 900.5"#, with: #""scrollSpeed": 1"#)
            .replacing(#""theme": "dark""#, with: #""theme": "Dark""#)
            .replacing(#""port": 8443"#, with: #""port": 70000"#)
        do {
            _ = try JSONDecoder().decode(Profile.self, from: Data(bad.utf8))
            Issue.record("expected an error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["settings"])
            let lines = context.debugDescription.split(separator: "\n")
            #expect(lines[0] == "3 problems in $.settings:")
            #expect(lines.count == 4)
            #expect(context.debugDescription.contains("$.settings.scrollSpeed"))
            #expect(context.debugDescription.contains("$.settings.theme"))
            #expect(context.debugDescription.contains("(did you mean `dark`?)"))
            #expect(context.debugDescription.contains("$.settings.network.port"))
            #expect((context.underlyingError as? ValidationFailure)?.errors.count == 3)
        }
    }

    @Test func anIssueInAnArrayNamesTheIndex() throws {
        let bad = text.replacing(#"{"hosts": []}"#, with: #"{"hosts": [""]}"#)
        do {
            _ = try JSONDecoder().decode(Profile.self, from: Data(bad.utf8))
            Issue.record("expected an error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["recent", "Index 1"])
            #expect(context.codingPath.last?.intValue == 1)
            #expect(context.debugDescription.contains("$.recent[1].hosts[0]"))
        }
    }

    @Test func aTopLevelSchemaBackedValueIsDecodedFromText() throws {
        let shape = try JSONDecoder().decode(SchemaCoded<Shape>.self, from: Data(#"{"type": "rect", "width": 3, "height": 4}"#.utf8))
        #expect(shape.value == .rect(Rect(width: 3, height: 4)))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SchemaCoded<Shape>.self, from: Data(#"{"type": "rect", "width": 3}"#.utf8))
        }
    }

    @Test func integersKeepEveryDigit() throws {
        let big = try JSONDecoder().decode(SchemaCoded<Int64>.self, from: Data("9007199254740993".utf8))
        #expect(big.value == 9_007_199_254_740_993)
        let unsigned = try JSONDecoder().decode(SchemaCoded<UInt64>.self, from: Data("18446744073709551615".utf8))
        #expect(unsigned.value == UInt64.max)
        let written = try JSONEncoder().encode(SchemaCoded(Int64.max))
        #expect(String(decoding: written, as: UTF8.self) == "9223372036854775807")
    }

    @Test func nullsBooleansAndNumbersAreToldApart() throws {
        let optional = try JSONDecoder().decode(SchemaCoded<Int?>.self, from: Data("5".utf8))
        #expect(optional.value == 5)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SchemaCoded<Bool>.self, from: Data("1".utf8)) }
        #expect(try JSONDecoder().decode(SchemaCoded<Bool>.self, from: Data("true".utf8)).value)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SchemaCoded<String>.self, from: Data("5".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SchemaCoded<Int>.self, from: Data("null".utf8)) }
    }

    @Test func unicodeStringsSurvive() throws {
        let text = "caf\u{E9} e\u{301} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \"quoted\" \\ \u{1}"
        let data = try JSONEncoder().encode(SchemaCoded(text))
        #expect(try JSONDecoder().decode(SchemaCoded<String>.self, from: data).value.unicodeScalars.elementsEqual(text.unicodeScalars))
    }

    @Test func generatedSettingsSurviveAJSONRoundTrip() throws {
        for seed in 0..<UInt64(60) {
            let sample = try Settings.schema.generator.sample(seed: seed)
            let data = try JSONEncoder().encode(SchemaCoded(sample.value))
            let back = try JSONDecoder().decode(SchemaCoded<Settings>.self, from: data)
            #expect(back.value == sample.value, "seed \(seed): \(String(decoding: data, as: UTF8.self))")
        }
    }

    @Test func propertyListCodersWorkToo() throws {
        // A decoder that is not JSON at all: the schema sees only the tree.
        var settings = Settings()
        settings.scrollSpeed = 640
        settings.theme = .light
        settings.network.hosts = ["p.example"]
        settings.shortcuts = ["a": "b"]
        let data = try PropertyListEncoder().encode(SchemaCoded(settings))
        let back = try PropertyListDecoder().decode(SchemaCoded<Settings>.self, from: data)
        #expect(back.value == settings)
        let bad = try PropertyListEncoder().encode(["scrollSpeed": 1.0])
        #expect(throws: DecodingError.self) { try PropertyListDecoder().decode(SchemaCoded<Settings>.self, from: bad) }
    }

    @Test func userInfoReachesTheSchemaThroughFoundationsCoders() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.schemaDecodeOptions] = DecodeOptions.lenient
        let decoded = try decoder.decode(SchemaCoded<Settings>.self, from: Data(#"{"scrollSpeed": 1}"#.utf8))
        #expect(decoded.value.scrollSpeed == 1200)
        let encoder = JSONEncoder()
        encoder.userInfo[.schemaEncodeStyle] = EncodeStyle.sparse
        encoder.outputFormatting = [.sortedKeys]
        var settings = Settings()
        settings.scrollSpeed = 700
        #expect(String(decoding: try encoder.encode(SchemaCoded(settings)), as: UTF8.self) == #"{"scrollSpeed":700}"#)
    }
}

/// Reads any JSON into a tree with the bridge.
private struct JSONTree: Decodable {
    var value: JSONValue
    init(from decoder: any Decoder) throws { value = try JSONValue(reading: decoder) }
}

@Suite("Foundation-free")
struct FoundationFreeTests {
    @Test func theLibrarySourcesNeverImportFoundation() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        var checked = 0
        for target in ["StoicSchema", "StoicJSON"] {
            let enumerator = FileManager.default.enumerator(at: sources.appending(path: target), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                checked += 1
                for line in text.split(separator: "\n") where line.contains("import Foundation") {
                    Issue.record("\(url.lastPathComponent) imports Foundation: \(line)")
                }
            }
        }
        #expect(checked > 30)
    }
}

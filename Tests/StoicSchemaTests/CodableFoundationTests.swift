// This file, and only this file, imports Foundation: the bridge itself must
// not, and these tests show it works with the decoders that do.
import Foundation
import StoicJSON
import StoicTesting
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

    @Test(.failureMode("design/06", "a value read through the Codable bridge nests deeper than `maxDepth`"))
    func deepNestingIsRefusedNotACrash() async throws {
        // 250 levels: inside JSONDecoder's own limit, and enough to crash the
        // recursive walk this replaced, in an ordinary task, under a key the
        // schema does not even declare.
        await #expect(processExitsWith: .success) {
            let text = #"{"limit": {"a": 1, "junk": "# + nestedTreeText(levels: 250) + "}}"
            let decoded = await Task.detached {
                (try? JSONDecoder().decode(FlatEnvelope.self, from: Data(text.utf8))) != nil
            }.value
            guard !decoded else { exit(1) }
        }
        do {
            let text = #"{"a": 1, "junk": "# + nestedTreeText(levels: 40) + "}"
            _ = try JSONDecoder().decode(SchemaCoded<Flat>.self, from: Data(text.utf8))
            Issue.record("expected an error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription == "nesting is deeper than 64 levels, the limit")
        }
        // The limit is the parse options' and moves with them.
        let decoder = JSONDecoder()
        var options = DecodeOptions(mode: .lenient)
        options.parse.maxDepth = 200
        decoder.userInfo[.schemaDecodeOptions] = options
        let read = try decoder.decode(SchemaCoded<Flat>.self, from: Data((#"{"a": 1, "junk": "# + nestedTreeText(levels: 40) + "}").utf8))
        #expect(read.value == Flat(a: 1))
    }

    @Test(.failureMode("design/06", "a value read through the Codable bridge repeats a key"))
    func aRepeatedKeyIsResolvedByTheDecoderBeforeTheSchemaSeesIt() throws {
        // StoicJSON refuses the document; JSONDecoder keeps the first value,
        // and the bridge cannot know there was a second.
        let text = #"{"a": 5, "a": 50}"#
        #expect(Flat.schema.decodeReporting(text).issues.map(\.code) == [.parseError])
        #expect(try JSONDecoder().decode(SchemaCoded<Flat>.self, from: Data(text.utf8)).value == Flat(a: 5))
    }

    @Test(.failureMode("design/06", "a decode that succeeds with warnings is asked only for its value"))
    func aWarningTravelsWithTheValueThroughTheBridge() throws {
        // `init(from:)` cannot hand a warning to anyone, so the wrapper
        // keeps it beside the value, with its path from the document root.
        let text = #"{"limit": {"a": 1, "ids": [1, "two", 3]}}"#
        let decoded = try JSONDecoder().decode(LossyEnvelope.self, from: Data(text.utf8))
        #expect(decoded.limit.value.ids == [1, 3])
        #expect(decoded.limit.warnings.map { "\($0.path) \($0.code)" } == ["$.limit.ids[1] dropped_element"])
        #expect(decoded.limit == SchemaCoded(Lossy(a: 1, ids: [1, 3])))
    }

    @Test func longStringsAndBigContainersAreRefusedByTheLimits() throws {
        let decoder = JSONDecoder()
        var options = DecodeOptions(mode: .lenient)
        options.parse.maxStringBytes = 8
        options.parse.maxContainerCount = 3
        decoder.userInfo[.schemaDecodeOptions] = options
        func refusal(_ text: String) -> String? {
            do {
                _ = try decoder.decode(SchemaCoded<Flat>.self, from: Data(text.utf8))
                return nil
            } catch let DecodingError.dataCorrupted(context) {
                return context.debugDescription
            } catch {
                return "\(error)"
            }
        }
        #expect(refusal(#"{"a": 1, "x": "123456789"}"#) == "a string is longer than 8 bytes (UTF-8), the limit")
        #expect(refusal(#"{"a": 1, "123456789": 0}"#) == "a string is longer than 8 bytes (UTF-8), the limit")
        #expect(refusal(#"{"a": 1, "x": [1, 2, 3, 4]}"#) == "a container has more than 3 elements, the limit")
        #expect(refusal(#"{"a": 1, "b": 2, "c": 3, "d": 4}"#) == "a container has more than 3 elements, the limit")
        #expect(refusal(#"{"a": 1, "x": [1, 2, 3]}"#) == nil)
    }
}

/// A flat model that ignores the keys it does not declare: the bridge still
/// walks whatever is under them.
struct Flat: Schematic, Equatable {
    var a: Int

    static let schema = Schema.object(Flat.self, unknownKeys: .ignore) { f in
        let a = f.field("a", \.a, .int())
        return f.build { v in Flat(a: v[a]) }
    }
}

struct FlatEnvelope: Decodable {
    var limit: SchemaCoded<Flat>
}

/// A model with a lossy array, whose dropped elements are warnings.
struct Lossy: Schematic, Equatable {
    var a: Int
    var ids: [Int]

    static let schema = Schema.object(Lossy.self) { f in
        let a = f.field("a", \.a, .int())
        let ids = f.field("ids", \.ids, .lossyArray(of: .int()), default: [])
        return f.build { v in Lossy(a: v[a], ids: v[ids]) }
    }
}

struct LossyEnvelope: Decodable {
    var limit: SchemaCoded<Lossy>
}

/// `levels` objects, each holding an array holding the next.
func nestedTreeText(levels: Int) -> String {
    String(repeating: #"{"children":["#, count: levels) + String(repeating: "]}", count: levels)
}

/// Reads any JSON into a tree with the bridge.
private struct JSONTree: Decodable {
    var value: JSONValue
    init(from decoder: any Decoder) throws { value = try JSONValue(reading: decoder) }
}

@Suite("Foundation-free")
struct FoundationFreeTests {
    /// StoicJSON never imports Foundation, and StoicSchema imports it only in
    /// the files that give Foundation's own types their schemas (design/06,
    /// "Foundation"): the decoder, the encoder and every tool are written
    /// against the standard library.
    @Test func theLibrarySourcesImportFoundationOnlyForFoundationTypes() throws {
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
                if target == "StoicSchema", url.deletingLastPathComponent().lastPathComponent == "Foundation" { continue }
                for line in text.split(separator: "\n") where line.contains("import Foundation") {
                    Issue.record("\(url.lastPathComponent) imports Foundation: \(line)")
                }
            }
        }
        #expect(checked > 30)
    }
}

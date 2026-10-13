import Foundation
import Stoic
@testable import StoicHTTP
import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// The parser's per-string and per-container limits against the client's
/// byte cap: a response the client agreed to read is decoded.
@Suite("HTTP decoding limits")
struct HTTPDecodingLimitTests {
    // Row: a response within the cap has one string over 1 MiB or an array over 100,000 elements.
    @Test(.failureMode("design/19", "a response within the cap has one string over 1 MiB or an array over 100,000 elements"))
    func aLongStringAndALongArrayWithinTheCapAreDecoded() async throws {
        let text = String(repeating: "x", count: 3 * 1024 * 1024)
        let count = JSONParseOptions.strict.maxContainerCount + 50_000
        let values = (0..<count).map { String($0 % 10) }.joined(separator: ",")
        let body = Array(#"{"text": "\#(text)", "values": [\#(values)]}"#.utf8)
        #expect(body.count < 10_000_000, "the premise: within the cap")
        #expect(text.utf8.count > JSONParseOptions.strict.maxStringBytes, "the premise: over the parser's string limit")
        try await withRig(.testing(maxResponseBytes: 10_000_000)) { (rig) async throws in
            rig.transport.on(.get("/blob"), respond: [.bytes(body)])
            let blob = try await rig.api.send(.get("/blob"), decoding: Blob.schema)
            #expect(blob.text.utf8.count == 3 * 1024 * 1024)
            #expect(blob.values.count == count)
        }
    }

    @Test func aStringAsLongAsTheCapAllowsIsDecoded() async throws {
        // The longest string a 2 MB response can hold: the body minus the JSON around it.
        let overhead = Array(#"{"text": "", "values": []}"#.utf8).count
        let text = String(repeating: "é", count: (2_000_000 - overhead) / 2)
        let body = Array(#"{"text": "\#(text)", "values": []}"#.utf8)
        #expect(body.count <= 2_000_000)
        try await withRig(.testing(maxResponseBytes: 2_000_000)) { (rig) async throws in
            rig.transport.on(.get("/blob"), respond: [.bytes(body)])
            let blob = try await rig.api.send(.get("/blob"), decoding: Blob.schema)
            #expect(blob.text == text)
        }
    }

    @Test func aSmallCapDoesNotLowerTheParsersLimits() async throws {
        let policy = HTTPPolicy.testing(maxResponseBytes: 1000)
        let options = policy.responseDecodeOptions
        #expect(options.parse.maxBytes == JSONParseOptions.strict.maxBytes)
        #expect(options.parse.maxStringBytes == JSONParseOptions.strict.maxStringBytes)
        #expect(options.parse.maxContainerCount == JSONParseOptions.strict.maxContainerCount)
        #expect(options.parse.maxDepth == JSONParseOptions.strict.maxDepth, "depth is not about size")
    }

    @Test func optionsGivenExplicitlyAreUsedExactlyAsGiven() async throws {
        var options = DecodeOptions.strict
        options.parse.maxStringBytes = 1000
        let body = Array(#"{"text": "\#(String(repeating: "x", count: 2000))", "values": []}"#.utf8)
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/blob"), respond: [.bytes(body)])
            let error = await #expect(throws: HTTPError.self) {
                try await rig.api.send(.get("/blob"), decoding: Blob.schema, options: options)
            }
            guard case .decoding? = error else {
                Issue.record("the per-call limit should have failed the decode, got \(String(describing: error))")
                return
            }
        }
    }
}

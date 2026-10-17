#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Testing

/// A download against a server that cuts, stalls, refuses, ignores ranges and
/// changes its file, under the simulation's seeded scheduler and virtual time:
/// whatever happens, what the destination holds is the exact bytes or nothing.
@Suite("Downloads under simulation", .timeLimit(.minutes(5)))
struct DownloadSimulationTests {
    /// One scripted answer, chosen at random.
    static func step(_ choice: Int, good: [UInt8], bad: [UInt8], random: inout RandomGenerator) -> Step {
        let size = good.count
        func offset() -> Int { Int.random(in: 0...size, using: &random) }
        let current = Resource(good, etag: "\"v1\"")
        switch choice {
        case 0: return .serving(current, chunkSize: 700, fault: .cut(after: offset()))
        case 1: return .serving(current, chunkSize: 700, fault: .fail(after: offset(), .timedOut))
        case 2: return .status(503)
        case 3: return .status(429, headers: ["Retry-After": String(Int.random(in: 1...90, using: &random))])
        case 4: return .failure(.networkConnectionLost)
        case 5: return .serving(Resource(bad, etag: "\"v2\""), chunkSize: 900, fault: offset() % 3 == 0 ? .cut(after: offset()) : nil)
        case 6: return .serving(Resource(good, etag: "\"v1\"", honoursRange: false), chunkSize: 700, fault: .cut(after: offset()))
        case 7: return .serving(current, chunkSize: 700, fault: .stall(after: offset(), for: .seconds(Int.random(in: 1...200, using: &random))))
        case 8: return .serving(Resource(good), chunkSize: 500, fault: .cut(after: offset()))
        default: return .status(Int.random(in: 0...1, using: &random) == 0 ? 404 : 403)
        }
    }

    @Test(.failureMode("design/23", "a download meets any mix of cuts, refusals and changes"))
    func theDestinationHoldsTheExactBytesOrNothingWhateverTheServerDoes() async throws {
        try await simulate(seeds: 0..<250) { sim in
            var random = Ambient.current.random.generator()
            let size = Int.random(in: 2_000...12_000, using: &random)
            let good = fileBytes(size, seed: sim.seed &+ 1)
            let bad = fileBytes(size, seed: sim.seed &+ 5_000)
            let upsets = Int.random(in: 0...6, using: &random)
            var script = (0..<upsets).map { _ in Self.step(Int.random(in: 0...9, using: &random), good: good, bad: bad, random: &random) }
            // What the server settles on: the right file, mostly; sometimes the wrong one for good.
            let settles = Int.random(in: 0..<10, using: &random) < 8
            script.append(.serving(Resource(settles ? good : bad, etag: settles ? "\"v1\"" : "\"v2\""), chunkSize: 800))

            let transport = ScriptedTransport()
            transport.on(.get("/model.bin"), respond: script)
            let disk = SimulatedFileSystem(recordsHistory: false)
            let client = HTTPClient(base: modelsBase, transport: transport)
            let policy = DownloadPolicy.testing(checkpointBytes: Int.random(in: 500...3_000, using: &random), writeBufferBytes: Int.random(in: 100...900, using: &random))
            let downloader = Downloader(client: client, fileSystem: disk, policy: policy, label: "simulation")
            let request = try download(good)

            var outcome: DownloadResult?
            var failure: DownloadError?
            do {
                outcome = try await downloader.download(request)
            } catch let error as DownloadError {
                failure = error
            }

            // Whatever happened, the destination is the file or nothing: never the wrong bytes.
            let placed = disk.contents(of: modelPath)
            if let outcome {
                try #require(placed == good, "a success placed the wrong bytes (seed \(sim.seed))")
                try #require(outcome.bytes == good.count)
                try #require(outcome.verifiedDigest?.hex == sha256Hex(good))
                try #require(disk.contents(of: partialPath) == nil && disk.contents(of: recordPath) == nil, "a success left its partial file behind")
            } else if let failure {
                try #require(placed == nil, "a failure placed a file: \(failure) (seed \(sim.seed))")
                switch failure {
                case .http, .digestMismatch: break
                default: Issue.record("an unexpected failure: \(failure) (seed \(sim.seed))")
                }
            }
            try #require(transport.requestCount <= 60, "a download that never ends (seed \(sim.seed))")
            try #require(transport.inFlightCount == 0, "a transfer was left open (seed \(sim.seed))")
        }
    }

    @Test func aSimulatedDownloadRunsTheSameWayTwice() async throws {
        // A seed is the whole story: the same seed takes the same path.
        func run() async throws -> Int {
            try await simulate(seed: 42) { sim in
                var random = Ambient.current.random.generator()
                let good = fileBytes(6_000)
                let transport = ScriptedTransport()
                transport.on(.get("/model.bin"), respond: [
                    Self.step(0, good: good, bad: good, random: &random), Self.step(3, good: good, bad: good, random: &random),
                    .serving(Resource(good, etag: "\"v1\""), chunkSize: 800),
                ])
                let client = HTTPClient(base: modelsBase, transport: transport)
                let downloader = Downloader(client: client, fileSystem: SimulatedFileSystem(), policy: .testing(), label: "replay")
                _ = try await downloader.download(try download(good))
                return transport.requestCount
            }.value
        }
        let first = try await run()
        let second = try await run()
        #expect(first == second)
    }
}
#endif

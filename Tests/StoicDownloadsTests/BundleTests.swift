#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Synchronization
import Testing

/// A fresh directory under the system's temporary one, removed when the test
/// is done with it.
struct TempDirectory: ~Copyable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "stoic-downloads-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> String { path + "/" + name }

    deinit {
        // stoic:allow(discarded-try): a temporary directory that cannot be removed is the system's to clear
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A downloader on a scripted server and the real file system, for what the
/// simulated one cannot model: directories, swapped and removed whole.
final class DiskHarness: Sendable {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let transport = ScriptedTransport()
    let downloader: Downloader

    init(policy: DownloadPolicy = .testing(), operation: Backend.Operation? = nil) {
        let client = HTTPClient(base: modelsBase, policy: .forDownloadTests, transport: transport)
        downloader = Downloader(client: client, fileSystem: PosixFileSystem(), policy: policy, label: "bundle", operation: operation)
    }

    func start(_ bundle: DownloadBundle, progress: (@Sendable (DownloadProgress) -> Void)? = nil) -> Task<DownloadBundleResult, any Error> {
        let downloader = downloader
        return Task { try await downloader.download(bundle, progress: progress) }
    }

    func waitOutBackoff(_ delay: Duration) async {
        let due = clock.now.advanced(by: delay)
        await eventually("the download never began a backoff of \(delay)") { clock.pendingDeadlines.contains(due) }
        await clock.advance(to: due)
    }
}

func withDiskHarness<R>(
    policy: DownloadPolicy = .testing(), operation: Backend.Operation? = nil, _ body: (DiskHarness) async throws -> R
) async throws -> R {
    let harness = DiskHarness(policy: policy, operation: operation)
    return try await withTestAmbient(clock: harness.clock, seed: 5, events: harness.events) { () async throws -> R in
        try await body(harness)
    }
}

func read(_ path: String) -> [UInt8]? {
    FileManager.default.contents(atPath: path).map { [UInt8]($0) }
}

func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

func names(in path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

/// Failure-mode rows of design/23 about bundles: several files fetched into a
/// staging directory and swapped over the destination whole.
@Suite("Download bundles", .timeLimit(.minutes(1)))
struct BundleTests {
    struct Model {
        var config = fileBytes(1_200, seed: 11)
        var tokenizer = fileBytes(2_500, seed: 12)
        var weights = fileBytes(9_000, seed: 13)

        func file(_ path: String, _ bytes: [UInt8], digest: Bool = true) throws -> DownloadBundle.File {
            DownloadBundle.File(path, HTTPRequest.get("/" + path), expectedSize: bytes.count, digest: digest ? try sha256(bytes) : nil)
        }

        func bundle(to destination: String, keepsPartialOnCancel: Bool = true) throws -> DownloadBundle {
            DownloadBundle(
                [try file("config.json", config), try file("tokenizer/tokens.json", tokenizer), try file("weights.bin", weights)],
                to: destination, keepsPartialOnCancel: keepsPartialOnCancel, fileMode: 0o644)
        }

        func serve(_ transport: ScriptedTransport, weights steps: [Step]? = nil) {
            transport.on(.get("/config.json"), respond: [.serving(Resource(config, etag: "\"c\""))])
            transport.on(.get("/tokenizer/tokens.json"), respond: [.serving(Resource(tokenizer, etag: "\"t\""))])
            transport.on(.get("/weights.bin"), respond: steps ?? [.serving(Resource(weights, etag: "\"w\""), chunkSize: 1_000)])
        }
    }

    @Test(.failureMode("design/23", "a bundle is downloaded"))
    func aBundleIsFetchedFileByFileAndPlacedAsOneDirectory() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            model.serve(h.transport)
            let destination = temp.file("org/model")
            let result = try await h.downloader.download(try model.bundle(to: destination))
            #expect(result.path == destination)
            #expect(result.files.map(\.path) == [destination + "/config.json", destination + "/tokenizer/tokens.json", destination + "/weights.bin"])
            #expect(result.files.map(\.bytes) == [1_200, 2_500, 9_000])
            #expect(result.files.map(\.requests) == [1, 1, 1])
            #expect(result.isDurable)
            #expect(read(destination + "/config.json") == model.config)
            #expect(read(destination + "/tokenizer/tokens.json") == model.tokenizer)
            #expect(read(destination + "/weights.bin") == model.weights)
            #expect(names(in: destination) == ["config.json", "tokenizer", "weights.bin"], "nothing but the bundle's files")
            #expect(names(in: temp.file("org")) == ["model"], "the staging directory is gone")
            let attributes = try FileManager.default.attributesOfItem(atPath: destination + "/weights.bin")
            #expect((attributes[.posixPermissions] as? Int) == 0o644)
            #expect(h.events.count("download.placed") == 4, "one for each file and one for the bundle")
        }
    }

    @Test(.failureMode("design/23", "a bundle has one file whole, one part-way and one missing"))
    func anInterruptedBundleResumesEachFileAsItIs() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            let destination = temp.file("model")
            // The first run: the config arrives, the tokenizer is cut part-way and then refused.
            h.transport.on(.get("/config.json"), respond: [.serving(Resource(model.config, etag: "\"c\""))])
            h.transport.on(.get("/tokenizer/tokens.json"), respond: [
                .serving(Resource(model.tokenizer, etag: "\"t\""), chunkSize: 500, fault: .cut(after: 1_500)), .status(403),
            ])
            let first = h.start(try model.bundle(to: destination))
            await h.waitOutBackoff(.seconds(10))
            do {
                _ = try await first.value
                Issue.record("the first run should have been refused")
            } catch DownloadError.http(let error) {
                #expect(error.statusCode == 403)
            }
            let staging = temp.file(".model.partial")
            #expect(read(staging + "/config.json") == model.config, "whole, at its own name")
            #expect(read(staging + "/tokenizer/tokens.json.partial")?.count == 1_500)
            #expect(!exists(staging + "/weights.bin") && !exists(staging + "/weights.bin.partial"), "missing")
            #expect(!exists(destination), "nothing is placed until every file is in")

            // The second run: nothing is asked for twice.
            model.serve(h.transport)
            let result = try await h.downloader.download(try model.bundle(to: destination))
            #expect(result.files.map(\.requests) == [0, 1, 1], "the whole file was verified and not fetched again")
            #expect(result.files.map(\.resumedFrom) == [1_200, 1_500, 0])
            #expect(h.transport.requests(to: .get("/config.json")).count == 1)
            #expect(h.transport.requests(to: .get("/tokenizer/tokens.json")).last?.headers["Range"] == "bytes=1500-")
            #expect(h.transport.requests(to: .get("/weights.bin")).last?.headers["Range"] == nil)
            #expect(h.events.count("download.file_reused") == 1)
            #expect(read(destination + "/tokenizer/tokens.json") == model.tokenizer)
            #expect(read(destination + "/weights.bin") == model.weights)
            #expect(!exists(staging))
        }
    }

    @Test(.failureMode("design/23", "a staged file does not check"))
    func aStagedFileThatDoesNotCheckIsFetchedAgain() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            let destination = temp.file("model")
            let staging = temp.file(".model.partial")
            try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
            // The right size and the wrong bytes: a file of an earlier version of the model.
            FileManager.default.createFile(atPath: staging + "/config.json", contents: Data(fileBytes(1_200, seed: 99)))
            model.serve(h.transport)
            let result = try await h.downloader.download(try model.bundle(to: destination))
            #expect(result.files.map(\.requests) == [1, 1, 1])
            #expect(read(destination + "/config.json") == model.config)
            #expect(h.events.count("download.file_reused") == 0)
        }
    }

    @Test func aStagedFileWithNoDigestToCheckItByIsNotTrusted() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            let destination = temp.file("model")
            let staging = temp.file(".model.partial")
            try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: staging + "/config.json", contents: Data(model.config))
            model.serve(h.transport)
            let bundle = DownloadBundle(
                [try model.file("config.json", model.config, digest: false), try model.file("weights.bin", model.weights)], to: destination)
            let result = try await h.downloader.download(bundle)
            #expect(result.files.map(\.requests) == [1, 1], "right size, but nothing says it is the right file")
        }
    }

    @Test(.failureMode("design/23", "the staging directory holds files that are not the bundle's"))
    func whatTheBundleDoesNotNameIsRemovedFromTheStagingDirectory() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            let destination = temp.file("model")
            let staging = temp.file(".model.partial")
            try FileManager.default.createDirectory(atPath: staging + "/old-dir", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: staging + "/removed-in-the-new-version.bin", contents: Data([1]))
            FileManager.default.createFile(atPath: staging + "/old-dir/x", contents: Data([2]))
            FileManager.default.createFile(atPath: staging + "/config.json.partial.resume.corrupt-1", contents: Data([3]))
            model.serve(h.transport)
            _ = try await h.downloader.download(try model.bundle(to: destination))
            #expect(names(in: destination) == ["config.json", "tokenizer", "weights.bin"])
            #expect(h.events.restartReasons.contains("stale_staging_files"))
        }
    }

    #if canImport(Darwin)
    @Test(.failureMode("design/23", "the bundle's destination already exists"))
    func anExistingDirectoryIsReplacedWholeAndTheOldOneRemoved() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            let destination = temp.file("model")
            try FileManager.default.createDirectory(atPath: destination + "/sub", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: destination + "/old.bin", contents: Data([9]))
            FileManager.default.createFile(atPath: destination + "/sub/old.txt", contents: Data([9]))
            model.serve(h.transport)
            let result = try await h.downloader.download(try model.bundle(to: destination))
            #expect(result.isDurable)
            #expect(names(in: destination) == ["config.json", "tokenizer", "weights.bin"], "the old files are not in the new directory")
            #expect(names(in: temp.path) == ["model"], "and the old directory is gone, not left at the staging path")
            #expect(read(destination + "/weights.bin") == model.weights)
        }
    }

    @Test func aFailedBundleLeavesTheOldDirectoryUntouched() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            let destination = temp.file("model")
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: destination + "/old.bin", contents: Data([9]))
            model.serve(h.transport, weights: [.status(404)])
            await #expect(throws: DownloadError.self) { try await h.downloader.download(try model.bundle(to: destination)) }
            #expect(names(in: destination) == ["old.bin"], "the old model is still the model")
            #expect(read(destination + "/old.bin") == [9])
        }
    }
    #endif

    @Test(.failureMode("design/23", "a file of a bundle does not check"))
    func aFileThatFailsItsDigestFailsTheBundleAndPlacesNothing() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness { h in
            let model = Model()
            let destination = temp.file("model")
            model.serve(h.transport, weights: [.serving(Resource(fileBytes(9_000, seed: 77)))])
            let task = h.start(try model.bundle(to: destination))
            do {
                _ = try await task.value
                Issue.record("the bundle should have failed")
            } catch DownloadError.digestMismatch(_, _, let attempts) {
                #expect(attempts == 2)
            }
            #expect(!exists(destination))
            let staging = temp.file(".model.partial")
            #expect(read(staging + "/config.json") == model.config, "the files that were right stay for the next run")
            #expect(!exists(staging + "/weights.bin.partial"), "the one that was wrong does not")
        }
    }

    @Test(.failureMode("design/23", "a bundle is cancelled"))
    func aCancelledBundleKeepsItsStagingDirectoryOrRemovesIt() async throws {
        for keeps in [true, false] {
            let temp = try TempDirectory()
            try await withDiskHarness { h in
                let model = Model()
                let destination = temp.file("model")
                model.serve(h.transport, weights: [
                    .serving(Resource(model.weights, etag: "\"w\""), chunkSize: 500, fault: .stall(after: 3_000, for: .seconds(3600))),
                ])
                let task = h.start(try model.bundle(to: destination, keepsPartialOnCancel: keeps))
                await eventually("the weights never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
                let staging = temp.file(".model.partial")
                if keeps {
                    #expect(read(staging + "/config.json") == model.config)
                    #expect(read(staging + "/weights.bin.partial")?.count == 3_000)
                } else {
                    #expect(!exists(staging))
                }
                #expect(!exists(destination))
            }
        }
    }

    @Test func aBundleReportsTheFileInProgressAndTheBytesOfTheWhole() async throws {
        let temp = try TempDirectory()
        try await withDiskHarness(policy: .testing(progressInterval: .zero)) { h in
            let model = Model()
            model.serve(h.transport)
            let seen = Mutex<[DownloadProgress]>([])
            _ = try await h.downloader.download(try model.bundle(to: temp.file("model"))) { progress in seen.withLock { $0.append(progress) } }
            let reports = seen.withLock { $0 }
            #expect(reports.allSatisfy { $0.fileCount == 3 && $0.totalBytes == 12_700 })
            #expect(Set(reports.map(\.fileIndex)) == [0, 1, 2])
            let bytes = reports.map(\.bytesDone)
            #expect(bytes == bytes.sorted(), "the bytes of the whole only grow")
            #expect(reports.last?.phase == .placing)
            #expect(reports.last?.bytesDone == 12_700)
            #expect(reports.contains { $0.fileIndex == 2 && $0.phase == .downloading && $0.bytesDone > 3_700 })
            #expect(reports.last?.fraction == 1)
        }
    }
}
#endif

#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Testing

/// Failure-mode rows of design/23 about the machine dying: at every file
/// operation of a download, whatever the disk kept, the destination is the
/// old file or the new one, whole, and the next run finishes the job.
@Suite("Download durability", .timeLimit(.minutes(5)))
struct DurabilityTests {
    static let old = Array("the old file, whole".utf8)
    static let policy = DownloadPolicy.testing(checkpointBytes: 1_500, writeBufferBytes: 400)
    /// The next run's: with no second fetch to fall back on, so a byte it trusted and should not have fails it.
    static let recoveryPolicy = DownloadPolicy.testing(verificationAttempts: 1, checkpointBytes: 1_500, writeBufferBytes: 400)

    /// A settled disk with an old file at the destination (or none).
    static func setup(hadOldFile: Bool) -> (SimulatedFileSystem) throws -> Void {
        { disk in
            try disk.createDirectory("/models")
            guard hadOldFile else { return }
            let file = try disk.open(modelPath, mode: .createExclusive)
            try disk.write(file, old, at: 0)
            try disk.fullSync(file)
            try disk.close(file)
            try disk.syncDirectory("/models")
        }
    }

    /// What must hold of the disk after a crash, once the next run has finished the download.
    static func check(_ image: SimulatedFileSystem, returned: Bool, hadOldFile: Bool, new: [UInt8]) async throws -> String? {
        // At the instant of the crash the destination is the old file or the new one: never torn.
        let found = image.contents(of: modelPath)
        if let found, found != new, found != old { return "the destination holds \(found.count) bytes that are neither the old file nor the new" }
        if found == nil, hadOldFile { return "the old file is gone, and the new one is not there" }
        if returned, found != new { return "the download had returned, and the destination is not the new file" }

        // The next run finishes the job, from whatever was left.
        let fork = image.fork()
        let result = try await withTestAmbient(clock: ImmediateClock()) {
            try await recover(fork, data: new, request: try download(new), policy: recoveryPolicy)
        }
        guard fork.contents(of: modelPath) == new else { return "after the next run the destination is not the new file (\(String(describing: result)))" }
        guard fork.contents(of: partialPath) == nil, fork.contents(of: recordPath) == nil else { return "the next run left its partial file or record behind" }
        return nil
    }

    @Test(
        .failureMode("design/23", "the process dies at any step of a download"),
        .failureMode("design/23", "the process dies at any step of placing"),
        arguments: [true, false]
    )
    func aCrashAtAnyFileOperationLeavesTheOldFileOrTheNewOneAndTheNextRunFinishes(hadOldFile: Bool) async throws {
        let new = fileBytes(6_500)
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await exploreDownloadCrashes(
                "a download of 6,500 bytes", setup: Self.setup(hadOldFile: hadOldFile),
                operation: { disk in
                    let harness = Harness(disk: disk, policy: Self.policy)
                    harness.transport.on(.get("/model.bin"), respond: [.serving(Resource(new, etag: "\"v1\""), chunkSize: 700)])
                    _ = try await harness.downloader.download(try download(new))
                    disk.checkpoint("returned")
                },
                check: { image, returned in try await Self.check(image, returned: returned, hadOldFile: hadOldFile, new: new) })
        }
        #expect(report.violations.isEmpty, "\(report)")
        #expect(report.operationCount > 20, "the exploration covered a download: \(report)")
    }

    @Test(.failureMode("design/23", "the process dies in a download that was cut and resumed"))
    func aCrashAtAnyFileOperationOfAResumedDownloadIsRecoverable() async throws {
        let new = fileBytes(6_500)
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await exploreDownloadCrashes(
                "a download that is cut twice", setup: Self.setup(hadOldFile: true),
                operation: { disk in
                    let harness = Harness(disk: disk, policy: Self.policy)
                    let server = Resource(new, etag: "\"v1\"")
                    harness.transport.on(.get("/model.bin"), respond: [
                        .serving(server, chunkSize: 700, fault: .cut(after: 2_300)),
                        .serving(server, chunkSize: 700, fault: .cut(after: 1_900)),
                        .serving(server, chunkSize: 700),
                    ])
                    _ = try await harness.downloader.download(try download(new))
                    disk.checkpoint("returned")
                },
                check: { image, returned in try await Self.check(image, returned: returned, hadOldFile: true, new: new) })
        }
        #expect(report.violations.isEmpty, "\(report)")
        #expect(report.operationCount > 40, "\(report)")
    }

    @Test(.failureMode("design/23", "the process dies while the next run is resuming"))
    func aCrashDuringTheRecoveryRunIsRecoverableToo() async throws {
        let new = fileBytes(5_000)
        var violations: [String] = []
        var runs = 0
        // The first run dies somewhere in the middle; the recovery run dies at each of its own steps.
        let first = SimulatedFileSystem()
        try Self.setup(hadOldFile: true)(first)
        first.settle()
        try await withTestAmbient(clock: ImmediateClock()) {
            let harness = Harness(disk: first, policy: Self.policy)
            harness.transport.on(.get("/model.bin"), respond: [.serving(Resource(new, etag: "\"v1\""), chunkSize: 700)])
            _ = try await harness.downloader.download(try download(new))
        }
        for point in stride(from: 0, through: first.operationCount, by: 5) {
            for image in first.crashImages(afterOperation: point, samples: 2, seed: UInt64(point)) {
                let second = image.fileSystem.fork()
                second.settle()
                do {
                    _ = try await withTestAmbient(clock: ImmediateClock()) { try await recover(second, data: new, request: try download(new), policy: Self.recoveryPolicy) }
                } catch {
                    violations.append("the recovery run after crash \(point) failed: \(error)")
                }
                for inner in stride(from: 0, through: second.operationCount, by: 4) {
                    for crashed in second.crashImages(afterOperation: inner, samples: 2, seed: UInt64(inner)) {
                        runs += 1
                        if let problem = try await Self.check(crashed.fileSystem, returned: false, hadOldFile: true, new: new) {
                            violations.append("first crash \(point), second crash \(inner): \(problem)")
                        }
                    }
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
        #expect(runs > 100)
    }

    // MARK: The directory sync

    @Test(.failureMode("design/23", "the directory sync after the rename fails"))
    func aFailedDirectorySyncAfterTheRenameLeavesTheFileInPlaceAndSaysSo() async throws {
        try await withHarness(through: { FaultingFileSystem($0, syncFailsAfterRenameTo: modelPath) }) { h in
            let data = fileBytes(3_000)
            h.transport.on(HTTPRequest.get("/model.bin"), respond: [.serving(Resource(data, etag: "\"v1\""))])
            let result = try await h.downloader.download(try download(data))
            #expect(!result.isDurable, "the file is in place, and nobody can say it survives a power cut")
            #expect(h.contents(modelPath) == data, "treated as placed: every reader sees it")
            #expect(h.contents(partialPath) == nil)
            #expect(h.events.events(named: "download.durability_unknown").first?.text("what") == "file")
            #expect(h.events.events(named: "download.placed").first?.flag("durable") == false)
            #expect(h.events.count("download.failed") == 0)
        }
    }

    @Test func aFailureToWriteTheRecordDurablyIsReportedAndTheDownloadGoesOn() async throws {
        try await withHarness { h in
            let data = fileBytes(3_000)
            h.transport.on(HTTPRequest.get("/model.bin"), respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 400)])
            // The directory syncs: the new directory's, then the record's at the start of the transfer.
            h.disk.inject(EIO, on: .syncDirectory, skipping: 1)
            let result = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
            #expect(result.isDurable)
            #expect(h.events.events(named: "download.durability_unknown").contains { $0.text("what") == "resume_record" })
        }
    }

    @Test func aRenameThatFailsLeavesTheVerifiedPartialFileForTheNextRun() async throws {
        try await withHarness(through: { FaultingFileSystem($0, renameTarget: modelPath) }) { h in
            let data = fileBytes(3_000)
            h.transport.on(HTTPRequest.get("/model.bin"), respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 400)])
            guard case DownloadError.store(let error)? = await failure(of: h.start(try download(data))) else {
                Issue.record("expected the disk's refusal")
                return
            }
            #expect(error.kind == .permissionDenied)
            #expect(h.contents(modelPath) == nil)
            #expect(h.contents(partialPath) == data)
            #expect(h.events.count("download.failed") == 1)
        }
    }
}
#endif

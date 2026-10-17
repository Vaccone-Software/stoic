#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Testing

/// Failure-mode rows of design/23 about what an earlier run left on disk: a
/// partial file and the record that says what it holds, and how much of it a
/// new run is willing to believe.
@Suite("Resuming", .timeLimit(.minutes(1)))
struct ResumeTests {
    static let route = HTTPRequest.get("/model.bin")

    /// Runs a download that is answered `403` after `cut` bytes, so a partial
    /// file and its record are left behind, as by a run that was interrupted.
    static func leavePartial(_ h: Harness, _ request: Download, server: Resource, cut: Int) async throws {
        h.transport.on(route, respond: [.serving(server, chunkSize: 500, fault: .cut(after: cut)), .status(403)])
        let first = h.start(request)
        await h.waitOutBackoff(.seconds(10))
        guard case DownloadError.http(let error)? = await failure(of: first) else {
            Issue.record("the first run should have ended with a 403")
            return
        }
        #expect(error.statusCode == 403)
        #expect(h.contents(partialPath)?.count == cut, "the partial file holds what arrived")
        #expect(h.contents(recordPath) != nil)
        h.transport.on(route, respond: [.serving(server, chunkSize: 500)])
    }

    @Test(.failureMode("design/23", "a run is stopped by an error that is not about the file"))
    func aRefusalAfterSomeBytesKeepsThemForTheNextRun() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"")
            try await Self.leavePartial(h, try download(data), server: server, cut: 4_000)
            let result = try await h.downloader.download(try download(data))
            #expect(result.resumedFrom == 4_000)
            #expect(result.requests == 1)
            #expect(h.transport.requests.last?.headers["Range"] == "bytes=4000-")
            #expect(h.transport.requests.last?.headers["If-Range"] == "\"v1\"")
            #expect(h.contents(modelPath) == data)
            #expect(h.events.count("download.resumed") == 1)
            #expect(h.events.events(named: "download.resumed").first?.number("offset") == 4_000)
            #expect(h.events.count("download.restarted") == 0)
        }
    }

    // MARK: The record

    @Test(.failureMode("design/23", "the partial file has no record"))
    func aPartialFileWithNoRecordIsStartedOver() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 3_000)
            try h.disk.remove(recordPath)
            _ = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons == ["record_missing"])
            #expect(h.transport.requests.last?.headers["Range"] == nil)
        }
    }

    @Test(.failureMode("design/23", "the resume record is torn or garbage"))
    func aRecordThatFailsItsChecksumIsStartedOverAndQuarantined() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 3_000)
            // One flipped bit in the middle of the record.
            let file = try h.disk.open(recordPath, mode: .readWrite)
            let byte = try h.disk.read(file, at: 30, count: 1)
            try h.disk.write(file, [byte[0] ^ 0x10], at: 30)
            try h.disk.close(file)
            _ = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons == ["record_invalid"])
            #expect(h.events.count("store.corrupt_quarantined") == 1)
            #expect(h.transport.requests.last?.headers["Range"] == nil)
        }
    }

    @Test(arguments: ["", "hello", "stoic-download 1\nidentity \nsynced 5\ntotal none\nvalidator none", "stoic-download 2\nx", "stoic-download 1\nidentity a\nsynced -5\ntotal none\nvalidator none"])
    func aRecordThatIsIntactButIsNotARecordIsStartedOver(content: String) async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 3_000)
            // Written the way a record is, with a valid checksum: the content is what is wrong.
            try AtomicFile(fileSystem: h.disk, options: .init(envelope: true)).write(Array(content.utf8), to: recordPath)
            _ = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons == ["record_invalid"])
        }
    }

    @Test(.failureMode("design/23", "the partial file belongs to another download"))
    func aPartialFileOfAnotherDownloadIsNotResumed() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000, seed: 1)
            let next = fileBytes(10_000, seed: 2)
            try await Self.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 3_000)
            // The same path, now pinned to the next revision of the file.
            h.transport.on(Self.route, respond: [.serving(Resource(next, etag: "\"v2\""))])
            _ = try await h.downloader.download(try download(next))
            #expect(h.contents(modelPath) == next)
            #expect(h.events.restartReasons == ["different_download"])
            #expect(h.transport.requests.last?.headers["Range"] == nil, "bytes of another file are not a prefix of this one")
        }
    }

    @Test(.failureMode("design/23", "the partial file is larger than the expected size"))
    func aPartialFileLargerThanTheFileIsDiscarded() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 3_000)
            try appendJunk(h.disk, to: partialPath, count: 9_000)
            _ = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons == ["larger_than_expected"])
        }
    }

    @Test(.failureMode("design/23", "the partial file holds bytes the record does not vouch for"))
    func bytesPastWhatTheRecordVouchesForAreCutOffNotTrusted() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 3_000)
            // What a power cut can leave: bytes after the last checkpoint, whatever they are.
            try appendJunk(h.disk, to: partialPath, count: 2_000)
            let result = try await h.downloader.download(try download(data))
            #expect(result.resumedFrom == 3_000)
            #expect(h.contents(modelPath) == data)
            #expect(h.events.events(named: "download.resumed").first?.number("discarded") == 2_000)
            #expect(h.transport.requests.last?.headers["Range"] == "bytes=3000-")
        }
    }

    @Test(.failureMode("design/23", "a resumed prefix was damaged"))
    func aDamagedPrefixIsCaughtByTheDigestAndFetchedAgainFromZero() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 4_000)
            // Rot in the part that was synced and believed.
            let file = try h.disk.open(partialPath, mode: .readWrite)
            try h.disk.write(file, [0xAA, 0xBB], at: 100)
            try h.disk.close(file)
            let result = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
            #expect(result.requests == 2, "the resume, and the refetch from zero")
            #expect(h.events.restartReasons == ["verification_failed"])
            #expect(h.transport.requests.suffix(2).map { $0.headers["Range"] } == ["bytes=4000-", nil])
        }
    }

    @Test func aPartialFileAlreadyWholeIsVerifiedAndPlacedWithoutARequest() async throws {
        // The first run is stopped by the disk refusing the rename that places the file.
        let disk = SimulatedFileSystem()
        let data = fileBytes(6_000)
        try await withHarness(disk: disk, through: { FaultingFileSystem($0, renameTarget: modelPath) }) { h in
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), fault: .cut(after: 6_000))])
            let first = await failure(of: h.start(try download(data)))
            guard case DownloadError.store(let error)? = first else {
                Issue.record("expected the disk's refusal, got \(String(describing: first))")
                return
            }
            #expect(error.kind == .permissionDenied)
            #expect(h.contents(partialPath) == data, "the file is whole and kept")
            #expect(h.contents(modelPath) == nil)
        }
        // The next run, on a disk that works.
        try await withHarness(disk: disk) { h in
            let result = try await h.downloader.download(try download(data))
            #expect(result.requests == 0, "nothing was left to fetch")
            #expect(result.resumedFrom == 6_000)
            #expect(h.transport.requestCount == 0)
            #expect(h.contents(modelPath) == data)
        }
    }

    // MARK: Validators

    @Test(.failureMode("design/23", "the server gives no validator and the download has a digest"))
    func withNoValidatorADigestIsWhatMakesResumingSafe() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data), server: Resource(data), cut: 4_000)
            _ = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
            #expect(h.transport.requests.last?.headers["Range"] == "bytes=4000-")
            #expect(h.transport.requests.last?.headers["If-Range"] == nil, "there is nothing to say it by")
        }
    }

    @Test(.failureMode("design/23", "the server gives no validator and the download has no digest"))
    func withNeitherAValidatorNorADigestAPartialFileIsNotResumed() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data, digest: false), server: Resource(data), cut: 4_000)
            _ = try await h.downloader.download(try download(data, digest: false))
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons == ["nothing_to_resume_by"])
            #expect(h.transport.requests.last?.headers["Range"] == nil, "a splice nothing could check is not made")
        }
    }

    @Test func lastModifiedIsTheValidatorWhenThereIsNoStrongEtag() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let date = "Wed, 21 Oct 2015 07:28:00 GMT"
            let server = Resource(data, etag: "W/\"weak\"", lastModified: date)
            try await Self.leavePartial(h, try download(data, digest: false), server: server, cut: 4_000)
            _ = try await h.downloader.download(try download(data, digest: false))
            #expect(h.transport.requests.last?.headers["If-Range"] == date, "a weak ETag is no validator")
            #expect(h.contents(modelPath) == data)
        }
    }

    @Test func aStrongEtagIsPreferredToALastModifiedDate() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"", lastModified: "Wed, 21 Oct 2015 07:28:00 GMT")
            try await Self.leavePartial(h, try download(data, digest: false), server: server, cut: 4_000)
            _ = try await h.downloader.download(try download(data, digest: false))
            #expect(h.transport.requests.last?.headers["If-Range"] == "\"v1\"")
        }
    }

    @Test func aWeakEtagAloneIsNoValidatorSoItNeedsADigest() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try await Self.leavePartial(h, try download(data, digest: false), server: Resource(data, etag: "W/\"w\""), cut: 4_000)
            _ = try await h.downloader.download(try download(data, digest: false))
            #expect(h.events.restartReasons == ["nothing_to_resume_by"])
        }
    }
}

/// Appends `count` bytes that are not the file's to a file on the disk.
func appendJunk(_ disk: SimulatedFileSystem, to path: String, count: Int) throws {
    let file = try disk.open(path, mode: .readWrite)
    let size = try disk.size(of: file)
    try disk.write(file, [UInt8](repeating: 0xEE, count: count), at: size)
    try disk.fullSync(file)
    try disk.close(file)
}
#endif

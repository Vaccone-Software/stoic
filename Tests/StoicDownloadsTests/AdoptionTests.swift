#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Testing

/// Failure-mode rows of design/23 about a partial file that Stoic did not
/// write, which the caller vouches for.
@Suite("Adopting a partial file", .timeLimit(.minutes(1)))
struct AdoptionTests {
    static let route = HTTPRequest.get("/model.bin")
    static let foreign = "/models/earlier-build/model.bin"

    /// A file an earlier program left, durable, with no record beside it.
    static func seed(_ disk: SimulatedFileSystem, _ path: String, _ bytes: [UInt8]) throws {
        try disk.createDirectory(String(path[..<path.lastIndex(of: "/")!]))
        let file = try disk.open(path, mode: .readWriteCreate)
        try disk.write(file, bytes, at: 0)
        try disk.fullSync(file)
        try disk.close(file)
    }

    @Test(.failureMode("design/23", "a partial file nobody recorded is adopted"))
    func anUnrecordedPartialFileIsResumedFromItsEndAndTheDigestStillDecides() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try Self.seed(h.disk, Self.foreign, Array(data[..<4_000]))
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let result = try await h.downloader.download(try download(data, mode: 0o644).adoptingUnrecordedPartial(at: Self.foreign))
            #expect(result.resumedFrom == 4_000)
            #expect(result.requests == 1)
            #expect(h.contents(modelPath) == data)
            #expect(h.transport.requests.last?.headers["Range"] == "bytes=4000-")
            #expect(h.transport.requests.last?.headers["If-Range"] == nil, "no validator was given, so none is asked")
            #expect(h.contents(Self.foreign) == nil, "the file moved to where the downloader resumes from, and on to the destination")
            #expect(try h.disk.permissions(of: modelPath) == 0o644, "the finished file has the download's mode, not the earlier program's")
            #expect(h.events.count("download.adopted") == 1)
            #expect(h.events.events(named: "download.adopted").first?.number("bytes") == 4_000)
            #expect(h.events.count("download.resumed") == 1)
            #expect(h.events.count("download.restarted") == 0)
        }
    }

    @Test func aValidatorIsAskedOfTheServerAndAChangedFileStartsOver() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try Self.seed(h.disk, Self.foreign, Array(data[..<4_000]))
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let kept = try download(data, digest: false).adoptingUnrecordedPartial(at: Self.foreign, validator: .etag("\"v1\""))
            let result = try await h.downloader.download(kept)
            #expect(result.resumedFrom == 4_000, "no digest, but a validator the server recognises")
            #expect(h.transport.requests.last?.headers["If-Range"] == "\"v1\"")
            #expect(h.contents(modelPath) == data)
        }
        try await withHarness { h in
            let data = fileBytes(10_000)
            try Self.seed(h.disk, Self.foreign, Array(data[..<4_000]))
            // The server's file is another version now: it answers the whole of it.
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v2\""), chunkSize: 500)])
            let stale = try download(data, digest: false).adoptingUnrecordedPartial(at: Self.foreign, validator: .etag("\"v1\""))
            let result = try await h.downloader.download(stale)
            #expect(result.resumedFrom == 0)
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons == ["validator_changed"])
        }
    }

    @Test(.failureMode("design/23", "an adopted partial file is not a prefix of the file"))
    func anAdoptedFileThatIsNotAPrefixFailsItsDigestAndIsFetchedAgain() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            // The caller was wrong: these bytes are another file's.
            try Self.seed(h.disk, Self.foreign, Array(fileBytes(4_000, seed: 99)))
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let result = try await h.downloader.download(try download(data).adoptingUnrecordedPartial(at: Self.foreign))
            #expect(h.contents(modelPath) == data, "the digest decided: never a spliced file")
            #expect(h.events.count("download.verification_failed") == 1)
            #expect(result.resumedFrom == 0, "the second run started from nothing")
            #expect(h.transport.requestCount == 2)
        }
    }

    @Test(.failureMode("design/23", "an adopted partial file has nothing to resume it by"))
    func aFileWithNoDigestAndNoValidatorIsLeftAloneAndTheFileIsFetchedWhole() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let theirs = Array(data[..<4_000])
            try Self.seed(h.disk, Self.foreign, theirs)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let result = try await h.downloader.download(try download(data, digest: false).adoptingUnrecordedPartial(at: Self.foreign))
            #expect(result.resumedFrom == 0)
            #expect(h.contents(modelPath) == data)
            #expect(h.contents(Self.foreign) == theirs, "not the downloader's to delete")
            #expect(h.events.events(named: "download.adoption_declined").map { $0.text("reason") } == ["nothing_to_resume_by"])
            #expect(h.events.count("download.adopted") == 0)
            #expect(h.transport.requests.last?.headers["Range"] == nil)
        }
    }

    @Test(arguments: [
        ("empty", 0, "empty"), ("larger than the file", 10_500, "larger_than_expected"),
    ] as [(String, Int, String)])
    func anUnusableFileIsDeclinedNotDeleted(_: String, size: Int, reason: String) async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let theirs = [UInt8](repeating: 7, count: size)
            try Self.seed(h.disk, Self.foreign, theirs)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            _ = try await h.downloader.download(try download(data).adoptingUnrecordedPartial(at: Self.foreign))
            #expect(h.events.events(named: "download.adoption_declined").map { $0.text("reason") } == [reason])
            #expect(h.contents(Self.foreign) == theirs)
            #expect(h.contents(modelPath) == data)
        }
    }

    @Test(.failureMode("design/23", "a partial file is offered for adoption and the downloader has one of its own"))
    func theDownloadersOwnPartialFileIsResumedAndTheOfferedOneIsNotTouched() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"")
            try await ResumeTests.leavePartial(h, try download(data), server: server, cut: 3_000)
            let theirs = Array(fileBytes(6_000, seed: 5))
            try Self.seed(h.disk, Self.foreign, theirs)
            let result = try await h.downloader.download(try download(data).adoptingUnrecordedPartial(at: Self.foreign))
            #expect(result.resumedFrom == 3_000, "the record the downloader wrote is the account of its own file")
            #expect(h.contents(modelPath) == data)
            #expect(h.contents(Self.foreign) == theirs)
            #expect(h.events.count("download.adopted") == 0)
        }
    }

    @Test func aPartialFileAtThePartialPathWithNoRecordIsAdoptedInPlace() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try Self.seed(h.disk, partialPath, Array(data[..<2_500]))
            h.transport.on(Self.route, respond: [.serving(Resource(data), chunkSize: 500)])
            let result = try await h.downloader.download(try download(data).adoptingUnrecordedPartial(at: partialPath))
            #expect(result.resumedFrom == 2_500)
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons.isEmpty, "not discarded as `record_missing`")
        }
    }

    @Test func aWholeFileIsAdoptedAndVerifiedWithoutARequest() async throws {
        try await withHarness { h in
            let data = fileBytes(3_000)
            try Self.seed(h.disk, Self.foreign, data)
            let result = try await h.downloader.download(try download(data).adoptingUnrecordedPartial(at: Self.foreign))
            #expect(result.requests == 0)
            #expect(h.transport.requestCount == 0)
            #expect(h.contents(modelPath) == data)
        }
    }

    @Test func anOrphanRecordWithNoPartialFileIsOverwrittenAndTheFileAdopted() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            try Self.seed(h.disk, Self.foreign, Array(data[..<4_000]))
            // What a crash between writing the record and moving the file leaves, or an old run's debris.
            try h.disk.createDirectory("/models")
            let orphan = Array("stoic-download 1\nidentity x\nsynced 9\ntotal none\nvalidator none".utf8)
            try AtomicFile(fileSystem: h.disk, options: .init(envelope: true)).write(orphan, to: recordPath)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let result = try await h.downloader.download(try download(data).adoptingUnrecordedPartial(at: Self.foreign))
            #expect(result.resumedFrom == 4_000)
            #expect(h.contents(modelPath) == data)
        }
    }
}
#endif

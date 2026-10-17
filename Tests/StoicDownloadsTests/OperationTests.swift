#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicTesting
import Testing

/// A download as a `.long` operation in design/22's terms: admitted under its
/// backend's capacity, bounded by the caller's deadline, never cut by an attempt
/// timeout, and never repeated by the operation (the downloader already did).
@Suite("Downloads as operations", .timeLimit(.minutes(1)))
struct DownloadOperationTests {
    static let route = HTTPRequest.get("/model.bin")

    @Test(.failureMode("design/23", "a download runs as a long operation"))
    func aDownloadRunsInsideItsOperationsAttemptAndTheClientDefersToIt() async throws {
        let operation = Backend.remote("downloads.operation.runs", capacity: 2).idempotent("download", length: .long)
        try await withHarness(operation: operation) { h in
            let data = fileBytes(5_000)
            // Cut once: the downloader resumes it. The client, inside a live attempt, makes one request for each.
            h.transport.on(Self.route, respond: [
                .serving(Resource(data, etag: "\"v1\""), fault: .cut(after: 2_000)), .serving(Resource(data, etag: "\"v1\"")),
            ])
            let task = h.start(try download(data))
            await h.waitOutBackoff(.seconds(10))
            let result = try await task.value
            #expect(result.requests == 2)
            #expect(h.contents(modelPath) == data)
            #expect(h.events.count("http.retry") == 0)
            #expect(h.events.count("retry.attempt_failed") == 0, "the operation did not retry a download the downloader had already resumed")
        }
    }

    @Test(.failureMode("design/23", "a long operation has no attempt timeout"))
    func noAttemptTimeoutCutsATransferThatIsProgressing() async throws {
        let operation = Backend.remote("downloads.operation.timeout", capacity: 2).idempotent("download", length: .long)
        #expect(operation.policy(at: .userInitiated).attemptTimeout == nil)
        #expect(operation.policy(at: .background).attemptTimeout == nil)
        try await withHarness(httpPolicy: .init(attemptTimeout: .seconds(1)), operation: operation) { h in
            let data = fileBytes(3_000)
            // Chunks a minute apart against a client attempt timeout of one second, and a caller's deadline of a day.
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 1_000, chunkDelay: .seconds(60))])
            let downloader = h.downloader
            let request = try download(data)
            let task = Task { () async throws -> DownloadResult in
                try await withTimeout(.seconds(86_400)) { () async throws -> DownloadResult in try await downloader.download(request) }
            }
            for _ in 0..<3 { await h.elapse(.seconds(60)) }
            let result = try await task.value
            #expect(result.bytes == 3_000)
            #expect(h.transport.requestCount == 1)
        }
    }

    @Test(.failureMode("design/23", "a download is admitted under its backend's capacity"))
    func aDownloadHoldsOneOfItsBackendsSlotsWhileItRuns() async throws {
        let operation = Backend.remote("downloads.operation.capacity", capacity: 1).idempotent("download", length: .long)
        try await withHarness(operation: operation) { h in
            let data = fileBytes(3_000)
            h.transport.on(Self.route, respond: [
                .serving(Resource(data, etag: "\"v1\""), chunkSize: 500, fault: .stall(after: 1_000, for: .seconds(3600))),
                .serving(Resource(data, etag: "\"v1\"")),
            ])
            let first = h.start(try download(data))
            await eventually("the first download never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
            let second = h.start(try download(data))
            // The second waits for the first's slot: nothing is asked of the server for it.
            try await Task.sleep(for: .milliseconds(100))
            #expect(h.transport.requestCount == 1)
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
            let result = try await second.value
            #expect(result.bytes == 3_000)
            #expect(h.transport.requestCount == 2)
        }
    }

    @Test(.failureMode("design/23", "a download waits for its slot past the caller's deadline"))
    func aCallerWhoCannotWaitForASlotIsToldItsDeadlinePassed() async throws {
        let operation = Backend.remote("downloads.operation.admission", capacity: 1).idempotent("download", length: .long)
        try await withHarness(operation: operation) { h in
            let data = fileBytes(3_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500, fault: .stall(after: 1_000, for: .seconds(3600)))])
            let first = h.start(try download(data))
            await eventually("the first download never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
            let downloader = h.downloader
            let request = try download(data)
            let second = Task { () async throws -> DownloadResult in
                try await withTimeout(.seconds(30)) { () async throws -> DownloadResult in try await downloader.download(request) }
            }
            await eventually("the second download never waited") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(30))) }
            await h.clock.advance(by: .seconds(30))
            guard case DownloadError.deadlineExceeded? = await failure(of: second) else {
                Issue.record("expected the deadline")
                return
            }
            #expect(h.transport.requestCount == 1)
            first.cancel()
            _ = await failure(of: first)
        }
    }

    @Test(.failureMode("design/23", "a download that nobody gave a deadline runs under the operation's default"))
    func theOperationsDefaultDeadlineBoundsADownloadThatHasNoOtherAndKeepsThePartialFile() async throws {
        let operation = Backend.remote("downloads.operation.default", capacity: 2).idempotent("download", length: .long)
        // design/22: a remote operation's total for someone waiting for seconds is 30 s, tripled for .long.
        #expect(operation.policy(at: .userInitiated).deadline == .seconds(90))
        try await withHarness(operation: operation) { h in
            let data = fileBytes(5_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500, fault: .stall(after: 2_000, for: .seconds(3600)))])
            let downloader = h.downloader
            let request = try download(data)
            let task = Task { () async throws -> DownloadResult in
                try await withUrgency(.userInitiated) { try await downloader.download(request) }
            }
            await eventually("the body never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
            await h.clock.advance(by: .seconds(90))
            guard case DownloadError.deadlineExceeded? = await failure(of: task) else {
                Issue.record("expected the default deadline")
                return
            }
            #expect(h.contents(partialPath)?.count == 2_000, "what arrived is kept for the next run")
        }
    }

    @Test(.failureMode("design/23", "a download is cancelled inside its operation"))
    func aCancelledDownloadInsideItsOperationIsCancellationNotAFailure() async throws {
        let operation = Backend.remote("downloads.operation.cancel", capacity: 2).idempotent("download", length: .long)
        try await withHarness(operation: operation) { h in
            let data = fileBytes(5_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500, fault: .stall(after: 2_000, for: .seconds(3600)))])
            let task = h.start(try download(data))
            await eventually("the body never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(h.events.count("download.failed") == 0)
            #expect(h.contents(partialPath)?.count == 2_000)
        }
    }

    @Test(.failureMode("design/23", "a download fails inside its operation"))
    func aFailureIsTheDownloadersAndTheOperationDoesNotRepeatIt() async throws {
        let operation = Backend.remote("downloads.operation.fail", capacity: 2).idempotent("download", length: .long)
        try await withHarness(operation: operation) { h in
            h.transport.on(Self.route, respond: [.status(404)])
            let task = h.start(try download(fileBytes(1_000)))
            guard case DownloadError.http(let error)? = await failure(of: task) else {
                Issue.record("expected the 404")
                return
            }
            #expect(error.statusCode == 404)
            #expect(h.transport.requestCount == 1, "a 404 is not repeated by either layer")
        }
    }

    @Test func aBundleRunsAsOneAttemptOfTheOperationToo() async throws {
        let operation = Backend.remote("downloads.operation.bundle", capacity: 1).idempotent("download", length: .long)
        let temp = try TempDirectory()
        try await withDiskHarness(operation: operation) { h in
            let model = BundleTests.Model()
            model.serve(h.transport)
            let result = try await h.downloader.download(try model.bundle(to: temp.file("model")))
            #expect(result.files.count == 3, "three files, one slot of a backend of one: they are one operation")
        }
    }
}
#endif

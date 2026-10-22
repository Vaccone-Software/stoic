#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Testing

/// Failure-mode rows of design/23 about one file: what arrives, what is
/// resumed, what is retried and what ends a download. On a scripted server, a
/// simulated disk and a virtual clock: nothing here sleeps in real time.
@Suite("Downloads", .timeLimit(.minutes(1)))
struct DownloadTests {
    static let route = HTTPRequest.get("/model.bin")

    // MARK: Whole

    @Test(.failureMode("design/23", "a file is downloaded whole"))
    func aFileIsDownloadedVerifiedAndPlaced() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 1_500)])
            let result = try await h.downloader.download(try download(data))
            #expect(result.path == modelPath)
            #expect(result.bytes == 10_000)
            #expect(result.requests == 1)
            #expect(result.resumedFrom == 0)
            #expect(result.isDurable)
            #expect(result.verifiedDigest?.hex == sha256Hex(data))
            #expect(h.contents(modelPath) == data)
            #expect(h.contents(partialPath) == nil)
            #expect(h.contents(recordPath) == nil)
            #expect(try h.disk.permissions(of: modelPath) == 0o600, "private unless the download says otherwise")
            #expect(h.transport.requests.count == 1)
            #expect(h.transport.requests[0].headers["Range"] == nil)
            #expect(h.events.count("download.started") == 1)
            #expect(h.events.count("download.verified") == 1)
            #expect(h.events.count("download.placed") == 1)
            #expect(h.events.count("download.failed") == 0)
        }
    }

    @Test func theFinishedFileHasTheRequestedMode() async throws {
        try await withHarness { h in
            let data = fileBytes(2_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""))])
            _ = try await h.downloader.download(try download(data, mode: 0o644))
            #expect(try h.disk.permissions(of: modelPath) == 0o644)
        }
    }

    @Test func aFileWithNoDigestIsPlacedWithItsSizeChecked() async throws {
        try await withHarness { h in
            let data = fileBytes(3_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data))])
            let result = try await h.downloader.download(try download(data, digest: false))
            #expect(result.verifiedDigest == nil)
            #expect(h.contents(modelPath) == data)
            #expect(h.events.count("download.verified") == 0)
        }
    }

    @Test func aGitBlobDigestHashesTheSizeFirst() async throws {
        try await withHarness { h in
            let data = fileBytes(5_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 700)])
            let request = Download(Self.route, to: modelPath, expectedSize: data.count, digest: try .gitBlobSHA1(gitBlobHex(data)))
            _ = try await h.downloader.download(request)
            #expect(h.contents(modelPath) == data)
        }
    }

    @Test func anExistingFileIsReplacedAtomically() async throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/models")
        let file = try disk.open(modelPath, mode: .createExclusive)
        try disk.write(file, Array("old".utf8), at: 0)
        try disk.fullSync(file)
        try disk.close(file)
        try disk.syncDirectory("/models")
        try await withHarness(disk: disk) { h in
            let data = fileBytes(2_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""))])
            _ = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
        }
    }

    // MARK: Cuts

    @Test(
        .failureMode("design/23", "the connection is cut part-way"),
        arguments: [1, 499, 500, 1_999, 2_000, 2_001, 5_000, 9_999]
    )
    func aCutIsResumedFromTheByteItHappenedAt(cut: Int) async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"")
            h.transport.on(Self.route, respond: [.serving(server, chunkSize: 700, fault: .cut(after: cut)), .serving(server, chunkSize: 700)])
            let task = h.start(try download(data))
            await h.waitOutBackoff(.seconds(10))
            let result = try await task.value
            #expect(h.contents(modelPath) == data)
            #expect(result.requests == 2)
            let second = h.transport.requests[1]
            #expect(second.headers["Range"] == "bytes=\(cut)-")
            #expect(second.headers["If-Range"] == "\"v1\"", "the validator the server gave goes back with the range")
            let retries = h.events.events(named: "download.retry")
            #expect(retries.count == 1)
            #expect(retries.first?.text("reason") == "transport_-1005")
            #expect(retries.first?.duration("delay") == .seconds(10))
            #expect(retries.first?.number("bytes") == cut)
            #expect(h.events.count("download.restarted") == 0)
        }
    }

    @Test func aCutAfterTheLastByteIsComplete() async throws {
        try await withHarness { h in
            let data = fileBytes(4_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), fault: .cut(after: 4_000))])
            let result = try await h.downloader.download(try download(data))
            #expect(result.requests == 1, "nothing is left to ask for")
            #expect(h.contents(modelPath) == data)
            #expect(h.clock.sleeperCount == 0)
        }
    }

    @Test func severalCutsAreResumedOneAfterAnother() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"")
            h.transport.on(Self.route, respond: [
                .serving(server, fault: .cut(after: 1_000)), .serving(server, fault: .cut(after: 2_500)),
                .serving(server, fault: .fail(after: 300, .timedOut)), .serving(server),
            ])
            let task = h.start(try download(data))
            for _ in 0..<3 { await h.waitOutBackoff(.seconds(10)) }
            _ = try await task.value
            #expect(h.contents(modelPath) == data)
            #expect(h.transport.requests.map { $0.headers["Range"] } == [nil, "bytes=1000-", "bytes=3500-", "bytes=3800-"])
        }
    }

    @Test(.failureMode("design/23", "a body ends short without an error"))
    func aShortBodyIsACutLikeAnyOther() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            // It promises 10,000 bytes, sends 6,000 and ends the body as if it were done.
            h.transport.on(Self.route, respond: [
                .streaming(Array(data[..<6_000]), headers: ["Content-Length": "10000"]),
                .serving(Resource(data)),
            ])
            let task = h.start(try download(data, expectedSize: false))
            await h.waitOutBackoff(.seconds(10))
            _ = try await task.value
            #expect(h.contents(modelPath) == data)
            #expect(h.events.events(named: "download.retry").first?.text("reason") == "short_body")
            #expect(h.transport.requests[1].headers["Range"] == "bytes=6000-")
        }
    }

    @Test(.failureMode("design/23", "a 200's body is longer than its Content-Length"))
    func aBodyLongerThanItsContentLengthIsNotPlaced() async throws {
        try await withHarness { h in
            // Five bytes on the wire, four declared, and a limit well above both.
            // The fifth shares no chunk with a byte the declaration allows.
            let body: [UInt8] = [1, 2, 3, 4, 5]
            h.transport.on(Self.route, respond: [.streaming(body, headers: ["Content-Length": "4"], chunkSize: 4)])
            let task = h.start(try download(body, digest: false, expectedSize: false, byteLimit: 1_000))
            let error = await failure(of: task)
            guard case DownloadError.badResponse(let status, _)? = error else {
                Issue.record("expected a body longer than declared, got \(String(describing: error))")
                return
            }
            #expect(status == 200)
            #expect(h.contents(modelPath) == nil, "a download never places more bytes than the server declared")
            #expect(h.contents(partialPath) == [1, 2, 3, 4], "the byte past Content-Length is not kept")
            #expect(h.transport.requestCount == 1, "not retried")
            #expect(h.transport.abortedCount == 1, "the connection was cancelled")
            #expect(h.events.count("download.placed") == 0)
            #expect(h.events.events(named: "download.failed").first?.text("kind") == "bad_response")
        }
    }

    @Test(.failureMode("design/23", "a 206's body is longer than its Content-Range"))
    func aPartialBodyLongerThanItsRangeIsNotWrittenPastIt() async throws {
        try await withHarness(policy: .testing(schedule: Schedule.immediate)) { h in
            let data = fileBytes(1_000)
            // The range is bytes 100-199 (100 bytes). The body is 150: the range,
            // then 50 bytes that are not the file. Content-Length names the 150,
            // which is what a transport delivers.
            var body = Array(data[100..<200])
            body.append(contentsOf: [UInt8](repeating: 0xA5, count: 50))
            h.transport.on(Self.route, respond: [
                .streaming(Array(data[..<100]), headers: ["Content-Length": "1000", "ETag": "\"v1\""], chunkSize: 50),
                .streaming(
                    body, status: 206,
                    headers: ["Content-Range": "bytes 100-199/1000", "Content-Length": "150", "ETag": "\"v1\""],
                    chunkSize: 40),
                .serving(Resource(data, etag: "\"v1\"")),
            ])
            // No delay between attempts: a body that was accepted past its range
            // would resume at once and place the splice, instead of waiting out a backoff.
            let task = h.start(try download(data, digest: false, expectedSize: false))
            let error = await failure(of: task)
            guard case DownloadError.badResponse(let status, _)? = error else {
                Issue.record("expected a range longer than declared, got \(String(describing: error))")
                return
            }
            #expect(status == 206)
            #expect(h.contents(modelPath) == nil, "the spliced file is not placed")
            guard let partial = h.contents(partialPath) else {
                Issue.record("the bytes inside the range were not kept")
                return
            }
            #expect(partial.count <= 200, "a 206 never writes past its range")
            #expect(partial.count >= 100)
            #expect(partial == Array(data[..<partial.count]))
            #expect(h.transport.requestCount == 2, "does not resume from past the range")
            #expect(h.transport.requests[1].headers["Range"] == "bytes=100-")
            #expect(h.events.count("download.placed") == 0)
            #expect(h.events.count("download.retry") == 1, "only the short first body is resumed")
        }
    }

    // MARK: A server that does not keep to its word

    @Test(.failureMode("design/23", "the server ignores Range and answers 200"))
    func aServerThatIgnoresRangeStartsTheFileOver() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, honoursRange: false)
            h.transport.on(Self.route, respond: [.serving(server, fault: .cut(after: 4_000)), .serving(server)])
            let task = h.start(try download(data))
            await h.waitOutBackoff(.seconds(10))
            _ = try await task.value
            #expect(h.contents(modelPath) == data, "not the first 4,000 bytes twice")
            #expect(h.transport.requests[1].headers["Range"] == "bytes=4000-")
            #expect(h.events.restartReasons == ["range_ignored"])
        }
    }

    @Test(.failureMode("design/23", "the server's file changed since the partial file was begun"))
    func aChangedValidatorStartsTheFileOver() async throws {
        try await withHarness { h in
            let before = fileBytes(10_000, seed: 1)
            let after = fileBytes(10_000, seed: 2)
            h.transport.on(Self.route, respond: [
                .serving(Resource(before, etag: "\"v1\""), fault: .cut(after: 4_000)),
                .serving(Resource(after, etag: "\"v2\"")),
            ])
            let task = h.start(try download(after))
            await h.waitOutBackoff(.seconds(10))
            _ = try await task.value
            #expect(h.contents(modelPath) == after)
            #expect(h.transport.requests[1].headers["If-Range"] == "\"v1\"")
            #expect(h.events.restartReasons == ["validator_changed"])
        }
    }

    @Test func aPartialAnswerForAnotherRangeStartsTheFileOver() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            // A server that answers a range with another one (it ignored the offset).
            h.transport.on(Self.route, respond: [
                .serving(Resource(data, etag: "\"v1\""), fault: .cut(after: 4_000)),
                .streaming(Array(data[2_000...]), status: 206, headers: ["Content-Range": "bytes 2000-9999/10000", "ETag": "\"v1\""]),
                .serving(Resource(data, etag: "\"v1\"")),
            ])
            let task = h.start(try download(data))
            await h.waitOutBackoff(.seconds(10))
            _ = try await task.value
            #expect(h.contents(modelPath) == data)
            #expect(h.events.restartReasons == ["range_mismatch"])
        }
    }

    @Test(.failureMode("design/23", "the server answers 416 and the partial file is the whole file"))
    func a416ForARangeAtTheEndMeansTheFileIsWhole() async throws {
        try await withHarness { h in
            let data = fileBytes(6_000)
            // Without an expected size, a cut after the last byte cannot be told from a cut anywhere else.
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), fault: .cut(after: 6_000)), .serving(Resource(data, etag: "\"v1\""))])
            let task = h.start(try download(data, expectedSize: false))
            await h.waitOutBackoff(.seconds(10))
            let result = try await task.value
            #expect(h.transport.requests[1].headers["Range"] == "bytes=6000-")
            #expect(result.requests == 2)
            #expect(h.contents(modelPath) == data)
            #expect(h.events.count("download.restarted") == 0, "nothing was thrown away")
        }
    }

    @Test(.failureMode("design/23", "the server answers 416 and the partial file is not the whole file"))
    func a416ForARangePastTheEndStartsTheFileOver() async throws {
        try await withHarness { h in
            let before = fileBytes(10_000, seed: 1)
            let after = fileBytes(5_000, seed: 2)
            // No validator: the server cannot be asked if the file changed, so it says the range is wrong.
            h.transport.on(Self.route, respond: [
                .serving(Resource(before), fault: .cut(after: 8_000)), .serving(Resource(after)),
            ])
            let task = h.start(try download(after, expectedSize: false))
            await h.waitOutBackoff(.seconds(10))
            _ = try await task.value
            #expect(h.contents(modelPath) == after)
            #expect(h.events.restartReasons == ["range_not_satisfiable"])
            #expect(h.transport.requests.map { $0.headers["Range"] } == [nil, "bytes=8000-", nil])
        }
    }

    @Test(.failureMode("design/23", "the server's file is not the size the download was pinned to"))
    func aFileOfAnotherSizeIsRefusedBeforeItIsFetched() async throws {
        try await withHarness { h in
            let data = fileBytes(8_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data))])
            let task = h.start(try download(fileBytes(10_000), digest: false))
            let error = await failure(of: task)
            guard case DownloadError.sizeMismatch(let expected, let reported)? = error else {
                Issue.record("expected a size mismatch, got \(String(describing: error))")
                return
            }
            #expect(expected == 10_000)
            #expect(reported == 8_000)
            #expect(h.contents(partialPath) == nil)
            #expect(h.contents(modelPath) == nil)
        }
    }

    // MARK: Digests

    @Test(.failureMode("design/23", "the digest does not match"))
    func aMismatchIsFetchedAgainFromZeroOnceThenFails() async throws {
        try await withHarness { h in
            let good = fileBytes(5_000, seed: 1)
            let bad = fileBytes(5_000, seed: 2)
            h.transport.on(Self.route, respond: [.serving(Resource(bad))])
            let task = h.start(try download(good))
            let error = await failure(of: task)
            guard case DownloadError.digestMismatch(let expected, let actual, let attempts)? = error else {
                Issue.record("expected a digest mismatch, got \(String(describing: error))")
                return
            }
            #expect(expected.hex == sha256Hex(good))
            #expect(actual == sha256Hex(bad))
            #expect(attempts == 2)
            #expect(h.transport.requestCount == 2, "once more, from zero")
            #expect(h.transport.requests.allSatisfy { $0.headers["Range"] == nil })
            #expect(h.contents(partialPath) == nil, "a mismatch deletes the partial file")
            #expect(h.contents(recordPath) == nil)
            #expect(h.contents(modelPath) == nil, "never a placed file with the wrong digest")
            #expect(h.events.count("download.verification_failed") == 2)
            #expect(h.events.restartReasons == ["verification_failed"])
        }
    }

    @Test func aMismatchThatTheSecondFetchFixesSucceeds() async throws {
        try await withHarness { h in
            let good = fileBytes(5_000, seed: 1)
            h.transport.on(Self.route, respond: [.serving(Resource(fileBytes(5_000, seed: 2))), .serving(Resource(good))])
            let result = try await h.downloader.download(try download(good))
            #expect(result.requests == 2)
            #expect(h.contents(modelPath) == good)
        }
    }

    @Test func oneVerificationAttemptMeansNoSecondFetch() async throws {
        try await withHarness(policy: .testing(verificationAttempts: 1)) { h in
            h.transport.on(Self.route, respond: [.serving(Resource(fileBytes(5_000, seed: 2)))])
            let task = h.start(try download(fileBytes(5_000, seed: 1)))
            guard case DownloadError.digestMismatch(_, _, let attempts)? = await failure(of: task) else {
                Issue.record("expected a digest mismatch")
                return
            }
            #expect(attempts == 1)
            #expect(h.transport.requestCount == 1)
            #expect(h.events.count("download.restarted") == 0)
        }
    }

    // MARK: The limit

    @Test(.failureMode("design/23", "the body is longer than the byte limit"))
    func aBodyPastTheLimitEndsTheDownloadAndDeletesWhatArrived() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            // Promised at the limit, and longer on the wire. A declared length
            // shorter than the limit is a different failure (the body is not
            // the length the server named); this one is the limit itself.
            h.transport.on(Self.route, respond: [.streaming(data, headers: ["Content-Length": "5000"], chunkSize: 400)])
            let task = h.start(try download(data, digest: false, expectedSize: false, byteLimit: 5_000))
            guard case DownloadError.byteLimitExceeded(let limit)? = await failure(of: task) else {
                Issue.record("expected the byte limit")
                return
            }
            #expect(limit == 5_000)
            #expect(h.contents(partialPath) == nil)
            #expect(h.contents(recordPath) == nil)
            #expect(h.transport.requestCount == 1, "not retried")
            #expect(h.transport.abortedCount == 1, "the connection was cancelled")
        }
    }

    @Test func aDeclaredLengthOverTheLimitFailsBeforeAByteIsRead() async throws {
        try await withHarness { h in
            h.transport.on(Self.route, respond: [.serving(Resource(fileBytes(10_000)))])
            let task = h.start(try download(fileBytes(10_000), digest: false, expectedSize: false, byteLimit: 5_000))
            guard case DownloadError.byteLimitExceeded(5_000)? = await failure(of: task) else {
                Issue.record("expected the byte limit")
                return
            }
            #expect(h.contents(partialPath) == nil)
        }
    }

    // MARK: Statuses and the schedule

    @Test(.failureMode("design/23", "the server answers 404"))
    func a404EndsTheDownloadAtOnce() async throws {
        try await withHarness { h in
            h.transport.on(Self.route, respond: [.status(404, body: "no such model")])
            let task = h.start(try download(fileBytes(1_000)))
            guard case DownloadError.http(let error)? = await failure(of: task) else {
                Issue.record("expected an HTTP error")
                return
            }
            #expect(error.statusCode == 404)
            #expect(h.transport.requestCount == 1)
            #expect(h.clock.sleeperCount == 0, "nothing was waited for")
            #expect(h.events.count("download.retry") == 0)
            #expect(h.events.count("download.failed") == 1)
            #expect(h.contents(modelPath) == nil)
        }
    }

    @Test(.failureMode("design/23", "an error response has a body larger than the byte limit"))
    func anErrorBodyLargerThanTheLimitIsStillTheStatus() async throws {
        try await withHarness { h in
            // A small file pinned at 100 bytes, and a 404 page of 50,000 (declared and delivered):
            // the limit is for the file, not for what answers in its place.
            h.transport.on(Self.route, respond: [.streaming(fileBytes(50_000), status: 404)])
            let task = h.start(try download(fileBytes(100)))
            guard case DownloadError.http(let error)? = await failure(of: task) else {
                Issue.record("expected the status, not the byte limit")
                return
            }
            #expect(error.statusCode == 404)
            #expect(h.transport.requestCount == 1)
            #expect(h.events.count("download.retry") == 0)
            #expect(h.contents(partialPath) == nil)
        }
    }

    @Test(arguments: [401, 403, 410])
    func otherClientErrorsAreFinalToo(status: Int) async throws {
        try await withHarness { h in
            h.transport.on(Self.route, respond: [.status(status)])
            let task = h.start(try download(fileBytes(1_000)))
            guard case DownloadError.http(let error)? = await failure(of: task) else {
                Issue.record("expected an HTTP error")
                return
            }
            #expect(error.statusCode == status)
            #expect(h.transport.requestCount == 1)
        }
    }

    @Test(.failureMode("design/23", "the server answers 429 or 503"))
    func aBusyServerIsAskedAgainOnTheSchedule() async throws {
        try await withHarness { h in
            let data = fileBytes(3_000)
            h.transport.on(Self.route, respond: [
                .status(503), .status(429, headers: ["Retry-After": "30"]), .serving(Resource(data)),
            ])
            let task = h.start(try download(data))
            await h.waitOutBackoff(.seconds(10))
            await h.waitOutBackoff(.seconds(30))
            _ = try await task.value
            #expect(h.contents(modelPath) == data)
            let retries = h.events.events(named: "download.retry")
            #expect(retries.map { $0.duration("delay") } == [.seconds(10), .seconds(30)], "the server's Retry-After, when it asks for more than the schedule")
            #expect(retries.map { $0.text("reason") } == ["status_503", "status_429"])
            #expect(h.transport.requestCount == 3, "the client's own retry is off: the downloader is the retry layer")
        }
    }

    @Test(.failureMode("design/23", "bytes arrive between failures"))
    func theScheduleStartsOverWheneverBytesArrive() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"")
            // Two failures with nothing received escalate: 10 s, 20 s. A cut that
            // delivered bytes starts over: 10 s. The failure after it has nothing again: 20 s.
            h.transport.on(Self.route, respond: [
                .status(503), .status(503), .serving(server, fault: .cut(after: 500)), .status(503), .serving(server),
            ])
            let task = h.start(try download(data))
            for delay in [10, 20, 10, 20] { await h.waitOutBackoff(.seconds(delay)) }
            _ = try await task.value
            #expect(h.contents(modelPath) == data)
            #expect(h.events.events(named: "download.retry").map { $0.duration("delay") } == [.seconds(10), .seconds(20), .seconds(10), .seconds(20)])
        }
    }

    @Test func aFailureWithNoBytesBacksOffUpToTheCap() async throws {
        try await withHarness { h in
            let data = fileBytes(1_000)
            h.transport.on(Self.route, respond: [.status(503), .status(503), .status(503), .status(503), .status(503), .status(503), .status(503), .serving(Resource(data))])
            let task = h.start(try download(data))
            for delay in [10, 20, 40, 80, 160, 300, 300] { await h.waitOutBackoff(.seconds(delay)) }
            _ = try await task.value
            #expect(h.events.events(named: "download.retry").map { $0.duration("delay") }.map { $0 ?? .zero } == [10, 20, 40, 80, 160, 300, 300].map { Duration.seconds($0) })
        }
    }

    @Test func theDefaultScheduleIsEqualJitterBetweenHalfAndWholeOfTheStep() async throws {
        try await withHarness(policy: DownloadPolicy(checkpointBytes: 2_000, writeBufferBytes: 500)) { h in
            let data = fileBytes(1_000)
            h.transport.on(Self.route, respond: [.status(503), .status(503), .serving(Resource(data))])
            let task = h.start(try download(data))
            let first = await h.waitOutNextBackoff(after: 0)
            let second = await h.waitOutNextBackoff(after: 1)
            _ = try await task.value
            #expect(first >= .seconds(5) && first <= .seconds(10))
            #expect(second >= .seconds(10) && second <= .seconds(20))
        }
    }

    @Test(.failureMode("design/23", "the schedule has a bound and it is spent"))
    func aBoundedScheduleEndsWithTheLastFailure() async throws {
        let schedule = Schedule.fixed(.seconds(10)).attempts(3).schedule
        try await withHarness(policy: .testing(schedule: schedule)) { h in
            h.transport.on(Self.route, respond: [.status(503)])
            let task = h.start(try download(fileBytes(1_000)))
            await h.waitOutBackoff(.seconds(10))
            await h.waitOutBackoff(.seconds(10))
            guard case DownloadError.retriesExhausted(let attempts, let last)? = await failure(of: task) else {
                Issue.record("expected the schedule to run out")
                return
            }
            #expect(attempts == 3)
            #expect(last.statusCode == 503)
            #expect(h.transport.requestCount == 3)
        }
    }

    @Test func aLostConnectionBeforeTheHeadIsRetriedToo() async throws {
        try await withHarness { h in
            let data = fileBytes(1_000)
            h.transport.on(Self.route, respond: [.failure(.notConnectedToInternet), .failure(.cannotConnectToHost), .serving(Resource(data))])
            let task = h.start(try download(data))
            await h.waitOutBackoff(.seconds(10))
            await h.waitOutBackoff(.seconds(20))
            _ = try await task.value
            #expect(h.events.events(named: "download.retry").map { $0.text("reason") } == ["transport_-1009", "transport_-1004"])
        }
    }

    // MARK: Cancellation and deadlines

    @Test(.failureMode("design/23", "the download is cancelled"))
    func aCancelledDownloadKeepsItsPartialFileAndIsNotAFailure() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"")
            h.transport.on(Self.route, respond: [.serving(server, chunkSize: 500, fault: .stall(after: 4_000, for: .seconds(3600))), .serving(server)])
            let task = h.start(try download(data))
            await eventually("the body never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(h.events.count("download.cancelled") == 1)
            #expect(h.events.count("download.failed") == 0, "cancelling is not failing")
            #expect(h.contents(partialPath)?.count == 4_000, "what arrived is kept")
            #expect(h.contents(partialPath) == Array(data[..<4_000]))
            #expect(h.contents(modelPath) == nil)

            // The next run resumes from it.
            let result = try await h.downloader.download(try download(data))
            #expect(result.resumedFrom == 4_000)
            #expect(h.transport.requests.last?.headers["Range"] == "bytes=4000-")
            #expect(h.contents(modelPath) == data)
            #expect(h.events.count("download.resumed") == 1)
        }
    }

    @Test(.failureMode("design/23", "a cancelled download is told not to keep its partial file"))
    func aCancelledDownloadThatKeepsNothingLeavesNothing() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500, fault: .stall(after: 4_000, for: .seconds(3600)))])
            let task = h.start(try download(data, keepsPartialOnCancel: false))
            await eventually("the body never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(h.contents(partialPath) == nil)
            #expect(h.contents(recordPath) == nil)
            #expect(h.events.events(named: "download.cancelled").first?.flag("kept") == false)
        }
    }

    @Test func aDownloadCancelledWhileBackingOffStopsAtOnce() async throws {
        try await withHarness { h in
            h.transport.on(Self.route, respond: [.status(503)])
            let task = h.start(try download(fileBytes(1_000)))
            await h.clock.waitForSleepers(count: 1)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(h.transport.requestCount == 1)
        }
    }

    @Test(.failureMode("design/23", "the caller's deadline passes"))
    func aDeadlineThatPassesKeepsThePartialFileAndIsNotACancellation() async throws {
        try await withHarness { h in
            let data = fileBytes(10_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500, fault: .stall(after: 4_000, for: .seconds(3600)))])
            let downloader = h.downloader
            let request = try download(data, keepsPartialOnCancel: false)
            let task = Task { () async throws -> DownloadResult in
                try await withTimeout(.seconds(60)) { () async throws -> DownloadResult in try await downloader.download(request) }
            }
            await eventually("the body never stalled") { h.clock.pendingDeadlines.contains(h.clock.now.advanced(by: .seconds(3600))) }
            await h.clock.advance(by: .seconds(60))
            guard case DownloadError.deadlineExceeded? = await failure(of: task) else {
                Issue.record("expected the deadline")
                return
            }
            #expect(h.contents(partialPath)?.count == 4_000, "the time ran out; nobody cancelled, so the partial file stays whatever the option says")
        }
    }

    @Test(.failureMode("design/23", "a backoff would outlast the caller's deadline"))
    func aWaitThatWouldOutlastTheDeadlineIsNotStarted() async throws {
        try await withHarness { h in
            h.transport.on(Self.route, respond: [.status(503)])
            let downloader = h.downloader
            let request = try download(fileBytes(1_000))
            let task = Task { () async throws -> DownloadResult in
                try await withTimeout(.seconds(5)) { () async throws -> DownloadResult in try await downloader.download(request) }
            }
            guard case DownloadError.deadlineExceeded? = await failure(of: task) else {
                Issue.record("expected the deadline")
                return
            }
            #expect(h.transport.requestCount == 1)
            #expect(h.events.count("download.retry") == 0, "a wait that cannot end in time is not begun")
        }
    }

    // MARK: Space

    @Test(.failureMode("design/23", "the volume has too little free space"))
    func aDownloadTheVolumeCannotHoldIsRefusedBeforeItBegins() async throws {
        try await withHarness(disk: SimulatedFileSystem(capacity: 5_000)) { h in
            h.transport.on(Self.route, respond: [.serving(Resource(fileBytes(10_000)))])
            let task = h.start(try download(fileBytes(10_000)))
            guard case DownloadError.insufficientSpace(let required, let available)? = await failure(of: task) else {
                Issue.record("expected a space error")
                return
            }
            #expect(required == 11_000, "what is left to fetch, and the margin")
            #expect(available == 5_000)
            #expect(h.transport.requestCount == 0, "nothing was asked for")
        }
    }

    @Test func aDownloadsOwnRequirementOverridesTheDefault() async throws {
        try await withHarness(disk: SimulatedFileSystem(capacity: 100_000)) { h in
            h.transport.on(Self.route, respond: [.serving(Resource(fileBytes(10_000)))])
            let task = h.start(try download(fileBytes(10_000), requiredFreeBytes: 200_000))
            guard case DownloadError.insufficientSpace(200_000, _)? = await failure(of: task) else {
                Issue.record("expected a space error")
                return
            }
        }
    }

    @Test func whatIsAlreadyOnDiskCountsAsRoom() async throws {
        let disk = SimulatedFileSystem(capacity: 12_000)
        try await withHarness(disk: disk) { h in
            let data = fileBytes(10_000)
            let server = Resource(data, etag: "\"v1\"")
            h.transport.on(Self.route, respond: [.serving(server, fault: .cut(after: 9_000)), .status(403)])
            let first = h.start(try download(data))   // leaves 9,000 bytes behind
            await h.waitOutBackoff(.seconds(10))
            _ = await failure(of: first)
            h.transport.on(Self.route, respond: [.serving(server)])
            // 10,000 + 1,000 margin would not fit in what is free; the 1,000 left to fetch do.
            _ = try await h.downloader.download(try download(data))
            #expect(h.contents(modelPath) == data)
        }
    }

    @Test(.failureMode("design/23", "the disk fills part-way"))
    func aFullDiskStopsTheDownloadAndKeepsWhatWasWritten() async throws {
        try await withHarness(disk: SimulatedFileSystem(capacity: 6_000)) { h in
            let data = fileBytes(10_000)
            h.transport.on(Self.route, respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let task = h.start(try download(data, requiredFreeBytes: 0))
            guard case DownloadError.store(let error)? = await failure(of: task) else {
                Issue.record("expected a disk error")
                return
            }
            #expect(error.kind == .diskFull)
            #expect(h.transport.requestCount == 1, "a full disk is not waited out")
            #expect(h.contents(modelPath) == nil)
        }
    }

    // MARK: The operation of the call

    @Test func aDownloadWithAPathResolvesAgainstTheClientsBase() async throws {
        try await withHarness { h in
            let data = fileBytes(500)
            h.transport.on(Self.route, respond: [.serving(Resource(data))])
            _ = try await h.downloader.download(try download(data))
            #expect(h.transport.requests.first?.url?.absoluteString == "https://models.example.com/model.bin")
        }
    }

    @Test func aRequestsOwnRangeIsReplacedAndItsHeadersGoAlong() async throws {
        try await withHarness { h in
            let data = fileBytes(500)
            h.transport.on(Self.route, respond: [.serving(Resource(data))])
            let request = Download(
                HTTPRequest.get("/model.bin", headers: ["Range": "bytes=10-", "X-Token": "secret"]), to: modelPath,
                expectedSize: data.count, digest: try sha256(data))
            _ = try await h.downloader.download(request)
            #expect(h.transport.requests.first?.headers["Range"] == nil)
            #expect(h.transport.requests.first?.headers["X-Token"] == "secret")
            #expect(h.contents(modelPath) == data)
        }
    }

    @Test func eventsCarryNoQueryStringAndNoTokens() async throws {
        try await withHarness { h in
            let data = fileBytes(500)
            h.transport.on(.get("/model.bin", query: [URLQueryItem(name: "token", value: "hunter2")]), respond: [.serving(Resource(data))])
            let request = Download(
                HTTPRequest.get("/model.bin", query: [URLQueryItem(name: "token", value: "hunter2")], headers: ["Authorization": "Bearer hunter2"]),
                to: modelPath, expectedSize: data.count, digest: try sha256(data))
            _ = try await h.downloader.download(request)
            // The client's own events carry the query as a private field; the downloader's carry none.
            let text = h.events.events.filter { $0.name.rawValue.hasPrefix("download.") }.map(\.description).joined(separator: "\n")
            #expect(!text.isEmpty)
            #expect(!text.contains("hunter2"))
            #expect(!text.contains("token"))
            #expect(h.contents(recordPath) == nil)
        }
    }
}
#endif

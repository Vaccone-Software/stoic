import Foundation
import Stoic
@testable import StoicHTTP
import StoicTesting
import Testing

/// Failure-mode rows of design/19 about streamed responses: the client's
/// `stream` on a scripted transport and a virtual clock, and the scripted
/// transport's own streaming (the tests of the real one are in
/// `URLSessionStreamingTests`).
@Suite("HTTP streaming")
struct HTTPStreamingTests {
    typealias Step = ScriptedTransport.Step

    static func data(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }

    /// Everything a body delivers, and in how many chunks.
    static func read(_ body: HTTPBodyStream) async throws -> (bytes: [UInt8], chunks: Int) {
        var bytes: [UInt8] = []
        var chunks = 0
        for try await chunk in body {
            bytes.append(contentsOf: chunk)
            chunks += 1
        }
        return (bytes, chunks)
    }

    /// Waits until something sleeps for exactly `delay` from now (a chunk's
    /// delay, a stall), then moves the clock that far. Not "until anything
    /// sleeps": a deadline's timer sleeps too, and a count of sleepers cannot
    /// tell which sleeper it is waiting for.
    static func advanceWhenSleeping(_ delay: Duration, on clock: TestClock) async {
        let due = clock.now.advanced(by: delay)
        await eventually("nothing was asleep until \(due)") { clock.pendingDeadlines.contains(due) }
        await clock.advance(to: due)
    }

    /// The error a body ends with, after the bytes it delivered.
    static func failure(of body: HTTPBodyStream) async -> (delivered: Int, error: any Error)? {
        var delivered = 0
        do {
            for try await chunk in body { delivered += chunk.count }
            return nil
        } catch {
            return (delivered, error)
        }
    }

    // MARK: The body

    @Test(.failureMode("design/19", "a body too large to hold is streamed"))
    func aBodyArrivesInChunksInOrderAndIsNeverHeldWhole() async throws {
        try await withRig { rig in
            let data = Self.data(100_000)
            rig.transport.on(.get("/model"), respond: [.streaming(data, headers: ["X-Answer": "42"], chunkSize: 30_000)])
            let response = try await rig.api.stream(.get("/model"), maxBytes: 1_000_000)
            #expect(response.status == 200)
            #expect(response.headers["x-answer"] == "42")
            #expect(response.headers["Content-Length"] == "100000")
            #expect(rig.transport.inFlightCount == 1, "a body being read is a request in flight")
            let (bytes, chunks) = try await Self.read(response.body)
            #expect(bytes == data)
            #expect(chunks == 4)
            #expect(rig.transport.inFlightCount == 0)
            #expect(rig.transport.abortedCount == 0)
            #expect(rig.events.count("http.request") == 1)
        }
    }

    @Test func aBodyLargerThanThePoliciesResponseLimitStreamsUnderItsOwn() async throws {
        try await withRig(.testing(maxResponseBytes: 1_000)) { rig in
            rig.transport.on(.get("/big"), respond: [.oversized(5_000_000)])
            let response = try await rig.api.stream(.get("/big"), maxBytes: 10_000_000)
            var total = 0
            for try await chunk in response.body { total += chunk.count }
            #expect(total == 5_000_000)
        }
    }

    @Test func anEmptyBodyEndsAtOnce() async throws {
        try await withRig { rig in
            rig.transport.on(.get("/empty"), respond: [.streaming([])])
            let response = try await rig.api.stream(.get("/empty"), maxBytes: 10)
            let (bytes, chunks) = try await Self.read(response.body)
            #expect(bytes.isEmpty)
            #expect(chunks == 0)
        }
    }

    // MARK: Before the head

    @Test(.failureMode("design/19", "a streamed request gets 503 before its head"))
    func aRequestThatFailsBeforeItsHeadIsRetriedAsSendRetries() async throws {
        try await withRig { rig in
            let data = Self.data(1_000)
            rig.transport.on(.get("/m"), respond: [.status(503), .status(503), .streaming(data)])
            let api = rig.api
            let task = Task { try await api.stream(.get("/m"), maxBytes: 10_000) }
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            let response = try await task.value
            #expect(try await Self.read(response.body).bytes == data, "the body is that of the answer that was good")
            #expect(rig.transport.requestCount == 3)
            #expect(rig.events.events(named: "http.retry").map { $0.text("reason") } == ["status_503", "status_503"])
        }
    }

    @Test(.failureMode("design/19", "a streamed request is answered with a failure status"))
    func aFailureStatusIsAnErrorWithAnExcerptAndItsBodyIsAbandoned() async throws {
        try await withRig(.testing(attempts: 1)) { rig in
            let body = [UInt8](repeating: UInt8(ascii: "x"), count: 100_000)
            rig.transport.on(.get("/gone"), respond: [.streaming(body, status: 404, chunkSize: 200)])
            await #expect(throws: HTTPError.status(404, excerpt: String(repeating: "x", count: 512), retryAfter: nil, attempts: 1)) {
                try await rig.api.stream(.get("/gone"), maxBytes: 1_000_000)
            }
            #expect(rig.transport.abortedCount == 1, "the rest of the body was never read")
            #expect(rig.transport.inFlightCount == 0)
        }
    }

    @Test(.failureMode("design/19", "a call accepts a status outside 2xx, such as 416"))
    func anAcceptedStatusIsAResponseWithItsHeaders() async throws {
        try await withRig { rig in
            let resource = ScriptedTransport.Resource(Self.data(500), etag: "\"v1\"")
            rig.transport.on(.get("/file"), respond: [.serving(resource)])
            let past = HTTPRequest.get("/file", headers: ["Range": "bytes=500-"])
            let response = try await rig.api.stream(past, maxBytes: 1_000, accepting: [416])
            #expect(response.status == 416)
            #expect(response.headers["Content-Range"] == "bytes */500")
            #expect(try await Self.read(response.body).bytes.isEmpty)

            // The same status, not accepted, is an error like any other.
            await #expect(throws: HTTPError.status(416, excerpt: "", retryAfter: nil, attempts: 1)) {
                try await rig.api.stream(past, maxBytes: 1_000)
            }
        }
    }

    // MARK: The body

    @Test(.failureMode("design/19", "a streamed body fails after its head"))
    func aFailureAfterTheHeadIsThrownByTheBodyAndNothingIsRetried() async throws {
        try await withRig { rig in
            rig.transport.on(.get("/m"), respond: [.streaming(Self.data(10_000), chunkSize: 1_000, fault: .cut(after: 4_000))])
            let response = try await rig.api.stream(.get("/m"), maxBytes: 100_000)
            let (delivered, error) = try #require(await Self.failure(of: response.body))
            #expect(delivered == 4_000, "what arrived before the cut was delivered")
            #expect(error as? HTTPError == .transport(.networkConnectionLost, attempts: 1))
            #expect(rig.transport.requestCount == 1, "bytes already taken cannot be sent again, so no retry")
            #expect(rig.clock.sleeperCount == 0)
            #expect(rig.transport.abortedCount == 1)
            #expect(rig.transport.inFlightCount == 0)
            // After a failure the sequence has ended.
            #expect(try await Self.read(response.body).bytes.isEmpty)
        }
    }

    @Test(.failureMode("design/19", "a streamed body is longer than its limit"))
    func aBodyPastItsLimitIsAbandonedAndADeclaredLengthOverItFailsFirst() async throws {
        try await withRig(.testing(attempts: 1)) { rig in
            // The server promises 5,000 bytes and sends 8,000: only a count notices.
            rig.transport.on(.get("/liar"), respond: [.streaming(Self.data(8_000), headers: ["Content-Length": "5000"], chunkSize: 1_000)])
            let response = try await rig.api.stream(.get("/liar"), maxBytes: 5_000)
            let (delivered, error) = try #require(await Self.failure(of: response.body))
            #expect(delivered == 5_000)
            #expect(error as? HTTPError == .responseTooLarge(limit: 5_000, attempts: 1))
            #expect(rig.transport.abortedCount == 1)
            #expect(rig.events.count("http.response_too_large") == 1)

            rig.transport.on(.get("/honest"), respond: [.streaming(Self.data(8_000))])
            await #expect(throws: HTTPError.responseTooLarge(limit: 5_000, attempts: 1)) {
                try await rig.api.stream(.get("/honest"), maxBytes: 5_000)
            }
            #expect(rig.transport.abortedCount == 2, "refused before the first byte")
        }
    }

    @Test(.failureMode("design/19", "a streamed body outlasts the attempt timeout"))
    func theAttemptTimeoutBoundsTheHeadAndNotTheBody() async throws {
        try await withRig(.testing(timeout: .seconds(10))) { rig in
            // Five chunks, thirty seconds apart: a hundred and fifty seconds against a ten-second attempt timeout.
            let data = Self.data(5_000)
            rig.transport.on(.get("/slow"), respond: [.streaming(data, chunkSize: 1_000, chunkDelay: .seconds(30))])
            let api = rig.api
            let reading = Task { () async throws -> [UInt8] in
                let response = try await api.stream(.get("/slow"), maxBytes: 100_000)
                return try await Self.read(response.body).bytes
            }
            for _ in 0..<5 { await Self.advanceWhenSleeping(.seconds(30), on: rig.clock) }
            let delivered = try await reading.value
            #expect(delivered == data)
            #expect(rig.transport.requestCount == 1)
            #expect(rig.events.count("http.retry") == 0)
            #expect(rig.clock.now.offset == .seconds(150))
        }
    }

    @Test func aServerThatNeverAnswersIsCutAtTheAttemptTimeout() async throws {
        try await withRig(.testing(attempts: 1, timeout: .seconds(10))) { rig in
            rig.transport.on(.get("/mute"), respond: [.hang])
            let api = rig.api
            let mute = Task { try await api.stream(.get("/mute"), maxBytes: 100) }
            await rig.waitForHangingAttempt()
            await rig.clock.advance(by: .seconds(10))
            await #expect(throws: HTTPError.timedOut(attempt: 1)) { try await mute.value }
            #expect(rig.transport.abortedCount == 1)
        }
    }

    @Test(.failureMode("design/19", "the caller's deadline passes while a body is read"))
    func aDeadlineThatPassesMidBodyEndsTheReadWithADeadlineRejection() async throws {
        try await withRig { rig in
            rig.transport.on(.get("/m"), respond: [.streaming(Self.data(10_000), chunkSize: 1_000, fault: .stall(after: 3_000, for: .seconds(3600)))])
            let api = rig.api
            let reading = Task { () async throws -> Int in
                try await withTimeout(.seconds(60)) { () async throws -> Int in
                    let response = try await api.stream(.get("/m"), maxBytes: 100_000)
                    var delivered = 0
                    for try await chunk in response.body { delivered += chunk.count }
                    return delivered
                }
            }
            // The stall is a sleep on the clock, as is the deadline's timer.
            await eventually("the body never stalled") { rig.clock.pendingDeadlines.contains(rig.clock.now.advanced(by: .seconds(3600))) }
            await rig.clock.advance(by: .seconds(60))
            do {
                _ = try await reading.value
                Issue.record("the read finished")
            } catch let error as HTTPError {
                #expect(error.rejection?.reason == .deadlineExceeded)
            } catch {
                Issue.record("expected a deadline rejection, got \(error)")
            }
            #expect(rig.transport.abortedCount == 1)
            #expect(rig.transport.inFlightCount == 0)
        }
    }

    @Test(.failureMode("design/19", "the caller is cancelled while a body is read"))
    func cancellingTheReaderCancelsTheTransferAndThrowsCancellation() async throws {
        try await withRig { rig in
            rig.transport.on(.get("/m"), respond: [.streaming(Self.data(10_000), chunkSize: 1_000, fault: .hang(after: 2_000))])
            let api = rig.api
            let reading = Task { () async throws -> Int in
                let response = try await api.stream(.get("/m"), maxBytes: 100_000)
                var delivered = 0
                for try await chunk in response.body { delivered += chunk.count }
                return delivered
            }
            await eventually("the body never began to hang") { rig.transport.inFlightCount == 1 && rig.transport.requests.count == 1 }
            try await Task.sleep(for: .milliseconds(20))   // real time: the hang waits on no clock
            reading.cancel()
            await #expect(throws: CancellationError.self) { try await reading.value }
            await eventually("the transfer was not cancelled") { rig.transport.abortedCount == 1 }
            #expect(rig.transport.inFlightCount == 0)
        }
    }

    @Test(.failureMode("design/19", "a streamed response is abandoned unread"))
    func aBodyThatIsDroppedOrCancelledReleasesItsConnection() async throws {
        try await withRig { rig in
            rig.transport.on(.get("/m"), respond: [.streaming(Self.data(10_000), chunkSize: 1_000)])
            var response: HTTPStreamedResponse? = try await rig.api.stream(.get("/m"), maxBytes: 100_000)
            #expect(rig.transport.inFlightCount == 1)
            response = nil
            #expect(response == nil)
            #expect(rig.transport.inFlightCount == 0, "dropping the last reference abandons the transfer")
            #expect(rig.transport.abortedCount == 1)

            let second = try await rig.api.stream(.get("/m"), maxBytes: 100_000)
            second.body.cancel()
            #expect(rig.transport.abortedCount == 2)
            await #expect(throws: CancellationError.self) { try await Self.read(second.body) }
        }
    }

    // MARK: Redirects and the pipeline

    @Test(.failureMode("design/19", "a streamed request is redirected"))
    func aRedirectIsFollowedItsBodyDroppedAndRangeTravelsWithItsValidator() async throws {
        try await withRig(headers: ["Authorization": "Bearer secret"]) { rig in
            let data = Self.data(2_000)
            rig.transport.on(.get("/file"), respond: [
                .streaming(Array("moved".utf8), status: 302, headers: ["Location": "https://cdn.example.net/blob"], chunkSize: 2),
            ])
            rig.transport.on(.get(URL(string: "https://cdn.example.net/blob")!), respond: [.serving(.init(data, etag: "\"v1\""))])
            let request = HTTPRequest.get("/file", headers: ["Range": "bytes=500-", "If-Range": "\"v1\"", "X-Custom": "no"])
            let response = try await rig.api.stream(request, maxBytes: 10_000)
            #expect(response.status == 206)
            #expect(response.headers["Content-Range"] == "bytes 500-1999/2000")
            #expect(try await Self.read(response.body).bytes == Array(data[500...]))

            let sent = rig.transport.requests
            #expect(sent.count == 2)
            #expect(sent[1].headers["Range"] == "bytes=500-")
            #expect(sent[1].headers["If-Range"] == "\"v1\"", "a Range arrives with the validator it was made for")
            #expect(sent[1].headers["Authorization"] == nil)
            #expect(sent[1].headers["X-Custom"] == nil)
            #expect(rig.transport.abortedCount == 1, "the redirect's body was dropped unread")
            #expect(rig.events.count("http.redirected") == 1)
        }
    }

    @Test func theBulkheadSlotIsReleasedAtTheHeadSoATransferDoesNotStarveTheHost() async throws {
        try await withRig(.testing(maxConcurrent: 1, queueLimit: 0)) { rig in
            rig.transport.on(.get("/big"), respond: [.streaming(Self.data(10_000), chunkSize: 1_000, fault: .hang(after: 1_000))])
            rig.transport.on(.get("/api"), respond: [.status(200)])
            let response = try await rig.api.stream(.get("/big"), maxBytes: 100_000)
            let first = try #require(try await response.body.first(where: { _ in true }))
            #expect(first.count == 1_000)
            // The transfer is mid-body, holding a connection and no slot.
            #expect(rig.transport.inFlightCount == 1)
            let answered = try await rig.api.send(.get("/api"))
            #expect(answered.status == 200)
            #expect(rig.api.bulkhead(forHost: "api.example.com")?.activeCount == 0)
            response.body.cancel()
        }
    }

    @Test func aStreamedRequestSendsItsHeadersTheKeyAndTheBase() async throws {
        try await withRig(headers: ["X-Client": "app"]) { rig in
            rig.transport.on(.get("/files/report"), respond: [.streaming([1])])
            let response = try await rig.api.stream(.get("/files/report", headers: ["Range": "bytes=0-"]), maxBytes: 10)
            #expect(try await Self.read(response.body).bytes == [1])
            #expect(rig.transport.requests.first?.headers["X-Client"] == "app")
            #expect(rig.transport.requests.first?.headers["Range"] == "bytes=0-")
        }
    }

    @Test(.failureMode("design/19", "a streamed call runs inside a `perform` attempt"))
    func aStreamedCallInsideAPerformAttemptIsOneAttemptWithNoClientTimeout() async throws {
        try await withRig(.testing(timeout: .seconds(1))) { rig in
            rig.transport.on(.get("/m"), respond: [.streaming(Self.data(3_000), chunkSize: 1_000, chunkDelay: .seconds(5))])
            let api = rig.api
            let download = Backend.remote("http.streams").readOnly("download", length: .long)
            let task = Task { () async throws -> Int in
                try await download.perform { _ throws(any Error) in
                    let response = try await api.stream(.get("/m"), maxBytes: 10_000)
                    return try await Self.read(response.body).bytes.count
                }
            }
            for _ in 0..<3 { await Self.advanceWhenSleeping(.seconds(5), on: rig.clock) }
            let count = try await task.value
            #expect(count == 3_000)
            #expect(rig.transport.requestCount == 1)
            #expect(rig.events.count("http.retry") == 0)
        }
    }

    // MARK: A transport that cannot stream

    /// A transport that only sends: it implements nothing of streaming.
    struct SendOnly: HTTPTransport {
        let answer: HTTPResponse
        func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse { answer }
    }

    @Test(.failureMode("design/19", "a transport has no streaming of its own"))
    func theDefaultStreamSendsAndYieldsTheWholeBodyAsOneChunk() async throws {
        let transport = SendOnly(answer: HTTPResponse(status: 200, headers: ["X": "1"], body: Self.data(1_000)))
        let response = try await transport.stream(.get(URL(string: "https://x.example.com/a")!), maxResponseBytes: 10_000)
        #expect(response.status == 200)
        #expect(response.headers["X"] == "1")
        let (bytes, chunks) = try await Self.read(response.body)
        #expect(bytes == Self.data(1_000))
        #expect(chunks == 1)

        let client = HTTPClient(base: URL(string: "https://x.example.com")!, transport: transport)
        let streamed = try await client.stream(.get("/a"), maxBytes: 10_000)
        #expect(try await Self.read(streamed.body).bytes.count == 1_000)
    }

    @Test func anEmptyBodyFromADefaultStreamHasNoChunks() async throws {
        let transport = SendOnly(answer: HTTPResponse(status: 204))
        let response = try await transport.stream(.get(URL(string: "https://x.example.com/a")!), maxResponseBytes: 10)
        #expect(try await Self.read(response.body).chunks == 0)
    }
}

/// The scripted transport's streaming, which every test above stands on.
@Suite("Scripted streaming")
struct ScriptedStreamingTests {
    typealias Step = ScriptedTransport.Step

    static func request(_ path: String, headers: HTTPHeaders = [:]) -> HTTPRequest {
        HTTPRequest(method: .get, target: .url(URL(string: "https://files.example.com\(path)")!), headers: headers)
    }

    static let file = HTTPStreamingTests.data(1_000)

    @Test func aServerHonoursRangeAndSaysWhereTheBytesStart() async throws {
        let transport = ScriptedTransport()
        transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [
            .serving(.init(Self.file, etag: "\"v1\"", lastModified: "Wed, 21 Oct 2015 07:28:00 GMT")),
        ])
        let whole = try await transport.send(Self.request("/f"), maxResponseBytes: 10_000)
        #expect(whole.status == 200)
        #expect(whole.headers["ETag"] == "\"v1\"")
        #expect(whole.headers["Last-Modified"] == "Wed, 21 Oct 2015 07:28:00 GMT")
        #expect(whole.headers["Accept-Ranges"] == "bytes")
        #expect(whole.headers["Content-Length"] == "1000")
        #expect(whole.body == Self.file)

        let part = try await transport.send(Self.request("/f", headers: ["Range": "bytes=250-"]), maxResponseBytes: 10_000)
        #expect(part.status == 206)
        #expect(part.headers["Content-Range"] == "bytes 250-999/1000")
        #expect(part.headers["Content-Length"] == "750")
        #expect(part.body == Array(Self.file[250...]))

        let middle = try await transport.send(Self.request("/f", headers: ["Range": "bytes=10-19"]), maxResponseBytes: 10_000)
        #expect(middle.status == 206)
        #expect(middle.headers["Content-Range"] == "bytes 10-19/1000")
        #expect(middle.body == Array(Self.file[10...19]))
    }

    @Test func anIfRangeThatNamesAnotherValidatorGetsTheWholeFile() async throws {
        let transport = ScriptedTransport()
        transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [
            .serving(.init(Self.file, etag: "\"v2\"", lastModified: "Wed, 21 Oct 2015 07:28:00 GMT")),
        ])
        let stale = try await transport.send(Self.request("/f", headers: ["Range": "bytes=250-", "If-Range": "\"v1\""]), maxResponseBytes: 10_000)
        #expect(stale.status == 200)
        #expect(stale.body.count == 1_000)
        let current = try await transport.send(Self.request("/f", headers: ["Range": "bytes=250-", "If-Range": "\"v2\""]), maxResponseBytes: 10_000)
        #expect(current.status == 206)
        let byDate = try await transport.send(
            Self.request("/f", headers: ["Range": "bytes=250-", "If-Range": "Wed, 21 Oct 2015 07:28:00 GMT"]), maxResponseBytes: 10_000)
        #expect(byDate.status == 206)
    }

    @Test func aWeakEtagNeverMatchesAnIfRange() async throws {
        let transport = ScriptedTransport()
        transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [.serving(.init(Self.file, etag: "W/\"v1\""))])
        let response = try await transport.send(Self.request("/f", headers: ["Range": "bytes=250-", "If-Range": "W/\"v1\""]), maxResponseBytes: 10_000)
        #expect(response.status == 200)
    }

    @Test func aServerThatIgnoresRangeSendsTheWholeFile() async throws {
        let transport = ScriptedTransport()
        transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [.serving(.init(Self.file, honoursRange: false))])
        let response = try await transport.send(Self.request("/f", headers: ["Range": "bytes=250-"]), maxResponseBytes: 10_000)
        #expect(response.status == 200)
        #expect(response.body == Self.file)
        #expect(response.headers["Accept-Ranges"] == nil)
    }

    @Test func aRangeAtOrPastTheEndIs416WithTheLength() async throws {
        let transport = ScriptedTransport()
        transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [.serving(.init(Self.file))])
        for start in [1_000, 5_000] {
            let response = try await transport.send(Self.request("/f", headers: ["Range": "bytes=\(start)-"]), maxResponseBytes: 10_000)
            #expect(response.status == 416)
            #expect(response.headers["Content-Range"] == "bytes */1000")
            #expect(response.body.isEmpty)
        }
    }

    @Test func aFaultHappensAfterTheBytesItNames() async throws {
        let transport = ScriptedTransport()
        let route = HTTPRequest.get(URL(string: "https://files.example.com/f")!)
        transport.on(route, respond: [
            .streaming(Self.file, chunkSize: 300, fault: .cut(after: 700)),
            .streaming(Self.file, chunkSize: 300, fault: .fail(after: 0, .timedOut)),
            .streaming(Self.file, chunkSize: 300, fault: .cut(after: 1_000)),
            .streaming(Self.file, chunkSize: 300, fault: .cut(after: 5_000)),
        ])
        let first = try await transport.stream(Self.request("/f"), maxResponseBytes: 10_000)
        let cut = try #require(await HTTPStreamingTests.failure(of: first.body))
        #expect(cut.delivered == 700)
        #expect((cut.error as? URLError)?.code == .networkConnectionLost)

        let second = try await transport.stream(Self.request("/f"), maxResponseBytes: 10_000)
        let failed = try #require(await HTTPStreamingTests.failure(of: second.body))
        #expect(failed.delivered == 0)
        #expect((failed.error as? URLError)?.code == .timedOut)

        // A cut after the last byte: every byte arrived, and the connection died.
        let third = try await transport.stream(Self.request("/f"), maxResponseBytes: 10_000)
        let late = try #require(await HTTPStreamingTests.failure(of: third.body))
        #expect(late.delivered == 1_000)

        // A fault past the end of the body never happens.
        let fourth = try await transport.stream(Self.request("/f"), maxResponseBytes: 10_000)
        #expect(try await HTTPStreamingTests.read(fourth.body).bytes == Self.file)
    }

    @Test func sendThroughAShapedBodyHasItsFaultsToo() async throws {
        let transport = ScriptedTransport()
        transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [.streaming(Self.file, fault: .cut(after: 10))])
        await #expect(throws: URLError(.networkConnectionLost)) {
            try await transport.send(Self.request("/f"), maxResponseBytes: 10_000)
        }
        #expect(transport.abortedCount == 1)
        #expect(transport.inFlightCount == 0)
    }

    @Test func aStallWaitsOnTheAmbientClockAndThenGoesOn() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) { () async throws in
            let transport = ScriptedTransport()
            transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [
                .streaming(Self.file, chunkSize: 400, fault: .stall(after: 400, for: .seconds(30))),
            ])
            let response = try await transport.stream(Self.request("/f"), maxResponseBytes: 10_000)
            let reading = Task { try await HTTPStreamingTests.read(response.body).bytes }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(29))
            #expect(clock.sleeperCount == 1, "not yet")
            await clock.advance(by: .seconds(1))
            #expect(try await reading.value == Self.file)
        }
    }

    @Test func aChunkDelayIsASleepBeforeEveryChunk() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) { () async throws in
            let transport = ScriptedTransport()
            transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [
                .streaming(Self.file, chunkSize: 500, chunkDelay: .seconds(2)),
            ])
            let response = try await transport.stream(Self.request("/f"), maxResponseBytes: 10_000)
            let reading = Task { try await HTTPStreamingTests.read(response.body) }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(2))
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(2))
            let (bytes, chunks) = try await reading.value
            #expect(bytes == Self.file)
            #expect(chunks == 2)
            #expect(clock.now.offset == .seconds(4))
        }
    }

    @Test func aBodyPastTheLimitDeliversUpToItAndThenFails() async throws {
        let transport = ScriptedTransport()
        transport.on(.get(URL(string: "https://files.example.com/f")!), respond: [
            .streaming(Self.file, headers: ["Content-Length": "100"], chunkSize: 300),
        ])
        let response = try await transport.stream(Self.request("/f"), maxResponseBytes: 450)
        let result = try #require(await HTTPStreamingTests.failure(of: response.body))
        #expect(result.delivered == 450)
        #expect(result.error as? HTTPTransportError == .responseTooLarge(limit: 450))
    }
}

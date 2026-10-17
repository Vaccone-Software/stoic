import Foundation
#if canImport(FoundationNetworking)
// URLSession and URLProtocol live here on Linux.
import FoundationNetworking
#endif
@testable import StoicHTTP
import StoicTesting
import Synchronization
import Testing

/// The real transport's streaming. Most of it runs on a real `URLSession`
/// with a `URLProtocol` stub for a server (its table is in
/// `URLSessionTransportTests.swift`, and these tests are in that suite, which
/// is serialized because the stub's book is shared). What the stub cannot
/// say, because it hands the session its bytes whatever the session decides
/// about reading (whether a transport that stops reading really makes the
/// server wait, and what a connection that dies mid-body leaves a reader),
/// is said over a real TCP connection to a server on the loopback
/// interface (`LoopbackServer`): nothing leaves the machine.
extension URLSessionTransportTests {
    static func streamingTransport(
        bufferBytes: Int = 4 << 20, configure: (URLSessionConfiguration) -> Void = { _ in }
    ) -> URLSessionTransport {
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configure(configuration)
        return URLSessionTransport(configuration: configuration, streamBufferBytes: bufferBytes)
    }

    /// A transport on the real network stack, for the loopback server.
    static func loopbackTransport(bufferBytes: Int = 4 << 20) -> URLSessionTransport {
        URLSessionTransport(configuration: .ephemeral, streamBufferBytes: bufferBytes)
    }

    static func loopbackRequest(_ server: LoopbackServer, _ path: String) -> HTTPRequest {
        HTTPRequest(method: .get, target: .url(server.url(path)))
    }

    /// The byte at offset `offset` of the body the loopback tests serve: its
    /// 64 KiB block number, so a reader can check order and completeness
    /// without holding the body.
    static func blockByte(at offset: Int) -> UInt8 { UInt8(truncatingIfNeeded: offset / 65_536) }

    /// Checks chunks against `blockByte(at:)`, in order: the first and last
    /// byte of every chunk, and one in every 1,024 between (a debug build
    /// cannot afford to look at all of 256 MiB, and a block that is wrong
    /// anywhere is wrong at a sampled byte of a 64 KiB block).
    struct BlockChecker {
        private(set) var offset = 0

        mutating func check(_ chunk: [UInt8]) {
            var index = 0
            while index < chunk.count {
                if chunk[index] != URLSessionTransportTests.blockByte(at: offset + index) {
                    Issue.record("byte \(offset + index) is \(chunk[index])")
                    break
                }
                index = index == chunk.count - 1 ? chunk.count : min(index + 1_024, chunk.count - 1)
            }
            offset += chunk.count
        }
    }

    // MARK: Chunks

    @Test(.failureMode("design/19", "a body too large to hold is streamed"))
    func aBodyArrivesAsChunksNotAsOneBuffer() async throws {
        let transport = Self.streamingTransport()
        let response = try await transport.stream(Self.request("/chunks"), maxResponseBytes: 1_000_000)
        #expect(response.status == 200)
        #expect(response.headers["Content-Length"] == "100000")
        var bytes: [UInt8] = []
        var chunks = 0
        for try await chunk in response.body {
            #expect(!chunk.isEmpty)
            bytes.append(contentsOf: chunk)
            chunks += 1
        }
        #expect(bytes == (0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        #expect(chunks > 1, "the delegate's chunks are delivered as they come")
    }

    @Test func aResponseWithNoBodyEndsAtOnce() async throws {
        let transport = Self.streamingTransport()
        let response = try await transport.stream(Self.request("/head-only"), maxResponseBytes: 10)
        #expect(response.headers["X-Answer"] == "42")
        var chunks = 0
        for try await _ in response.body { chunks += 1 }
        #expect(chunks == 0)
    }

    // MARK: Backpressure

    @Test func aLaggingConsumerSuspendsTheTaskAndResumingItLosesNothing() async throws {
        // What the stub can show: the buffer fills, the task is suspended, the
        // consumer's draining resumes it, and every byte arrives in order. (That
        // suspending really stops the system reading is `aSlowConsumerMakesTheServerWait`.)
        let transport = Self.streamingTransport(bufferBytes: 256 * 1024)
        let response = try await transport.stream(Self.request("/flood"), maxResponseBytes: 100 << 20)
        var iterator = response.body.makeAsyncIterator()
        var checker = BlockChecker()
        checker.check(try #require(try await iterator.next()))
        await eventually("the task was never suspended") { transport.transfers.streams.suspensions >= 1 }
        while let chunk = try await iterator.next() { checker.check(chunk) }
        #expect(checker.offset == 8 * 1024 * 1024)
        #expect(transport.transfers.streams.resumptions >= 1)
    }

    @Test(.failureMode("design/19", "a consumer reads slower than the body arrives"))
    func aSlowConsumerMakesTheServerWait() async throws {
        let total = 256 << 20
        let server = try LoopbackServer { connection in
            guard connection.writeHead(200, ["Content-Length": String(total)]) else { return }
            var offset = 0
            while offset < total {
                guard connection.write([UInt8](repeating: Self.blockByte(at: offset), count: 65_536)) else { return }
                offset += 65_536
            }
        }
        defer { server.stop() }
        let transport = Self.loopbackTransport(bufferBytes: 512 * 1024)
        let response = try await transport.stream(Self.loopbackRequest(server, "/model"), maxResponseBytes: total)

        // The consumer takes one chunk and stops. The server must stop too: its
        // sends block once the connection's windows and our buffer are full.
        var iterator = response.body.makeAsyncIterator()
        var checker = BlockChecker()
        checker.check(try #require(try await iterator.next()))
        await eventually("the transfer was never suspended") { transport.transfers.streams.suspensions >= 1 }
        var stable = 0
        var last = -1
        for _ in 0..<200 where stable < 6 {
            try await Task.sleep(for: .milliseconds(50))
            let now = server.bytesWritten
            stable = now == last ? stable + 1 : 0
            last = now
        }
        #expect(stable >= 6, "the server never stopped writing: \(last) bytes of \(total)")
        #expect(last < total / 4, "the server wrote \(last) bytes of \(total) to a reader that had stopped")
        let peakWhileStopped = transport.transfers.streams.peakBufferedBytes

        // Reading on resumes the transfer, and every byte arrives in order.
        while let chunk = try await iterator.next() { checker.check(chunk) }
        #expect(checker.offset == total)
        #expect(transport.transfers.streams.resumptions >= 1)
        // The buffer is a bound of the order of its size, not an exact one: what the
        // system had already read when the task was suspended still arrives (measured
        // on a Mac: the server wrote 1.6 MB to a stopped reader, and 917,504 bytes were
        // the most held, for a limit of 524,288). What matters is a few buffers, not the body.
        let peak = transport.transfers.streams.peakBufferedBytes
        #expect(peakWhileStopped < total / 32, "held \(peakWhileStopped) bytes while the consumer had stopped")
        #expect(peak < total / 32, "held \(peak) bytes of \(total) at the most")
    }

    @Test(.failureMode("design/19", "a streamed body fails after its head"))
    func aConnectionLostMidBodyIsThrownAfterTheBytesThatArrived() async throws {
        let server = try LoopbackServer { connection in
            guard connection.writeHead(200, ["Content-Length": "1000000"]) else { return }
            // Promises a megabyte, sends 300 kB, and the connection is gone.
            for _ in 0..<5 { _ = connection.write([UInt8](repeating: 1, count: 60_000)) }
        }
        defer { server.stop() }
        let transport = Self.loopbackTransport()
        let response = try await transport.stream(Self.loopbackRequest(server, "/cut"), maxResponseBytes: 10_000_000)
        var delivered = 0
        do {
            for try await chunk in response.body { delivered += chunk.count }
            Issue.record("the body ended without failing")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost, "got \(error)")
        }
        // What the system had read when it saw the connection die is what it hands over: it
        // may have kept some of the 300 kB back, never more than was sent.
        #expect(delivered <= 300_000, "delivered \(delivered)")
        var again = 0
        for try await chunk in response.body { again += chunk.count }
        #expect(again == 0, "after a failure the sequence has ended")
    }

    @Test(.failureMode("design/19", "the caller is cancelled while a body is read"))
    func cancellingTheReaderMidBodyDropsTheConnection() async throws {
        let server = try LoopbackServer { connection in
            guard connection.writeHead(200, ["Content-Length": String(1 << 30)]) else { return }
            while connection.write([UInt8](repeating: 1, count: 65_536)) {}
        }
        defer { server.stop() }
        let transport = Self.loopbackTransport(bufferBytes: 256 * 1024)
        let response = try await transport.stream(Self.loopbackRequest(server, "/endless"), maxResponseBytes: 1 << 30)
        let reading = Task { () async throws -> Int in
            var total = 0
            for try await chunk in response.body { total += chunk.count }
            return total
        }
        await eventually("the body never began") { server.bytesWritten > 1_000_000 }
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        // The server's own sends find the connection closed.
        await eventually("the connection was never dropped") { server.peerGoneCount >= 1 }
        // And cancelling the stream itself, which nothing is reading, does the same.
        let second = try await transport.stream(Self.loopbackRequest(server, "/endless"), maxResponseBytes: 1 << 30)
        second.body.cancel()
        await eventually("the second connection was never dropped") { server.peerGoneCount >= 2 }
    }

    // MARK: Cancellation and limits, on the stub

    @Test(.failureMode("design/19", "a streamed response is abandoned unread"))
    func cancellingOrDroppingTheStreamCancelsTheDataTask() async throws {
        let transport = Self.streamingTransport()
        let response = try await transport.stream(Self.request("/big"), maxResponseBytes: 10_000_000)
        response.body.cancel()
        await eventually("the data task was never cancelled") { StubProtocol.hasStopped("/big") }
        await #expect(throws: CancellationError.self) {
            for try await _ in response.body {}
        }

        StubProtocol.reset()
        var dropped: HTTPStreamedResponse? = try await transport.stream(Self.request("/big"), maxResponseBytes: 10_000_000)
        #expect(dropped != nil)
        dropped = nil
        #expect(dropped == nil)
        await eventually("dropping the stream never cancelled the data task") { StubProtocol.hasStopped("/big") }
    }

    @Test func cancellingBeforeTheHeadCancelsTheRequestAndThrowsCancellationError() async throws {
        let transport = Self.streamingTransport()
        let task = Task { try await transport.stream(Self.request("/hang"), maxResponseBytes: 1000) }
        await eventually { StubProtocol.hasStarted("/hang") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await eventually("the data task was never cancelled") { StubProtocol.hasStopped("/hang") }
    }

    @Test(.failureMode("design/19", "a streamed body is longer than its limit"))
    func aBodyPastTheLimitEndsTheStreamAndCancelsTheTask() async throws {
        let transport = Self.streamingTransport()
        let response = try await transport.stream(Self.request("/big"), maxResponseBytes: 100_000)
        var delivered = 0
        do {
            for try await chunk in response.body { delivered += chunk.count }
            Issue.record("the body ended without failing")
        } catch {
            #expect(error as? HTTPTransportError == .responseTooLarge(limit: 100_000))
        }
        #expect(delivered == 100_000, "up to the limit, and not a byte more")
        await eventually("the data task was never cancelled") { StubProtocol.hasStopped("/big") }
    }

    @Test func aDeclaredLengthOverTheLimitFailsBeforeTheFirstByte() async throws {
        let transport = Self.streamingTransport()
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 1000)) {
            try await transport.stream(Self.request("/declared"), maxResponseBytes: 1000)
        }
        await eventually { StubProtocol.hasStopped("/declared") }
    }

    @Test func aNetworkFailureBeforeTheHeadIsTheURLError() async {
        let transport = Self.streamingTransport()
        let error = await #expect(throws: URLError.self) {
            try await transport.stream(Self.request("/offline"), maxResponseBytes: 1000)
        }
        #expect(error?.code == .notConnectedToInternet)
    }

    @Test func aCallersConfigurationReachesTheSessionForStreamingToo() async throws {
        // Lodestar's: wait for connectivity, and stay off expensive and constrained networks.
        let transport = Self.streamingTransport { configuration in
            configuration.waitsForConnectivity = true
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
            configuration.timeoutIntervalForRequest = 45
            configuration.httpAdditionalHeaders = ["X-From-Configuration": "yes"]
        }
        let response = try await transport.stream(Self.request("/ok"), maxResponseBytes: 1000)
        var bytes: [UInt8] = []
        for try await chunk in response.body { bytes.append(contentsOf: chunk) }
        #expect(String(decoding: bytes, as: UTF8.self) == "hello")
        #expect(StubProtocol.seen.first?.headers["X-From-Configuration"] == "yes", "the session is the configuration's")
    }

    @Test func theClientStreamsOverTheRealTransport() async throws {
        let api = HTTPClient(base: URL(string: "https://api.example.com")!, transport: Self.streamingTransport())
        let response = try await api.stream(.get("/chunks"), maxBytes: 1_000_000)
        var total = 0
        for try await chunk in response.body { total += chunk.count }
        #expect(total == 100_000)
        let missing = await #expect(throws: HTTPError.self) { try await api.stream(.get("/missing"), maxBytes: 1000) }
        #expect(missing?.statusCode == 404)
    }
}

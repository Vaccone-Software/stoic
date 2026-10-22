import Foundation
#if canImport(FoundationNetworking)
// URLResponse and HTTPURLResponse live here on Linux.
import FoundationNetworking
#endif
@testable import StoicHTTP
import Testing

/// The buffer between a data task's delegate callbacks and the reader of a
/// streamed body, driven by hand: the callbacks are made in the order a
/// session makes them, so what a real session does only by timing is
/// settled here (which is why `URLSessionStreamingTests` need not assert it).
@Suite("Stream transfer")
struct StreamTransferTests {
    static func transfer(limit: Int = 1_000_000, buffer: Int = 100, method: HTTPMethod = .get) -> (StreamTransfer, StreamStatistics) {
        let statistics = StreamStatistics()
        return (StreamTransfer(limit: limit, bufferLimit: buffer, statistics: statistics, method: method), statistics)
    }

    static func head(status: Int = 200, length: Int64 = -1) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/f")!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: length >= 0 ? ["Content-Length": String(length)] : [:])!
    }

    static func data(_ count: Int, _ value: UInt8 = 1) -> Data { Data(repeating: value, count: count) }

    /// Makes the head arrive, as a session does before any data: the reader
    /// registers, the task resumes, the head comes.
    static func open(_ transfer: StreamTransfer, status: Int = 200, length: Int64 = -1) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
            transfer.awaitHead(continuation)
            #expect(transfer.receive(Self.head(status: status, length: length)))
        }
    }

    @Test func bytesThatArrivedBeforeAFailureAreDeliveredBeforeIt() async throws {
        let (transfer, _) = Self.transfer()
        try await Self.open(transfer)
        #expect(transfer.receive(Self.data(30, 1)))
        #expect(transfer.receive(Self.data(20, 2)))
        transfer.complete(error: URLError(.networkConnectionLost))

        #expect(try await transfer.next() == [UInt8](repeating: 1, count: 30))
        #expect(try await transfer.next() == [UInt8](repeating: 2, count: 20))
        await #expect(throws: URLError(.networkConnectionLost)) { try await transfer.next() }
        #expect(try await transfer.next() == nil, "after the failure the sequence has ended")
    }

    @Test func aFinishedBodyEndsOnceItsChunksAreTaken() async throws {
        let (transfer, _) = Self.transfer()
        try await Self.open(transfer)
        _ = transfer.receive(Self.data(10))
        transfer.complete(error: nil)
        #expect(try await transfer.next()?.count == 10)
        #expect(try await transfer.next() == nil)
        #expect(try await transfer.next() == nil)
    }

    @Test func aReaderThatIsWaitingTakesTheNextChunkDirectly() async throws {
        let (transfer, statistics) = Self.transfer()
        try await Self.open(transfer)
        let reading = Task { try await transfer.next() }
        // Wait until the reader is parked: a chunk that arrives then goes straight to it.
        try await Task.sleep(for: .milliseconds(20))
        _ = transfer.receive(Self.data(40, 7))
        #expect(try await reading.value == [UInt8](repeating: 7, count: 40))
        #expect(statistics.peakBufferedBytes == 0, "nothing was buffered")
    }

    @Test func aWaitingReaderIsToldOfTheEnd() async throws {
        let (transfer, _) = Self.transfer()
        try await Self.open(transfer)
        let reading = Task { try await transfer.next() }
        try await Task.sleep(for: .milliseconds(20))
        transfer.complete(error: nil)
        #expect(try await reading.value == nil)
    }

    #if canImport(Darwin)
    @Test func theTaskIsSuspendedWhenTheBufferFillsAndResumedWhenAQuarterIsLeft() async throws {
        let (transfer, statistics) = Self.transfer(buffer: 100)
        try await Self.open(transfer)
        for _ in 0..<4 { _ = transfer.receive(Self.data(30)) }   // 30, 60, 90, 120: over 100 at the fourth
        #expect(statistics.suspensions == 1)
        #expect(statistics.peakBufferedBytes == 120)
        _ = transfer.receive(Self.data(30))   // the system had more in flight: no second suspension
        #expect(statistics.suspensions == 1)

        _ = try await transfer.next()   // 120 left
        _ = try await transfer.next()   // 90
        _ = try await transfer.next()   // 60
        _ = try await transfer.next()   // 30: over a quarter (25)
        #expect(statistics.resumptions == 0)
        _ = try await transfer.next()   // 0
        #expect(statistics.resumptions == 1)
    }
    #endif

    @Test func aBodyPastTheLimitDeliversUpToItAndThenFailsWithResponseTooLarge() async throws {
        let (transfer, _) = Self.transfer(limit: 50)
        try await Self.open(transfer)
        #expect(transfer.receive(Self.data(30)))
        #expect(!transfer.receive(Self.data(30, 9)), "the task is to be cancelled")
        transfer.complete(error: URLError(.cancelled))

        #expect(try await transfer.next()?.count == 30)
        #expect(try await transfer.next() == [UInt8](repeating: 9, count: 20), "up to the limit")
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 50)) { try await transfer.next() }
        #expect(try await transfer.next() == nil)
    }

    @Test(arguments: [
        (method: HTTPMethod.head, status: 200), (method: .get, status: 204), (method: .post, status: 204),
        (method: .get, status: 304), (method: .head, status: 404),
    ])
    func aDeclaredLengthIsNotARefusalWhenNoBodyWillBeTransferred(method: HTTPMethod, status: Int) async throws {
        let (transfer, _) = Self.transfer(limit: 50, method: method)
        let head = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
            transfer.awaitHead(continuation)
            #expect(transfer.receive(Self.head(status: status, length: 20_000_000)))
        }
        #expect(head.statusCode == status)
        transfer.complete(error: nil)
        #expect(try await transfer.next() == nil)
    }

    @Test func bytesThatArriveOnAHeadAreStillHeldToTheLimit() async throws {
        let (transfer, _) = Self.transfer(limit: 50, method: .head)
        try await Self.open(transfer, length: 20_000_000)
        #expect(transfer.receive(Self.data(30)))
        #expect(!transfer.receive(Self.data(30, 9)), "the task is to be cancelled")
        transfer.complete(error: URLError(.cancelled))

        #expect(try await transfer.next()?.count == 30)
        #expect(try await transfer.next() == [UInt8](repeating: 9, count: 20), "up to the limit")
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 50)) { try await transfer.next() }
        #expect(try await transfer.next() == nil)
    }

    @Test func aDeclaredLengthOverTheLimitRefusesTheHead() async throws {
        let (transfer, _) = Self.transfer(limit: 50)
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 50)) {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
                transfer.awaitHead(continuation)
                #expect(!transfer.receive(Self.head(length: 51)), "the task is to be cancelled")
            }
        }
        transfer.complete(error: URLError(.cancelled))
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 50)) { _ = try await transfer.next() }
    }

    @Test func abandoningWakesAWaitingReaderWithCancellationAndEndsLaterReads() async throws {
        let (transfer, _) = Self.transfer()
        try await Self.open(transfer)
        let reading = Task { try await transfer.next() }
        try await Task.sleep(for: .milliseconds(20))
        transfer.abandon()
        await #expect(throws: CancellationError.self) { _ = try await reading.value }
        await #expect(throws: CancellationError.self) { _ = try await transfer.next() }
        transfer.abandon()   // harmless twice
    }

    @Test func abandoningDropsWhatWasBuffered() async throws {
        let (transfer, _) = Self.transfer()
        try await Self.open(transfer)
        _ = transfer.receive(Self.data(30))
        transfer.abandon()
        await #expect(throws: CancellationError.self) { _ = try await transfer.next() }
        #expect(!transfer.receive(Self.data(30)), "data after an abandonment is refused")
    }

    @Test func aTaskCancelledWhileTheReaderIsWaitingAbandonsTheTransfer() async throws {
        let (transfer, _) = Self.transfer()
        try await Self.open(transfer)
        let reading = Task { try await transfer.next() }
        try await Task.sleep(for: .milliseconds(20))
        reading.cancel()
        await #expect(throws: CancellationError.self) { _ = try await reading.value }
        #expect(!transfer.receive(Self.data(1)))
    }

    @Test func aTransferThatFailsBeforeTheHeadFailsTheHead() async throws {
        let (transfer, _) = Self.transfer()
        await #expect(throws: URLError(.notConnectedToInternet)) {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
                transfer.awaitHead(continuation)
                transfer.complete(error: URLError(.notConnectedToInternet))
            }
        }
    }
}

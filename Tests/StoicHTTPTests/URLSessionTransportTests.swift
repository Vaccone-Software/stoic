import Foundation
#if canImport(FoundationNetworking)
// URLSession and URLProtocol live here on Linux.
import FoundationNetworking
#endif
import StoicHTTP
@testable import StoicHTTP
import Synchronization
import Testing

/// A URL protocol that answers from a table, in-process: the real
/// `URLSession` machinery (delegates, cancellation, redirects) with no
/// network.
final class StubProtocol: URLProtocol {
    struct Seen: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: [UInt8]
    }

    private struct Book {
        var seen: [Seen] = []
        var stopped: Set<String> = []
        var started: Set<String> = []
    }

    private static let book = Mutex(Book())

    static var seen: [Seen] { book.withLock { $0.seen } }
    static func hasStopped(_ path: String) -> Bool { book.withLock { $0.stopped.contains(path) } }
    static func hasStarted(_ path: String) -> Bool { book.withLock { $0.started.contains(path) } }
    static func reset() { book.withLock { $0 = Book() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        // Apple's loading hands a protocol the body as a stream; Linux's may
        // leave it in `httpBody`.
        var body = request.httpBody.map { [UInt8]($0) } ?? []
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = unsafe stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body += buffer.prefix(count)
            }
            stream.close()
        }
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.book.withLock {
            $0.seen.append(Seen(url: url, method: request.httpMethod ?? "GET", headers: headers, body: body))
            $0.started.insert(url.path)
        }

        func respond(_ status: Int, _ fields: [String: String] = [:]) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        switch url.path {
        case "/ok":
            respond(200, ["X-Answer": "42", "Content-Type": "text/plain"])
            client?.urlProtocol(self, didLoad: Data("hello".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "/echo":
            respond(201)
            client?.urlProtocol(self, didLoad: Data(body))
            client?.urlProtocolDidFinishLoading(self)
        case "/big":
            respond(200)
            for _ in 0..<4 { client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 65_536)) }
            // Never finishes: only a cancelled task ends it.
        case "/declared":
            respond(200, ["Content-Length": "5000000"])
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 65_536))   // URLSession hands over the response once the first chunk arrives
        case "/representation":
            // The size a GET would send. A HEAD reads this and no body.
            respond(200, ["Content-Length": "20000000", "ETag": "\"model\"", "Accept-Ranges": "bytes"])
            client?.urlProtocolDidFinishLoading(self)
        case "/no-content":
            respond(204, ["Content-Length": "20000000", "ETag": "\"gone\""])
            client?.urlProtocolDidFinishLoading(self)
        case "/not-modified":
            respond(304, ["Content-Length": "20000000", "ETag": "\"cached\""])
            client?.urlProtocolDidFinishLoading(self)
        case "/head-bytes":
            // A HEAD whose server sends a body anyway. The declared length is
            // not a refusal; the bytes are.
            respond(200, ["Content-Length": "20000000"])
            client?.urlProtocol(self, didLoad: Data(repeating: 9, count: 4_000))
            client?.urlProtocolDidFinishLoading(self)
        case "/hang":
            break
        case "/chunks":
            respond(200, ["Content-Length": "100000"])
            for index in 0..<100 {
                client?.urlProtocol(self, didLoad: Data((0..<1000).map { UInt8(truncatingIfNeeded: index * 1000 + $0) }))
            }
            client?.urlProtocolDidFinishLoading(self)
        case "/flood":
            // 8 MiB in 64 KiB chunks, handed over as fast as the loading thread can.
            respond(200)
            for index in 0..<128 { client?.urlProtocol(self, didLoad: Data(repeating: UInt8(index), count: 65_536)) }
            client?.urlProtocolDidFinishLoading(self)
        case "/head-only":
            respond(200, ["X-Answer": "42"])
            client?.urlProtocolDidFinishLoading(self)
        case "/cut":
            respond(200)
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 1000))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case "/offline":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        // swift-corelibs-foundation's URLProtocolClient.wasRedirectedTo is a fatalError.
        #if canImport(Darwin)
        case "/redirect":
            let target = URL(string: "https://other.example.com/final")!
            var next = URLRequest(url: target)
            next.allHTTPHeaderFields = headers
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            // As the system's HTTP loading does: a redirect the delegate
            // declines is delivered as the response, body and all.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("moved".utf8))
            client?.urlProtocolDidFinishLoading(self)
        #endif
        case "/final":
            respond(200)
            client?.urlProtocol(self, didLoad: Data("arrived".utf8))
            client?.urlProtocolDidFinishLoading(self)
        default:
            respond(404)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        guard let path = request.url?.path else { return }
        _ = Self.book.withLock { $0.stopped.insert(path) }
    }
}

@Suite("URLSession transport", .serialized)
struct URLSessionTransportTests {
    static func transport() -> URLSessionTransport {
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(configuration: configuration)
    }

    static func request(_ path: String, method: HTTPMethod = .get, headers: HTTPHeaders = [:], body: [UInt8]? = nil) -> HTTPRequest {
        HTTPRequest(method: method, target: .url(URL(string: "https://api.example.com\(path)")!), headers: headers, body: body)
    }

    @Test func aResponseComesBackWithItsStatusHeadersAndBody() async throws {
        let transport = Self.transport()
        let response = try await transport.send(Self.request("/ok", headers: ["X-Token": "abc"]), maxResponseBytes: 1000)
        #expect(response.status == 200)
        #expect(response.text == "hello")
        #expect(response.headers["x-answer"] == "42")
        #expect(StubProtocol.seen.first?.headers["X-Token"] == "abc")
    }

    @Test func theMethodHeadersAndBodyAreSent() async throws {
        let transport = Self.transport()
        let request = Self.request("/echo", method: .post, headers: ["Content-Type": "application/json"], body: Array(#"{"a":1}"#.utf8))
        let response = try await transport.send(request, maxResponseBytes: 1000)
        #expect(response.status == 201)
        #expect(response.text == #"{"a":1}"#)
        #expect(StubProtocol.seen.first?.headers["Content-Type"] == "application/json")
    }

    @Test func aBodyPastTheLimitCancelsTheTransferWithoutKeepingTheExcess() async throws {
        let transport = Self.transport()
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 100_000)) {
            try await transport.send(Self.request("/big"), maxResponseBytes: 100_000)
        }
        await eventually("the data task was never cancelled") { StubProtocol.hasStopped("/big") }
    }

    @Test func aHeadAndEmptyStatusesAreNotRefusedForTheLengthTheyDeclare() async throws {
        let transport = Self.transport()
        let head = try await transport.send(Self.request("/representation", method: .head), maxResponseBytes: 1_000)
        #expect(head.status == 200)
        #expect(head.headers["Content-Length"] == "20000000")
        #expect(head.headers["ETag"] == "\"model\"")
        #expect(head.body.isEmpty)
        #expect(StubProtocol.seen.last?.method == "HEAD")

        let empty = try await transport.send(Self.request("/no-content"), maxResponseBytes: 1_000)
        #expect(empty.status == 204)
        #expect(empty.headers["ETag"] == "\"gone\"")
        #expect(empty.body.isEmpty)

        let cached = try await transport.send(Self.request("/not-modified"), maxResponseBytes: 1_000)
        #expect(cached.status == 304)
        #expect(cached.headers["ETag"] == "\"cached\"")
        #expect(cached.body.isEmpty)

        // The same declaration on a GET, which will transfer a body, is still a refusal.
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 1_000)) {
            try await transport.send(Self.request("/representation"), maxResponseBytes: 1_000)
        }
    }

    @Test func bytesThatArriveOnAHeadAreStillHeldToTheLimit() async throws {
        let transport = Self.transport()
        // The stub finishes the load inside `startLoading`, so `stopLoading` is
        // not a signal here: the delegate has already been given the bytes, and
        // the transfer refuses once they pass the limit.
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 1_000)) {
            try await transport.send(Self.request("/head-bytes", method: .head), maxResponseBytes: 1_000)
        }
    }

    @Test func aDeclaredLengthOverTheLimitIsRefusedBeforeAnyByteMoves() async throws {
        let transport = Self.transport()
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 1000)) {
            try await transport.send(Self.request("/declared"), maxResponseBytes: 1000)
        }
        await eventually { StubProtocol.hasStopped("/declared") }
    }

    @Test func cancellingTheCallerCancelsTheTaskAndThrowsCancellationError() async throws {
        let transport = Self.transport()
        let task = Task { try await transport.send(Self.request("/hang"), maxResponseBytes: 1000) }
        await eventually { StubProtocol.hasStarted("/hang") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await eventually("the data task was never cancelled") { StubProtocol.hasStopped("/hang") }
    }

    @Test func aNetworkFailureIsTheURLError() async {
        let transport = Self.transport()
        let error = await #expect(throws: URLError.self) {
            try await transport.send(Self.request("/offline"), maxResponseBytes: 1000)
        }
        #expect(error?.code == .notConnectedToInternet)
    }

    // The stub's /redirect needs `wasRedirectedTo`, a fatalError in swift-corelibs-foundation (design/19, As built).
    #if canImport(Darwin)
    @Test func aRedirectIsTheResponseNotFollowed() async throws {
        let transport = Self.transport()
        let response = try await transport.send(Self.request("/redirect", headers: ["X-API-Key": "secret-key"]), maxResponseBytes: 1000)
        #expect(response.status == 302)
        #expect(response.headers["Location"] == "https://other.example.com/final")
        #expect(response.text == "moved")
        #expect(StubProtocol.seen.map(\.url.path) == ["/redirect"], "the transport went nowhere else")
    }
    #endif

    @Test func concurrentRequestsOnOneSessionEachGetTheirOwnResponse() async throws {
        let transport = Self.transport()
        async let ok = transport.send(Self.request("/ok"), maxResponseBytes: 1000)
        async let echo = transport.send(Self.request("/echo", method: .post, body: Array("ping".utf8)), maxResponseBytes: 1000)
        async let final = transport.send(Self.request("/final"), maxResponseBytes: 1000)
        let (first, second, third) = try await (ok, echo, final)
        #expect(first.text == "hello")
        #expect(second.status == 201 && second.text == "ping")
        #expect(third.text == "arrived")
    }

    // Same reason: it redirects through the stub's /redirect.
    #if canImport(Darwin)
    @Test func theClientFollowsARedirectOverTheRealTransportWithoutTheClientsHeaders() async throws {
        let api = HTTPClient(base: URL(string: "https://api.example.com")!, transport: Self.transport(), headers: ["X-API-Key": "secret-key"])
        let response = try await api.send(.get("/redirect", headers: ["Accept": "text/plain"]))
        #expect(response.text == "arrived")
        #expect(StubProtocol.seen.map(\.url.host) == ["api.example.com", "other.example.com"])
        #expect(StubProtocol.seen.first?.headers["X-API-Key"] == "secret-key")
        let final = try #require(StubProtocol.seen.last)
        #expect(final.headers["X-API-Key"] == nil, "a custom credential stays with its origin")
        #expect(final.headers["Accept"] == "text/plain")
    }
    #endif

    @Test func theClientRunsOverTheRealTransport() async throws {
        let api = HTTPClient(base: URL(string: "https://api.example.com")!, transport: Self.transport())
        let response = try await api.send(.get("/ok"))
        #expect(response.text == "hello")
        let missing = await #expect(throws: HTTPError.self) { try await api.send(.get("/missing")) }
        #expect(missing?.statusCode == 404)
    }
}

@Suite("Byte budget")
struct ByteBudgetTests {
    @Test func bytesUpToTheLimitAreKeptAndTheNextOneIsNot() {
        var budget = ByteBudget(limit: 5)
        let first = budget.append([1, 2, 3])
        let exact = budget.append([4, 5])
        #expect(first && exact, "exactly the limit is allowed")
        #expect(!budget.exceeded)
        let over = budget.append([6])
        #expect(!over)
        #expect(budget.exceeded)
        #expect(budget.bytes == [1, 2, 3, 4, 5])
    }

    @Test func aChunkStraddlingTheLimitKeepsOnlyWhatFits() {
        var budget = ByteBudget(limit: 4)
        let straddling = budget.append([1, 2, 3, 4, 5, 6])
        #expect(!straddling)
        #expect(budget.bytes == [1, 2, 3, 4])
        let after = budget.append([9])
        #expect(!after, "once exceeded, always exceeded")
        #expect(budget.bytes == [1, 2, 3, 4])
    }

    @Test(arguments: [(method: HTTPMethod.head, status: 200), (method: .get, status: 204), (method: .get, status: 304)])
    func aDeclaredLengthIsNotARefusalWhenNoBodyWillBeTransferred(method: HTTPMethod, status: Int) async throws {
        let transfer = Transfer(limit: 50, method: method)
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
            transfer.begin(continuation)
            let head = HTTPURLResponse(
                url: URL(string: "https://example.com/f")!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "20000000", "ETag": "\"model\""])!
            #expect(transfer.receive(head))
            transfer.complete(error: nil)
        }
        #expect(response.status == status)
        #expect(response.headers["Content-Length"] == "20000000")
        #expect(response.headers["ETag"] == "\"model\"")
        #expect(response.body.isEmpty)
    }

    @Test func bytesThatArriveOnAHeadAreStillCountedByTheBudget() async throws {
        let transfer = Transfer(limit: 50, method: .head)
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 50)) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                transfer.begin(continuation)
                let head = HTTPURLResponse(
                    url: URL(string: "https://example.com/f")!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "20000000"])!
                #expect(transfer.receive(head))
                #expect(transfer.receive(Data(repeating: 1, count: 40)))
                #expect(!transfer.receive(Data(repeating: 2, count: 20)))
                transfer.complete(error: URLError(.cancelled))
            }
        }
    }

    @Test func aDeclaredLengthIsCheckedAgainstTheLimit() {
        var unknown = ByteBudget(limit: 10)
        let unknownOK = unknown.declare(length: -1)
        var fits = ByteBudget(limit: 10)
        let fitsOK = fits.declare(length: 10)
        var tooBig = ByteBudget(limit: 10)
        let tooBigOK = tooBig.declare(length: 11)
        #expect(unknownOK && fitsOK && !tooBigOK)
        #expect(tooBig.exceeded)
    }
}

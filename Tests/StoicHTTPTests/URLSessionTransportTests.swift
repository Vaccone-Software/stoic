import Foundation
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
        var body: [UInt8] = []
        if let stream = request.httpBodyStream {
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
            $0.seen.append(Seen(url: url, headers: headers, body: body))
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
        case "/hang":
            break
        case "/offline":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case "/redirect":
            let target = URL(string: "https://other.example.com/final")!
            var next = URLRequest(url: target)
            next.allHTTPHeaderFields = headers
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
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

    @Test func aRedirectToAnotherHostDropsCredentials() async throws {
        let transport = Self.transport()
        let headers: HTTPHeaders = ["Authorization": "Bearer t", "Cookie": "sid=1", "Accept": "text/plain"]
        let response = try await transport.send(Self.request("/redirect", headers: headers), maxResponseBytes: 1000)
        #expect(response.text == "arrived")
        let final = try #require(StubProtocol.seen.first { $0.url.path == "/final" })
        #expect(final.headers["Authorization"] == nil)
        #expect(final.headers["Cookie"] == nil)
        #expect(final.headers["Accept"] == "text/plain")
    }

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

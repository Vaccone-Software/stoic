import Foundation
import Stoic
import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

@Suite("HTTP requests on the wire")
struct HTTPResolutionTests {
    static func sent(_ request: HTTPRequest, base: String = "https://api.example.com/v1", headers: HTTPHeaders = [:]) async throws -> HTTPRequest {
        let transport = ScriptedTransport(unscripted: .status(200))
        let api = HTTPClient(base: URL(string: base)!, policy: .testing(), transport: transport, headers: headers)
        _ = try await api.send(request)
        return try #require(transport.requests.first)
    }

    @Test func aPathIsJoinedToTheBaseURLsPath() async throws {
        let request = try await Self.sent(.get("/users/42"))
        #expect(request.url?.absoluteString == "https://api.example.com/v1/users/42")
        #expect(try await Self.sent(.get("users"), base: "https://api.example.com/v1/").url?.absoluteString == "https://api.example.com/v1/users")
    }

    @Test func aPathIsEncodedAndItsQueryItemsAreAppended() async throws {
        let request = try await Self.sent(.get("/files/a b", query: [URLQueryItem(name: "q", value: "x&y")]))
        #expect(request.url?.absoluteString == "https://api.example.com/v1/files/a%20b?q=x%26y")
    }

    @Test func aQueryWrittenIntoThePathIsAQueryNotPartOfThePath() async throws {
        let request = try await Self.sent(.get("/search?a=1", query: [URLQueryItem(name: "b", value: "2")]))
        #expect(request.url?.absoluteString == "https://api.example.com/v1/search?a=1&b=2")
    }

    @Test func anAbsoluteURLIgnoresTheBase() async throws {
        let request = try await Self.sent(.get(URL(string: "https://cdn.example.com/a.png")!))
        #expect(request.url?.absoluteString == "https://cdn.example.com/a.png")
    }

    @Test func defaultHeadersGoOnlyToTheBaseURLsHost() async throws {
        let defaults: HTTPHeaders = ["Authorization": "Bearer t", "X-App": "1"]
        let own = try await Self.sent(.get("/a", headers: ["X-App": "2"]), headers: defaults)
        #expect(own.headers["Authorization"] == "Bearer t")
        #expect(own.headers["X-App"] == "2", "the request's own header wins")
        let foreign = try await Self.sent(.get(URL(string: "https://elsewhere.example.com/a")!), headers: defaults)
        #expect(foreign.headers["Authorization"] == nil, "a token must not follow a link to another host")
        #expect(foreign.headers["X-App"] == nil)
    }

    @Test func aRequestThatCannotBeResolvedFailsAtOnceWithoutBeingSent() async throws {
        let transport = ScriptedTransport()
        let api = HTTPClient(base: apiBase, policy: .testing(), transport: transport)
        let error = await #expect(throws: HTTPError.self) { try await api.send(.get(URL(string: "ftp://example.com/a")!)) }
        #expect(error == .transport(.badURL, attempts: 0))
        #expect(transport.requestCount == 0)
    }

    @Test func theIdempotencyKeyIsSentAsAHeaderAndTheSameOneEachTime() async throws {
        let transport = ScriptedTransport()
        transport.on(.post("/orders", json: [:]), respond: [.status(201)])
        let api = HTTPClient(base: apiBase, policy: .testing(), transport: transport)
        let key = IdempotencyKey(rawValue: "order-9")
        _ = try await api.send(.post("/orders", json: ["n": 1]), idempotencyKey: key)
        #expect(transport.requests.first?.headers["Idempotency-Key"] == "order-9")
        #expect(transport.requests.first?.idempotencyKey == key)
    }
}

@Suite("HTTP privacy and errors")
struct HTTPPrivacyTests {
    static let secrets = ["SECRET-TOKEN", "SECRET-COOKIE", "SECRET-QUERY", "SECRET-BODY", "SECRET-REPLY", "SECRET-SETCOOKIE"]

    @Test func noEventCarriesACredentialACookieOrABody() async throws {
        try await withRig(.testing(attempts: 2)) { (rig) async throws in
            rig.transport.on(.post("/hook", json: [:]), respond: [
                .status(503, headers: ["Set-Cookie": "SECRET-SETCOOKIE"], body: "SECRET-REPLY"),
                .status(400, headers: ["Set-Cookie": "SECRET-SETCOOKIE"], body: "SECRET-REPLY"),
            ])
            let request = HTTPRequest.post(
                "/hook", json: ["note": "SECRET-BODY"], query: [URLQueryItem(name: "token", value: "SECRET-QUERY")],
                headers: ["Authorization": "Bearer SECRET-TOKEN", "Cookie": "sid=SECRET-COOKIE", "Proxy-Authorization": "SECRET-TOKEN"])
            let task = rig.start(request, key: IdempotencyKey(rawValue: "k"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            let error = await rig.httpError(of: task)
            #expect(error?.statusCode == 400)

            #expect(rig.events.count("http.request") == 2)
            for event in rig.events.events {
                for field in event.fields {
                    let text = field.description
                    for secret in Self.secrets where text.contains(secret) {
                        // The query string is the one place a secret may appear, and only as a private field.
                        #expect(event.name == "http.request" && field.key == "query" && field.privacy == .private, "\(event)")
                    }
                }
                #expect(!event.description.contains("SECRET-TOKEN") && !event.description.contains("SECRET-COOKIE"))
                #expect(!event.description.contains("SECRET-BODY") && !event.description.contains("SECRET-REPLY"))
            }
            let attempt = try #require(rig.events.events(named: "http.request").first)
            #expect(attempt.fields.first { $0.key == "query" }?.privacy == .private)
            #expect(attempt.fields.filter { $0.key == "method" || $0.key == "host" || $0.key == "path" }.allSatisfy { $0.privacy == .public })
            #expect(attempt.text("path") == "/hook")
            #expect(attempt.text("host") == "api.example.com")
        }
    }

    @Test func anErrorsDescriptionHasNoBodyNoURLAndNoIssueText() {
        let errors: [HTTPError] = [
            .status(500, excerpt: "SECRET-REPLY", retryAfter: nil, attempts: 2),
            .transport(.timedOut, attempts: 1),
            .timedOut(attempt: 3),
            .responseTooLarge(limit: 10, attempts: 1),
            .rejected(Rejection(.circuitOpen, label: "http api.example.com"), attempts: 0),
        ]
        for error in errors { #expect(!"\(error)".contains("SECRET")) }
        #expect("\(errors[0])" == "HTTP 500 after 2 attempts")
    }

    @Test func headersPrintedAnywhereAreRedacted() {
        let request = HTTPRequest(method: .get, target: .path("/a"), headers: ["Authorization": "Bearer SECRET-TOKEN"])
        #expect(!"\(request)".contains("SECRET-TOKEN"))
        #expect(!"\(request.headers)".contains("SECRET-TOKEN"))
        #expect(!String(reflecting: request.headers).contains("SECRET-TOKEN"))
    }

    @Test func anHTTPErrorClassifiesItselfLikeTheClientsPolicy() {
        #expect(HTTPError.status(503, excerpt: "", retryAfter: nil, attempts: 1).retryDecision == .retry)
        #expect(HTTPError.status(429, excerpt: "", retryAfter: .seconds(7), attempts: 1).retryDecision == .retryAfter(.seconds(7)))
        #expect(HTTPError.status(404, excerpt: "", retryAfter: nil, attempts: 1).retryDecision == .stop)
        #expect(HTTPError.status(501, excerpt: "", retryAfter: nil, attempts: 1).retryDecision == .stop)
        #expect(HTTPError.transport(.cannotConnectToHost, attempts: 1).retryDecision == .retry)
        #expect(HTTPError.transport(.serverCertificateUntrusted, attempts: 1).retryDecision == .stop)
        #expect(HTTPError.timedOut(attempt: 1).retryDecision == .retry)
        #expect(HTTPError.responseTooLarge(limit: 1, attempts: 1).retryDecision == .stop)
        #expect(HTTPError.rejected(Rejection(.circuitOpen, retryAfter: .seconds(9)), attempts: 0).retryDecision == .retryAfter(.seconds(9)))
        #expect(HTTPError.rejected(Rejection(.deadlineExceeded), attempts: 1).retryDecision == .stop)
        #expect(HTTPError.rejected(Rejection(.budgetExhausted), attempts: 1).retryDecision == .stop)
    }

    @Test func everyErrorSaysHowManyAttemptsWereMade() {
        #expect(HTTPError.timedOut(attempt: 2).attempts == 2)
        #expect(HTTPError.timedOut(attempt: 2).wasRetried)
        #expect(!HTTPError.transport(.timedOut, attempts: 1).wasRetried)
        #expect(HTTPError.rejected(Rejection(.circuitOpen), attempts: 0).attempts == 0)
    }
}

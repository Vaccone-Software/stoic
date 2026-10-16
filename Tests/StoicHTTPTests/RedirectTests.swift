import Foundation
import Stoic
@testable import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

/// The client follows redirects itself, so which headers go where, what
/// becomes of the method, and what is refused are its rules on every
/// platform.
@Suite("HTTP redirects")
struct HTTPRedirectTests {
    static let other = URL(string: "https://other.example.com/final")!
    static let defaults: HTTPHeaders = ["X-API-Key": "secret-key", "Authorization": "Bearer t"]

    static func redirect(_ status: Int = 302, to location: String) -> Step {
        .status(status, headers: ["Location": location])
    }

    static func names(_ headers: HTTPHeaders) -> [String] {
        headers.fields.map { $0.name.lowercased() }.sorted()
    }

    static func policy(maxRedirects: Int = 10, attempts: Int = 3) -> HTTPPolicy {
        var policy = HTTPPolicy.testing(attempts: attempts, coalesce: false)
        policy.maxRedirects = maxRedirects
        return policy
    }

    // MARK: Origins

    // Row: a redirect leads to another origin.
    @Test(.failureMode("design/19", "a redirect leads to another origin"))
    func aRedirectToAnotherOriginLeavesEveryCredentialBehind() async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            rig.transport.on(.get("/redirect"), respond: [Self.redirect(to: Self.other.absoluteString)])
            rig.transport.on(.get(Self.other), respond: [.status(200, body: "arrived")])
            let request = HTTPRequest.get("/redirect", headers: [
                "Cookie": "sid=1", "X-Session": "s", "Accept": "text/plain", "Accept-Language": "fr",
            ])
            let response = try await rig.start(request).value
            #expect(response.text == "arrived")

            let sent = rig.transport.requests
            #expect(sent.count == 2)
            #expect(sent[0].headers["X-API-Key"] == "secret-key", "the base URL's origin gets the client's headers")
            #expect(sent[1].url == Self.other)
            #expect(Self.names(sent[1].headers) == ["accept", "accept-language"], "the key, the token and the cookie stayed behind")
        }
    }

    @Test func aChangeOfPortOrSchemeIsAChangeOfOrigin() async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            let port = try #require(URL(string: "https://api.example.com:8443/new"))
            rig.transport.on(.get("/moved"), respond: [Self.redirect(301, to: port.absoluteString)])
            rig.transport.on(.get(port), respond: [.status(200)])
            _ = try await rig.start(.get("/moved")).value
            #expect(rig.sentHeaders.map { $0["X-API-Key"] } == ["secret-key", nil], "same host, another port")
        }

        // An upgrade from http to https is followed, but it is another origin too.
        let transport = ScriptedTransport()
        let base = try #require(URL(string: "http://local.example.com"))
        let secure = try #require(URL(string: "https://local.example.com/b"))
        transport.on(.get("/a"), respond: [Self.redirect(308, to: secure.absoluteString)])
        transport.on(.get(secure), respond: [.status(200)])
        let api = HTTPClient(base: base, policy: Self.policy(), transport: transport, headers: Self.defaults)
        _ = try await api.send(.get("/a"))
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer t", nil])
    }

    @Test func aRedirectWithinTheOriginKeepsEveryHeaderTheBodyAndTheKey() async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [Self.redirect(307, to: "/v2/orders")])
            rig.transport.on(.post("/v2/orders", json: [:]), respond: [.status(201)])
            let request = HTTPRequest.post("/orders", json: ["n": 1], headers: ["X-Session": "s"])
            let response = try await rig.start(request, key: IdempotencyKey(rawValue: "order-1")).value
            #expect(response.status == 201)

            let sent = rig.transport.requests
            #expect(sent.map(\.url?.path) == ["/orders", "/v2/orders"], "a relative Location is resolved against the request")
            #expect(sent[1].method == .post)
            #expect(sent[1].body == sent[0].body)
            #expect(Self.names(sent[1].headers) == Self.names(sent[0].headers))
            #expect(sent[1].headers["Idempotency-Key"] == "order-1")
            #expect(sent[1].headers["X-API-Key"] == "secret-key")
        }
    }

    @Test func thePortAnOriginImpliesIsTheSameOrigin() async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Self.redirect(to: "https://API.example.com:443/b")])
            rig.transport.on(.get("/b"), respond: [.status(200)])
            _ = try await rig.start(.get("/a")).value
            #expect(rig.sentHeaders.map { $0["X-API-Key"] } == ["secret-key", "secret-key"])
        }
    }

    @Test func aChainThatLeftTheBaseOriginNeverRegainsTheClientsHeaders() async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            let bounce = try #require(URL(string: "https://other.example.com/bounce"))
            rig.transport.on(.get("/start"), respond: [Self.redirect(to: bounce.absoluteString)])
            rig.transport.on(.get(bounce), respond: [Self.redirect(to: "https://api.example.com/admin/delete-everything")])
            rig.transport.on(.get("/admin/delete-everything"), respond: [.status(200)])
            _ = try await rig.start(.get("/start", headers: ["X-Session": "s"])).value
            let back = try #require(rig.transport.requests.last)
            #expect(back.url?.path == "/admin/delete-everything")
            #expect(back.headers.isEmpty, "a host the client was sent to cannot steer it into authenticated requests")
        }
    }

    @Test func aKeyedPostRedirectedToAnotherOriginGoesWithoutItsKeyAndIsNotRetriedThere() async throws {
        try await withRig(Self.policy(), headers: Self.defaults) { (rig) async throws in
            let elsewhere = try #require(URL(string: "https://other.example.com/inbox"))
            rig.transport.on(.post("/orders", json: [:]), respond: [Self.redirect(307, to: elsewhere.absoluteString)])
            rig.transport.on(HTTPRequest(method: .post, target: .url(elsewhere)), respond: [.status(503)])
            let error = await rig.httpError(of: rig.start(.post("/orders", json: ["n": 1]), key: IdempotencyKey(rawValue: "order-1")))
            #expect(error == .status(503, excerpt: "", retryAfter: nil, attempts: 2))
            let sent = rig.transport.requests
            #expect(sent.count == 2, "unkeyed there, so not repeated there")
            #expect(sent[1].body == sent[0].body)
            #expect(sent[1].headers["Idempotency-Key"] == nil)
            #expect(sent[1].idempotencyKey == nil)
            #expect(Self.names(sent[1].headers) == ["content-type"])
        }
    }

    // MARK: Refusals

    // Row: an https request is redirected to http.
    @Test(.failureMode("design/19", "an https request is redirected to http"))
    func aRedirectFromHTTPSToHTTPIsRefusedEvenToTheSameHost() async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            rig.transport.on(.get("/login"), respond: [Self.redirect(to: "http://api.example.com/login")])
            let error = await rig.httpError(of: rig.start(.get("/login")))
            #expect(error == .redirectRefused(.downgrade, status: 302, location: "http://api.example.com/login", attempts: 1))
            #expect(rig.transport.requestCount == 1, "nothing was sent in the clear")
            #expect(rig.events.count("http.redirected") == 0)
            #expect(rig.events.count("http.failed") == 1)
            #expect(error?.retryDecision == .stop)
            #expect(!"\(String(describing: error))".contains("login"), "the description never shows the Location")
        }
    }

    // Row: a redirect chain is longer than the limit.
    @Test(.failureMode("design/19", "a redirect chain is longer than the limit"))
    func aChainPastTheLimitIsRefusedAfterTheLimit() async throws {
        try await withRig(Self.policy(maxRedirects: 3)) { (rig) async throws in
            rig.transport.on(.get("/loop"), respond: [Self.redirect(to: "/loop")])
            let error = await rig.httpError(of: rig.start(.get("/loop")))
            #expect(error == .redirectRefused(.limit, status: 302, location: "/loop", attempts: 4))
            #expect(rig.transport.requestCount == 4, "the request and three redirects")
            #expect(rig.events.events(named: "http.redirected").map { $0.number("hop") } == [1, 2, 3])
        }
        #expect(HTTPPolicy.standard.maxRedirects == 10)
    }

    @Test func aLocationThatIsNotHTTPIsRefusedAndHandedToTheCaller() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/authorize"), respond: [Self.redirect(to: "myapp://callback?code=abc")])
            let error = await rig.httpError(of: rig.start(.get("/authorize")))
            #expect(error == .redirectRefused(.invalidLocation, status: 302, location: "myapp://callback?code=abc", attempts: 1))
            #expect(!"\(String(describing: error))".contains("abc"))
        }
    }

    @Test func noRedirectsFollowsNoneAndHandsBackTheFirst() async throws {
        try await withRig(Self.policy(maxRedirects: 0)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Self.redirect(303, to: "/b")])
            let error = await rig.httpError(of: rig.start(.get("/a")))
            #expect(error == .redirectRefused(.limit, status: 303, location: "/b", attempts: 1))
        }
    }

    @Test func aRedirectStatusWithoutALocationAndTheOtherThreeHundredsAreAnswers() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(302)])
            rig.transport.on(.get("/b"), respond: [.status(304, headers: ["Location": "/c"])])
            #expect(await rig.httpError(of: rig.start(.get("/a"))) == .status(302, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(await rig.httpError(of: rig.start(.get("/b"))) == .status(304, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(rig.transport.requestCount == 2)
        }
    }

    // MARK: Methods

    // Row: a POST is answered 301, 302 or 303.
    @Test(.failureMode("design/19", "a POST is answered 301, 302 or 303"), arguments: [301, 302, 303])
    func aPostAnswered301302Or303IsFollowedAsAGetWithoutItsBody(status: Int) async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [Self.redirect(status, to: "/orders/9")])
            rig.transport.on(.get("/orders/9"), respond: [.status(200)])
            _ = try await rig.start(.post("/orders", json: ["n": 1]), key: IdempotencyKey(rawValue: "order-1")).value
            let result = try #require(rig.transport.requests.last)
            #expect(result.method == .get)
            #expect(result.body == nil)
            #expect(Self.names(result.headers) == ["authorization", "x-api-key"], "no body headers, no key; still the client's own origin")
        }
    }

    @Test func otherMethodsFollowTheFetchRules() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(HTTPRequest(method: .head, target: .path("/a")), respond: [Self.redirect(303, to: "/b")])
            rig.transport.on(HTTPRequest(method: .head, target: .path("/b")), respond: [.status(200)])
            rig.transport.on(.put("/c", json: [:]), respond: [Self.redirect(302, to: "/d")])
            rig.transport.on(.put("/d", json: [:]), respond: [.status(204)])
            rig.transport.on(.delete("/e"), respond: [Self.redirect(303, to: "/f")])
            rig.transport.on(.get("/f"), respond: [.status(200)])
            _ = try await rig.start(HTTPRequest(method: .head, target: .path("/a"))).value
            _ = try await rig.start(.put("/c", json: ["v": 1])).value
            _ = try await rig.start(.delete("/e")).value
            let sent = rig.transport.requests
            #expect(sent.map(\.method) == [.head, .head, .put, .put, .delete, .get], "303 keeps a HEAD; 302 keeps a PUT; 303 turns the rest into GET")
            #expect(sent[3].body == sent[2].body)
        }
    }

    // Row: a request is redirected with 307 or 308.
    @Test(.failureMode("design/19", "a request is redirected with 307 or 308"), arguments: [307, 308])
    func a307Or308KeepsTheMethodAndTheBodyKeyedOrNot(status: Int) async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/upload", json: [:]), respond: [Self.redirect(status, to: "/uploads/new")])
            rig.transport.on(.post("/uploads/new", json: [:]), respond: [.status(201)])
            #expect(try await rig.start(.post("/upload", json: ["n": 1])).value.status == 201)
            let sent = rig.transport.requests
            #expect(sent.map(\.method) == [.post, .post])
            #expect(sent[1].body == sent[0].body)
            #expect(sent[1].headers["Content-Type"] == "application/json")
            #expect(rig.events.count("http.retry") == 0, "the server did not act on it, so this is not a repeat")
        }
    }

    // MARK: Bounds and policies

    // Row: the caller's deadline passes during a redirect chain.
    @Test(.failureMode("design/19", "the caller's deadline passes during a redirect chain"))
    func theCallersDeadlineSpansEveryHop() async throws {
        try await withRig(Self.policy()) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Self.redirect(to: "/b").after(.seconds(2))])
            rig.transport.on(.get("/b"), respond: [Step.status(200).after(.seconds(2))])
            let api = rig.api
            let task = Task { try await withTimeout(.seconds(3)) { try await api.send(.get("/a")) } }
            // The caller's deadline and the delay: a 10 s attempt timeout cannot narrow a 3 s deadline, so it sets no timer.
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(2))
            await eventually { rig.transport.requestCount == 2 }
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(1))
            let error = try #require(await rig.failure(of: task) as? HTTPError)
            #expect(error.rejection?.reason == .deadlineExceeded, "the second hop would have answered at 4 s")
            #expect(error.attempts == 2)
            #expect(rig.transport.abortedCount == 1)
        }
    }

    @Test func aHopIsNotARetry() async throws {
        try await withRig(Self.policy(attempts: 1)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Self.redirect(to: "/b")])
            rig.transport.on(.get("/b"), respond: [Self.redirect(to: "/c")])
            rig.transport.on(.get("/c"), respond: [.status(200)])
            _ = try await rig.start(.get("/a")).value
            #expect(rig.transport.requestCount == 3, "one attempt each: the hops used none of the schedule")
            #expect(rig.events.count("http.retry") == 0)
            let attempts = rig.events.events(named: "http.request")
            #expect(attempts.map { $0.number("attempt") } == [1, 2, 3])
            #expect(attempts.map { $0.text("outcome") } == ["redirect", "redirect", "ok"])
        }
    }

    @Test func eachHopIsRetriedOnItsOwnSchedule() async throws {
        try await withRig(Self.policy(attempts: 2)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Self.redirect(to: "/b")])
            rig.transport.on(.get("/b"), respond: [.status(503), .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
            #expect(rig.events.events(named: "http.retry").map { $0.text("reason") } == ["status_503"])
        }
    }

    @Test func aRedirectGoesThroughThePoliciesOfTheHostItLeadsTo() async throws {
        try await withRig(Self.policy(attempts: 1)) { (rig) async throws in
            let ping = try #require(URL(string: "https://other.example.com/ping"))
            rig.transport.on(.get(ping), respond: [.status(200)])
            rig.transport.on(.get("/a"), respond: [Self.redirect(to: Self.other.absoluteString)])
            _ = try await rig.start(.get(ping)).value
            try #require(rig.api.breaker(forHost: "other.example.com")).forceOpen()

            let error = try #require(await rig.httpError(of: rig.start(.get("/a"))))
            #expect(error.rejection?.reason == .circuitOpen, "the other host's breaker decides")
            #expect(error.attempts == 1)
            #expect(rig.transport.requests(to: .get(Self.other)).isEmpty)
            #expect(rig.api.breaker(forHost: "api.example.com")?.state == .closed, "a redirect is a healthy answer")
        }
    }

    @Test func aHopInTheBaseOriginCanReauthenticate() async throws {
        let hook = RenewalHook()
        try await withRig(headers: ["Authorization": "Bearer old"], reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.get("/old"), respond: [Self.redirect(301, to: "/new")])
            rig.transport.on(.get("/new"), respond: [.status(401), .status(200)])
            #expect(try await rig.start(.get("/old")).value.status == 200)
            #expect(rig.transport.requests.map(\.url?.path) == ["/old", "/new", "/new"])
            #expect(rig.sentHeaders.map { $0["Authorization"] } == ["Bearer old", "Bearer old", "Bearer new"])
            #expect(hook.started == 1)
        }
    }

    // MARK: Events

    @Test func theRedirectEventSaysWhereButNeverWithWhat() async throws {
        try await withRig(headers: Self.defaults) { (rig) async throws in
            let signed = "https://other.example.com/final?sig=SECRET-SIGNATURE"
            rig.transport.on(.get("/a"), respond: [Self.redirect(to: signed)])
            rig.transport.on(.get(Self.other), respond: [.status(200)])
            _ = try await rig.start(.get("/a", query: [URLQueryItem(name: "token", value: "SECRET-QUERY")])).value

            let redirected = try #require(rig.events.events(named: "http.redirected").first)
            #expect(redirected.level == .info)
            #expect(redirected.label == "http api.example.com")
            #expect(redirected.text("method") == "GET" && redirected.text("host") == "api.example.com" && redirected.text("path") == "/a")
            #expect(redirected.number("status") == 302 && redirected.number("hop") == 1)
            #expect(redirected.text("to_method") == "GET" && redirected.text("to_host") == "other.example.com")
            #expect(redirected.text("to_path") == "/final")
            if case .bool(let changed)? = redirected["origin_changed"] { #expect(changed) } else { Issue.record("no origin_changed") }
            for event in rig.events.events {
                for field in event.fields where field.description.contains("SECRET") || field.description.contains("secret-key") {
                    #expect(event.name == "http.request" && field.key == "query" && field.privacy == .private, "\(event)")
                }
            }
        }
    }
}

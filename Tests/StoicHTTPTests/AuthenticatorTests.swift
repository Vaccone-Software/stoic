import Foundation
import Stoic
@testable import StoicHTTP
import StoicJSON
import StoicTesting
import Synchronization
import Testing

/// An authenticator whose behaviour a test writes: what `prepare` does, the
/// verdicts `received` gives in turn, and a numbered signature per attempt.
final class ScriptedAuthenticator: HTTPAuthenticator {
    enum Preparing: Sendable {
        case immediately
        /// Waits on the ambient clock; gives up as `timed_out` at the
        /// caller's deadline, or `cancelled` when the caller leaves.
        case waiting(Duration, onlyFor: String? = nil)
        case failing(String)
    }

    private struct State {
        var prepared: [HTTPRequest] = []
        var authenticated: [HTTPRequest] = []
        var received: [(status: Int, request: HTTPRequest)] = []
        var verdicts: [HTTPAuthenticatorVerdict] = []
        var authenticateFailure: String?
    }

    private let state = Mutex(State())
    private let preparing: Preparing

    init(preparing: Preparing = .immediately, verdicts: [HTTPAuthenticatorVerdict] = [], authenticateFailure: String? = nil) {
        self.preparing = preparing
        state.withLock {
            $0.verdicts = verdicts
            $0.authenticateFailure = authenticateFailure
        }
    }

    var prepared: [HTTPRequest] { state.withLock { $0.prepared } }
    var authenticated: [HTTPRequest] { state.withLock { $0.authenticated } }
    var receivedStatuses: [Int] { state.withLock { $0.received.map(\.status) } }
    var receivedRequests: [HTTPRequest] { state.withLock { $0.received.map(\.request) } }

    static func error(_ code: String, _ decision: RetryDecision = .stop) -> HTTPAuthenticationError {
        HTTPAuthenticationError(scheme: "Test", code: code, retryDecision: decision)
    }

    func prepare(_ request: HTTPRequest) async throws(HTTPAuthenticationError) {
        state.withLock { $0.prepared.append(request) }
        switch preparing {
        case .immediately:
            return
        case .waiting(let delay, let path):
            if let path, request.url?.path != path { return }
            do {
                try await Ambient.sleep(for: delay)
            } catch {
                throw Self.error(Deadline.current?.hasPassed == true ? "timed_out" : "cancelled", .retry)
            }
        case .failing(let code):
            throw Self.error(code)
        }
    }

    func authenticate(_ request: HTTPRequest) async throws(HTTPAuthenticationError) -> HTTPHeaders {
        let (count, failure) = state.withLock { state -> (Int, String?) in
            state.authenticated.append(request)
            return (state.authenticated.count, state.authenticateFailure)
        }
        if let failure { throw Self.error(failure) }
        return ["X-Signature": "sig-\(count)", "Content-Digest": "digest-\(count)"]
    }

    func received(_ response: HTTPResponse, to request: HTTPRequest) async -> HTTPAuthenticatorVerdict {
        state.withLock { state in
            state.received.append((response.status, request))
            return state.verdicts.isEmpty ? .accept : state.verdicts.removeFirst()
        }
    }
}

/// A client with an authenticator, on a script and a test clock.
final class AuthenticatedRig: Sendable {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let transport = ScriptedTransport()
    let authenticator: ScriptedAuthenticator
    let renewals: RenewalHook
    let api: HTTPClient

    init(_ authenticator: ScriptedAuthenticator, policy: HTTPPolicy = .testing(), renewals: RenewalHook = RenewalHook()) {
        self.authenticator = authenticator
        self.renewals = renewals
        api = HTTPClient(
            base: apiBase, policy: policy, transport: transport, headers: ["Authorization": "Bearer old"],
            reauthenticate: { try await renewals.run() }, authenticator: authenticator)
    }

    func run<R>(_ body: (AuthenticatedRig) async throws -> R) async throws -> R {
        try await withTestAmbient(clock: clock, seed: 7, events: events) { () async throws -> R in try await body(self) }
    }

    func start(_ request: HTTPRequest, key: IdempotencyKey? = nil, overrides: HTTPOverrides = .none) -> Sending {
        let api = api
        return Task { try await api.send(request, idempotencyKey: key, overrides: overrides) }
    }

    /// Waits until the `count`-th failed attempt is waiting out its backoff:
    /// an attempt's own timeout is a sleeper too, so the event comes first.
    func waitForBackoff(_ count: Int) async {
        await eventually("backoff \(count) never began") { events.count("retry.attempt_failed") >= count }
        await clock.waitForSleepers(count: 1)
    }

    func outcome(of task: Sending) async -> Result<HTTPResponse, any Error> {
        do { return .success(try await task.value) } catch { return .failure(error) }
    }
}

@Suite("HTTP authenticator")
struct HTTPAuthenticatorTests {
    // MARK: Which attempts are authenticated

    @Test func everyAttemptIsAuthenticatedAfreshWithTheSameKey() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(503), .status(503), .status(201)])
            let key = IdempotencyKey(rawValue: "check-in-1")
            let task = rig.start(.post("/v1/check-ins", json: [:]), key: key)
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            #expect(try await task.value.status == 201)
        }
        let sent = rig.transport.requests
        #expect(sent.map { $0.headers["X-Signature"] } == ["sig-1", "sig-2", "sig-3"], "a new signature per attempt")
        #expect(Set(sent.map { $0.headers["Idempotency-Key"] }) == ["check-in-1"], "the same request")
        #expect(rig.authenticator.prepared.count == 1, "prepare is once per send of a hop, not per retry")
        #expect(rig.authenticator.receivedStatuses == [503, 503, 201], "every response, successes included")
        #expect(rig.authenticator.authenticated.allSatisfy { $0.headers["Authorization"] == "Bearer old" },
                "authenticate sees the request with the client's headers")
    }

    @Test func aSameOriginRedirectIsAuthenticatedForItsOwnPathAndMethod() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.post("/v1/orders", json: [:]), respond: [.status(303, headers: ["Location": "/v1/orders/7"])])
            rig.transport.on(.get("/v1/orders/7"), respond: [.json("{}")])
            #expect(try await rig.api.send(.post("/v1/orders", json: [:])).status == 200)
        }
        let signed = rig.authenticator.authenticated
        #expect(signed.map(\.method) == [.post, .get])
        #expect(signed.map { $0.url?.path } == ["/v1/orders", "/v1/orders/7"])
        #expect(signed.last?.body == nil, "a 303 is a GET without a body")
        #expect(rig.transport.requests.map { $0.headers["X-Signature"] } == ["sig-1", "sig-2"])
        #expect(rig.authenticator.prepared.count == 2, "each hop is prepared")
    }

    @Test func aRedirectToAnotherOriginCarriesNothingOfTheAuthenticator() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.post("/v1/upload", json: [:]),
                             respond: [.status(307, headers: ["Location": "https://cdn.example.net/put"])])
            rig.transport.on(HTTPRequest(method: .post, target: .url(URL(string: "https://cdn.example.net/put")!)), respond: [.status(201)])
            #expect(try await rig.api.send(.post("/v1/upload", json: [:]), idempotencyKey: IdempotencyKey(rawValue: "u1")).status == 201)
        }
        let hop = try #require(rig.transport.requests.last)
        #expect(hop.url?.host == "cdn.example.net")
        #expect(hop.headers["X-Signature"] == nil && hop.headers["Content-Digest"] == nil)
        #expect(hop.headers["Idempotency-Key"] == nil && hop.headers["Authorization"] == nil)
        #expect(rig.authenticator.authenticated.count == 1, "only the first hop")
        #expect(rig.authenticator.prepared.count == 1)
    }

    @Test func identicalGETsCoalesceIntoOneAuthenticatedFlight() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/events"), respond: [Step.json("[]").after(.seconds(1))])
            let tasks = (0..<3).map { _ in rig.start(.get("/v1/events")) }
            await eventually("every caller joined") { rig.api.coalescedWaiters(for: .get("/v1/events")) == 3 }
            await rig.clock.waitForSleepers(count: 1)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { #expect(try await task.value.status == 200) }
        }
        #expect(rig.transport.requestCount == 1)
        #expect(rig.authenticator.authenticated.count == 1)
    }

    @Test func aStreamedRequestIsAuthenticated() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/export"), respond: [.streaming(Array(repeating: 7, count: 64), chunkSize: 16)])
            let response = try await rig.api.stream(.get("/v1/export"), maxBytes: 1024)
            var total = 0
            while let chunk = try await response.body.read() { total += chunk.count }
            #expect(total == 64)
        }
        #expect(rig.transport.requests.first?.headers["X-Signature"] == "sig-1")
    }

    @Test func aCallThatTurnsItOffAndAnotherHostAreNotAuthenticated() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/health"), respond: [.status(204)])
            rig.transport.on(.get(URL(string: "https://elsewhere.example.org/x")!), respond: [.status(204)])
            _ = try await rig.api.send(.get("/v1/health"), overrides: HTTPOverrides(authenticate: false))
            _ = try await rig.api.send(.get(URL(string: "https://elsewhere.example.org/x")!))
        }
        #expect(rig.authenticator.prepared.isEmpty && rig.authenticator.authenticated.isEmpty)
        #expect(rig.authenticator.receivedStatuses.isEmpty)
        #expect(rig.transport.requests.allSatisfy { $0.headers["X-Signature"] == nil })
    }

    @Test func insideAPerformAttemptTheOneAttemptIsAuthenticated() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/feed"), respond: [.status(503), .json("[]")])
            let fetch = Backend.remote("http.authenticated").readOnly("feed")
            let api = rig.api
            let task: Sending = Task { try await fetch.perform { _ throws(any Error) in try await api.send(.get("/v1/feed")) } }
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
        }
        #expect(rig.transport.requests.map { $0.headers["X-Signature"] } == ["sig-1", "sig-2"], "each of the operation's attempts signed afresh")
    }

    // MARK: Waiting holds no slot

    @Test func aWaitInPrepareHoldsNoSlotOfTheHost() async throws {
        let rig = AuthenticatedRig(
            ScriptedAuthenticator(preparing: .waiting(.seconds(30), onlyFor: "/v1/slow")), policy: .testing(maxConcurrent: 1))
        try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/slow"), respond: [.status(204)])
            rig.transport.on(.get("/v1/fast"), respond: [.status(204)])
            let slow = rig.start(.get("/v1/slow"))
            await rig.clock.waitForSleepers(count: 1)
            // The host has one slot. The slow request is waiting in `prepare`,
            // so the fast one goes through at once.
            #expect(try await rig.api.send(.get("/v1/fast")).status == 204)
            #expect(rig.transport.requestCount == 1)
            await rig.clock.advance(by: .seconds(30))
            #expect(try await slow.value.status == 204)
        }
    }

    // MARK: Verdicts

    @Test func aReplayPreparesAuthenticatesAndSendsOnceMore() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator(verdicts: [.replay]))
        try await rig.run { (rig) async throws in
            rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(401), .status(201)])
            #expect(try await rig.api.send(.post("/v1/check-ins", json: [:])).status == 201)
        }
        #expect(rig.transport.requests.map { $0.headers["X-Signature"] } == ["sig-1", "sig-2"])
        #expect(rig.authenticator.prepared.count == 2)
        #expect(rig.renewals.started == 0, "the authenticator's 401 is not the reauthentication hook's")
    }

    @Test func aReplayIsOncePerHopAndTheSecondRefusalIsTheAnswer() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator(verdicts: [.replay, .replay, .replay]))
        let outcome = try await rig.run { (rig) async throws in
            rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(401), .status(401), .status(201)])
            return await rig.outcome(of: rig.start(.post("/v1/check-ins", json: [:])))
        }
        guard case .failure(let error as HTTPError) = outcome, case .status(401, _, _, _, let attempts) = error else {
            Issue.record("expected the second 401 as the answer: \(outcome)")
            return
        }
        #expect(attempts == 2, "a replay counts as an attempt")
        #expect(rig.transport.requestCount == 2)
        #expect(rig.renewals.started == 0, "a 401 the authenticator claimed never reaches the hook")
    }

    @Test func aRefusalFailsTheCallAndNeitherRetriesNorReauthenticates() async throws {
        let refusal = ScriptedAuthenticator.error("invalid")
        let rig = AuthenticatedRig(ScriptedAuthenticator(verdicts: [.refuse(refusal)]))
        let outcome = try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/events"), respond: [.status(401), .status(200)])
            return await rig.outcome(of: rig.start(.get("/v1/events")))
        }
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("not refused: \(outcome)"); return }
        #expect(error == .authenticationFailed(refusal, attempts: 1))
        #expect(error.retryDecision == .stop && !error.neverReachedBackend)
        #expect(error.description == "Test authentication failed: invalid after 1 attempt")
        #expect(rig.transport.requestCount == 1)
        #expect(rig.renewals.started == 0)
        #expect(rig.api.breaker(forHost: "api.example.com")?.snapshot.failures == 0, "a refusal says nothing about the host")
    }

    @Test func anAccepted401StillReachesTheReauthenticationHook() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator())
        try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/me"), respond: [.status(401), .json("{}")])
            #expect(try await rig.api.send(.get("/v1/me")).status == 200)
        }
        #expect(rig.renewals.started == 1)
        #expect(rig.transport.requests.last?.headers["Authorization"] == "Bearer new")
        #expect(rig.transport.requests.map { $0.headers["X-Signature"] } == ["sig-1", "sig-2"], "the replay is signed afresh")
    }

    // MARK: Failures before anything is sent

    @Test func aPrepareThatFailsSendsNothing() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator(preparing: .failing("unsupported")))
        let outcome = try await rig.run { (rig) async throws in
            rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(201)])
            return await rig.outcome(of: rig.start(.post("/v1/check-ins", json: [:])))
        }
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("not failed: \(outcome)"); return }
        #expect(error == .authenticationFailed(ScriptedAuthenticator.error("unsupported"), attempts: 0))
        #expect(error.neverReachedBackend)
        #expect(rig.transport.requestCount == 0)
        #expect(rig.events.count("http.failed") == 1)
    }

    @Test func anAuthenticateThatFailsSendsNothing() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator(authenticateFailure: "header_conflict"))
        let outcome = try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/events"), respond: [.status(200)])
            return await rig.outcome(of: rig.start(.get("/v1/events")))
        }
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("not failed: \(outcome)"); return }
        #expect(error == .authenticationFailed(ScriptedAuthenticator.error("header_conflict"), attempts: 0))
        #expect(error.neverReachedBackend)
        #expect(rig.transport.requestCount == 0)
        #expect(rig.events.count("http.request") == 0, "no attempt reached the transport")
    }

    @Test func aCallerCancelledWhilePreparingGetsCancellation() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator(preparing: .waiting(.seconds(60))))
        let outcome = try await rig.run { (rig) async throws in
            rig.transport.on(.get("/v1/events"), respond: [.status(200)])
            let task = rig.start(.get("/v1/events"))
            await rig.clock.waitForSleepers(count: 1)
            task.cancel()
            return await rig.outcome(of: task)
        }
        guard case .failure(let error) = outcome else { Issue.record("not cancelled"); return }
        #expect(error is CancellationError)
        #expect(rig.transport.requestCount == 0)
    }

    @Test func aDeadlineShorterThanTheWaitIsTheAuthenticatorsTimeout() async throws {
        let rig = AuthenticatedRig(ScriptedAuthenticator(preparing: .waiting(.seconds(60))))
        let outcome = try await rig.run { (rig) async throws in
            rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(201)])
            let api = rig.api
            let task: Sending = Task {
                try await withDeadline(Deadline.after(.seconds(5))) { () async throws -> HTTPResponse in
                    try await api.send(.post("/v1/check-ins", json: [:]))
                }
            }
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(5))
            return await rig.outcome(of: task)
        }
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("not timed out: \(outcome)"); return }
        #expect(error == .authenticationFailed(ScriptedAuthenticator.error("timed_out", .retry), attempts: 0))
        #expect(rig.transport.requestCount == 0, "nothing sent")
    }
}

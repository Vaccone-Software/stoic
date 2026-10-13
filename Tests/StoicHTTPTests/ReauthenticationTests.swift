import Foundation
import Stoic
@testable import StoicHTTP
import StoicJSON
import StoicTesting
import Synchronization
import Testing

/// Counts what a hook did, and holds it until the test lets it go.
final class RenewalHook: Sendable {
    private struct State {
        var started = 0
        var finished = 0
        var open: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>
    private let result: Result<HTTPHeaders, Failure>

    struct Failure: Error {}

    /// - Parameter held: Whether the hook waits for ``release()`` before it answers.
    init(held: Bool = false, result: Result<HTTPHeaders, Failure> = .success(["Authorization": "Bearer new"])) {
        state = Mutex(State(open: !held))
        self.result = result
    }

    var started: Int { state.withLock { $0.started } }
    var finished: Int { state.withLock { $0.finished } }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func run() async throws -> HTTPHeaders {
        state.withLock { $0.started += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        state.withLock { $0.finished += 1 }
        return try result.get()
    }
}

@Suite("HTTP reauthentication")
struct HTTPReauthenticationTests {
    private static let old: HTTPHeaders = ["Authorization": "Bearer old"]

    // Row: the server answers 401 and the client can reauthenticate.
    @Test(.failureMode("design/19", "the server answers 401 and the client can reauthenticate"))
    func a401RunsTheHookOnceAndTheRequestIsReplayedWithTheNewCredentials() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.get("/me"), respond: [.status(401), .json(#"{"id": 1}"#)])
            rig.transport.on(.get("/next"), respond: [.status(200)])
            let response = try await rig.start(.get("/me")).value
            #expect(response.status == 200)
            #expect(hook.started == 1)
            #expect(rig.sentHeaders.map { $0["Authorization"] } == ["Bearer old", "Bearer new"])
            #expect(rig.events.count("http.reauthenticated") == 1)
            #expect(rig.events.events(named: "http.retry").map { $0.text("reason") } == ["status_401"])

            // The renewed credentials are the client's from now on.
            _ = try await rig.start(.get("/next")).value
            #expect(rig.sentHeaders.last?["Authorization"] == "Bearer new")
            #expect(hook.started == 1)
        }
    }

    // Row: ten requests get 401 at once.
    @Test(.failureMode("design/19", "ten requests get 401 at once"))
    func concurrentRequestsRefusedTogetherShareOneRunOfTheHook() async throws {
        let hook = RenewalHook(held: true)
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            for index in 0..<10 { rig.transport.on(.get("/item/\(index)"), respond: [.status(401), .status(200)]) }
            let tasks = (0..<10).map { rig.start(.get("/item/\($0)")) }
            await eventually("every request waits on the renewal") { rig.api.renewalWaiters() == 10 }
            #expect(hook.started == 1)
            hook.release()
            for task in tasks { #expect(try await task.value.status == 200) }
            #expect(hook.started == 1, "one run, for ten requests")
            #expect(rig.transport.requestCount == 20)
            let replays = rig.transport.requests.suffix(10)
            #expect(replays.allSatisfy { $0.headers["Authorization"] == "Bearer new" })
        }
    }

    @Test func aRequestRefusedWithCredentialsThatWereRenewedMeanwhileReplaysWithoutTheHook() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.get("/slow"), respond: [Step.status(401).after(.seconds(5)), .status(200)])
            rig.transport.on(.get("/quick"), respond: [.status(401), .status(200)])
            let slow = rig.start(.get("/slow"))
            await eventually { rig.transport.inFlightCount == 1 }
            _ = try await rig.start(.get("/quick")).value
            #expect(hook.started == 1)
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(5))
            #expect(try await slow.value.status == 200)
            #expect(hook.started == 1, "the credentials were already new")
            #expect(rig.transport.requests(to: .get("/slow")).map { $0.headers["Authorization"] } == ["Bearer old", "Bearer new"])
        }
    }

    // Row: the reauthentication hook fails.
    @Test(.failureMode("design/19", "the reauthentication hook fails"))
    func aFailingHookIsATypedErrorAndTheRequestIsNotReplayed() async throws {
        let hook = RenewalHook(result: .failure(.init()))
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.get("/me"), respond: [.status(401), .status(200)])
            let error = await rig.httpError(of: rig.start(.get("/me")))
            #expect(error == .reauthenticationFailed(status: 401, attempts: 1))
            #expect(rig.transport.requestCount == 1)
            let event = try #require(rig.events.events(named: "http.reauthenticate_failed").first)
            #expect(event.text("error") == "Failure", "the type, never the text")

            // The failure is not remembered: the next 401 asks the hook again.
            rig.transport.on(.get("/again"), respond: [.status(401)])
            #expect(await rig.httpError(of: rig.start(.get("/again"))) == .reauthenticationFailed(status: 401, attempts: 1))
            #expect(hook.started == 2)
        }
    }

    // Row: the replayed request gets 401 too.
    @Test(.failureMode("design/19", "the replayed request gets 401 too"))
    func aSecond401IsTheAnswerAndTheHookRunsAtMostOncePerRequest() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.get("/forbidden"), respond: [.status(401, body: "no")])
            let error = await rig.httpError(of: rig.start(.get("/forbidden")))
            #expect(error == .status(401, excerpt: "no", retryAfter: nil, attempts: 2))
            #expect(hook.started == 1)
            #expect(rig.transport.requestCount == 2)
        }
    }

    @Test func anUnkeyedPostRefusedWith401IsReplayedWithTheSameBody() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [.status(401), .status(201)])
            let response = try await rig.start(.post("/orders", json: ["id": 1])).value
            #expect(response.status == 201, "a 401 means the server did not act on it")
            let sent = rig.transport.requests
            #expect(sent.count == 2)
            #expect(sent.map(\.body) == [Array(#"{"id":1}"#.utf8), Array(#"{"id":1}"#.utf8)])
            #expect(!sent.contains { $0.headers.contains("Idempotency-Key") })
        }
    }

    @Test func aKeyedRequestKeepsItsKeyOnTheReplay() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [.status(401), .status(201)])
            let key = IdempotencyKey.random()
            _ = try await rig.start(.post("/orders", json: [:]), key: key).value
            #expect(rig.sentHeaders.map { $0["Idempotency-Key"] } == [key.rawValue, key.rawValue])
        }
    }

    @Test func aRequestRefusedByAnotherHostIsNotTheClientsToRepair() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            let other = try #require(URL(string: "https://other.example.com/me"))
            rig.transport.on(.get(other), respond: [.status(401)])
            let error = await rig.httpError(of: rig.start(.get(other)))
            #expect(error == .status(401, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(hook.started == 0)
            #expect(rig.sentHeaders.allSatisfy { $0["Authorization"] == nil }, "the app's token never goes there")
        }
    }

    @Test func aCallCanOptOutSoThatTheHooksOwnRequestDoesNotTriggerIt() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.post("/token", json: [:]), respond: [.status(401)])
            let error = await rig.httpError(of: rig.start(.post("/token", json: [:]), overrides: HTTPOverrides(reauthenticate: false)))
            #expect(error == .status(401, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(hook.started == 0)
        }
    }

    @Test func aClientWithoutAHookReturnsThe401() async throws {
        try await withRig(headers: Self.old) { (rig) async throws in
            rig.transport.on(.get("/me"), respond: [.status(401)])
            #expect(await rig.httpError(of: rig.start(.get("/me"))) == .status(401, excerpt: "", retryAfter: nil, attempts: 1))
        }
    }

    @Test func requestHeadersStillWinOverTheRenewedOnes() async throws {
        let hook = RenewalHook()
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.get("/me"), respond: [.status(401), .status(200)])
            _ = try await rig.start(.get("/me", headers: ["Authorization": "Bearer special"])).value
            #expect(rig.sentHeaders.map { $0["Authorization"] } == ["Bearer special", "Bearer special"])
        }
    }

    @Test func aCallerCancelledWhileTheHookRunsIsCancelled() async throws {
        let hook = RenewalHook(held: true)
        try await withRig(headers: Self.old, reauthenticate: { try await hook.run() }) { (rig) async throws in
            rig.transport.on(.get("/me"), respond: [.status(401), .status(200)])
            let task = rig.start(.get("/me"))
            await eventually { hook.started == 1 }
            task.cancel()
            #expect(await rig.failure(of: task) is CancellationError)
            hook.release()
            await eventually { hook.finished == 1 }
            #expect(rig.transport.requestCount == 1, "the request was not replayed")
        }
    }
}

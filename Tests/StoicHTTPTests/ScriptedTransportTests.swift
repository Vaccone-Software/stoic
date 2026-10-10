import Foundation
import Stoic
import StoicHTTP
import StoicTesting
import Testing

@Suite("Scripted transport")
struct ScriptedTransportTests {
    static func request(_ path: String, method: HTTPMethod = .get, headers: HTTPHeaders = [:], query: [URLQueryItem] = []) -> HTTPRequest {
        HTTPRequest(method: method, target: .url(URL(string: "https://api.example.com\(path)")!), query: query, headers: headers)
    }

    static func send(_ transport: ScriptedTransport, _ request: HTTPRequest, limit: Int = 1_000_000) async throws -> HTTPResponse {
        try await transport.send(request, maxResponseBytes: limit)
    }

    @Test func stepsAreConsumedInOrderAndTheLastRepeats() async throws {
        let transport = ScriptedTransport()
        transport.on(.get("/a"), respond: [.status(503), .json(#"{"ok":true}"#)])
        let statuses = try await [
            Self.send(transport, Self.request("/a")).status,
            Self.send(transport, Self.request("/a")).status,
            Self.send(transport, Self.request("/a")).status,
        ]
        #expect(statuses == [503, 200, 200])
    }

    @Test func aFallbackAnswersOnceTheStepsRunOut() async throws {
        let transport = ScriptedTransport()
        transport.on(.get("/a"), respond: [.status(500)], then: .status(204))
        let statuses = try await [Self.send(transport, Self.request("/a")).status, Self.send(transport, Self.request("/a")).status]
        #expect(statuses == [500, 204])
    }

    @Test func routesAreIndependentAndMatchOnMethodAndPath() async throws {
        let transport = ScriptedTransport()
        transport.on(.get("/a"), respond: [.status(201)])
        transport.on(.delete("/a"), respond: [.status(202)])
        #expect(try await Self.send(transport, Self.request("/a", method: .delete)).status == 202)
        #expect(try await Self.send(transport, Self.request("/a")).status == 201)
    }

    @Test func aRouteWithAQueryOnlyMatchesThatQuery() async throws {
        let transport = ScriptedTransport()
        let page2 = [URLQueryItem(name: "page", value: "2")]
        transport.on(.get("/list", query: page2), respond: [.status(200, body: "two")])
        transport.on(.get("/list"), respond: [.status(200, body: "any")])
        #expect(try await Self.send(transport, Self.request("/list", query: page2)).text == "two")
        #expect(try await Self.send(transport, Self.request("/list")).text == "any")
    }

    @Test func everyRequestIsRecordedWithItsHeaders() async throws {
        let transport = ScriptedTransport()
        transport.on(.get("/a"), respond: [.status(200)])
        _ = try await Self.send(transport, Self.request("/a", headers: ["Authorization": "Bearer t", "X-Id": "1"]))
        _ = try await Self.send(transport, Self.request("/a"))
        #expect(transport.requestCount == 2)
        #expect(transport.requests[0].headers["authorization"] == "Bearer t")
        #expect(transport.requests(to: .get("/a")).count == 2)
        #expect(transport.requests(to: .get("/other")).isEmpty)
    }

    @Test func aRequestNoRouteMatchesIsA404AndListed() async throws {
        let transport = ScriptedTransport()
        transport.on(.get("/a"), respond: [.status(200)])
        let response = try await Self.send(transport, Self.request("/nowhere"))
        #expect(response.status == 404)
        #expect(transport.unscriptedRequests.map(\.description) == ["GET api.example.com/nowhere"])
    }

    @Test func aFailureStepThrowsTheURLError() async {
        let transport = ScriptedTransport()
        transport.on(.get("/a"), respond: [.failure(.notConnectedToInternet)])
        await #expect(throws: URLError.self) { try await Self.send(transport, Self.request("/a")) }
    }

    @Test func aDelayWaitsOnTheAmbientClock() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) { () async throws in
            let transport = ScriptedTransport()
            transport.on(.get("/slow"), respond: [Step.status(200).after(.seconds(5))])
            let task = Task { try await Self.send(transport, Self.request("/slow")) }
            await clock.waitForSleepers(count: 1)
            #expect(transport.inFlightCount == 1)
            await clock.advance(by: .seconds(4))
            #expect(transport.inFlightCount == 1)
            await clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
            #expect(transport.inFlightCount == 0)
            #expect(transport.maxInFlightCount == 1)
        }
    }

    @Test func aHangEndsWhenTheRequestIsCancelled() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) { () async throws in
            let transport = ScriptedTransport()
            transport.on(.get("/never"), respond: [.hang])
            let task = Task { try await Self.send(transport, Self.request("/never")) }
            await eventually { transport.inFlightCount == 1 }
            #expect(clock.sleeperCount == 0, "a hang waits on no clock")
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(transport.abortedCount == 1)
            #expect(transport.inFlightCount == 0)
        }
    }

    @Test func aBodyPastTheLimitIsAbortedWithoutBeingAllocated() async {
        let transport = ScriptedTransport()
        transport.on(.get("/huge"), respond: [.oversized(2_000_000_000)])
        transport.on(.get("/big"), respond: [.bytes([UInt8](repeating: 1, count: 101))])
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 100)) {
            try await Self.send(transport, Self.request("/huge"), limit: 100)
        }
        await #expect(throws: HTTPTransportError.responseTooLarge(limit: 100)) {
            try await Self.send(transport, Self.request("/big"), limit: 100)
        }
        #expect(transport.abortedCount == 2)
    }

    typealias Step = ScriptedTransport.Step
}

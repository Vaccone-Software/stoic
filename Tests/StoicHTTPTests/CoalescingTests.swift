import Foundation
import Stoic
import StoicHTTP
@testable import StoicHTTP
import StoicTesting
import Testing

@Suite("HTTP coalescing")
struct HTTPCoalescingTests {
    // Row: ten identical GETs at once.
    @Test(.failureMode("design/19", "ten identical GETs at once")) func tenIdenticalGetsMakeOneRequestAndGetTenResults() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/avatar/7"), respond: [Step.bytes([1, 2, 3]).after(.seconds(1))])
            let request = HTTPRequest.get("/avatar/7")
            let tasks = (0..<10).map { _ in rig.start(request) }
            await eventually("every caller joins the flight") { rig.api.coalescedWaiters(for: request) == 10 }
            await rig.clock.waitForSleepers(count: 2)   // the attempt's timer and the scripted delay
            await rig.clock.advance(by: .seconds(1))
            for task in tasks {
                #expect(try await task.value.body == [1, 2, 3])
            }
            #expect(rig.transport.requestCount == 1)
            #expect(rig.events.count("http.coalesced") == 9)
        }
    }

    @Test func requestsThatDifferInAHeaderThatVariesTheResponseAreNotShared() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/me"), respond: [Step.json("{}").after(.seconds(1))])
            let alice = HTTPRequest.get("/me", headers: ["Authorization": "Bearer alice"])
            let bob = HTTPRequest.get("/me", headers: ["authorization": "Bearer bob"])
            let tasks = [rig.start(alice), rig.start(alice), rig.start(bob)]
            await eventually("both of alice's calls join one flight") { rig.api.coalescedWaiters(for: alice) == 2 }
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 2, "one for each user")
            #expect(Set(rig.sentHeaders.compactMap { $0["Authorization"] }) == ["Bearer alice", "Bearer bob"])
        }
    }

    @Test func requestsThatDifferInTheirQueryAreNotShared() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/list"), respond: [Step.json("{}").after(.seconds(1))])
            let first = rig.start(.get("/list", query: [URLQueryItem(name: "page", value: "1")]))
            let second = rig.start(.get("/list", query: [URLQueryItem(name: "page", value: "2")]))
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            _ = try await first.value
            _ = try await second.value
            #expect(rig.transport.requestCount == 2)
        }
    }

    @Test func callersThatDifferOnlyInACustomHeaderAreNotShared() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Step.json("{}").after(.seconds(1))])
            let tasks = ["alice", "bob"].map { rig.start(.get("/a", headers: ["X-Auth-Token": $0])) }
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 2, "one for each token")
        }
    }

    @Test func identicalCallersWithACustomHeaderShareOneRequestWhateverTheCaseAndOrder() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Step.json("{}").after(.seconds(1))])
            let first = HTTPRequest.get("/a", headers: ["X-Auth-Token": "alice", "X-Trace": "t"])
            let second = HTTPRequest.get("/a", headers: ["x-trace": "t", "x-auth-token": "alice"])
            let tasks = [rig.start(first), rig.start(second), rig.start(first)]
            await eventually("every caller joins the flight") { rig.api.coalescedWaiters(for: first) == 3 }
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 1)
        }
    }

    @Test func aHeaderNamedInTheIgnoreListDoesNotSplitFlights() async throws {
        var policy = HTTPPolicy.testing()
        policy.ignoreHeadersForCoalescing = ["X-Request-Id"]
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Step.json("{}").after(.seconds(1))])
            let tasks = ["1", "2"].map { rig.start(.get("/a", headers: ["x-request-id": $0, "X-Auth-Token": "alice"])) }
            await eventually("both callers join the flight") {
                rig.api.coalescedWaiters(for: .get("/a", headers: ["X-Request-Id": "9", "X-Auth-Token": "alice"])) == 2
            }
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 1)
        }
    }

    @Test func getCoalescingIsOnByDefault() {
        #expect(HTTPPolicy.standard.coalesceGETs)
    }

    @Test func nothingIsSharedOnceTheFirstResponseHasLanded() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(200)])
            _ = try await rig.start(.get("/a")).value
            _ = try await rig.start(.get("/a")).value
            #expect(rig.transport.requestCount == 2, "deduplication, not a cache")
        }
    }

    @Test func onlyGetsAreCoalesced() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.delete("/a"), respond: [Step.status(204).after(.seconds(1))])
            let tasks = (0..<3).map { _ in rig.start(.delete("/a")) }
            await eventually { rig.transport.inFlightCount == 3 }
            await rig.clock.waitForSleepers(count: 6)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 3)
        }
    }

    @Test func coalescingCanBeTurnedOff() async throws {
        try await withRig(.testing(coalesce: false)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Step.status(200).after(.seconds(1))])
            let tasks = (0..<3).map { _ in rig.start(.get("/a")) }
            await eventually { rig.transport.inFlightCount == 3 }
            await rig.clock.waitForSleepers(count: 6)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 3)
        }
    }

    @Test func everyCallerSeesTheSharedFailureAndTheRetriesAreSharedToo() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503), .status(503), .status(503)])
            let request = HTTPRequest.get("/a")
            let tasks = (0..<4).map { _ in rig.start(request) }
            await eventually { rig.api.coalescedWaiters(for: request) == 4 }
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            for task in tasks {
                #expect(await rig.httpError(of: task) == .status(503, excerpt: "", retryAfter: nil, attempts: 3))
            }
            #expect(rig.transport.requestCount == 3, "three attempts for four callers")
        }
    }

    @Test func aCallerThatLeavesDoesNotCancelTheRequestOthersAreWaitingFor() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Step.status(200).after(.seconds(1))])
            let request = HTTPRequest.get("/a")
            let leaver = rig.start(request)
            let stayer = rig.start(request)
            await eventually { rig.api.coalescedWaiters(for: request) == 2 }
            leaver.cancel()
            #expect(await rig.failure(of: leaver) is CancellationError)
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await stayer.value.status == 200)
            #expect(rig.transport.abortedCount == 0)
            #expect(rig.transport.requestCount == 1)
        }
    }

    @Test func theLastCallerLeavingCancelsTheRequest() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.hang])
            let task = rig.start(.get("/a"))
            await rig.waitForHangingAttempt()
            task.cancel()
            #expect(await rig.failure(of: task) is CancellationError)
            await eventually { rig.transport.abortedCount == 1 }
        }
    }

    @Test func aCallerWithMoreTimeThanTheStarterIsNotGivenTheStartersTimeout() async throws {
        try await withRig(.testing(timeout: .seconds(60))) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Step.status(200).after(.seconds(5)), .status(200)])
            let request = HTTPRequest.get("/a")
            let api = rig.api
            let hurried = Task { try await withTimeout(.seconds(2)) { try await api.send(request) } }
            await eventually { rig.api.coalescedWaiters(for: request) == 1 }
            let patient = Task { try await withTimeout(.seconds(30)) { try await api.send(request) } }
            await eventually { rig.api.coalescedWaiters(for: request) == 2 }
            // The attempt's 60 s timeout narrows neither caller's deadline, so it starts no timer.
            await eventually { rig.clock.sleeperCount >= 6 }
            await rig.clock.advance(by: .seconds(2))
            #expect(await rig.failure(of: hurried) is HTTPError)
            // The patient caller starts a flight of its own, which the second step answers at once.
            await eventually { rig.transport.requestCount == 2 }
            #expect(try await patient.value.status == 200)
        }
    }
}

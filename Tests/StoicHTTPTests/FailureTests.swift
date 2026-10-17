import Foundation
import Stoic
import StoicHTTP
@testable import StoicHTTP
import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// Failure-mode rows of design/19 about what the client reports and what it
/// refuses to do: statuses, the breaker, the bulkhead, the size limit,
/// decoding and cancellation.
@Suite("HTTP failures")
struct HTTPFailureTests {
    static let breakerAfterFour = CircuitBreaker.Configuration(minimumCalls: 4, failureRateThreshold: 0.5)

    // Row: the server says 404.
    @Test(.failureMode("design/19", "the server says 404")) func a404IsFinalAndTheBreakerDoesNotCountIt() async throws {
        try await withRig(.testing(breaker: Self.breakerAfterFour)) { (rig) async throws in
            rig.transport.on(.get("/missing"), respond: [.status(404, body: "no such user")])
            for _ in 0..<10 {
                #expect(await rig.httpError(of: rig.start(.get("/missing"))) == .status(404, excerpt: "no such user", retryAfter: nil, attempts: 1))
            }
            #expect(rig.transport.requestCount == 10, "one attempt each")
            let breaker = try #require(rig.api.breaker(forHost: "api.example.com"))
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 10)
            #expect(breaker.snapshot.failures == 0)
            #expect(rig.events.count("http.retry") == 0)
        }
    }

    @Test func theErrorBodyExcerptIsBounded() async throws {
        var policy = HTTPPolicy.testing()
        policy.errorExcerptBytes = 4
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(422, body: "unprocessable entity")])
            let error = await rig.httpError(of: rig.start(.get("/a")))
            #expect(error == .status(422, excerpt: "unpr", retryAfter: nil, attempts: 1))
        }
    }

    // Row: the host keeps failing.
    @Test(.failureMode("design/19", "the host keeps failing")) func aHostThatKeepsFailingOpensTheBreakerAndCallsFailFast() async throws {
        try await withRig(.testing(attempts: 1, breaker: Self.breakerAfterFour)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(500)])
            for _ in 0..<4 { _ = await rig.httpError(of: rig.start(.get("/a"))) }
            let breaker = try #require(rig.api.breaker(forHost: "api.example.com"))
            #expect(breaker.state == .open)
            let error = try #require(await rig.httpError(of: rig.start(.get("/a"))))
            let rejection = try #require(error.rejection)
            #expect(rejection.reason == .circuitOpen)
            #expect(rejection.retryAfter != nil)
            #expect(error.attempts == 0, "never sent")
            #expect(rig.transport.requestCount == 4)
            #expect(rig.events.count("breaker.opened") == 1)
        }
    }

    @Test func anOpenBreakerEndsTheRetriesInsteadOfWaitingItOut() async throws {
        try await withRig(.testing(attempts: 3, breaker: Self.breakerAfterFour)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(500)])
            // Three failures in the first call, a fourth opens the breaker in the second.
            for call in 1...2 {
                let task = rig.start(.get("/a"))
                await rig.waitForBackoff((call - 1) * 2 + 1)
                await rig.clock.advance(by: .seconds(1))
                if call == 1 {
                    await rig.waitForBackoff(2)
                    await rig.clock.advance(by: .seconds(2))
                }
                let error = try #require(await rig.httpError(of: task))
                if call == 1 {
                    #expect(error == .status(500, excerpt: "", retryAfter: nil, attempts: 3))
                } else {
                    #expect(error.rejection?.reason == .circuitOpen)
                    #expect(error.attempts == 1, "the first attempt opened it; the retry was refused, not waited for")
                }
            }
            #expect(rig.transport.requestCount == 4)
        }
    }

    @Test func serverErrorsTransportFailuresAndTimeoutsCountAgainstTheHost() async throws {
        for (name, failing, hangs) in [("transport", Step.failure(.cannotConnectToHost), false), ("5xx", .status(502), false), ("timeout", .hang, true)] {
            try await withRig(.testing(attempts: 1, breaker: Self.breakerAfterFour)) { (rig) async throws in
                rig.transport.on(.get("/a"), respond: [failing])
                for _ in 0..<4 {
                    let task = rig.start(.get("/a"))
                    if hangs {
                        await rig.waitForHangingAttempt()
                        await rig.clock.advance(by: .seconds(10))
                    }
                    _ = await rig.httpError(of: task)
                }
                #expect(rig.api.breaker(forHost: "api.example.com")?.state == .open, "\(name)")
            }
        }
    }

    @Test func beingOfflineDoesNotCountAgainstTheHost() async throws {
        try await withRig(.testing(attempts: 1, breaker: Self.breakerAfterFour)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.failure(.notConnectedToInternet)])
            for _ in 0..<8 {
                #expect(await rig.httpError(of: rig.start(.get("/a"))) == .transport(.notConnectedToInternet, attempts: 1))
            }
            #expect(rig.api.breaker(forHost: "api.example.com")?.state == .closed)
        }
    }

    @Test func theBreakerClosesAgainWhenAProbeSucceeds() async throws {
        try await withRig(.testing(attempts: 1, breaker: Self.breakerAfterFour)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(500)])
            for _ in 0..<4 { _ = await rig.httpError(of: rig.start(.get("/a"))) }
            let breaker = try #require(rig.api.breaker(forHost: "api.example.com"))
            #expect(breaker.state == .open)
            await rig.clock.advance(by: .seconds(31))
            #expect(breaker.state == .halfOpen)
            rig.transport.on(.get("/a"), respond: [.status(200)])
            let task = rig.start(.get("/a"))
            #expect(try await task.value.status == 200)
            #expect(breaker.state == .closed)
        }
    }

    @Test func eachHostHasItsOwnBreakerAndBulkhead() async throws {
        try await withRig(.testing(attempts: 1, breaker: Self.breakerAfterFour)) { (rig) async throws in
            let bad = URL(string: "https://bad.example.com/a")!
            rig.transport.on(.get(bad), respond: [.status(500)])
            rig.transport.on(.get("/a"), respond: [.status(200)])
            for _ in 0..<4 { _ = await rig.httpError(of: rig.start(.get(bad))) }
            #expect(rig.api.breaker(forHost: "bad.example.com")?.state == .open)
            #expect(try await rig.start(.get("/a")).value.status == 200, "the healthy host is untouched")
            let good = try #require(rig.api.breaker(forHost: "api.example.com"))
            let other = try #require(rig.api.breaker(forHost: "bad.example.com"))
            #expect(good !== other)
            let goodBulkhead = rig.api.bulkhead(forHost: "api.example.com")
            let otherBulkhead = rig.api.bulkhead(forHost: "bad.example.com")
            #expect(goodBulkhead != nil && goodBulkhead !== otherBulkhead)
        }
    }

    // Bulkhead: at most N in flight to one host, the next waits, then is refused.
    @Test func atMostTheConfiguredRequestsAreInFlightToOneHost() async throws {
        try await withRig(.testing(maxConcurrent: 2, queueLimit: 1, coalesce: false)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [Step.status(200).after(.seconds(5))])
            let first = rig.start(.get("/a"))
            let second = rig.start(.get("/a"))
            await eventually { rig.transport.inFlightCount == 2 }
            let queued = rig.start(.get("/a"))
            let bulkhead = try #require(rig.api.bulkhead(forHost: "api.example.com"))
            await eventually { bulkhead.queuedCount == 1 }

            let refused = try #require(await rig.httpError(of: rig.start(.get("/a"))))
            #expect(refused.rejection?.reason == .bulkheadFull)
            #expect(refused.attempts == 0)

            await rig.clock.waitForSleepers(count: 4)   // each request's attempt timer and scripted delay
            await rig.clock.advance(by: .seconds(5))
            #expect(try await first.value.status == 200)
            #expect(try await second.value.status == 200)
            await eventually { rig.transport.requestCount == 3 }
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(5))
            #expect(try await queued.value.status == 200)
            #expect(rig.transport.maxInFlightCount == 2)
            #expect(rig.transport.requestCount == 3)
        }
    }

    // Row: the response is 2 GB.
    @Test(.failureMode("design/19", "the response is 2 GB")) func aResponseOverTheLimitIsCutAndNeverRetried() async throws {
        try await withRig(.testing(maxResponseBytes: 1000)) { (rig) async throws in
            rig.transport.on(.get("/huge"), respond: [.oversized(2_000_000_000)])
            let error = await rig.httpError(of: rig.start(.get("/huge")))
            #expect(error == .responseTooLarge(limit: 1000, attempts: 1))
            #expect(rig.transport.requestCount == 1)
            #expect(rig.transport.abortedCount == 1, "the connection was cancelled")
            #expect(rig.events.count("http.response_too_large") == 1)
            #expect(rig.api.breaker(forHost: "api.example.com")?.snapshot.failures == 0)
        }
    }

    @Test func aTransportThatIgnoresTheLimitIsStillBounded() async throws {
        let bytes = [UInt8](repeating: 1, count: 1001)
        try await withRig(.testing(maxResponseBytes: 1000)) { (rig) async throws in
            let transport = IgnoresLimit(response: HTTPResponse(status: 200, body: bytes))
            let api = HTTPClient(base: apiBase, policy: .testing(maxResponseBytes: 1000), transport: transport)
            let error = await #expect(throws: HTTPError.self) { try await api.send(.get("/a")) }
            #expect(error == .responseTooLarge(limit: 1000, attempts: 1))
        }
    }

    // Row: the body does not match the schema.
    @Test(.failureMode("design/19", "the body does not match the schema")) func aBodyThatDoesNotMatchIsADecodingErrorWithEveryIssueAndIsNotRetried() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/users/1"), respond: [.json(#"{"id": 0, "name": 5}"#)])
            let api = rig.api
            let error = await #expect(throws: HTTPError.self) { try await api.send(.get("/users/1"), decoding: User.schema) }
            guard case .decoding(let failure, let attempts)? = error else {
                Issue.record("expected a decoding error, got \(String(describing: error))")
                return
            }
            #expect(attempts == 1)
            #expect(failure.errors.count == 2, "both fields, not the first: \(failure)")
            #expect(rig.transport.requestCount == 1)
            #expect(rig.events.count("http.decoding_failed") == 1)
            let reported = try #require(rig.events.events(named: "http.decoding_failed").first)
            #expect(reported.number("errors") == 2)
            #expect(reported.level == .notice)
            #expect(reported.label == "http api.example.com")
            #expect(reported.text("method") == "GET" && reported.text("host") == "api.example.com" && reported.text("path") == "/users/1")
            #expect(rig.events.count("retry.attempt_failed") == 0)
        }
    }

    @Test func aMatchingBodyDecodesAndAsksForJSON() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/users/42"), respond: [.json(#"{"id": 42, "name": "Ada"}"#)])
            let user = try await rig.api.send(.get("/users/42"), decoding: User.schema)
            #expect(user == User(id: 42, name: "Ada"))
            #expect(rig.sentHeaders.first?["Accept"] == "application/json")
        }
    }

    @Test func aFieldTheServerAddsDoesNotBreakDecoding() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/users/42"), respond: [.json(#"{"id": 42, "name": "Ada", "plan": "pro", "flags": [1, 2]}"#)])
            let user = try await rig.api.send(.get("/users/42"), decoding: User.schema)
            #expect(user == User(id: 42, name: "Ada"))
        }
    }

    // Row: the body decodes with warnings or repairs.
    @Test(.failureMode("design/19", "the body decodes with warnings or repairs")) func aDecodeThatSucceededWithWarningsIsReportedWithoutItsValues() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/users/42"), respond: [.json(#"{"id": 42, "name": "Ada", "s3cret-key": "s3cret-value"}"#)])
            let user = try await rig.api.send(.get("/users/42"), decoding: User.schema)
            #expect(user == User(id: 42, name: "Ada"), "the value still goes to the caller")
            let reported = rig.events.events(named: "http.decoded_with_warnings")
            let event = try #require(reported.first)
            #expect(reported.count == 1)
            #expect(event.level == .warning)
            #expect(event.label == "http api.example.com")
            #expect(event.text("method") == "GET" && event.text("host") == "api.example.com" && event.text("path") == "/users/42")
            #expect(event.number("warnings") == 1)
            #expect(event.number("repairs") == 0)
            #expect(event.text("codes") == "unknown_key")
            #expect(event.fields.first { $0.key == "codes" }?.privacy == .public)
            #expect(event.text("paths") == "$.s3cret-key" || event.text("paths") == #"$["s3cret-key"]"#, "\(event)")
            #expect(event.fields.first { $0.key == "paths" }?.privacy == .private, "a path can name a key the server chose")
            #expect(!event.fields.contains { $0.description.contains("s3cret-value") || $0.description.contains("Ada") }, "no value, no body: \(event)")
            #expect(rig.events.count("http.decoding_failed") == 0)
        }
    }

    @Test func theDecodingEventsNameTheRequestThatAnsweredAfterARedirect() async throws {
        try await withRig { (rig) async throws in
            let cdn = "https://cdn.example.com/profiles"
            rig.transport.on(.get("/users/1"), respond: [.status(302, headers: ["Location": "\(cdn)/1"])])
            rig.transport.on(.get("/users/2"), respond: [.status(302, headers: ["Location": "\(cdn)/2"])])
            rig.transport.on(.get(URL(string: "\(cdn)/1")!), respond: [.json(#"{"id": 0, "name": 5}"#)])
            rig.transport.on(.get(URL(string: "\(cdn)/2")!), respond: [.json(#"{"id": 2, "name": "Grace", "plan": "pro"}"#)])
            _ = await #expect(throws: HTTPError.self) { try await rig.api.send(.get("/users/1"), decoding: User.schema) }
            _ = try await rig.api.send(.get("/users/2"), decoding: User.schema)
            let failed = try #require(rig.events.events(named: "http.decoding_failed").first)
            let warned = try #require(rig.events.events(named: "http.decoded_with_warnings").first)
            for (event, path) in [(failed, "/profiles/1"), (warned, "/profiles/2")] {
                #expect(event.label == "http cdn.example.com", "\(event.name): the hop that answered")
                #expect(event.text("method") == "GET" && event.text("host") == "cdn.example.com" && event.text("path") == path, "\(event.name)")
            }
        }
    }

    @Test func aRepairIsCountedAndACleanDecodeSaysNothing() async throws {
        var policy = HTTPPolicy.testing()
        policy.decodeOptions = .lenient
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/users/1"), respond: [.json(#"{"id": 7, "name": 5}"#)])
            rig.transport.on(.get("/users/2"), respond: [.json(#"{"id": 2, "name": "Grace"}"#)])
            _ = try await rig.api.send(.get("/users/1"), decoding: User.schema)
            let event = try #require(rig.events.events(named: "http.decoded_with_warnings").first)
            #expect(event.number("warnings") == 0)
            #expect(event.number("repairs") == 1)
            #expect(event.text("path") == "/users/1")
            _ = try await rig.api.send(.get("/users/2"), decoding: User.schema)
            #expect(rig.events.count("http.decoded_with_warnings") == 1, "a clean decode records nothing")
        }
    }

    @Test func aResponseWithinTheCapDecodesEvenWhenItIsOverTheParsersDefaultLimit() async throws {
        let chunk = String(repeating: "x", count: 900_000)
        let pad = Array(repeating: "\"\(chunk)\"", count: 10).joined(separator: ",")
        let body = Array(#"{"id": 3, "name": "Ada", "pad": [\#(pad)]}"#.utf8)
        #expect(body.count > JSONParseOptions.strict.maxBytes, "the premise: over 8 MiB")
        try await withRig(.testing(maxResponseBytes: 10_000_000)) { (rig) async throws in
            rig.transport.on(.get("/big"), respond: [.bytes(body)])
            let user = try await rig.api.send(.get("/big"), decoding: User.schema)
            #expect(user == User(id: 3, name: "Ada"))
        }
    }

    @Test func aResponseOverTheCapNeverReachesTheDecoder() async throws {
        try await withRig(.testing(maxResponseBytes: 1000)) { (rig) async throws in
            rig.transport.on(.get("/big"), respond: [.oversized(5000)])
            let error = await #expect(throws: HTTPError.self) { try await rig.api.send(.get("/big"), decoding: User.schema) }
            #expect(error == .responseTooLarge(limit: 1000, attempts: 1))
        }
    }

    @Test func decodeOptionsSetOnThePolicyApplyToEveryCallAndACallCanOverrideThem() async throws {
        var policy = HTTPPolicy.testing()
        policy.decodeOptions = .lenient
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/users/1"), respond: [.json(#"{"id": 7, "name": 5}"#)])
            let repaired = try await rig.api.send(.get("/users/1"), decoding: User.schema)
            #expect(repaired == User(id: 7, name: ""), "the policy's lenient mode repaired the field")
            let error = await #expect(throws: HTTPError.self) {
                try await rig.api.send(.get("/users/1"), decoding: User.schema, options: .strict)
            }
            guard case .decoding? = error else {
                Issue.record("the per-call strict options should have failed the decode, got \(String(describing: error))")
                return
            }
        }
    }

    @Test func anErrorStatusIsNotADecodingAttempt() async throws {
        try await withRig(.testing(attempts: 1)) { (rig) async throws in
            rig.transport.on(.get("/users/42"), respond: [.status(404)])
            let error = await #expect(throws: HTTPError.self) { try await rig.api.send(.get("/users/42"), decoding: User.schema) }
            #expect(error?.statusCode == 404)
        }
    }

    // Row: the caller is cancelled.
    @Test(.failureMode("design/19", "the caller is cancelled")) func cancellingTheCallerCancelsTheRequestAndThrowsCancellationError() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.hang])
            let task = rig.start(.get("/a"))
            await rig.waitForHangingAttempt()
            task.cancel()
            let error = await rig.failure(of: task)
            #expect(error is CancellationError)
            await eventually { rig.transport.abortedCount == 1 }
            #expect(rig.transport.requestCount == 1, "a cancelled request is not retried")
            #expect(rig.events.count("http.failed") == 0)
            #expect(rig.api.breaker(forHost: "api.example.com")?.snapshot.calls == 0, "the caller's cancellation says nothing about the host")
        }
    }

    @Test func cancellingDuringABackoffStopsTheRetries() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            task.cancel()
            #expect(await rig.failure(of: task) is CancellationError)
            #expect(rig.transport.requestCount == 1)
        }
    }

    @Test func aStatusErrorCarriesTheServersRetryAfterAsSent() async throws {
        try await withRig(.testing(attempts: 1)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(429, headers: ["Retry-After": "120"])])
            #expect(await rig.httpError(of: rig.start(.get("/a"))) == .status(429, excerpt: "", retryAfter: .seconds(120), attempts: 1))
        }
    }

    @Test func aBusyHostsBreakerOutlivesMoreThanTheLimitOfOtherHosts() async throws {
        try await withRig(.testing(attempts: 1)) { (rig) async throws in
            rig.transport.on(.get("/ping"), respond: [], then: .status(200))
            rig.transport.on(.get("/hot"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/hot")).value
            let hot = try #require(rig.api.breaker(forHost: "api.example.com"))
            hot.forceOpen()
            for index in 0..<(HostTable.limit + 100) {
                if index % 100 == 0 { _ = await rig.httpError(of: rig.start(.get("/hot"))) }   // still in use
                let other = try #require(URL(string: "https://host\(index).example.com/ping"))
                _ = try await rig.start(.get(other)).value
            }
            let error = try #require(await rig.httpError(of: rig.start(.get("/hot"))))
            #expect(error.rejection?.reason == .circuitOpen, "the hot host was not forgotten")
            #expect(rig.api.breaker(forHost: "api.example.com") === hot)
        }
    }

    @Test func aHostWithARequestInFlightIsNeverForgotten() async throws {
        try await withRig(.testing(attempts: 1, maxConcurrent: 1, queueLimit: 0, coalesce: false)) { (rig) async throws in
            rig.transport.on(.get("/slow"), respond: [.hang])
            rig.transport.on(.get("/ping"), respond: [], then: .status(200))
            let slow = rig.start(.get("/slow"))
            await rig.waitForHangingAttempt()
            let bulkhead = try #require(rig.api.bulkhead(forHost: "api.example.com"))
            for index in 0..<(HostTable.limit + 100) {
                let other = try #require(URL(string: "https://host\(index).example.com/ping"))
                _ = try await rig.start(.get(other)).value
            }
            #expect(rig.api.bulkhead(forHost: "api.example.com") === bulkhead, "the least recently used host was in use")
            #expect(rig.api.hostCount == HostTable.limit)

            // Its one slot is still taken: a fresh bulkhead would have let this through.
            let second = try #require(await rig.httpError(of: rig.start(.get("/slow"))))
            #expect(second.rejection?.reason == .bulkheadFull)
            #expect(rig.transport.requests(to: .get("/slow")).count == 1)
            slow.cancel()
            _ = await rig.failure(of: slow)
        }
    }

    @Test func hostsInUseMayHoldTheTableOverItsLimitUntilTheirRequestsEnd() {
        var table = HostTable()
        let keys = (0...HostTable.limit).map { "host\($0)" }
        for key in keys { _ = table.lease(key) { HostState(label: key, breaker: nil, limiter: nil, bulkhead: nil) } }
        #expect(table.count == HostTable.limit + 1, "every host is in use, so none is forgotten")
        table.release(keys[5])
        #expect(table.count == HostTable.limit)
        #expect(table.existing(keys[5]) == nil, "the idle one went")
        #expect(table.existing(keys[0]) != nil, "older, but still in use")
        let again = table.lease(keys[0]) { HostState(label: "fresh", breaker: nil, limiter: nil, bulkhead: nil) }
        #expect(again.label == "host0", "a host in the table is reused, not made again")
    }
}

/// A transport that returns its response whatever limit it is given.
struct IgnoresLimit: HTTPTransport {
    let response: HTTPResponse
    func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse { response }
}

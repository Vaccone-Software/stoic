public import Foundation
public import Stoic
public import StoicSchema
internal import Synchronization

/// A client for one API, with the resilience a careful team would write by
/// hand and rarely does.
///
///     let api = HTTPClient(base: URL(string: "https://api.example.com")!)
///     let user = try await api.send(.get("/users/42"), decoding: User.schema)
///     try await api.send(.post("/orders", json: order.encoded), idempotencyKey: order.key)
///
/// Every request goes through, for its host and in this order: the caller's
/// deadline, retry, a circuit breaker, a rate limit (if the policy has one), a
/// bulkhead, a timeout for the attempt, the transport (design/19). The
/// breaker, rate limit and bulkhead are kept by the client, one set per host,
/// so a dead host cannot use up the app's connections or slow the healthy
/// ones.
///
/// - Only what is safe to repeat is repeated: `GET`, `HEAD`, `OPTIONS`,
///   `PUT` and `DELETE`, and `POST` or `PATCH` carrying an idempotency key,
///   sent as `Idempotency-Key`, the same on every attempt.
/// - A retry inside another retry's attempt makes one attempt (the default
///   of Stoic's `retry`): whoever retries around the client owns the retrying.
/// - Cancelling the caller cancels the request and throws
///   `CancellationError`; the caller's deadline is honoured at every stage,
///   and a wait that would outlast it is not started.
/// - The breaker and bulkhead measure time on the ambient clock in force when
///   a host is first used, like every Stoic breaker.
public final class HTTPClient: Sendable {
    /// Requests with a path are resolved against this URL. Its own path is
    /// kept: a base of `https://example.com/v1` and a path of `/users` is
    /// `https://example.com/v1/users`.
    public let base: URL
    public let policy: HTTPPolicy
    /// Names the client in events, as `"<label> <host>"`.
    public let label: String

    private let transport: any HTTPTransport
    private let defaultHeaders: HTTPHeaders
    private let hosts = Mutex(HostTable())
    private let flights: SingleFlight<FlightKey, Delivered, FlightFailure>
    private let reauthenticate: (@Sendable () async throws -> HTTPHeaders)?
    private let credentials = Mutex(Credentials())
    private let refreshes: SingleFlight<Int, Void, ReauthenticationFailure>

    /// - Parameters:
    ///   - base: The API's URL.
    ///   - policy: The resilience settings; ``HTTPPolicy/standard`` by default.
    ///   - transport: How requests reach the network; a ``URLSessionTransport``
    ///     by default, a ``ScriptedTransport`` in tests.
    ///   - headers: Sent with every request to the base URL's host (and
    ///     only to it: an absolute URL on another host never receives them,
    ///     so a token cannot leak to a host the caller merely linked to).
    ///   - label: Names the client in events.
    ///   - reauthenticate: Runs when a request to the base URL's origin is
    ///     answered `401`, and returns the headers to send from then on (a new
    ///     `Authorization`), which replace the same-named ones in `headers`.
    ///     The request is then sent once more with them; if that is `401`
    ///     too, the `401` is the answer. See "Reauthentication" below.
    public init(
        base: URL,
        policy: HTTPPolicy = .standard,
        transport: any HTTPTransport = URLSessionTransport(),
        headers: HTTPHeaders = [:],
        label: String = "http",
        reauthenticate: (@Sendable () async throws -> HTTPHeaders)? = nil
    ) {
        self.base = base
        self.policy = policy
        self.transport = transport
        self.defaultHeaders = headers
        self.label = label
        self.flights = SingleFlight(label: "\(label) coalesced")
        self.reauthenticate = reauthenticate
        self.refreshes = SingleFlight(label: "\(label) reauthentication")
    }

    // MARK: Sending

    /// Sends `request` and returns the response, whose status is a success.
    ///
    /// - Parameters:
    ///   - idempotencyKey: Makes a `POST` or `PATCH` retryable: the key is
    ///     sent as `Idempotency-Key` on every attempt. Create it once per
    ///     *operation*, outside any code that may run again.
    ///   - overrides: What this call changes about the policy: its attempt
    ///     timeout, retry schedule, coalescing, whether it passes the breaker.
    /// - Throws: ``HTTPError``, or `CancellationError` if the caller was
    ///   cancelled.
    @discardableResult
    public func send(
        _ request: HTTPRequest, idempotencyKey: IdempotencyKey? = nil, overrides: HTTPOverrides = .none
    ) async throws -> HTTPResponse {
        try await deliver(request, key: idempotencyKey, overrides: overrides).response
    }

    /// Sends `request` and decodes the response body through `schema`. A body
    /// that does not match is ``HTTPError/decoding(_:attempts:)`` with every
    /// issue, and is not retried. Asks for `application/json` unless the
    /// request names an `Accept` itself.
    ///
    /// - Parameters:
    ///   - options: How to decode, instead of the policy's
    ///     ``HTTPPolicy/decodeOptions``.
    ///   - overrides: What this call changes about the policy, as for
    ///     ``send(_:idempotencyKey:overrides:)``.
    public func send<Value: Sendable>(
        _ request: HTTPRequest,
        idempotencyKey: IdempotencyKey? = nil,
        overrides: HTTPOverrides = .none,
        decoding schema: Schema<Value>,
        options: DecodeOptions? = nil
    ) async throws -> Value {
        var request = request
        if !request.headers.contains("Accept") { request.headers["Accept"] = "application/json" }
        let delivered = try await deliver(request, key: idempotencyKey, overrides: overrides)
        let decoded = schema.decodeReporting(delivered.response.body, options: options ?? policy.responseDecodeOptions)
        guard let value = decoded.value else {
            let failure = ValidationFailure(issues: decoded.issues)
            Ambient.record(Event("http.decoding_failed", level: .notice, label: label, fields: [
                .init("errors", .int(failure.errors.count)),
                .init("bytes", .int(delivered.response.body.count)),
            ]))
            throw HTTPError.decoding(failure, attempts: delivered.attempts)
        }
        return value
    }

    // MARK: Inspection

    /// The callers waiting on the shared request for `request`, which a test
    /// uses to know that every caller has joined before it lets the response
    /// through.
    func coalescedWaiters(for request: HTTPRequest, overrides: HTTPOverrides = .none) -> Int {
        let prepared: PreparedRequest
        do {
            prepared = try prepare(request, key: nil, overrides: overrides)
        } catch {
            return 0
        }
        return flights.waiterCount(for: FlightKey(prepared.request, ignoring: policy.ignoreHeadersForCoalescing, overrides: overrides))
    }

    /// The callers waiting on the renewal of the credentials that were
    /// `generation` (the first, by default), which a test uses to know that
    /// every refused request has joined before it lets the hook answer.
    func renewalWaiters(generation: Int = 0) -> Int {
        refreshes.waiterCount(for: generation)
    }

    /// The hosts whose policies the client keeps now.
    var hostCount: Int {
        hosts.withLock { $0.count }
    }

    /// The breaker for `host` (as `host` or `host:port`), once the client has
    /// sent it a request; `nil` before then, or when the policy has none.
    public func breaker(forHost host: String) -> CircuitBreaker? {
        hosts.withLock { $0.existing(host.lowercased()) }?.breaker
    }

    /// The bulkhead for `host`, with the same naming and lifetime as
    /// ``breaker(forHost:)``.
    public func bulkhead(forHost host: String) -> Bulkhead? {
        hosts.withLock { $0.existing(host.lowercased()) }?.bulkhead
    }

    /// The rate limiter for `host`, with the same naming and lifetime as
    /// ``breaker(forHost:)``; `nil` when the policy has no ``HTTPPolicy/rateLimit``.
    public func rateLimiter(forHost host: String) -> RateLimiter? {
        hosts.withLock { $0.existing(host.lowercased()) }?.limiter
    }

    // MARK: Delivery

    private enum Outcome {
        case delivered(Delivered)
        case failed(HTTPError)
        case cancelled
    }

    private func deliver(_ request: HTTPRequest, key: IdempotencyKey?, overrides: HTTPOverrides) async throws -> Delivered {
        let prepared = try prepare(request, key: key, overrides: overrides)
        // A predicate is a closure, which cannot be compared: a call with
        // its own never joins a flight, nor starts one for others to join.
        let coalesce = (overrides.coalesce ?? policy.coalesceGETs) && overrides.retryOnResponse == nil
        if coalesce, prepared.request.method == .get, prepared.request.body == nil {
            return try await coalesced(prepared)
        }
        return try settle(await run(prepared))
    }

    private func settle(_ outcome: Outcome) throws -> Delivered {
        switch outcome {
        case .delivered(let delivered): return delivered
        case .failed(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }

    /// Identical `GET`s in flight at once make one request. The flight runs
    /// the whole pipeline once, for everyone; each caller waits under its own
    /// deadline, and the request is cancelled only when the last caller
    /// leaves (`SingleFlight`'s rule).
    ///
    /// A flight belongs to no caller, so it carries none of their deadlines;
    /// the one who starts it lends it theirs, so its retries honour a deadline
    /// as an uncoalesced request's would. A caller who joined with a *later*
    /// deadline, and finds the flight ended by the starter's, starts a new
    /// flight instead of inheriting someone else's timeout.
    private func coalesced(_ prepared: PreparedRequest) async throws -> Delivered {
        let key = FlightKey(prepared.request, ignoring: policy.ignoreHeadersForCoalescing, overrides: prepared.overrides)
        let led = LedFlag()
        while true {
            let lent = Deadline.current
            do throws(PolicyError<FlightFailure>) {
                let delivered = try await flights.run(key) { () async throws(FlightFailure) -> Delivered in
                    led.mark()
                    let outcome: Outcome
                    if let lent {
                        outcome = await withDeadline(lent) { await self.run(prepared) }
                    } else {
                        outcome = await self.run(prepared)
                    }
                    switch outcome {
                    case .delivered(let delivered):
                        return delivered
                    case .failed(let error):
                        throw FlightFailure(error: error, starterDeadline: lent?.instant)
                    case .cancelled:
                        let cancelled = HTTPError.rejected(Rejection(.cancelled, label: prepared.hostLabel(self.label)), attempts: 0)
                        throw FlightFailure(error: cancelled, starterDeadline: lent?.instant)
                    }
                }
                noteCoalesced(prepared, led)
                return delivered
            } catch {
                switch error {
                case .failed(let failure):
                    if !led.value, failure.error.rejection?.reason == .deadlineExceeded, !Task.isCancelled,
                       let theirs = failure.starterDeadline, endedByAnotherCallersDeadline(theirs) {
                        continue
                    }
                    noteCoalesced(prepared, led)
                    throw failure.error
                case .rejected(let rejection):
                    noteCoalesced(prepared, led)
                    if rejection.reason == .cancelled { throw CancellationError() }
                    throw HTTPError.rejected(rejection, attempts: 0)
                }
            }
        }
    }

    /// Whether this caller has more time than the starter of a flight that
    /// ended at `starterDeadline`.
    private func endedByAnotherCallersDeadline(_ starterDeadline: AnyClock.Instant) -> Bool {
        guard let mine = Deadline.current else { return true }
        return !mine.hasPassed && mine.instant > starterDeadline
    }

    private func noteCoalesced(_ prepared: PreparedRequest, _ led: LedFlag) {
        guard !led.value else { return }
        Ambient.record(Event("http.coalesced", level: .debug, label: prepared.hostLabel(label), fields: prepared.fields))
    }

    // MARK: Reauthentication

    /// Runs one request through the policies of its host, and, if the server
    /// refuses its credentials and the client has a way to renew them, once
    /// more with the renewed ones.
    ///
    /// Only a `401` from the base URL's origin to a request carrying the
    /// client's headers is the client's to repair, and only once per request:
    /// the replay's answer is the answer. A `401` means the server did not act
    /// on the request, so replaying is safe for any method, keyed or not.
    /// Concurrent requests refused for the same credentials share one run of
    /// the hook (`SingleFlight`, keyed by the generation of the credentials
    /// that were refused), and a request that finds the credentials already
    /// renewed since it was prepared replays without running the hook at all.
    private func run(_ prepared: PreparedRequest) async -> Outcome {
        let log = AttemptLog()
        let first = await execute(prepared, log: log)
        guard reauthenticate != nil, prepared.overrides.reauthenticate, prepared.carriesClientHeaders,
              case .failed(.status(401, _, _, _)) = first else {
            return first
        }
        let label = prepared.hostLabel(self.label)
        if credentials.withLock({ $0.generation }) == prepared.generation {
            let generation = prepared.generation
            do throws(PolicyError<ReauthenticationFailure>) {
                try await refreshes.run(generation) { () async throws(ReauthenticationFailure) -> Void in
                    try await self.renewCredentials(refused: generation, label: label)
                }
            } catch {
                switch error {
                case .rejected(let rejection):
                    if rejection.reason == .cancelled { return .cancelled }
                    return .failed(.rejected(rejection, attempts: log.count))
                case .failed:
                    return .failed(.reauthenticationFailed(status: 401, attempts: log.count))
                }
            }
        }
        let replay: PreparedRequest
        do {
            replay = try prepare(prepared.source, key: prepared.sourceKey, overrides: prepared.overrides)
        } catch {
            return .failed(error)
        }
        return await execute(replay, log: log)
    }

    /// Calls the hook, unless another request got there first.
    private func renewCredentials(refused generation: Int, label: String) async throws(ReauthenticationFailure) {
        guard let reauthenticate, credentials.withLock({ $0.generation }) == generation else { return }
        let renewed: HTTPHeaders
        do {
            renewed = try await reauthenticate()
        } catch {
            Ambient.record(Event("http.reauthenticate_failed", level: .warning, label: label, fields: [
                .init("error", .string(String(describing: type(of: error))), privacy: .public),
            ]))
            throw ReauthenticationFailure(kind: String(describing: type(of: error)))
        }
        credentials.withLock { credentials in
            credentials.headers = renewed
            credentials.generation += 1
        }
        Ambient.record(Event("http.reauthenticated", level: .info, label: label, fields: []))
    }

    /// Runs one request through the policies of its host.
    private func execute(_ prepared: PreparedRequest, log: AttemptLog) async -> Outcome {
        let host = leaseHost(for: prepared)
        defer { hosts.withLock { $0.release(prepared.hostKey) } }
        let watcher = RetryWatcher(forwardingTo: Ambient.current.instrumentation, label: host.label)
        let policy = self.policy
        let safeToRepeat = prepared.safeToRepeat
        // Retry is the outermost stage; the classifier sees what the inner
        // stages throw. Anything a policy refused (an open breaker, a full
        // bulkhead, the deadline) ends the retrying: waiting for a breaker
        // that said "fail fast" would defeat it.
        // The stage hands its classifier the attempt's own error, unwrapped;
        // a policy's refusal arrives as a `Rejection`.
        let classifier = RetryClassifier<any Error> { failure in
            guard let attempt = failure as? AttemptError else { return .stop }
            return attempt.decision(policy: policy, safeToRepeat: safeToRepeat)
        }
        var stages: [any Policy] = [
            Retrying(prepared.overrides.schedule ?? policy.schedule, budget: policy.retryBudget, classify: classifier, nesting: .singleAttempt, label: host.label)
        ]
        if let breaker = host.breaker, !prepared.overrides.bypassBreaker { stages.append(breaker) }
        if let limiter = host.limiter { stages.append(limiter) }
        if let bulkhead = host.bulkhead { stages.append(bulkhead) }
        let pipeline = Pipeline(stages)

        let result: Result<HTTPResponse, PolicyError<AttemptError>> = await withAmbient({ $0.instrumentation = watcher }) {
            () async -> Result<HTTPResponse, PolicyError<AttemptError>> in
            do throws(PolicyError<AttemptError>) {
                let response = try await pipeline.execute { () async throws(AttemptError) -> HTTPResponse in
                    try await self.attempt(prepared, host: host, log: log)
                }
                return .success(response)
            } catch {
                return .failure(error)
            }
        }

        switch result {
        case .success(let response):
            return .delivered(Delivered(response: response, attempts: log.count))
        case .failure(let error):
            let outcome = finalOutcome(for: error, attempts: log.count, watcher: watcher, host: host)
            if case .failed(let failure) = outcome {
                Ambient.record(Event("http.failed", level: .warning, label: host.label, fields: prepared.fields + [
                    .init("error", .string(String(describing: failure)), privacy: .public),
                    .init("attempts", .int(failure.attempts)),
                ]))
            }
            return outcome
        }
    }

    /// What a failed pipeline means for the caller.
    private func finalOutcome(
        for error: PolicyError<AttemptError>, attempts: Int, watcher: RetryWatcher, host: HostState
    ) -> Outcome {
        // A cancelled caller is cancelled, and its deadline passing is a
        // rejection, whatever the last attempt happened to fail with. (An
        // attempt can see the cancellation before the task does: the
        // attempt's own timer and the caller's deadline fire together.)
        var cancelled = Task.isCancelled
        if case .failed(.cancelled) = error { cancelled = true }
        if cancelled {
            if CancellationCause.current == .deadline || Deadline.current?.hasPassed == true {
                return .failed(.rejected(Rejection(.deadlineExceeded, label: host.label), attempts: attempts))
            }
            return .cancelled
        }
        // `retry` rethrows the last error whatever stopped it; its events
        // say what did.
        if watcher.budgetExhausted {
            return .failed(.rejected(Rejection(.budgetExhausted, label: host.label), attempts: attempts))
        }
        if let wait = watcher.deadlineSkip {
            return .failed(.rejected(Rejection(.deadlineExceeded, label: host.label, retryAfter: wait), attempts: attempts))
        }
        switch error {
        case .rejected(let rejection):
            if rejection.reason == .cancelled { return .cancelled }
            return .failed(.rejected(rejection, attempts: attempts))
        case .failed(let attempt):
            switch attempt {
            case .status(let code, let excerpt, let retryAfter, _):
                return .failed(.status(code, excerpt: excerpt, retryAfter: retryAfter, attempts: attempts))
            case .transport(let code):
                return .failed(.transport(code, attempts: attempts))
            case .timedOut:
                return .failed(.timedOut(attempt: attempts))
            case .tooLarge(let limit):
                return .failed(.responseTooLarge(limit: limit, attempts: attempts))
            case .cancelled:
                return .cancelled
            }
        }
    }

    // MARK: One attempt

    /// One request to the transport, bounded by the attempt timeout, with
    /// its outcome classified.
    private func attempt(_ prepared: PreparedRequest, host: HostState, log: AttemptLog) async throws(AttemptError) -> HTTPResponse {
        let clock = Ambient.current.clock
        let started = clock.now
        let (number, gap, previous) = log.begin(at: started)
        if number > 1 {
            Ambient.record(Event("http.retry", level: .info, label: host.label, fields: prepared.fields + [
                .init("attempt", .int(number)),
                .init("delay", .duration(gap ?? .zero)),
                .init("reason", .string(previous), privacy: .public),
            ]))
        }

        let transport = self.transport
        let request = prepared.request
        let limit = policy.maxResponseBytes
        let callerDeadline = Deadline.current
        var result: Result<HTTPResponse, AttemptError>
        do throws(AttemptError) {
            result = .success(try await withTimeout(prepared.overrides.attemptTimeout ?? policy.attemptTimeout, label: "\(host.label) attempt \(number)") {
                () async throws(AttemptError) -> HTTPResponse in
                do {
                    return try await transport.send(request, maxResponseBytes: limit)
                } catch {
                    throw AttemptError(classifying: error)
                }
            })
        } catch {
            result = .failure(error)
        }

        // A cancellation the attempt's own timer caused is a timeout. One the
        // caller caused (cancelling, or its deadline passing) is not.
        if case .failure(.cancelled) = result, !Task.isCancelled, callerDeadline?.hasPassed != true {
            result = .failure(.timedOut)
        }
        if case .success(let response) = result {
            if response.body.count > limit {
                result = .failure(.tooLarge(limit: limit))
            } else {
                // The predicate sees every response that arrived whole. A
                // success is only turned into a failure to ask again if it
                // could be asked again: an unkeyed `POST` that was answered
                // is answered.
                let verdict = (prepared.overrides.retryOnResponse ?? policy.retryOnResponse)?(response)
                let asksAgain = prepared.safeToRepeat && verdict.map { $0 != .stop } == true
                if !response.isSuccess || asksAgain {
                    result = .failure(.status(
                        code: response.status,
                        excerpt: String(decoding: response.body.prefix(policy.errorExcerptBytes), as: UTF8.self),
                        retryAfter: HTTPRetry.retryAfterDelay(response.headers["Retry-After"], now: policy.wallClock()),
                        verdict: verdict
                    ))
                }
            }
        }

        let finished = clock.now
        var fields = prepared.fields + [
            .init("attempt", .int(number)),
            .init("duration", .duration(started.duration(to: finished))),
        ]
        if let query = prepared.query, !query.isEmpty { fields.append(.init("query", .string(query), privacy: .private)) }
        switch result {
        case .success(let response):
            fields += [.init("status", .int(response.status)), .init("outcome", .string("ok"), privacy: .public)]
            log.end(at: finished, reason: "ok")
        case .failure(let failure):
            if case .status(let code, _, _, _) = failure { fields.append(.init("status", .int(code))) }
            fields.append(.init("outcome", .string(failure.reason), privacy: .public))
            log.end(at: finished, reason: failure.reason)
            if case .tooLarge = failure {
                Ambient.record(Event("http.response_too_large", level: .warning, label: host.label, fields: prepared.fields + [
                    .init("limit", .int(limit)),
                ]))
            }
        }
        Ambient.record(Event("http.request", level: .debug, label: host.label, fields: fields))
        return try result.get()
    }

    // MARK: Preparation

    /// The policies of the request's host, held in the table until the caller
    /// releases them, so that a host is never forgotten mid-request.
    private func leaseHost(for prepared: PreparedRequest) -> HostState {
        let key = prepared.hostKey
        return hosts.withLock { table in
            table.lease(key) { makeHost(key) }
        }
    }

    private func makeHost(_ key: String) -> HostState {
        let label = "\(self.label) \(key)"
        let clock = Ambient.current.clock
        let breaker = policy.breaker.map { configuration -> CircuitBreaker in
            var configuration = configuration
            configuration.recordWhen = { error in (error as? AttemptError)?.countsAgainstHost ?? false }
            return CircuitBreaker(label: label, configuration, clock: clock)
        }
        let limiter = policy.rateLimit.map {
            RateLimiter(rate: $0.rate, per: $0.interval, burst: $0.burst, queueLimit: $0.queueLimit, label: label, clock: clock)
        }
        let bulkhead = policy.maxConcurrentPerHost.map {
            Bulkhead(maxConcurrent: $0, queueLimit: policy.queueLimitPerHost, label: label)
        }
        return HostState(label: label, breaker: breaker, limiter: limiter, bulkhead: bulkhead)
    }

    /// Resolves the request against the base URL, folds in the query, adds
    /// the default headers (for the base URL's host only) and the idempotency
    /// key.
    private func prepare(_ request: HTTPRequest, key: IdempotencyKey?, overrides: HTTPOverrides) throws(HTTPError) -> PreparedRequest {
        func invalid() -> HTTPError { .transport(.badURL, attempts: 0) }

        var components: URLComponents
        switch request.target {
        case .url(let url):
            guard let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw invalid() }
            components = parsed
        case .path(let path):
            guard var parsed = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw invalid() }
            var rawPath = path
            if let mark = path.firstIndex(of: "?") {
                rawPath = String(path[..<mark])
                parsed.percentEncodedQuery = String(path[path.index(after: mark)...])
            }
            let basePath = parsed.path.hasSuffix("/") ? String(parsed.path.dropLast()) : parsed.path
            parsed.path = basePath + (rawPath.hasPrefix("/") ? rawPath : "/" + rawPath)
            components = parsed
        }
        if !request.query.isEmpty { components.queryItems = (components.queryItems ?? []) + request.query }
        guard let url = components.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw invalid()
        }

        var headers = request.headers
        let current = credentials.withLock { $0 }
        let sameOrigin = Self.sameOrigin(url, base)
        if sameOrigin { headers = defaultHeaders.merging(current.headers).merging(headers) }
        let effectiveKey = key ?? request.idempotencyKey
        if let effectiveKey { headers[HTTPRequest.idempotencyKeyHeader] = effectiveKey.rawValue }

        let resolved = HTTPRequest(
            method: request.method, target: .url(url), headers: headers, body: request.body, idempotencyKey: effectiveKey)
        return PreparedRequest(
            request: resolved,
            host: host,
            hostKey: (url.port.map { "\(host):\($0)" } ?? host).lowercased(),
            path: url.path,
            query: components.percentEncodedQuery,
            safeToRepeat: resolved.isSafeToRepeat,
            overrides: overrides,
            source: request,
            sourceKey: key,
            generation: current.generation,
            carriesClientHeaders: sameOrigin
        )
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }
}

extension PreparedRequest {
    /// The label of this request's host, as `HTTPClient` names it.
    func hostLabel(_ clientLabel: String) -> String { "\(clientLabel) \(hostKey)" }
}

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
/// - Inside a live attempt of a declared operation's `perform` (design/22),
///   the client makes one attempt and skips its own retry, breaker, bulkhead
///   and rate limit: the operation is that backend's retry layer, and the
///   client is the transport and the classification of what it saw.
/// - Cancelling the caller cancels the request and throws
///   `CancellationError`; the caller's deadline is honoured at every stage,
///   and a wait that would outlast it is not started.
/// - The breaker and bulkhead measure time on the ambient clock in force when
///   a host is first used, like every Stoic breaker.
/// - Redirects are followed by the client, not the transport, each hop
///   through its own host's policies: never from `https` to `http`, never
///   past ``HTTPPolicy/maxRedirects``, and with no credential, client header
///   or idempotency key once a redirect leaves the request's origin.
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
    ///   - headers: Sent with every request to the base URL's origin (and
    ///     only to it: an absolute URL on another host never receives them,
    ///     nor does a redirect once it has left that origin, so a token
    ///     cannot leak to a host the caller merely linked to, or was sent to).
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
    ///   - request: The request to send.
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
    /// issue, and is not retried. A body that matches, but with warnings or
    /// repairs (a key the server added, a field repaired to its default),
    /// returns its value and records one `http.decoded_with_warnings`. Asks
    /// for `application/json` unless the request names an `Accept` itself.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - idempotencyKey: Makes a `POST` or `PATCH` retryable, as for
    ///     ``send(_:idempotencyKey:overrides:)``.
    ///   - schema: What the response body must match.
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
            Ambient.record(Event("http.decoding_failed", level: .notice, label: delivered.label, fields: delivered.fields + [
                .init("errors", .int(failure.errors.count)),
                .init("bytes", .int(delivered.response.body.count)),
            ]))
            throw HTTPError.decoding(failure, attempts: delivered.attempts)
        }
        let unerrored = decoded.issues.filter { $0.severity != .error }
        if !unerrored.isEmpty { noteDecodedWithWarnings(unerrored, of: delivered) }
        return value
    }

    /// A decode that succeeded can still have decided something: a field
    /// repaired to its default, an element dropped, a key the server added.
    /// The value goes to the caller; what was decided is said here, as codes
    /// and counts. A path may name a key the server chose, so it is private.
    private func noteDecodedWithWarnings(_ issues: [Issue], of delivered: Delivered) {
        let codes = Set(issues.map(\.code.rawValue)).sorted().joined(separator: ",")
        let paths = issues.map { String(describing: $0.path) }.joined(separator: ", ")
        Ambient.record(Event("http.decoded_with_warnings", level: .warning, label: delivered.label, fields: delivered.fields + [
            .init("warnings", .int(issues.filter { $0.severity == .warning }.count)),
            .init("repairs", .int(issues.filter { $0.severity == .repaired }.count)),
            .init("codes", .string(codes), privacy: .public),
            .init("paths", .string(paths), privacy: .private),
        ]))
    }

    // MARK: Streaming

    /// Sends `request` and returns as soon as the response head has arrived
    /// with a success status, with the body to be read as a stream: for a body
    /// too large to hold in memory, a model or an installer.
    ///
    /// It is one exchange through the same pipeline as ``send(_:idempotencyKey:overrides:)``
    /// (design/19): the base URL and headers, redirects, the host's breaker,
    /// rate limit and bulkhead, the retry policy, and the classification of
    /// failures as ``HTTPError``, with these differences:
    ///
    /// - **Retrying ends at the head.** A `503`, a lost connection or a timeout
    ///   before the head arrives is retried as for `send`. Once the head is
    ///   returned the body is the caller's: a failure while reading it is
    ///   thrown by the body (``HTTPBodyStream``), never retried here, because
    ///   the bytes already delivered cannot be unsent. Resuming is the
    ///   caller's to do, with a `Range` request of its own.
    /// - **The attempt timeout bounds the wait for the head** and for the
    ///   excerpt of an error response, not the body. The caller's deadline
    ///   bounds everything: a body being read when it passes ends with
    ///   `.rejected(deadline_exceeded)`. A stalled body is cut by the
    ///   transport's own limit on silence (`URLSession`'s
    ///   `timeoutIntervalForRequest`), as `URLError.timedOut`.
    /// - **The bulkhead, the rate limit and the breaker see the exchange up to
    ///   the head**, and release their slot and permit there: a transfer that
    ///   runs for an hour must not hold one of the host's eight slots against
    ///   its API calls, nor does a cut part-way through a body count against
    ///   the breaker. How many transfers run at once is the caller's to bound.
    /// - **`retryOnResponse` and coalescing do not apply:** the body has not
    ///   arrived, and a stream is not shared.
    /// - **The size is bounded by `maxBytes`, not ``HTTPPolicy/maxResponseBytes``.**
    ///   The bound is the caller's to name, because the policy's, ten
    ///   megabytes by default, is made for API responses.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - maxBytes: The most body bytes to read. A declared `Content-Length`
    ///     over it fails before the first byte when a body will be transferred.
    ///     A `HEAD`, `204` or `304` declares the size a `GET` would have sent
    ///     and is not refused for it; bytes that arrive are still counted. A
    ///     body that passes the limit ends with
    ///     ``HTTPError/responseTooLarge(limit:attempts:)``, with the connection
    ///     cancelled.
    ///   - statuses: Statuses outside 2xx that are returned as responses, with
    ///     their bodies, instead of thrown: for a caller that interprets them
    ///     itself (`416`, "the range is not satisfiable", for one that resumes).
    ///     A redirect is followed whatever this says.
    ///   - idempotencyKey: As for ``send(_:idempotencyKey:overrides:)``.
    ///   - overrides: As for ``send(_:idempotencyKey:overrides:)``: a call that
    ///     retries for itself passes a schedule of one attempt.
    /// - Throws: ``HTTPError`` before the head arrives, or `CancellationError`
    ///   if the caller was cancelled. The body throws ``HTTPError``
    ///   (`transport`, `responseTooLarge`, `timedOut`, `rejected`) or
    ///   `CancellationError`.
    public func stream(
        _ request: HTTPRequest,
        maxBytes: Int,
        accepting statuses: Set<Int> = [],
        idempotencyKey: IdempotencyKey? = nil,
        overrides: HTTPOverrides = .none
    ) async throws -> HTTPStreamedResponse {
        precondition(maxBytes >= 0, "a byte limit cannot be negative")
        let prepared = try prepare(request, key: idempotencyKey, overrides: overrides)
        let outcome = await run(prepared, defers: PerformAttempt.isLive, mode: .streamed(limit: maxBytes, accepted: statuses))
        let delivered = try settle(outcome)
        return HTTPStreamedResponse(
            status: delivered.response.status, headers: delivered.response.headers,
            body: delivered.stream ?? HTTPBodyStream(bytes: delivered.response.body))
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
        // Inside a live attempt of a `perform` the operation is the retry
        // layer: this call is one attempt of it, and says what it saw.
        let defers = PerformAttempt.isLive
        // A predicate is a closure, which cannot be compared: a call with
        // its own never joins a flight, nor starts one for others to join.
        // Nor does a call that defers: a flight runs the starter's pipeline in
        // a task of its own, outside the attempt the operation is waiting on.
        let coalesce = (overrides.coalesce ?? policy.coalesceGETs) && overrides.retryOnResponse == nil && !defers
        if coalesce, prepared.request.method == .get, prepared.request.body == nil {
            return try await coalesced(prepared)
        }
        return try settle(await run(prepared, defers: defers, mode: .buffered))
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
                        outcome = await withDeadline(lent) { await self.run(prepared, defers: false, mode: .buffered) }
                    } else {
                        outcome = await self.run(prepared, defers: false, mode: .buffered)
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

    // MARK: Redirects

    /// Runs one request, and follows the redirects it is answered with
    /// (``Redirects`` holds the rules).
    ///
    /// Each hop is a request to its own host, through that host's policies:
    /// its breaker, rate limit and bulkhead protect the host it goes to, and
    /// what it meets there is counted against that host, not the one that
    /// redirected. A hop is not a retry: it is the way to the answer, so it
    /// takes no retry budget and does not use up the schedule's attempts
    /// (each hop has the schedule's attempts of its own). What bounds the
    /// chain is ``HTTPPolicy/maxRedirects`` and the caller's deadline, which
    /// every hop runs under; every hop counts in ``HTTPError/attempts``.
    private func run(_ prepared: PreparedRequest, defers: Bool, mode: BodyMode) async -> Outcome {
        let log = AttemptLog()
        var current = prepared
        var followed = 0
        while true {
            let outcome = await exchange(current, log: log, defers: defers, mode: mode)
            guard case .delivered(let delivered) = outcome, Redirects.isRedirect(delivered.response) else { return outcome }
            let response = delivered.response
            let label = current.hostLabel(self.label)
            switch Redirects.next(after: response, to: current, followed: followed, limit: policy.maxRedirects) {
            case .refuse(let refusal, let location):
                let error = HTTPError.redirectRefused(refusal, status: response.status, location: location, attempts: log.count)
                Ambient.record(Event("http.failed", level: .warning, label: label, fields: current.fields + [
                    .init("error", .string(String(describing: error)), privacy: .public),
                    .init("attempts", .int(log.count)),
                ]))
                return .failed(error)
            case .follow(let hop):
                let next: PreparedRequest
                do {
                    next = try prepare(hop.request, key: nil, overrides: current.overrides, clientHeaders: hop.clientHeaders)
                } catch {
                    return .failed(error)
                }
                followed += 1
                Ambient.record(Event("http.redirected", level: .info, label: label, fields: current.fields + [
                    .init("status", .int(response.status)),
                    .init("hop", .int(followed)),
                    .init("to_method", .string(next.request.method.rawValue), privacy: .public),
                    .init("to_host", .string(next.host), privacy: .public),
                    .init("to_path", .string(next.path), privacy: .public),
                    .init("origin_changed", .bool(hop.changesOrigin)),
                ]))
                log.hop()
                current = next
            }
        }
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
    private func exchange(_ prepared: PreparedRequest, log: AttemptLog, defers: Bool, mode: BodyMode) async -> Outcome {
        let first = await execute(prepared, log: log, defers: defers, mode: mode)
        guard reauthenticate != nil, prepared.overrides.reauthenticate, prepared.carriesClientHeaders,
              case .failed(.status(401, _, _, _, _)) = first else {
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
            replay = try prepare(
                prepared.source, key: prepared.sourceKey, overrides: prepared.overrides, clientHeaders: prepared.clientHeadersAllowed)
        } catch {
            return .failed(error)
        }
        return await execute(replay, log: log, defers: defers, mode: mode)
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

    /// Runs one request through the policies of its host, or, when it runs
    /// inside a live attempt of a `perform` (`defers`), as one attempt of
    /// that operation: the transport and the classification, with nothing of
    /// the client's own retry, breaker, bulkhead or rate limit, and neither
    /// its attempt timeout nor its `retryOnResponse`, which belong to its own
    /// retry. The operation's timer bounds the attempt, and what the operation
    /// retries is what its classification, ``HTTPError``'s, says.
    private func execute(_ prepared: PreparedRequest, log: AttemptLog, defers: Bool, mode: BodyMode) async -> Outcome {
        if defers {
            let label = prepared.hostLabel(self.label)
            let result: Result<Received, AttemptError>
            do throws(AttemptError) {
                result = .success(try await attempt(prepared, label: label, log: log, defers: true, mode: mode))
            } catch {
                result = .failure(error)
            }
            switch result {
            case .success(let received):
                return .delivered(Delivered(
                    response: received.response, stream: received.stream, attempts: log.count, label: label, fields: prepared.fields))
            case .failure(let error):
                return failed(finalOutcome(for: .failed(error), prepared, attempts: log.count, watcher: nil, label: label), prepared, label: label)
            }
        }
        let host = leaseHost(for: prepared)
        defer { hosts.withLock { $0.release(prepared.hostKey) } }
        let watcher = RetryWatcher(forwardingTo: Ambient.current.instrumentation, label: host.label)
        let policy = self.policy
        let safeToRepeat = prepared.safeToRepeat
        let keyed = prepared.request.carriesIdempotencyKey
        // Retry is the outermost stage; the classifier sees what the inner
        // stages throw. Anything a policy refused (an open breaker, a full
        // bulkhead, the deadline) ends the retrying: waiting for a breaker
        // that said "fail fast" would defeat it.
        // The stage hands its classifier the attempt's own error, unwrapped;
        // a policy's refusal arrives as a `Rejection`.
        let classifier = RetryClassifier<any Error> { failure in
            guard let attempt = failure as? AttemptError else { return .stop }
            return attempt.decision(policy: policy, safeToRepeat: safeToRepeat, keyed: keyed)
        }
        var stages: [any Policy] = [
            Retrying(prepared.overrides.schedule ?? policy.schedule, budget: policy.retryBudget, classify: classifier, nesting: .singleAttempt, label: host.label)
        ]
        if let breaker = host.breaker, !prepared.overrides.bypassBreaker { stages.append(breaker) }
        if let limiter = host.limiter { stages.append(limiter) }
        if let bulkhead = host.bulkhead { stages.append(bulkhead) }
        let pipeline = Pipeline(stages)

        let result: Result<Received, PolicyError<AttemptError>> = await withAmbient({ $0.instrumentation = watcher }) {
            () async -> Result<Received, PolicyError<AttemptError>> in
            do throws(PolicyError<AttemptError>) {
                let received = try await pipeline.execute { () async throws(AttemptError) -> Received in
                    try await self.attempt(prepared, label: host.label, log: log, defers: false, mode: mode)
                }
                return .success(received)
            } catch {
                return .failure(error)
            }
        }

        switch result {
        case .success(let received):
            return .delivered(Delivered(
                response: received.response, stream: received.stream, attempts: log.count, label: prepared.hostLabel(label),
                fields: prepared.fields))
        case .failure(let error):
            return failed(finalOutcome(for: error, prepared, attempts: log.count, watcher: watcher, label: host.label), prepared, label: host.label)
        }
    }

    /// Reports a failure the caller will see, and passes it on.
    private func failed(_ outcome: Outcome, _ prepared: PreparedRequest, label: String) -> Outcome {
        if case .failed(let failure) = outcome {
            Ambient.record(Event("http.failed", level: .warning, label: label, fields: prepared.fields + [
                .init("error", .string(String(describing: failure)), privacy: .public),
                .init("attempts", .int(failure.attempts)),
            ]))
        }
        return outcome
    }

    /// What a failed pipeline means for the caller. There is no `watcher` for
    /// a call that defers: it has no retry to say why it stopped.
    private func finalOutcome(
        for error: PolicyError<AttemptError>, _ prepared: PreparedRequest, attempts: Int, watcher: RetryWatcher?, label: String
    ) -> Outcome {
        // A cancelled caller is cancelled, and its deadline passing is a
        // rejection, whatever the last attempt happened to fail with. (An
        // attempt can see the cancellation before the task does: the
        // attempt's own timer and the caller's deadline fire together.)
        var cancelled = Task.isCancelled
        if case .failed(.cancelled) = error { cancelled = true }
        if cancelled {
            if CancellationCause.current == .deadline || Deadline.current?.hasPassed == true {
                return .failed(.rejected(Rejection(.deadlineExceeded, label: label), attempts: attempts))
            }
            return .cancelled
        }
        // `retry` rethrows the last error whatever stopped it; its events
        // say what did.
        if watcher?.budgetExhausted == true {
            return .failed(.rejected(Rejection(.budgetExhausted, label: label), attempts: attempts))
        }
        if let wait = watcher?.deadlineSkip {
            return .failed(.rejected(Rejection(.deadlineExceeded, label: label, retryAfter: wait), attempts: attempts))
        }
        switch error {
        case .rejected(let rejection):
            if rejection.reason == .cancelled { return .cancelled }
            return .failed(.rejected(rejection, attempts: attempts))
        case .failed(let attempt):
            switch attempt {
            case .status(let code, let excerpt, let retryAfter, _):
                // `keyed` carries the in-progress reading, so an outer retry
                // classifies the error as this client did (a conflict the
                // policy takes as a refusal is not a wait to the outbox either).
                let keyed = prepared.request.carriesIdempotencyKey
                    && (code != 409 || policy.keyedConflictIsInProgress)
                return .failed(.status(code, excerpt: excerpt, retryAfter: retryAfter, keyed: keyed, attempts: attempts))
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
    /// its outcome classified. A call that `defers` to a `perform` has no
    /// attempt timeout but one it asked for itself (the operation's timer
    /// bounds the attempt), and no `retryOnResponse` (a response is a failure
    /// only for the retry that asks again).
    ///
    /// A streamed call is over at the head: the attempt timeout bounds the
    /// wait for it (and for the excerpt of an error response), never the
    /// body, which a download that is progressing must be free to take as
    /// long as it needs. The body that comes back is the client's hold on the
    /// transport's (``GuardedBody``).
    private func attempt(
        _ prepared: PreparedRequest, label: String, log: AttemptLog, defers: Bool, mode: BodyMode
    ) async throws(AttemptError) -> Received {
        let clock = Ambient.current.clock
        let started = clock.now
        let (number, retry, gap, previous) = log.begin(at: started)
        if retry {
            Ambient.record(Event("http.retry", level: .info, label: label, fields: prepared.fields + [
                .init("attempt", .int(number)),
                .init("delay", .duration(gap ?? .zero)),
                .init("reason", .string(previous), privacy: .public),
            ]))
        }

        let transport = self.transport
        let request = prepared.request
        let limit: Int
        let streamed: Bool
        switch mode {
        case .buffered:
            limit = policy.maxResponseBytes
            streamed = false
        case .streamed(let bytes, _):
            limit = bytes
            streamed = true
        }
        let excerptBytes = policy.errorExcerptBytes
        let callerDeadline = Deadline.current
        let timeout = defers ? prepared.overrides.attemptTimeout : prepared.overrides.attemptTimeout ?? policy.attemptTimeout
        var result: Result<Received, AttemptError>
        do throws(AttemptError) {
            if let timeout {
                result = .success(try await withTimeout(timeout, label: "\(label) attempt \(number)") {
                    () async throws(AttemptError) -> Received in
                    try await Self.exchange(request, over: transport, mode: mode, limit: limit, excerptBytes: excerptBytes)
                })
            } else {
                result = .success(try await Self.exchange(request, over: transport, mode: mode, limit: limit, excerptBytes: excerptBytes))
            }
        } catch {
            result = .failure(error)
        }

        // A cancellation the attempt's own timer caused is a timeout. One the
        // caller caused (cancelling, or its deadline passing) is not.
        if case .failure(.cancelled) = result, !Task.isCancelled, callerDeadline?.hasPassed != true {
            result = .failure(.timedOut)
        }
        if case .success(var received) = result {
            let response = received.response
            if !streamed, response.body.count > limit {
                result = .failure(.tooLarge(limit: limit))
            } else if Redirects.isRedirect(response) {
                // Not the answer but the way to it: the host answered, and the
                // client follows it (or refuses to) once this hop is over.
            } else if let body = received.stream {
                // A streamed head that is wanted: the answer. The body is not
                // here yet, so there is nothing for `retryOnResponse` to see.
                received.stream = GuardedBody(
                    body, limit: limit, attempts: log.count, label: label, fields: prepared.fields).stream
                result = .success(received)
            } else {
                // The predicate sees every response that arrived whole, but a
                // redirect. A success is only turned into a failure to ask
                // again if it could be asked again: an unkeyed `POST` that was
                // answered is answered.
                let verdict = defers || streamed ? nil : (prepared.overrides.retryOnResponse ?? policy.retryOnResponse)?(response)
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
        case .success(let received):
            let outcome = Redirects.isRedirect(received.response) ? "redirect" : "ok"
            fields += [.init("status", .int(received.response.status)), .init("outcome", .string(outcome), privacy: .public)]
            log.end(at: finished, reason: outcome)
        case .failure(let failure):
            if case .status(let code, _, _, _) = failure { fields.append(.init("status", .int(code))) }
            fields.append(.init("outcome", .string(failure.reason), privacy: .public))
            log.end(at: finished, reason: failure.reason)
            if case .tooLarge = failure {
                Ambient.record(Event("http.response_too_large", level: .warning, label: label, fields: prepared.fields + [
                    .init("limit", .int(limit)),
                ]))
            }
        }
        Ambient.record(Event("http.request", level: .debug, label: label, fields: fields))
        return try result.get()
    }

    /// One exchange with the transport: the whole response for a buffered
    /// call, and for a streamed one the head with its body unread. A redirect
    /// has its body dropped unread (it is the way to the answer), and so
    /// does the head of a failure but for as much of its body as an excerpt
    /// holds; a status the caller said it would interpret (`accepted`)
    /// comes back with its body, like a success.
    private static func exchange(
        _ request: HTTPRequest, over transport: any HTTPTransport, mode: BodyMode, limit: Int, excerptBytes: Int
    ) async throws(AttemptError) -> Received {
        do {
            switch mode {
            case .buffered:
                return Received(response: try await transport.send(request, maxResponseBytes: limit), stream: nil)
            case .streamed(_, let accepted):
                // The transport is given no limit, because the limit is for the body the caller
                // asked for, not for whatever answers: a `404` page larger than a small file's
                // limit is a `404`, not "too large". The limit is applied below, to a body that
                // is wanted (the declared length here, when a body will be transferred, and the
                // bytes as they are read by `GuardedBody`); a failure's body is only ever read
                // as far as its excerpt.
                let streamed = try await transport.stream(request, maxResponseBytes: .max)
                var head = HTTPResponse(status: streamed.status, headers: streamed.headers)
                if Redirects.isRedirect(head) {
                    streamed.body.cancel()
                    return Received(response: head, stream: nil)
                }
                if streamed.isSuccess || accepted.contains(streamed.status) {
                    // A HEAD, 204 or 304 names the size a GET would have sent and
                    // transfers no body (RFC 9110). Refusing that length drops the
                    // headers the caller asked for. Bytes that arrive are counted
                    // by GuardedBody.
                    if ResponseBody.willBeTransferred(method: request.method, status: streamed.status),
                        let declared = streamed.headers["Content-Length"].flatMap({ Int($0) }), declared > limit {
                        streamed.body.cancel()
                        throw HTTPTransportError.responseTooLarge(limit: limit)
                    }
                    return Received(response: head, stream: streamed.body)
                }
                head.body = try await streamed.body.prefix(excerptBytes)
                return Received(response: head, stream: nil)
            }
        } catch {
            throw AttemptError(classifying: error)
        }
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
    /// the default headers (for the base URL's origin only, and only if
    /// `clientHeaders` allows them: a redirect chain that has left that origin
    /// does not) and the idempotency key.
    private func prepare(
        _ request: HTTPRequest, key: IdempotencyKey?, overrides: HTTPOverrides, clientHeaders: Bool = true
    ) throws(HTTPError) -> PreparedRequest {
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
        let sameOrigin = clientHeaders && Origin(url) != nil && Origin(url) == Origin(base)
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
            clientHeadersAllowed: clientHeaders,
            carriesClientHeaders: sameOrigin
        )
    }
}

extension PreparedRequest {
    /// The label of this request's host, as `HTTPClient` names it.
    func hostLabel(_ clientLabel: String) -> String { "\(clientLabel) \(hostKey)" }
}

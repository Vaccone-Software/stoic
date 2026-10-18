public import Foundation
internal import Stoic
internal import Synchronization

/// An ``HTTPTransport`` that answers from a script instead of the network,
/// for tests of anything built on ``HTTPClient``.
///
/// Each route has its own list of steps, consumed one per request: a status
/// with headers and a body, a delay, a `URLError`, a hang until the request is
/// cancelled, a body too large to read. Delays wait on the *ambient* clock,
/// so under a `TestClock` (or inside a simulation) the test decides when a
/// slow response arrives. A hang waits on no clock at all, only for
/// cancellation, so it ends exactly when the client's attempt timeout fires
/// (or the caller leaves) and a simulation has no timer of it to fire early. Every request is recorded, headers
/// included, so a test can assert what was sent and how often. A body can have
/// a shape of its own (``Step/streaming(_:status:headers:chunkSize:chunkDelay:fault:)``,
/// ``Step/serving(_:chunkSize:chunkDelay:fault:)``): chunks, a connection cut part-way, an
/// error, a stall, a server that honours `Range` or ignores it, a validator
/// that changes, a `416`; and ``stream(_:maxResponseBytes:)`` delivers it a chunk
/// at a time, where ``send(_:maxResponseBytes:)`` has it whole. A redirect is
/// a step like any other (`.status(302, headers: ["Location": "/next"])`):
/// the transport returns it, and the client follows it.
///
///     let transport = ScriptedTransport()
///     transport.on(.get("/users/42"), respond: [.status(503), .status(503), .json(#"{"id": 42}"#)])
///     let api = HTTPClient(base: url, transport: transport)
///
/// It lives in `StoicHTTP` rather than a separate testing product, as
/// `SimulatedFileSystem` lives in `StoicStore`: it needs nothing from
/// `StoicTesting` (only the ambient clock), and an app's own tests then need
/// the one import.
public final class ScriptedTransport: HTTPTransport {
    /// One scripted behaviour for one request.
    public struct Step: Sendable {
        enum Kind: Sendable {
            case response(status: Int, headers: HTTPHeaders, body: [UInt8])
            // A body of `totalBytes` that is never materialised: reading it
            // past the limit aborts, as a real transfer would.
            case streamed(status: Int, headers: HTTPHeaders, totalBytes: Int)
            // A body with a shape: chunks, delays, a fault.
            case shaped(status: Int, headers: HTTPHeaders, bytes: [UInt8], pacing: Pacing)
            // A file a server holds, answered as the request asks.
            case served(Resource, pacing: Pacing)
            case failure(URLError.Code)
            case hang
        }

        let kind: Kind
        var delay: Duration

        init(_ kind: Kind, delay: Duration = .zero) {
            self.kind = kind
            self.delay = delay
        }

        /// A response with `code`, headers and a text body.
        public static func status(_ code: Int, headers: HTTPHeaders = [:], body: String = "") -> Step {
            Step(.response(status: code, headers: headers, body: Array(body.utf8)))
        }

        /// A response with `code` and a body of bytes.
        public static func bytes(_ body: [UInt8], status: Int = 200, headers: HTTPHeaders = [:]) -> Step {
            Step(.response(status: status, headers: headers, body: body))
        }

        /// A `200` (or `status`) response with a JSON body and
        /// `Content-Type: application/json`.
        public static func json(_ text: String, status: Int = 200, headers: HTTPHeaders = [:]) -> Step {
            var headers = headers
            if !headers.contains("Content-Type") { headers["Content-Type"] = "application/json" }
            return Step(.response(status: status, headers: headers, body: Array(text.utf8)))
        }

        /// A response whose body is `totalBytes` long, never allocated: a
        /// 2 GB download costs the test nothing, and the transport aborts it
        /// at the client's byte limit.
        public static func oversized(_ totalBytes: Int, status: Int = 200, headers: HTTPHeaders = [:]) -> Step {
            Step(.streamed(status: status, headers: headers, totalBytes: totalBytes))
        }

        /// A response whose body arrives in chunks of `chunkSize` bytes, with
        /// the `Content-Length` of the whole of it (unless `headers` has one:
        /// a server may promise more than it delivers), and whatever goes
        /// wrong part-way if `fault` says so. `chunkDelay` is waited, on the
        /// ambient clock, before every chunk.
        public static func streaming(
            _ body: [UInt8], status: Int = 200, headers: HTTPHeaders = [:], chunkSize: Int = 16 * 1024,
            chunkDelay: Duration = .zero, fault: Fault? = nil
        ) -> Step {
            precondition(chunkSize > 0, "a chunk has at least one byte")
            var headers = headers
            if !headers.contains("Content-Length") { headers["Content-Length"] = String(body.count) }
            return Step(.shaped(
                status: status, headers: headers, bytes: body,
                pacing: Pacing(chunkSize: chunkSize, chunkDelay: chunkDelay, fault: fault)))
        }

        /// The answer of a server that holds `resource`, to this request:
        /// the whole file, the part a `Range` asks for, or a `416`, with the
        /// validators a real server sends. Body chunks and faults are as for
        /// ``streaming(_:status:headers:chunkSize:chunkDelay:fault:)``.
        public static func serving(
            _ resource: Resource, chunkSize: Int = 16 * 1024, chunkDelay: Duration = .zero, fault: Fault? = nil
        ) -> Step {
            precondition(chunkSize > 0, "a chunk has at least one byte")
            return Step(.served(resource, pacing: Pacing(chunkSize: chunkSize, chunkDelay: chunkDelay, fault: fault)))
        }

        /// The request fails with this `URLError` code.
        public static func failure(_ code: URLError.Code) -> Step {
            Step(.failure(code))
        }

        /// The server never answers: the request waits, on no clock, until it is cancelled.
        public static let hang = Step(.hang)

        /// This step, after waiting `delay` on the ambient clock.
        public func after(_ delay: Duration) -> Step {
            Step(kind, delay: delay)
        }
    }

    private struct Route {
        var method: HTTPMethod
        var host: String?
        var path: String
        var query: [URLQueryItem]?
        var steps: [Step]
        var fallback: Step?
        var next = 0

        func matches(_ method: HTTPMethod, _ url: URL) -> Bool {
            guard self.method == method, path == url.path else { return false }
            if let host, host != url.host { return false }
            if let query {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                return items == query
            }
            return true
        }

        func sameRoute(as other: Route) -> Bool {
            method == other.method && host == other.host && path == other.path && query == other.query
        }

        mutating func takeStep() -> Step? {
            if next < steps.count {
                defer { next += 1 }
                return steps[next]
            }
            return fallback ?? steps.last
        }
    }

    private struct State {
        var routes: [Route] = []
        var requests: [HTTPRequest] = []
        var inFlight = 0
        var maxInFlight = 0
        var aborted = 0
    }

    private let state = Mutex(State())
    private let unscripted: Step

    /// - Parameter unscripted: The answer to a request no route matches; a
    ///   `404` by default. Such a request is recorded like any other, and
    ///   listed in ``unscriptedRequests``.
    public init(unscripted: Step = .status(404, body: "no script for this request")) {
        self.unscripted = unscripted
    }

    /// Scripts the route `request` names: its method, its path (and host,
    /// when it is an absolute URL) and, if it has one, its query. Steps are
    /// consumed one per matching request; when they run out the `then` step
    /// answers every further request, or the last step again if there is
    /// none. Scripting a route again replaces its script.
    public func on(_ request: HTTPRequest, respond steps: [Step], then fallback: Step? = nil) {
        precondition(!steps.isEmpty || fallback != nil, "a route needs at least one step")
        var route: Route
        switch request.target {
        case .path(let path):
            route = Route(method: request.method, host: nil, path: path, query: request.query.isEmpty ? nil : request.query, steps: steps, fallback: fallback)
        case .url(let url):
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = (components?.queryItems ?? []) + request.query
            route = Route(
                method: request.method, host: url.host, path: url.path, query: query.isEmpty ? nil : query,
                steps: steps, fallback: fallback)
        }
        state.withLock { state in
            if let index = state.routes.firstIndex(where: { $0.sameRoute(as: route) }) {
                state.routes[index] = route
            } else {
                state.routes.append(route)
            }
        }
    }

    /// Every request received, in arrival order, with its final headers.
    public var requests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    /// The requests that matched the route `request` names, using the same
    /// matching as ``on(_:respond:then:)``.
    public func requests(to route: HTTPRequest) -> [HTTPRequest] {
        let probe = Route(
            method: route.method, host: nil, path: Self.path(of: route), query: nil, steps: [], fallback: nil)
        return requests.filter { request in
            guard let url = request.url else { return false }
            return probe.matches(request.method, url)
        }
    }

    /// The number of requests received.
    public var requestCount: Int {
        state.withLock { $0.requests.count }
    }

    /// The requests no route matched.
    public var unscriptedRequests: [HTTPRequest] {
        state.withLock { state in
            state.requests.filter { request in
                guard let url = request.url else { return true }
                return !state.routes.contains { $0.matches(request.method, url) }
            }
        }
    }

    /// Requests being answered right now (waiting out a delay, or hanging).
    public var inFlightCount: Int {
        state.withLock { $0.inFlight }
    }

    /// The most requests ever being answered at once: what a bulkhead test
    /// asserts against.
    public var maxInFlightCount: Int {
        state.withLock { $0.maxInFlight }
    }

    /// Requests abandoned before their response was delivered: cancelled
    /// while waiting or hanging, or cut at the byte limit. A request the
    /// client gave up on is a request the transport saw cancelled.
    public var abortedCount: Int {
        state.withLock { $0.aborted }
    }

    public func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse {
        switch try await begin(request, maxResponseBytes: maxResponseBytes) {
        case .shaped(let plan, let body):
            // The whole body, read as a streaming client would, so that a cut,
            // a fault or a stall is what the caller of `send` sees too.
            var bytes: [UInt8] = []
            while let chunk = try await body.next() { bytes.append(contentsOf: chunk) }
            return HTTPResponse(status: plan.status, headers: plan.headers, body: bytes)
        case .whole(let response):
            return response
        }
    }

    public func stream(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPStreamedResponse {
        switch try await begin(request, maxResponseBytes: maxResponseBytes) {
        case .shaped(let plan, let body):
            return HTTPStreamedResponse(
                status: plan.status, headers: plan.headers,
                body: HTTPBodyStream(next: { try await body.next() }, cancel: { body.cancel() }))
        case .whole(let response):
            return HTTPStreamedResponse(status: response.status, headers: response.headers, body: HTTPBodyStream(bytes: response.body))
        }
    }

    /// What `begin` hands back: a body still to be read, or a response that
    /// is already whole.
    private enum Exchange {
        case shaped(Plan, ScriptedBody)
        case whole(HTTPResponse)
    }

    /// Records the request, finds its step, waits out the step's delay and
    /// answers the head. A request with a body to be read stays in flight
    /// until the body ends; every other one is out of flight when this
    /// returns or throws, and is aborted if it was cancelled or refused.
    private func begin(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> Exchange {
        guard let url = request.url else { throw URLError(.badURL) }
        let step = state.withLock { state -> Step in
            state.requests.append(request)
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            guard let index = state.routes.firstIndex(where: { $0.matches(request.method, url) }),
                  let step = state.routes[index].takeStep() else {
                return unscripted
            }
            return step
        }
        var handedOver = false
        defer { if !handedOver { state.withLock { $0.inFlight -= 1 } } }

        do {
            if step.delay > .zero { try await Ambient.sleep(for: step.delay) }
            let plan: Plan
            switch step.kind {
            case .response(let status, let headers, let body):
                if body.count > maxResponseBytes { throw TooLarge() }
                return .whole(HTTPResponse(status: status, headers: headers, body: body))
            case .streamed(let status, var headers, let totalBytes):
                // A server that streams a body says how long it is.
                if !headers.contains("Content-Length") { headers["Content-Length"] = String(totalBytes) }
                plan = Plan(
                    status: status, headers: headers, source: .zeros(totalBytes), pacing: Pacing(chunkSize: 64 * 1024),
                    declaredLength: totalBytes)
            case .shaped(let status, let headers, let bytes, let pacing):
                plan = Plan(
                    status: status, headers: headers, source: .bytes(bytes), pacing: pacing,
                    declaredLength: Int(headers["Content-Length"] ?? "") ?? bytes.count)
            case .served(let resource, let pacing):
                plan = Self.answer(request, from: resource, pacing: pacing)
            case .failure(let code):
                throw URLError(code)
            case .hang:
                try await Self.suspendUntilCancelled()
                throw CancellationError()
            }
            // A declared length over the limit is refused before the first byte.
            if plan.declaredLength > maxResponseBytes { throw TooLarge() }
            handedOver = true
            let body = ScriptedBody(plan, limit: maxResponseBytes) { [self] aborted in
                state.withLock { state in
                    state.inFlight -= 1
                    if aborted { state.aborted += 1 }
                }
            }
            return .shaped(plan, body)
        } catch is TooLarge {
            state.withLock { $0.aborted += 1 }
            throw HTTPTransportError.responseTooLarge(limit: maxResponseBytes)
        } catch let error as CancellationError {
            state.withLock { $0.aborted += 1 }
            throw error
        }
    }

    private struct TooLarge: Error {}

    /// Waits for cancellation and nothing else. A hang that slept on the
    /// clock would be a timer like any other: a simulation that fires the
    /// next timer early would fire it, and a whole virtual lifetime would
    /// pass in one step.
    private static func suspendUntilCancelled() async throws {
        try await CancellationGate().waitUntilCancelled()
    }

    private static func path(of request: HTTPRequest) -> String {
        switch request.target {
        case .path(let path): path
        case .url(let url): url.path
        }
    }
}

/// Resumes one waiter when cancelled, whichever comes first: the task
/// waiting being cancelled, or the gate.
final class CancellationGate: Sendable {
    private struct State {
        var cancelled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// Waits, on no clock, until the calling task or the gate is cancelled.
    func waitUntilCancelled() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wait(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func wait(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state -> Bool in
            if state.cancelled { return true }
            state.waiter = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func cancel() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.cancelled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

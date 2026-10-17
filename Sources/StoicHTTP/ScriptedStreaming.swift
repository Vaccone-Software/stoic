public import Foundation
internal import Stoic
internal import Synchronization

// What a scripted transport can say with a body that has a shape: a file a
// server holds, answered with ranges, validators and a 416, and the ways a
// transfer goes wrong half way. Everything that waits does so on the
// ambient clock (or, for a hang, on nothing), so a test decides when.

extension ScriptedTransport {
    /// A file a scripted server holds: what ``Step/serving(_:chunkSize:chunkDelay:fault:)``
    /// answers a request for, as a real server would.
    ///
    /// A request for the whole file is answered `200` with its length and
    /// validators. A request with `Range: bytes=N-` (or `N-M`) is answered
    /// `206` with the `Content-Range` that says where the bytes start and how
    /// long the file is, unless the server does not honour ranges, or an
    /// `If-Range` names a validator the file no longer has: then it is the
    /// whole file again, `200`, which is what such a server does. A range that
    /// starts at or past the end is `416` with `Content-Range: bytes */length`.
    /// Suffix ranges (`bytes=-N`) and several ranges are not scripted: they
    /// are answered as a request for the whole file.
    public struct Resource: Sendable, Hashable {
        public var bytes: [UInt8]
        /// Sent as `ETag`, exactly as written (quotes, `W/` and all).
        public var etag: String?
        /// Sent as `Last-Modified`, exactly as written: an HTTP-date.
        public var lastModified: String?
        /// Whether `Range` is honoured. A server that is not answers every
        /// request with the whole file, `200`.
        public var honoursRange: Bool

        public init(_ bytes: [UInt8], etag: String? = nil, lastModified: String? = nil, honoursRange: Bool = true) {
            self.bytes = bytes
            self.etag = etag
            self.lastModified = lastModified
            self.honoursRange = honoursRange
        }
    }

    /// What goes wrong with a body part-way through. `after` counts the body
    /// bytes of *this response* delivered when it happens (not offsets in the
    /// file), and a fault whose offset is past the end of the body never
    /// happens.
    public enum Fault: Sendable, Hashable {
        /// The connection is lost: the body ends with `URLError.networkConnectionLost`.
        case cut(after: Int)
        /// The body ends with this error.
        case fail(after: Int, URLError.Code)
        /// The server goes quiet for `duration`, on the ambient clock, and
        /// then goes on.
        case stall(after: Int, for: Duration)
        /// The server goes quiet and never goes on: the read waits, on no
        /// clock, until it is cancelled.
        case hang(after: Int)

        var offset: Int {
            switch self {
            case .cut(let offset), .fail(let offset, _), .stall(let offset, _), .hang(let offset): offset
            }
        }
    }

    /// How a scripted body is cut into chunks, and what happens to it.
    struct Pacing: Sendable {
        var chunkSize = 16 * 1024
        var chunkDelay = Duration.zero
        var fault: Fault?
    }

    /// Where a scripted body's bytes come from: held, or never allocated.
    enum BodySource: Sendable {
        case bytes([UInt8])
        case zeros(Int)

        var count: Int {
            switch self {
            case .bytes(let bytes): bytes.count
            case .zeros(let count): count
            }
        }

        func slice(_ offset: Int, _ count: Int) -> [UInt8] {
            switch self {
            case .bytes(let bytes): Array(bytes[offset..<offset + count])
            case .zeros: [UInt8](repeating: 0, count: count)
            }
        }
    }

    /// What a step comes to for one request: the head, and the body to be
    /// delivered.
    struct Plan: Sendable {
        var status: Int
        var headers: HTTPHeaders
        var source: BodySource
        var pacing: Pacing
        /// The length the server declared, which a transport that honours a
        /// limit refuses before the first byte.
        var declaredLength: Int
    }

    /// The answer a server holding `resource` gives `request`.
    static func answer(_ request: HTTPRequest, from resource: Resource, pacing: Pacing) -> Plan {
        var headers = HTTPHeaders()
        if let etag = resource.etag { headers["ETag"] = etag }
        if let lastModified = resource.lastModified { headers["Last-Modified"] = lastModified }
        if resource.honoursRange { headers["Accept-Ranges"] = "bytes" }
        let total = resource.bytes.count
        func whole() -> Plan {
            headers["Content-Length"] = String(total)
            return Plan(status: 200, headers: headers, source: .bytes(resource.bytes), pacing: pacing, declaredLength: total)
        }
        guard resource.honoursRange, let range = request.headers["Range"].flatMap(ByteRange.init) else { return whole() }
        if let validator = request.headers["If-Range"], !resource.matches(ifRange: validator) { return whole() }
        guard range.start < total else {
            headers["Content-Range"] = "bytes */\(total)"
            headers["Content-Length"] = "0"
            return Plan(status: 416, headers: headers, source: .bytes([]), pacing: pacing, declaredLength: 0)
        }
        let end = min(range.end ?? total - 1, total - 1)
        headers["Content-Range"] = "bytes \(range.start)-\(end)/\(total)"
        headers["Content-Length"] = String(end - range.start + 1)
        return Plan(
            status: 206, headers: headers, source: .bytes(Array(resource.bytes[range.start...end])), pacing: pacing,
            declaredLength: end - range.start + 1
        )
    }

    /// `bytes=N-` or `bytes=N-M`; nothing else is scripted.
    struct ByteRange {
        var start: Int
        var end: Int?

        init?(_ header: String) {
            guard header.hasPrefix("bytes=") else { return nil }
            let parts = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let start = Int(parts[0]), start >= 0 else { return nil }
            if parts[1].isEmpty {
                end = nil
            } else if let end = Int(parts[1]), end >= start {
                self.end = end
            } else {
                return nil
            }
            self.start = start
        }
    }
}

extension ScriptedTransport.Resource {
    /// Whether an `If-Range` validator still names this file: its strong
    /// `ETag`, or its `Last-Modified`, compared as RFC 9110 says (strongly).
    fileprivate func matches(ifRange validator: String) -> Bool {
        if let etag, !etag.hasPrefix("W/"), validator == etag { return true }
        if let lastModified, validator == lastModified { return true }
        return false
    }
}

/// One scripted body being delivered, chunk by chunk, to one reader.
///
/// The reader asks, and the body answers on the ambient clock: a chunk delay
/// or a stall is a sleep a `TestClock` must advance, a hang waits for
/// cancellation only. It tells its transport when it ends, however it ends,
/// so the transport's counts of requests in flight and requests aborted are
/// right whether the body was read to its end, failed, or was walked away from.
final class ScriptedBody: Sendable {
    private enum Phase {
        case running
        /// Read to its end.
        case ended
        /// Ended by a failure the reader was told of; further reads find nothing.
        case failed
        /// Abandoned by its reader.
        case cancelled
    }

    private struct State {
        var delivered = 0
        var faultSpent = false
        var phase = Phase.running
    }

    private let plan: ScriptedTransport.Plan
    private let limit: Int
    private let finish: @Sendable (_ aborted: Bool) -> Void
    private let state = Mutex(State())
    private let gate = CancellationGate()

    /// - Parameters:
    ///   - limit: The most bytes the body may deliver.
    ///   - finish: Told once, when the body has ended: whether it was
    ///     abandoned (cancelled, failed, cut or over the limit) rather than
    ///     read to its end.
    init(_ plan: ScriptedTransport.Plan, limit: Int, finish: @escaping @Sendable (_ aborted: Bool) -> Void) {
        self.plan = plan
        self.limit = limit
        self.finish = finish
    }

    deinit {
        // A body that was never read to its end is abandoned.
        end(.cancelled)
    }

    private func end(_ phase: Phase) {
        let first = state.withLock { state -> Bool in
            guard state.phase == .running else { return false }
            state.phase = phase
            return true
        }
        if first { finish(phase != .ended) }
    }

    /// Abandons the body: a read that is hanging wakes with `CancellationError`.
    func cancel() {
        end(.cancelled)
        gate.cancel()
    }

    func next() async throws -> [UInt8]? {
        do {
            return try await advance()
        } catch is CancellationError {
            end(.cancelled)
            throw CancellationError()
        } catch {
            end(.failed)
            throw error
        }
    }

    private func advance() async throws -> [UInt8]? {
        enum Step {
            case ended
            case cancelled
            case fault(ScriptedTransport.Fault)
            case chunk(offset: Int, count: Int)
            case overLimit
        }
        let step = state.withLock { state -> Step in
            switch state.phase {
            case .ended, .failed: return .ended
            case .cancelled: return .cancelled
            case .running: break
            }
            let total = plan.source.count
            if let fault = plan.pacing.fault, !state.faultSpent, fault.offset <= state.delivered {
                state.faultSpent = true
                return .fault(fault)
            }
            if state.delivered >= total { return .ended }
            var count = min(max(1, plan.pacing.chunkSize), total - state.delivered)
            if let fault = plan.pacing.fault, !state.faultSpent, fault.offset > state.delivered {
                count = min(count, fault.offset - state.delivered)
            }
            let room = limit - state.delivered
            if room <= 0 { return .overLimit }
            count = min(count, room)
            return .chunk(offset: state.delivered, count: count)
        }
        switch step {
        case .ended:
            end(.ended)
            return nil
        case .cancelled:
            throw CancellationError()
        case .overLimit:
            throw HTTPTransportError.responseTooLarge(limit: limit)
        case .fault(let fault):
            switch fault {
            case .cut:
                throw URLError(.networkConnectionLost)
            case .fail(_, let code):
                throw URLError(code)
            case .stall(_, let duration):
                try await Ambient.sleep(for: duration)
                return try await advance()
            case .hang:
                try await gate.waitUntilCancelled()
                throw CancellationError()
            }
        case .chunk(let offset, let count):
            if plan.pacing.chunkDelay > .zero { try await Ambient.sleep(for: plan.pacing.chunkDelay) }
            // A cancelled body delivers no more, even a chunk it was about to.
            let abandoned = state.withLock { state -> Bool in
                guard state.phase == .running else { return true }
                state.delivered += count
                return false
            }
            if abandoned { throw CancellationError() }
            return plan.source.slice(offset, count)
        }
    }
}

internal import Foundation
#if canImport(FoundationNetworking)
// URLSession and HTTPURLResponse live here on Linux.
internal import FoundationNetworking
#endif
internal import Synchronization

/// What the streamed transfers of one transport did. The tests read it: a
/// bound that is only claimed is a bound nobody has seen hold.
final class StreamStatistics: Sendable {
    private struct Counts {
        var peakBufferedBytes = 0
        var suspensions = 0
        var resumptions = 0
    }

    private let counts = Mutex(Counts())

    /// The most body bytes any streamed transfer has held for its consumer.
    var peakBufferedBytes: Int { counts.withLock { $0.peakBufferedBytes } }
    /// How often a transfer stopped taking bytes from the system, its buffer
    /// full, for want of a consumer (Apple platforms).
    var suspensions: Int { counts.withLock { $0.suspensions } }
    /// How often a consumer's read let it take bytes again.
    var resumptions: Int { counts.withLock { $0.resumptions } }

    func noteBuffered(_ bytes: Int) {
        counts.withLock { $0.peakBufferedBytes = max($0.peakBufferedBytes, bytes) }
    }

    func noteSuspension() { counts.withLock { $0.suspensions += 1 } }
    func noteResumption() { counts.withLock { $0.resumptions += 1 } }
}

/// One streamed response on Linux: the buffer between a data task's delegate
/// callbacks and the task reading the body. (Apple platforms pull the body
/// from `bytes(for:)` instead: `PulledTransfer`.)
///
/// The buffer is not bounded. swift-corelibs-foundation restarts a suspended
/// data task from its first byte when it is resumed (the behaviour Apple's
/// documentation describes for every task that is not a download), which
/// would hand the consumer the body again from zero, and it has no
/// `bytes(for:)`; so the task is never suspended, and the buffer holds what
/// the consumer has not yet taken (design/19, Streaming).
///
/// The consumer is told of the end, or of a failure, only after it has taken
/// every chunk that arrived first: bytes that reached the buffer are valid
/// whatever happened next.
final class StreamTransfer: TransferSink {
    private enum End {
        case finished
        case failed(any Error)
    }

    /// Who is parked in a continuation, waiting on the transfer. One slot, so
    /// the head and a reader are never both waiting: the head is awaited before
    /// the task resumes, and the body is read only once the head has arrived.
    private enum Parked {
        case nobody
        /// The caller of `awaitHead`, until the head arrives or the transfer ends.
        case head(CheckedContinuation<HTTPURLResponse, any Error>)
        /// The consumer, waiting for a chunk or the end. The buffer is empty:
        /// a reader parks because there was nothing to take, and what arrives
        /// meanwhile goes to it.
        case reader(CheckedContinuation<[UInt8]?, any Error>)
    }

    /// Where the transfer is, apart from who is waiting on it.
    private enum Phase {
        /// Bytes can still arrive.
        case live
        /// Over, and the consumer not yet told: it is told once it has taken
        /// every chunk that arrived first.
        case ending(End)
        /// The consumer has been told of the end or of the failure; reads
        /// that follow return the end.
        case endDelivered
        /// The consumer gave up. Reads throw `CancellationError`, even after
        /// the end was delivered, and nothing that arrives is kept.
        case abandoned

        var isAbandoned: Bool {
            if case .abandoned = self { true } else { false }
        }
    }

    private struct State {
        var task: URLSessionDataTask?
        var parked = Parked.nobody
        var chunks: [[UInt8]] = []
        /// Index of the oldest chunk not yet taken; the array is compacted
        /// when enough have gone.
        var first = 0
        var buffered = 0
        var received = 0
        var phase = Phase.live

        /// The caller waiting for the head, taken out of its slot.
        mutating func takeHead() -> CheckedContinuation<HTTPURLResponse, any Error>? {
            guard case .head(let continuation) = parked else { return nil }
            parked = .nobody
            return continuation
        }

        /// The reader waiting for a chunk, taken out of its slot.
        mutating func takeReader() -> CheckedContinuation<[UInt8]?, any Error>? {
            guard case .reader(let continuation) = parked else { return nil }
            parked = .nobody
            return continuation
        }

        /// Ends the transfer because the head was refused. A refusal replaces
        /// the reason of an ending the consumer has not yet been told of, and
        /// does nothing once it has been told, or has gone.
        mutating func refuseHead(with failure: any Error) {
            switch phase {
            case .live, .ending: phase = .ending(.failed(failure))
            case .endDelivered, .abandoned: break
            }
        }
    }

    private let limit: Int
    private let statistics: StreamStatistics
    /// The request's method: a `HEAD` transfers no body, whatever the status.
    private let method: HTTPMethod
    private let state = Mutex(State())

    init(limit: Int, statistics: StreamStatistics, method: HTTPMethod) {
        self.limit = limit
        self.statistics = statistics
        self.method = method
    }

    func attach(_ task: URLSessionDataTask) {
        state.withLock { $0.task = task }
    }

    /// Waits for the head. Called once, before the task resumes: a head that
    /// arrives before anyone waits for it has nobody to go to. Nothing here can
    /// tell that from a head that has not come yet, so the order is the caller's
    /// to keep. A second wait, or one after a reader has parked, would drop a
    /// continuation, and is refused.
    func awaitHead(_ continuation: CheckedContinuation<HTTPURLResponse, any Error>) {
        let abandoned = state.withLock { state -> Bool in
            if state.phase.isAbandoned { return true }
            switch state.parked {
            case .nobody:
                state.parked = .head(continuation)
                return false
            case .head, .reader:
                preconditionFailure("the head is awaited once, before the task resumes")
            }
        }
        if abandoned { continuation.resume(throwing: CancellationError()) }
    }

    // MARK: The session's side

    func receive(_ response: URLResponse) -> Bool {
        enum Verdict {
            case head(HTTPURLResponse)
            case refused(any Error)
        }
        let (continuation, verdict) = state.withLock { state -> (CheckedContinuation<HTTPURLResponse, any Error>?, Verdict) in
            let continuation = state.takeHead()
            guard let http = response as? HTTPURLResponse else {
                let failure = URLError(.badServerResponse)
                state.refuseHead(with: failure)
                return (continuation, .refused(failure))
            }
            // A HEAD, 204 or 304 transfers no body. Content-Length is the size
            // a GET would have sent, not bytes about to arrive. Bytes that do
            // arrive are still counted in `receive(_: Data)`.
            let declaresABody = ResponseBody.willBeTransferred(method: method, status: http.statusCode)
            if declaresABody, response.expectedContentLength > Int64(limit) {
                let failure = HTTPTransportError.responseTooLarge(limit: limit)
                state.refuseHead(with: failure)
                return (continuation, .refused(failure))
            }
            return (continuation, .head(http))
        }
        switch verdict {
        case .head(let http):
            continuation?.resume(returning: http)
            return true
        case .refused(let failure):
            continuation?.resume(throwing: failure)
            return false
        }
    }

    func receive(_ data: Data) -> Bool {
        enum Delivery {
            case none
            case chunk(CheckedContinuation<[UInt8]?, any Error>, [UInt8])
            case failure(CheckedContinuation<[UInt8]?, any Error>)
        }
        let (keepGoing, delivery) = state.withLock { state -> (Bool, Delivery) in
            // Whatever follows an abandoned or ended transfer is dropped.
            guard case .live = state.phase else { return (false, .none) }
            var bytes = [UInt8](data)
            let room = limit - state.received
            let over = bytes.count > room
            if over { bytes.removeSubrange(room...) }
            state.received += bytes.count
            if over { state.phase = .ending(.failed(HTTPTransportError.responseTooLarge(limit: limit))) }

            var delivery = Delivery.none
            if !bytes.isEmpty {
                if let waiter = state.takeReader() {
                    // A waiting consumer means an empty buffer: it takes the chunk directly.
                    delivery = .chunk(waiter, bytes)
                } else {
                    state.chunks.append(bytes)
                    state.buffered += bytes.count
                    statistics.noteBuffered(state.buffered)
                }
            }
            if over, case .none = delivery, let waiter = state.takeReader() {
                state.phase = .endDelivered
                delivery = .failure(waiter)
            }
            return (!over, delivery)
        }
        switch delivery {
        case .none: break
        case .chunk(let waiter, let bytes): waiter.resume(returning: bytes)
        case .failure(let waiter): waiter.resume(throwing: HTTPTransportError.responseTooLarge(limit: limit))
        }
        return keepGoing
    }

    func complete(error: (any Error)?) {
        enum Delivery {
            case none
            case end(CheckedContinuation<[UInt8]?, any Error>)
            case failure(CheckedContinuation<[UInt8]?, any Error>, any Error)
        }
        let (head, headFailure, delivery) = state.withLock { state -> (CheckedContinuation<HTTPURLResponse, any Error>?, any Error, Delivery) in
            state.task = nil
            let head = state.takeHead()
            let headFailure: any Error = state.phase.isAbandoned ? CancellationError() : (error ?? URLError(.badServerResponse))
            // The first ending stands: a refusal or a limit passed has already
            // said why the transfer is over.
            if case .live = state.phase {
                state.phase = .ending(error.map { .failed($0) } ?? .finished)
            }
            var delivery = Delivery.none
            if case .ending(let ending) = state.phase, state.first == state.chunks.count, let waiter = state.takeReader() {
                state.phase = .endDelivered
                switch ending {
                case .finished: delivery = .end(waiter)
                case .failed(let failure): delivery = .failure(waiter, failure)
                }
            }
            return (head, headFailure, delivery)
        }
        head?.resume(throwing: headFailure)
        switch delivery {
        case .none: break
        case .end(let waiter): waiter.resume(returning: nil)
        case .failure(let waiter, let failure): waiter.resume(throwing: failure)
        }
    }

    // MARK: The consumer's side

    /// Whether a reader is parked, waiting for a chunk or the end. The tests
    /// read it: a chunk that arrives once the reader is parked goes straight
    /// to it, and nothing else says the reader has got that far.
    var isWaitingForChunk: Bool {
        state.withLock { state in
            if case .reader = state.parked { true } else { false }
        }
    }

    /// The next chunk, or `nil` at the end of the body.
    func next() async throws -> [UInt8]? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8]?, any Error>) in
                enum Step {
                    case chunk([UInt8])
                    case end
                    case failure(any Error)
                    case waiting
                }
                let step = state.withLock { state -> Step in
                    if state.phase.isAbandoned { return .failure(CancellationError()) }
                    if state.first < state.chunks.count {
                        let chunk = state.chunks[state.first]
                        state.first += 1
                        if state.first == state.chunks.count {
                            state.chunks.removeAll(keepingCapacity: true)
                            state.first = 0
                        } else if state.first >= 64 {
                            state.chunks.removeFirst(state.first)
                            state.first = 0
                        }
                        state.buffered -= chunk.count
                        return .chunk(chunk)
                    }
                    if case .ending(let ending) = state.phase {
                        state.phase = .endDelivered
                        switch ending {
                        case .finished: return .end
                        case .failed(let failure): return .failure(failure)
                        }
                    }
                    if case .endDelivered = state.phase { return .end }
                    switch state.parked {
                    case .nobody:
                        state.parked = .reader(continuation)
                        return .waiting
                    case .reader:
                        preconditionFailure("two tasks are reading one response body")
                    case .head:
                        preconditionFailure("the body is read before its head has arrived")
                    }
                }
                switch step {
                case .chunk(let chunk): continuation.resume(returning: chunk)
                case .end: continuation.resume(returning: nil)
                case .failure(let failure): continuation.resume(throwing: failure)
                case .waiting: break
                }
            }
        } onCancel: {
            abandon()
        }
    }

    /// Ends the transfer from the consumer's side: the data task is
    /// cancelled, what was buffered is dropped, and a reader that is waiting
    /// or comes later gets `CancellationError`. Harmless after the end.
    func abandon() {
        let (task, parked) = state.withLock { state -> (URLSessionDataTask?, Parked) in
            guard !state.phase.isAbandoned else { return (nil, .nobody) }
            state.phase = .abandoned
            state.chunks.removeAll()
            state.first = 0
            state.buffered = 0
            let parked = state.parked
            state.parked = .nobody
            return (state.task, parked)
        }
        switch parked {
        case .nobody: break
        case .head(let head): head.resume(throwing: CancellationError())
        case .reader(let waiter): waiter.resume(throwing: CancellationError())
        }
        task?.cancel()
    }
}

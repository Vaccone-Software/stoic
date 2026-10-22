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
    /// How often a transfer stopped the system reading, for want of a consumer.
    var suspensions: Int { counts.withLock { $0.suspensions } }
    /// How often a drained buffer let it read again.
    var resumptions: Int { counts.withLock { $0.resumptions } }

    func noteBuffered(_ bytes: Int) {
        counts.withLock { $0.peakBufferedBytes = max($0.peakBufferedBytes, bytes) }
    }

    func noteSuspension() { counts.withLock { $0.suspensions += 1 } }
    func noteResumption() { counts.withLock { $0.resumptions += 1 } }
}

/// One streamed response: the buffer between a data task's delegate callbacks
/// and the task reading the body.
///
/// The buffer is bounded. When it holds `bufferLimit` bytes the data task is
/// suspended, which stops the system reading from the connection, and it is
/// resumed when the consumer has drained the buffer to a quarter of the limit
/// (so it does not flap on every chunk). The suspending and resuming happen
/// under the state's lock, with the decision that causes them: done outside
/// it, a resume could run before the suspend it answers and leave a consumer
/// waiting on a task that nothing will wake. Both calls only enqueue work on
/// the session, so the lock is not held across anything that waits.
///
/// The consumer is told of the end, or of a failure, only after it has taken
/// every chunk that arrived first: bytes that reached the buffer are valid
/// whatever happened next.
final class StreamTransfer: TransferSink {
    private enum End {
        case finished
        case failed(any Error)
    }

    private struct State {
        var task: URLSessionDataTask?
        var head: CheckedContinuation<HTTPURLResponse, any Error>?
        var chunks: [[UInt8]] = []
        /// Index of the oldest chunk not yet taken; the array is compacted
        /// when enough have gone.
        var first = 0
        var buffered = 0
        var waiter: CheckedContinuation<[UInt8]?, any Error>?
        var received = 0
        var ending: End?
        var endDelivered = false
        var suspended = false
        var abandoned = false
    }

    /// Whether a full buffer suspends the data task. On Apple platforms it does,
    /// and the system stops reading (measured: the server's sends block, and
    /// every byte arrives in order after the resume). It does not elsewhere:
    /// swift-corelibs-foundation restarts a suspended data task from its first byte
    /// when it is resumed (the behaviour Apple's own documentation describes for
    /// every task that is not a download), which would hand the consumer the body
    /// again from zero. On Linux the buffer is therefore not bounded: it holds
    /// what the consumer has not yet taken (design/19, Streaming).
    static var suspendsTask: Bool {
        #if canImport(Darwin)
        true
        #else
        false
        #endif
    }

    private let limit: Int
    private let bufferLimit: Int
    private let statistics: StreamStatistics
    /// The request's method: a `HEAD` transfers no body, whatever the status.
    private let method: HTTPMethod
    private let state = Mutex(State())

    init(limit: Int, bufferLimit: Int, statistics: StreamStatistics, method: HTTPMethod) {
        self.limit = limit
        self.bufferLimit = bufferLimit
        self.statistics = statistics
        self.method = method
    }

    func attach(_ task: URLSessionDataTask) {
        state.withLock { $0.task = task }
    }

    /// Waits for the head. Called before the task resumes.
    func awaitHead(_ continuation: CheckedContinuation<HTTPURLResponse, any Error>) {
        let abandoned = state.withLock { state -> Bool in
            if state.abandoned { return true }
            state.head = continuation
            return false
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
            let continuation = state.head
            state.head = nil
            guard let http = response as? HTTPURLResponse else {
                let failure = URLError(.badServerResponse)
                state.ending = .failed(failure)
                return (continuation, .refused(failure))
            }
            // A HEAD, 204 or 304 transfers no body. Content-Length is the size
            // a GET would have sent, not bytes about to arrive. Bytes that do
            // arrive are still counted in `receive(_: Data)`.
            let declaresABody = ResponseBody.willBeTransferred(method: method, status: http.statusCode)
            if declaresABody, response.expectedContentLength > Int64(limit) {
                let failure = HTTPTransportError.responseTooLarge(limit: limit)
                state.ending = .failed(failure)
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
            guard !state.abandoned, state.ending == nil else { return (false, .none) }
            var bytes = [UInt8](data)
            let room = limit - state.received
            let over = bytes.count > room
            if over { bytes.removeSubrange(room...) }
            state.received += bytes.count
            if over { state.ending = .failed(HTTPTransportError.responseTooLarge(limit: limit)) }

            var delivery = Delivery.none
            if !bytes.isEmpty {
                if let waiter = state.waiter {
                    // A waiting consumer means an empty buffer: it takes the chunk directly.
                    state.waiter = nil
                    delivery = .chunk(waiter, bytes)
                } else {
                    state.chunks.append(bytes)
                    state.buffered += bytes.count
                    statistics.noteBuffered(state.buffered)
                    if Self.suspendsTask, state.buffered >= bufferLimit, !state.suspended, !over {
                        state.suspended = true
                        state.task?.suspend()
                        statistics.noteSuspension()
                    }
                }
            }
            if over, case .none = delivery, let waiter = state.waiter {
                state.waiter = nil
                state.endDelivered = true
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
            let head = state.head
            state.head = nil
            let headFailure: any Error = state.abandoned ? CancellationError() : (error ?? URLError(.badServerResponse))
            if state.ending == nil {
                state.ending = state.abandoned ? .failed(CancellationError()) : (error.map { .failed($0) } ?? .finished)
            }
            var delivery = Delivery.none
            if let waiter = state.waiter, state.first == state.chunks.count, let ending = state.ending {
                state.waiter = nil
                state.endDelivered = true
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
                    if state.abandoned { return .failure(CancellationError()) }
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
                        if state.suspended, state.buffered <= bufferLimit / 4 {
                            state.suspended = false
                            state.task?.resume()
                            statistics.noteResumption()
                        }
                        return .chunk(chunk)
                    }
                    if let ending = state.ending {
                        if state.endDelivered { return .end }
                        state.endDelivered = true
                        switch ending {
                        case .finished: return .end
                        case .failed(let failure): return .failure(failure)
                        }
                    }
                    precondition(state.waiter == nil, "two tasks are reading one response body")
                    state.waiter = continuation
                    return .waiting
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
        let (task, head, waiter) = state.withLock { state -> (URLSessionDataTask?, CheckedContinuation<HTTPURLResponse, any Error>?, CheckedContinuation<[UInt8]?, any Error>?) in
            guard !state.abandoned else { return (nil, nil, nil) }
            state.abandoned = true
            state.chunks.removeAll()
            state.first = 0
            state.buffered = 0
            let taken = (state.task, state.head, state.waiter)
            state.head = nil
            state.waiter = nil
            return taken
        }
        head?.resume(throwing: CancellationError())
        waiter?.resume(throwing: CancellationError())
        task?.cancel()
    }
}

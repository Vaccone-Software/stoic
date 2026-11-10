#if canImport(Darwin)
internal import Foundation
internal import Synchronization

/// One streamed response, pulled from `URLSession.bytes(for:)` a byte at a
/// time into a ring the consumer takes chunks from (design/19, Streaming).
///
/// **Why pulled.** A data task's delegate is handed what the system has read,
/// and the system reads ahead of a delegate queue that is not running: with
/// the queue held for a second, a loopback server wrote all 268 MB of a body
/// into the process while the transfer had asked to stop at 512 KiB. Suspending
/// the task cannot recall what is already queued. `bytes(for:)` is flow
/// controlled inside the loading system: when its reader stops, the system
/// stops reading at a window of its own (measured at 11 to 13 MB on macOS 27,
/// whatever the load, and set by no API), and the server waits.
///
/// **The bound.** What this transfer holds is at most `capacity` bytes,
/// exactly: the pump takes no byte from the system while the ring is full.
/// What the system holds for the connection is its own window on top.
///
/// **The pump** (a task of its own, never on an actor: an actor would hop
/// executors on every byte) stores each byte in the ring and publishes it with
/// one atomic store. It wakes the reader only when the byte the reader asked
/// for has arrived, so a reader that keeps up costs it nothing more.
///
/// **The reader** takes what has arrived, up to `chunk` bytes. When less than
/// a chunk has arrived it waits for a full chunk or for `linger`, whichever
/// comes first: a fast body arrives in full chunks, and a trickle (one event a
/// second) is delivered within `linger` of arriving, not when a chunk fills.
/// The pump cannot tell the reader "nothing more right now": `bytes(for:)`
/// does not say when its next byte would wait.
///
/// The consumer is told of the end, or of a failure, only after it has taken
/// every byte that arrived first.
final class PulledTransfer: Sendable {
    private enum End: Sendable {
        case finished
        case failed(any Error)
    }

    private struct State: Sendable {
        var reader: CheckedContinuation<Void, Never>?
        var pump: CheckedContinuation<Void, Never>?
        var end: End?
        var endDelivered = false
        var abandoned = false
        var reading = false
        var pumpTask: Task<Void, Never>?
        var dataTask: URLSessionDataTask?
    }

    /// The most bytes one chunk carries.
    static let chunkBytes = 65_536
    /// How long a reader waits for a chunk to fill once a byte has arrived.
    static let linger = Duration.milliseconds(1)

    private let limit: Int
    private let capacity: Int
    private let chunk: Int
    private let statistics: StreamStatistics
    private let method: HTTPMethod
    private let ring: ByteRing

    /// Bytes the pump has stored: every one below it may be read.
    private let written = Atomic<Int>(0)
    /// Bytes the reader has taken: every slot below it may be written again.
    private let read = Atomic<Int>(0)
    /// The pump wakes the reader once `written` reaches this; `Int.max` when
    /// no reader waits.
    private let wakeAt = Atomic<Int>(.max)
    /// Whether the pump waits for room in the ring.
    private let pumpWaiting = Atomic<Bool>(false)
    /// Whether the pump has stopped: `State.end` says why.
    private let ended = Atomic<Bool>(false)
    private let state = Mutex(State())

    init(limit: Int, capacity: Int, statistics: StreamStatistics, method: HTTPMethod) {
        self.limit = limit
        self.capacity = capacity
        chunk = min(Self.chunkBytes, capacity)
        self.statistics = statistics
        self.method = method
        ring = ByteRing(capacity: capacity)
    }

    // MARK: The head

    /// Sends `request` and returns the head; the pump then starts taking the
    /// body. A declared length over the limit is refused before the first
    /// byte when a body will be transferred.
    func open(_ request: URLRequest, on session: URLSession) async throws -> HTTPURLResponse {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        let task = bytes.task
        guard let http = response as? HTTPURLResponse else {
            task.cancel()
            throw URLError(.badServerResponse)
        }
        // A HEAD, 204 or 304 transfers no body. Content-Length is the size a
        // GET would have sent, not bytes about to arrive. Bytes that do arrive
        // are still counted by the pump.
        if ResponseBody.willBeTransferred(method: method, status: http.statusCode), response.expectedContentLength > Int64(limit) {
            task.cancel()
            throw HTTPTransportError.responseTooLarge(limit: limit)
        }
        let pump = Task { await self.pump(bytes) }
        let abandoned = state.withLock { state -> Bool in
            state.pumpTask = pump
            state.dataTask = task
            return state.abandoned
        }
        if abandoned {
            pump.cancel()
            task.cancel()
        }
        return http
    }

    // MARK: The pump

    @concurrent
    private func pump(_ bytes: URLSession.AsyncBytes) async {
        var stored = 0
        var slot = 0
        var end = End.finished
        do {
            for try await byte in bytes {
                if stored == limit {
                    // One byte past the limit: the excess is never kept.
                    end = .failed(HTTPTransportError.responseTooLarge(limit: limit))
                    bytes.task.cancel()
                    break
                }
                if stored - read.load(ordering: .sequentiallyConsistent) == capacity {
                    guard await waitForRoom(stored) else { break }
                }
                ring.store(byte, at: slot)
                slot += 1
                if slot == capacity { slot = 0 }
                stored += 1
                written.store(stored, ordering: .sequentiallyConsistent)
                if stored >= wakeAt.load(ordering: .sequentiallyConsistent) { wakeReader() }
            }
        } catch {
            end = .failed(error)
        }
        state.withLock { state in
            if state.end == nil { state.end = end }
            state.pumpTask = nil
            state.dataTask = nil
        }
        ended.store(true, ordering: .sequentiallyConsistent)
        wakeReader()
    }

    /// Waits until the reader has taken a byte of a full ring. `false` when
    /// the transfer was abandoned meanwhile.
    private func waitForRoom(_ stored: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.abandoned { return true }
                pumpWaiting.store(true, ordering: .sequentiallyConsistent)
                if stored - read.load(ordering: .sequentiallyConsistent) < capacity {
                    pumpWaiting.store(false, ordering: .sequentiallyConsistent)
                    return true
                }
                state.pump = continuation
                statistics.noteBuffered(capacity)
                statistics.noteSuspension()
                return false
            }
            if now { continuation.resume() }
        }
        return !state.withLock { $0.abandoned }
    }

    private func wakePump() {
        let pump = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer {
                state.pump = nil
                pumpWaiting.store(false, ordering: .sequentiallyConsistent)
            }
            return state.pump
        }
        if let pump {
            statistics.noteResumption()
            pump.resume()
        }
    }

    // MARK: The reader

    private func wakeReader() {
        let reader = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer {
                state.reader = nil
                wakeAt.store(.max, ordering: .sequentiallyConsistent)
            }
            return state.reader
        }
        reader?.resume()
    }

    /// Parks the reader until `written` reaches `target`, the pump stops, the
    /// transfer is abandoned, or something wakes it: every wake is a hint, and
    /// the caller reads the conditions again.
    private func park(until target: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.abandoned { return true }
                wakeAt.store(target, ordering: .sequentiallyConsistent)
                if written.load(ordering: .sequentiallyConsistent) >= target || ended.load(ordering: .sequentiallyConsistent) {
                    wakeAt.store(.max, ordering: .sequentiallyConsistent)
                    return true
                }
                state.reader = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    private var isAbandoned: Bool { state.withLock { $0.abandoned } }

    /// The next chunk, or `nil` at the end of the body.
    func next() async throws -> [UInt8]? {
        let second = state.withLock { state -> Bool in
            defer { state.reading = true }
            return state.reading
        }
        precondition(!second, "two tasks are reading one response body")
        defer { state.withLock { $0.reading = false } }
        return try await withTaskCancellationHandler {
            try await take()
        } onCancel: {
            abandon()
        }
    }

    private func take() async throws -> [UInt8]? {
        if isAbandoned { throw CancellationError() }
        let taken = read.load(ordering: .relaxed)
        while written.load(ordering: .sequentiallyConsistent) == taken {
            if ended.load(ordering: .sequentiallyConsistent) {
                // The pump's last bytes are published before it ends.
                if written.load(ordering: .sequentiallyConsistent) > taken { break }
                return try deliverEnd()
            }
            await park(until: taken + 1)
            if isAbandoned { throw CancellationError() }
        }
        if written.load(ordering: .sequentiallyConsistent) - taken < chunk, !ended.load(ordering: .sequentiallyConsistent) {
            // Less than a chunk: wait for one, or for `linger`, whichever comes first.
            let clock = ContinuousClock()
            let lingerEnds = clock.now.advanced(by: Self.linger)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Cancelled once the chunk has filled: the wake is not sent.
                    guard (try? await clock.sleep(until: lingerEnds, tolerance: .zero)) != nil else { return }
                    self.wakeReader()
                }
                while written.load(ordering: .sequentiallyConsistent) - taken < chunk, !ended.load(ordering: .sequentiallyConsistent),
                    !isAbandoned, clock.now < lingerEnds
                {
                    await park(until: taken + chunk)
                }
                group.cancelAll()
            }
            if isAbandoned { throw CancellationError() }
        }
        let available = written.load(ordering: .sequentiallyConsistent) - taken
        statistics.noteBuffered(available)
        let count = min(available, chunk)
        let bytes = ring.copy(from: taken % capacity, count: count)
        read.store(taken + count, ordering: .sequentiallyConsistent)
        if pumpWaiting.load(ordering: .sequentiallyConsistent) { wakePump() }
        return bytes
    }

    /// The end, told once: `nil` for a finished body, the failure for one that
    /// failed, then `nil`; `CancellationError` once abandoned.
    private func deliverEnd() throws -> [UInt8]? {
        let end = try state.withLock { state throws(CancellationError) -> End? in
            if state.abandoned { throw CancellationError() }
            if state.endDelivered { return nil }
            state.endDelivered = true
            return state.end
        }
        if case .failed(let failure)? = end { throw failure }
        return nil
    }

    // MARK: Abandoning

    /// Ends the transfer from the consumer's side: the pump and the data task
    /// are cancelled, what was held is dropped, and a reader that is waiting or
    /// comes later gets `CancellationError`. Harmless after the end.
    func abandon() {
        let (reader, pump, pumpTask, dataTask) = state.withLock { state in
            guard !state.abandoned else {
                return (CheckedContinuation<Void, Never>?.none, CheckedContinuation<Void, Never>?.none, Task<Void, Never>?.none, URLSessionDataTask?.none)
            }
            state.abandoned = true
            defer {
                state.reader = nil
                state.pump = nil
            }
            return (state.reader, state.pump, state.pumpTask, state.dataTask)
        }
        reader?.resume()
        pump?.resume()
        pumpTask?.cancel()
        dataTask?.cancel()
    }
}

/// The bytes between the pump and the reader.
///
/// One writer and one reader, never at the same slot: the pump writes a slot
/// only after the reader's `read` says it was taken, and the reader copies a
/// slot only after the pump's `written` says it was stored. Both counters are
/// sequentially consistent atomics in `PulledTransfer`, which orders each
/// slot's write before its read and its read before its next write.
// stoic:allow(unchecked-sendable): one writer and one reader, ordered by PulledTransfer's `written` and `read` (see above)
@safe
final class ByteRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<UInt8>

    init(capacity: Int) {
        precondition(capacity > 0, "a ring needs room for at least one byte")
        self.capacity = capacity
        unsafe storage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        unsafe storage.deallocate()
    }

    /// Stores `byte` at `slot`, which is below `capacity`.
    @inline(__always)
    func store(_ byte: UInt8, at slot: Int) {
        unsafe storage[slot] = byte
    }

    /// `count` bytes from `start`, wrapping at the end of the ring.
    func copy(from start: Int, count: Int) -> [UInt8] {
        let first = min(count, capacity - start)
        return unsafe [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            unsafe buffer.baseAddress!.initialize(from: storage + start, count: first)
            if first < count { unsafe (buffer.baseAddress! + first).initialize(from: storage, count: count - first) }
            initialized = count
        }
    }
}
#endif

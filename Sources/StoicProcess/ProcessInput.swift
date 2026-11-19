#if os(macOS)
internal import Stoic
internal import Darwin
internal import Synchronization

/// A child's standard input: bytes queued in order and written by one
/// writer as fast as the child reads them.
///
/// ``send(_:)-([UInt8])`` (and its `String` form) is synchronous and never blocks: an interface can hand a
/// message to a child from the main actor, and a child that stops reading
/// fills its pipe without holding up the caller. What is queued is bounded
/// (``ChildProcess/Options/inputCapacity``): past it, a send throws
/// ``ProcessError/inputFull(queued:capacity:)`` and queues nothing, rather
/// than holding an unbounded backlog for a child that may never read it.
///
/// Sends are written in the order they were made, each whole, never
/// interleaved with another. ``flush()`` waits until everything sent so far
/// is written; ``finish()`` closes the input once it is, which a child reads
/// as end of file.
public final class ProcessInput: Sendable {
    let descriptor: Descriptor
    let capacity: Int
    let label: String?
    let recorder: Recorder
    private let state = Mutex(State())

    private struct State {
        var queue: [[UInt8]] = []
        var head = 0
        var queued = 0
        /// Bytes sent and bytes written (or given up), since the start.
        var sent = 0
        var settled = 0
        var writing = false
        var finishing = false
        var closed = false
        var flushers: [(id: Int, upTo: Int, waiter: CheckedContinuation<Void, Never>)] = []
        var nextFlusher = 0
    }

    init(_ descriptor: Descriptor, capacity: Int, label: String?, recorder: Recorder) {
        self.descriptor = descriptor
        self.capacity = capacity
        self.label = label
        self.recorder = recorder
    }

    /// Queues `bytes` to be written after everything sent before it.
    ///
    /// - Throws: ``ProcessError/inputClosed`` once the child's input is
    ///   closed (it ended, its input was finished, or it was stopped), and
    ///   ``ProcessError/inputFull(queued:capacity:)`` when the bytes would
    ///   take the queue past its capacity.
    public func send(_ bytes: [UInt8]) throws(ProcessError) {
        guard !bytes.isEmpty else { return }
        let startWriter = try state.withLock { state throws(ProcessError) -> Bool in
            if state.closed || state.finishing { throw .inputClosed }
            guard state.queued + bytes.count <= capacity else {
                throw .inputFull(queued: state.queued, capacity: capacity)
            }
            state.queue.append(bytes)
            state.queued += bytes.count
            state.sent += bytes.count
            guard !state.writing else { return false }
            state.writing = true
            return true
        }
        if startWriter { startWriting() }
    }

    /// Queues the UTF-8 bytes of `text`.
    public func send(_ text: String) throws(ProcessError) {
        try send(Array(text.utf8))
    }

    /// How many bytes are queued and not yet written.
    public var queued: Int { state.withLock { $0.queued } }

    /// Returns once everything sent before the call is written, or will
    /// never be (the input closed). Ends early, with nothing undone, if the
    /// task is cancelled.
    public func flush() async {
        let id = state.withLock { state -> Int in
            defer { state.nextFlusher += 1 }
            return state.nextFlusher
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if state.settled >= state.sent || state.closed || Task.isCancelled { return true }
                    state.flushers.append((id, state.sent, waiter))
                    return false
                }
                if now { waiter.resume() }
            }
        } onCancel: {
            state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard let index = state.flushers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.flushers.remove(at: index).waiter
            }?.resume()
        }
    }

    /// Closes the input once everything sent is written. Further sends throw
    /// ``ProcessError/inputClosed``.
    public func finish() {
        let closeNow = state.withLock { state -> Bool in
            state.finishing = true
            return !state.writing
        }
        if closeNow { close() }
    }

    /// Closes the input now, dropping whatever is queued.
    func close() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.closed = true
            state.queue = []
            state.head = 0
            state.queued = 0
            state.settled = state.sent
            defer { state.flushers = [] }
            return state.flushers.map(\.waiter)
        }
        descriptor.close()
        for waiter in waiting { waiter.resume() }
    }

    /// The one writer. A task of its own, owned by the input: it ends when
    /// the queue is empty, or when the input is closed, which wakes any
    /// wait it is in.
    private func startWriting() {
        Task { [self] in await write() }
    }

    private func write() async {
        while let bytes = nextQueued() {
            var offset = 0
            while offset < bytes.count {
                let written: Int? = descriptor.use { fd in
                    bytes.withUnsafeBytes { raw in
                        unsafe Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    }
                }
                guard let written else { return }           // closed
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN {
                    await descriptor.wait()
                    if descriptor.isClosed { return }
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    // EPIPE: the child closed its end (or ended). Nothing
                    // queued can reach it now.
                    recorder.record(Event("process.input_closed", level: .debug, label: label,
                                         fields: [.init("dropped", .int(bytes.count - offset + queued))]))
                    close()
                    return
                }
            }
            wrote(bytes.count)
        }
    }

    private func nextQueued() -> [UInt8]? {
        let (next, closeNow) = state.withLock { state -> ([UInt8]?, Bool) in
            guard !state.closed, state.head < state.queue.count else {
                state.writing = false
                state.queue = []
                state.head = 0
                return (nil, state.finishing && !state.closed)
            }
            let next = state.queue[state.head]
            state.head += 1
            // Compacted now and then, not on every write.
            if state.head > 64, state.head * 2 > state.queue.count {
                state.queue.removeFirst(state.head)
                state.head = 0
            }
            return (next, false)
        }
        if closeNow { close() }
        return next
    }

    private func wrote(_ count: Int) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.queued -= count
            state.settled += count
            let settled = state.settled
            let ready = state.flushers.filter { $0.upTo <= settled }.map(\.waiter)
            state.flushers.removeAll { $0.upTo <= settled }
            return ready
        }
        for waiter in ready { waiter.resume() }
    }
}
#endif

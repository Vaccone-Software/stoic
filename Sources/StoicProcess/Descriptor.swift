#if os(macOS)
internal import Darwin
internal import Dispatch
internal import Synchronization

/// One end of a pipe this process holds, non-blocking, with a way to wait
/// until it can be read or written without holding a thread.
///
/// The wait is a kqueue readiness source (`DispatchSource`) resumed only
/// while someone waits and suspended again as soon as it fires: nothing is
/// read ahead of the caller, so a child that writes faster than its output
/// is read is held back by the pipe, as it would be by a terminal, and
/// memory never grows with what it writes.
///
/// The descriptor is closed by the source's cancel handler, after the
/// source has stopped looking at it, and never while a `read` or `write`
/// is using it (`use`): closing a number another thread is about to use
/// lets the kernel give it to the next file opened, which that thread would
/// then read or write.
final class Descriptor: Sendable {
    enum Kind { case read, write }

    let fd: Int32
    private let state: Mutex<State>

    private struct State {
        var source: (any DispatchSourceProtocol)?
        /// Resumed (watching) rather than suspended or never activated.
        var watching = false
        var waiter: CheckedContinuation<Void, Never>?
        var closed = false
        /// Woken for a reason other than readiness: the reader should stop
        /// waiting once nothing more is there (see `Reader.endWhenIdle`).
        var nudged = false
        /// `use` calls under way: the close waits for the last.
        var users = 0
        var cancelled = false
    }

    init(_ fd: Int32, _ kind: Kind, queue: DispatchQueue) {
        self.fd = fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // A write to a pipe whose reader has gone raises SIGPIPE, which ends
        // the whole process unless it is ignored; this makes it EPIPE on
        // this descriptor alone, whatever the process does with the signal.
        if kind == .write { _ = fcntl(fd, F_SETNOSIGPIPE, 1) }
        let source: any DispatchSourceProtocol = switch kind {
        case .read: DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        case .write: DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        }
        source.setCancelHandler { _ = Darwin.close(fd) }
        state = Mutex(State(source: source))
        state.withLock { $0.source?.setEventHandler { [weak self] in self?.fired() } }
    }

    /// Returns once the descriptor may be ready, it was closed, it was
    /// nudged, or the task was cancelled. The caller tries again and decides
    /// which it was: readiness is a hint, never a promise.
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.closed || state.nudged || Task.isCancelled { return true }
                    state.waiter = waiter
                    if !state.watching, let source = state.source {
                        state.watching = true
                        source.resume()
                    }
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiter.take() }?.resume()
        }
    }

    /// A descriptor nobody closed (an output nobody read to its end) is
    /// closed as it goes: Dispatch traps on releasing a source that is
    /// suspended or was never activated.
    deinit {
        close()
    }

    /// Ends any wait now and the next one at once.
    func nudge() {
        state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.nudged = true
            return state.waiter.take()
        }?.resume()
    }

    var isNudged: Bool { state.withLock { $0.nudged } }

    /// Runs `body` with the descriptor, unless it is closed (nil). A close
    /// meanwhile waits for it to return.
    func use<R>(_ body: (Int32) -> R) -> R? {
        let open = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.users += 1
            return true
        }
        guard open else { return nil }
        let result = body(fd)
        state.withLock { state in
            state.users -= 1
            Self.cancelIfDue(&state)
        }
        return result
    }

    /// Stops watching and closes the descriptor (once the source has let go
    /// of it and no `use` holds it). Any wait ends. Safe to call more than
    /// once.
    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.closed else { return nil }
            state.closed = true
            Self.cancelIfDue(&state)
            return state.waiter.take()
        }
        waiter?.resume()
    }

    private static func cancelIfDue(_ state: inout State) {
        guard state.closed, state.users == 0, !state.cancelled, let source = state.source else { return }
        state.cancelled = true
        state.source = nil
        // A suspended or never-activated source must be resumed before it
        // is cancelled and released: Dispatch traps on releasing one that
        // is suspended.
        if !state.watching {
            state.watching = true
            source.resume()
        }
        source.cancel()
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    private func fired() {
        state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.closed, let source = state.source else { return nil }
            if state.watching {
                state.watching = false
                source.suspend()
            }
            return state.waiter.take()
        }?.resume()
    }
}
#endif

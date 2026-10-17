public import Stoic
internal import Synchronization

/// What the network looks like to the app at one moment.
///
/// `satisfied` means a route to the internet exists, not that a given host
/// answers: it is the cheap early signal, not a replacement for a timeout.
/// `isExpensive` (cellular, a personal hotspot) and `isConstrained` (Low Data
/// Mode) are separate from reachability, because a path that is up can still
/// be one the user does not want a large upload on.
public struct NetworkPath: Sendable, Hashable, CustomStringConvertible {
    public enum Status: Sendable, Hashable {
        /// A route exists.
        case satisfied
        /// No route: offline, in airplane mode, or still waiting for an
        /// interface to connect.
        case unsatisfied
    }

    public var status: Status
    /// Cellular, a personal hotspot, or any link the system calls costly.
    public var isExpensive: Bool
    /// Low Data Mode is on for the link.
    public var isConstrained: Bool

    public init(status: Status, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// A route on an unmetered, unrestricted link.
    public static let satisfied = NetworkPath(status: .satisfied)
    /// No route.
    public static let unsatisfied = NetworkPath(status: .unsatisfied)

    /// Whether a route exists.
    public var isReachable: Bool { status == .satisfied }

    public var description: String {
        var text = status == .satisfied ? "satisfied" : "unsatisfied"
        if isExpensive { text += ", expensive" }
        if isConstrained { text += ", constrained" }
        return text
    }
}

/// A source of network path changes.
///
/// The seam over `NWPathMonitor`: code that waits for the network, or backs
/// off while it is down, takes a `PathMonitor` and tests with
/// ``FakePathMonitor``. The system implementation is ``SystemPathMonitor``.
public protocol PathMonitor: Sendable {
    /// A stream of paths: the current one first, then every change.
    ///
    /// Each call is its own subscription. The monitor behind it runs until
    /// the stream is finished or the task iterating it is cancelled or
    /// stops; nothing is left running after.
    func updates() -> AsyncStream<NetworkPath>
}

/// Why ``PathMonitor/waitUntilReachable(until:allowsExpensive:allowsConstrained:settle:)`` gave up.
public enum ReachabilityError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The deadline passed first. `lastPath` is the last path seen, `nil` if none arrived.
    case deadlineExceeded(lastPath: NetworkPath?)
    /// The waiting task was cancelled.
    case cancelled
    /// The monitor's stream ended before a usable path arrived.
    case monitorEnded

    public var description: String {
        switch self {
        case .deadlineExceeded(let path): "deadline exceeded" + (path.map { " (last path: \($0))" } ?? "")
        case .cancelled: "cancelled"
        case .monitorEnded: "monitor ended"
        }
    }
}

extension PathMonitor {
    /// ``updates()`` with flapping removed: a change is delivered only once
    /// it has held for `settle`.
    ///
    /// Radios glitch. A phone walking between access points, a router
    /// restarting, or a tunnel coming up reports "unsatisfied" for a fraction
    /// of a second; an app that reacts to each report cancels and restarts
    /// its work for nothing. Here:
    ///
    /// - the first path is delivered at once, since a consumer needs a
    ///   starting point;
    /// - a later path is delivered after it has stayed the latest for
    ///   `settle` on the ambient clock, and not before;
    /// - a path that goes back to the one already delivered before `settle`
    ///   has passed was a glitch, and nothing is delivered;
    /// - `settle` of zero (or less) delivers every path unchanged;
    /// - a change still waiting when the monitor's stream ends is dropped:
    ///   it never held.
    ///
    /// Two paths are the same when status, expensive and constrained all
    /// match, so a link flipping to expensive settles like any other change.
    ///
    /// - Parameter settle: How long a change must hold. One second by default.
    public func stablePaths(settle: Duration = .seconds(1)) -> AsyncStream<NetworkPath> {
        let source = updates()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let debouncer = Debouncer(settle: settle, continuation: continuation)
            let task = Task { await debouncer.run(source) }
            continuation.onTermination = { _ in
                debouncer.stop()
                task.cancel()
            }
        }
    }

    /// Waits for a usable network path and returns it.
    ///
    /// Returns at once if the path is usable now. Otherwise waits, through
    /// ``stablePaths(settle:)``, so a path that comes up for a moment and
    /// drops again does not release the caller to fail on its first request.
    ///
    /// The wait ends with the earlier of `deadline` and the deadline already
    /// in force (`Deadline.current`), if there is one; with neither it ends
    /// only when the task is cancelled, so give callers a deadline.
    ///
    /// - Parameters:
    ///   - deadline: When to give up.
    ///   - allowsExpensive: Whether an expensive path (cellular) is good enough.
    ///   - allowsConstrained: Whether a Low Data Mode path is good enough.
    ///   - settle: How long a change must hold, as for ``stablePaths(settle:)``.
    /// - Throws: ``ReachabilityError``.
    public func waitUntilReachable(
        until deadline: Deadline? = nil,
        allowsExpensive: Bool = true,
        allowsConstrained: Bool = true,
        settle: Duration = .seconds(1)
    ) async throws(ReachabilityError) -> NetworkPath {
        let requirement = Requirement(allowsExpensive: allowsExpensive, allowsConstrained: allowsConstrained)
        // The earlier of the two, so "did the deadline pass" asks about the
        // one that actually applied.
        let effective: Deadline?
        switch (deadline, Deadline.current) {
        case let (explicit?, current?): effective = explicit.earlier(current)
        case let (explicit?, nil): effective = explicit
        case let (nil, current?): effective = current
        case (nil, nil): effective = nil
        }
        let outcome: WaitOutcome
        if let effective {
            outcome = await withDeadline(effective, label: "reachability.wait") {
                await Self.firstUsable(in: self.stablePaths(settle: settle), requirement)
            }
        } else {
            outcome = await Self.firstUsable(in: stablePaths(settle: settle), requirement)
        }
        if let path = outcome.usable { return path }
        // The deadline first: a wait cut short by an enclosing deadline is
        // cancelled too, and "out of time" is the truer answer.
        if let effective, effective.hasPassed { throw .deadlineExceeded(lastPath: outcome.last) }
        if Task.isCancelled { throw .cancelled }
        throw .monitorEnded
    }

    private static func firstUsable(in paths: AsyncStream<NetworkPath>, _ requirement: Requirement) async -> WaitOutcome {
        var last: NetworkPath?
        for await path in paths {
            last = path
            if requirement.accepts(path) { return WaitOutcome(usable: path, last: path) }
        }
        return WaitOutcome(usable: nil, last: last)
    }
}

private struct Requirement: Sendable {
    let allowsExpensive: Bool
    let allowsConstrained: Bool

    func accepts(_ path: NetworkPath) -> Bool {
        path.isReachable && (allowsExpensive || !path.isExpensive) && (allowsConstrained || !path.isConstrained)
    }
}

private struct WaitOutcome: Sendable {
    let usable: NetworkPath?
    let last: NetworkPath?
}

/// The debounce behind ``PathMonitor/stablePaths(settle:)``.
private final class Debouncer: Sendable {
    private struct Pending {
        let path: NetworkPath
        let generation: UInt64
        let timer: Task<Void, Never>
    }

    private struct State {
        var delivered: NetworkPath?
        var pending: Pending?
        var generation: UInt64 = 0
        var stopped = false
    }

    private let settle: Duration
    private let continuation: AsyncStream<NetworkPath>.Continuation
    private let state = Mutex(State())

    init(settle: Duration, continuation: AsyncStream<NetworkPath>.Continuation) {
        self.settle = settle
        self.continuation = continuation
    }

    func run(_ source: AsyncStream<NetworkPath>) async {
        for await path in source { receive(path) }
        // The monitor ended; a change that never settled is dropped.
        stop()
        continuation.finish()
    }

    func stop() {
        let timer = state.withLock { state -> Task<Void, Never>? in
            state.stopped = true
            defer { state.pending = nil }
            return state.pending?.timer
        }
        timer?.cancel()
    }

    private func receive(_ path: NetworkPath) {
        let superseded = state.withLock { state -> Task<Void, Never>? in
            guard !state.stopped else { return nil }
            // The first path, or no debouncing: deliver now.
            if state.delivered == nil || settle <= .zero {
                state.delivered = path
                continuation.yield(path)
                return nil
            }
            // Back to what was delivered: the change was a glitch.
            if path == state.delivered {
                defer { state.pending = nil }
                return state.pending?.timer
            }
            // Already waiting on this very path: let its timer run.
            if let pending = state.pending, pending.path == path { return nil }
            state.generation += 1
            let generation = state.generation
            let old = state.pending?.timer
            let timer = Task { [settle] in
                do { try await Ambient.sleep(for: settle) } catch { return }
                self.settled(path, generation: generation)
            }
            state.pending = Pending(path: path, generation: generation, timer: timer)
            return old
        }
        superseded?.cancel()
    }

    private func settled(_ path: NetworkPath, generation: UInt64) {
        state.withLock { state in
            guard !state.stopped, let pending = state.pending, pending.generation == generation else { return }
            state.pending = nil
            state.delivered = path
            continuation.yield(path)
        }
    }
}

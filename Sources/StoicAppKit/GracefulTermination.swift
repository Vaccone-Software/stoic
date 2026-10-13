#if canImport(AppKit)
public import AppKit
public import Stoic

/// Lets a Mac app finish its asynchronous shutdown before it quits — but
/// never lets a hung shutdown stop it from quitting.
///
/// `applicationWillTerminate(_:)` is synchronous, and the process exits as
/// soon as it returns, so async cleanup started there is cut off. AppKit's
/// answer is `applicationShouldTerminate(_:)` returning `.terminateLater`,
/// then `reply(toApplicationShouldTerminate: true)` once cleanup is done.
/// This type does that, with a hard deadline: if shutdown has not finished
/// by then, the app quits anyway and the overrun is reported.
///
/// The shutdown runs *off* the main actor, and the deadline is kept on it. A
/// step that blocks its thread — a synchronous call into a framework that has
/// stopped answering — therefore cannot hold the main actor, and with it the
/// timer and the reply, hostage: the deadline still fires. What is left
/// running at that point is named in `lifecycle.terminate_overran`
/// (`abandoned_work`, `tasks_running` and the labels of both), the same
/// accounting ``abandoningAfter(_:label:limit:clock:qos:fileID:line:operation:)``
/// keeps. Work that must run on the main actor hops there itself, with
/// `await MainActor.run { … }`.
///
///     @main final class AppDelegate: NSObject, NSApplicationDelegate {
///         private var app: Task<Void, any Error>?
///         private lazy var termination = GracefulTermination(deadline: .seconds(8)) { [app] in
///             app?.cancel()                 // a ServiceGraph's run ends, stopping every service
///             _ = await app?.result
///         }
///
///         func applicationDidFinishLaunching(_ notification: Notification) {
///             app = Task { try await graph.run { services in try await AppModel(services).run() } }
///         }
///
///         func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
///             termination.shouldTerminate(sender)
///         }
///     }
@MainActor
public final class GracefulTermination {
    private let deadline: Duration
    private let shutdown: @concurrent @Sendable () async -> Void
    private let clock: AnyClock
    private var state = State.running

    private enum State { case running, terminating, finished }

    /// - Parameters:
    ///   - deadline: The longest the app waits for `shutdown` before quitting anyway.
    ///   - clock: The clock the deadline is measured on (the ambient clock by default).
    ///   - shutdown: Stops everything. Cancellation of the surrounding work
    ///     is the usual way to start it. It does not run on the main actor.
    public init(deadline: Duration = .seconds(10), clock: AnyClock? = nil, shutdown: @escaping @concurrent @Sendable () async -> Void) {
        self.deadline = deadline
        self.shutdown = shutdown
        self.clock = clock ?? Ambient.current.clock
    }

    /// Call from `applicationShouldTerminate(_:)` and return its answer.
    public func shouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate { approve in application.reply(toApplicationShouldTerminate: approve) }
    }

    /// The same, with the reply injected: for tests, and for hosts that
    /// manage termination themselves.
    public func shouldTerminate(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        switch state {
        case .finished:
            return .terminateNow
        case .terminating:
            return .terminateLater
        case .running:
            state = .terminating
        }
        let shutdown = shutdown
        let clock = clock
        let deadline = deadline
        let instrumentation = Ambient.current.instrumentation
        instrumentation.record(Event("lifecycle.terminate_started", level: .info, fields: [.init("deadline", .duration(deadline))]))
        Task.stoic { @MainActor in
            let outcome = await GracefulTermination.run(shutdown, within: deadline, clock: clock)
            var fields: [Event.Field] = [.init("deadline", .duration(deadline))]
            if !outcome.finishedInTime {
                fields += GracefulTermination.leftRunning()
            }
            instrumentation.record(Event(
                outcome.finishedInTime ? "lifecycle.terminate_completed" : "lifecycle.terminate_overran",
                level: outcome.finishedInTime ? .info : .error,
                fields: fields
            ))
            self.state = .finished
            reply(true)
        }
        return .terminateLater
    }

    private struct Outcome: Sendable {
        let finishedInTime: Bool
    }

    /// Runs `shutdown` off the main actor, returning whether it finished
    /// before `deadline`. On overrun the shutdown keeps running, unwaited:
    /// the process is about to exit.
    @concurrent
    private static func run(_ shutdown: @escaping @concurrent @Sendable () async -> Void, within deadline: Duration, clock: AnyClock) async -> Outcome {
        let finished = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let work = Task.stoic {
            await shutdown()
            finished.continuation.yield(true)
        }
        let timer = Task.stoic {
            // stoic:allow(discarded-try): only cancellation ends this sleep early, and then the shutdown has already answered
            try? await clock.sleep(until: clock.now.advanced(by: deadline), tolerance: nil)
            finished.continuation.yield(false)
        }
        var iterator = finished.stream.makeAsyncIterator()
        let result = await iterator.next() ?? false
        timer.cancel()
        _ = work
        return Outcome(finishedInTime: result)
    }

    /// What is still running when the deadline passes: the abandoned work
    /// the ledger knows of, and Stoic-owned tasks not yet finished.
    private static func leftRunning() -> [Event.Field] {
        let abandoned = AbandonedWork.current
        let tasks = TaskLedger.current
        return [
            .init("abandoned_work", .int(abandoned.count)),
            .init("abandoned_labels", .string(Set(abandoned.map(\.label)).sorted().joined(separator: ",")), privacy: .public),
            .init("tasks_running", .int(tasks.count)),
            .init("task_labels", .string(Set(tasks.map { $0.label ?? $0.kind.rawValue }).sorted().joined(separator: ",")), privacy: .public),
        ]
    }
}
#endif

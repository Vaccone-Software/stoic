internal import Synchronization

/// A ``BackgroundTaskScheduling`` the test drives.
///
///     let scheduler = FakeBackgroundScheduler()
///     try job.register()
///     let task = scheduler.launch("com.example.sync")        // as the system would
///     task?.expire()                                          // and later take the time back
///
/// It records every registration and submitted request, and can be told to
/// refuse either.
public final class FakeBackgroundScheduler: BackgroundTaskScheduling {
    private struct State {
        var handlers: [String: @Sendable (any BackgroundTaskHandle) -> Void] = [:]
        var requests: [BackgroundTaskRequest] = []
        var acceptsRegistration = true
        var submitFailure: BackgroundTaskError?
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether `register` succeeds; `true` until set otherwise.
    public var acceptsRegistration: Bool {
        get { state.withLock { $0.acceptsRegistration } }
        set { state.withLock { $0.acceptsRegistration = newValue } }
    }

    /// The error every `submit` throws, until cleared with `nil`.
    public var submitFailure: BackgroundTaskError? {
        get { state.withLock { $0.submitFailure } }
        set { state.withLock { $0.submitFailure = newValue } }
    }

    /// The requests submitted, in order (refused ones are not included).
    public var requests: [BackgroundTaskRequest] { state.withLock { $0.requests } }

    /// The identifiers with a launch handler.
    public var registeredIdentifiers: Set<String> { state.withLock { Set($0.handlers.keys) } }

    public func register(identifier: String, launch: @escaping @Sendable (any BackgroundTaskHandle) -> Void) -> Bool {
        state.withLock { state in
            guard state.acceptsRegistration, state.handlers[identifier] == nil else { return false }
            state.handlers[identifier] = launch
            return true
        }
    }

    public func submit(_ request: BackgroundTaskRequest) async throws(BackgroundTaskError) {
        let failure = state.withLock { state -> BackgroundTaskError? in
            if let failure = state.submitFailure { return failure }
            state.requests.append(request)
            return nil
        }
        if let failure { throw failure }
    }

    /// Launches the task registered for `identifier`, as the system would,
    /// and returns it. `nil` if nothing is registered.
    @discardableResult
    public func launch(_ identifier: String, expiringImmediately: Bool = false) -> FakeBackgroundTask? {
        guard let handler = state.withLock({ $0.handlers[identifier] }) else { return nil }
        let task = FakeBackgroundTask(identifier: identifier, expiringImmediately: expiringImmediately)
        handler(task)
        return task
    }
}

/// A ``BackgroundTaskHandle`` that records what it is told.
public final class FakeBackgroundTask: BackgroundTaskHandle {
    private struct State {
        var expirationHandler: (@Sendable () -> Void)?
        var completions: [Bool] = []
    }

    public let identifier: String
    private let expiresImmediately: Bool
    private let state = Mutex(State())

    /// - Parameters:
    ///   - identifier: The task's identifier, as the system gave it.
    ///   - expiringImmediately: Whether the system takes the time
    ///     back the moment an expiration handler is set: a task that was
    ///     already out of time when the app got to it.
    public init(identifier: String, expiringImmediately: Bool = false) {
        self.identifier = identifier
        self.expiresImmediately = expiringImmediately
    }

    /// Every `success` passed to `setTaskCompleted`, in order. A correct job
    /// leaves exactly one.
    public var completions: [Bool] { state.withLock { $0.completions } }

    /// Whether an expiration handler has been set.
    public var hasExpirationHandler: Bool { state.withLock { $0.expirationHandler != nil } }

    public func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.expirationHandler = handler }
        if expiresImmediately { handler() }
    }

    public func setTaskCompleted(success: Bool) {
        state.withLock { $0.completions.append(success) }
    }

    /// Takes the time back, as the system does: calls the expiration handler.
    public func expire() {
        let handler = state.withLock { $0.expirationHandler }
        handler?()
    }
}

extension Task where Failure == Never {
    /// Starts a task the way every task Stoic owns starts: with the ambient
    /// executor preference (``Ambient/taskExecutor``), so a simulation — or
    /// an app that keeps background work on its own executor — reaches work
    /// that structured concurrency alone would not.
    ///
    /// The task does not inherit the semaphore permits its creator holds
    /// (debug builds track them to report reentrancy): its creator does not
    /// wait for it as for a child, so a permit it asks for is contention, not
    /// a self-deadlock. A hand-written `Task {}` does inherit them.
    @discardableResult
    package static func stoic(
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task {
        #if DEBUG
        if !HeldPermits.current.isEmpty {
            // Starts on the operation's actor one hop later; debug builds only,
            // and only when a permit is held.
            return start { await HeldPermits.$current.withValue([]) { await operation() } }
        }
        #endif
        return start(operation)
    }

    private static func start(_ operation: sending @escaping @isolated(any) () async -> Success) -> Task {
        if let executor = Ambient.current.taskExecutor {
            return Task(executorPreference: executor, operation: operation)
        }
        return Task(operation: operation)
    }
}

extension Task where Failure == any Error {
    /// ``Task/stoic(_:)``, for work that throws.
    @discardableResult
    package static func stoic(
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task {
        #if DEBUG
        if !HeldPermits.current.isEmpty {
            return start { try await HeldPermits.$current.withValue([]) { try await operation() } }
        }
        #endif
        return start(operation)
    }

    private static func start(_ operation: sending @escaping @isolated(any) () async throws -> Success) -> Task {
        if let executor = Ambient.current.taskExecutor {
            return Task(executorPreference: executor, operation: operation)
        }
        return Task(operation: operation)
    }
}

extension Task where Success == Void, Failure == Never {
    /// Starts a task that belongs to no caller: it inherits none of its
    /// creator's call-scoped context — no deadline, no enclosing retry
    /// attempt, no urgency, no cancellation cause — only `ambient`, and its
    /// executor preference.
    ///
    /// For work a library does on behalf of many callers, started by
    /// whichever caller came first and bounded by a timeout of its own: an
    /// XPC peer's handshake and the end of a run, a simulated service's
    /// handlers (design/25). Inheriting that one caller's deadline would fail
    /// the work for every other caller waiting on it, and its retry attempt
    /// would make a `perform` inside the work look nested in it. It runs at
    /// its creator's priority.
    @discardableResult
    package static func owned(in ambient: Ambient, _ operation: sending @escaping () async -> Void) -> Task {
        // stoic:allow(task-detached): inheriting nothing is the point; the ambient context is bound again inside, and the executor preference passed.
        Task.detached(executorPreference: ambient.taskExecutor, priority: Task<Never, Never>.currentPriority) {
            await withAmbient({ $0 = ambient }, operation: operation)
        }
    }
}

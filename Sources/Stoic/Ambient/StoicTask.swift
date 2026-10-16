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

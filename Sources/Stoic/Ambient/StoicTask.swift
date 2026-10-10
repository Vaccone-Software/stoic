extension Task where Failure == Never {
    /// Starts a task the way every task Stoic owns starts: with the ambient
    /// executor preference (``Ambient/taskExecutor``), so a simulation — or
    /// an app that keeps background work on its own executor — reaches work
    /// that structured concurrency alone would not.
    @discardableResult
    package static func stoic(
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task {
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
        if let executor = Ambient.current.taskExecutor {
            return Task(executorPreference: executor, operation: operation)
        }
        return Task(operation: operation)
    }
}

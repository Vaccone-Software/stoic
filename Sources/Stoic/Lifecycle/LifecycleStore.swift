/// Where a lifecycle's records are kept: a server's database, Stoic's
/// journal on a device, memory in a test.
///
/// The protocol is the obligation; ``update(_:attempts:_:)`` (and
/// ``apply(_:to:by:because:)``, ``settle(_:)``) is the compliant path.
///
/// **What a conforming store promises.** `commit` compares the stored
/// revision with the change's ``LifecycleChange/base`` and, in one
/// transaction, writes the new head, inserts the change's entries and
/// inserts its effects (key and value) where its delivery mechanism reads
/// them; or does none of it. A store that finds another revision returns
/// ``LifecycleCommit/conflict(current:)``. A change made from another record
/// (its key differs) is refused with the store's own error, and nothing is
/// written. `insert` never overwrites an existing id. Delivery from there is
/// the app's, always under the effect's key. A store that cannot do this
/// atomically does not conform.
public protocol LifecycleStore<Definition, ID>: Sendable {
    associatedtype Definition: Lifecycle
    associatedtype ID: Hashable & Sendable
    associatedtype Failure: Error

    /// The record kept under `id`, or `nil`.
    func load(_ id: ID) async throws(Failure) -> Definition.Record?

    /// Every history entry of the record under `id`, in order.
    func history(of id: ID) async throws(Failure) -> [Definition.Entry]

    /// Keeps `record` under `id`, unless the id is taken: then nothing is
    /// written and it returns `false`.
    func insert(_ record: Definition.Record, as id: ID) async throws(Failure) -> Bool

    /// Commits `change` to the record under `id` if its revision is still
    /// the change's base: the head, the entries and the effects together,
    /// or nothing.
    func commit(_ change: Definition.Change, to id: ID) async throws(Failure) -> LifecycleCommit<Definition>

    /// The moment the store reads and applies at, for a reading of the wall
    /// clock. A server's store returns `now`. A store on a device whose clock
    /// belongs to its owner returns the latest moment it has seen when `now`
    /// is earlier, so a clock set back cannot un-expire a state
    /// (`JournaledLifecycleStore`).
    ///
    /// A requirement with no default, so every store says which it is.
    func moment(for now: Moment) async -> Moment
}

/// What a store did with a change.
public enum LifecycleCommit<L: Lifecycle>: Sendable {
    /// Head, entries and effects were written together.
    case committed
    /// The stored revision was not the change's base: another writer
    /// committed first. Nothing was written. `current` is the record as
    /// stored now, or `nil` if there is none.
    case conflict(current: L.Record?)
}

/// Why ``LifecycleStore/update(_:attempts:_:)`` did not commit.
public enum LifecycleUpdateError<L: Lifecycle, Failure: Error>: Error {
    /// The definition refused (see ``LifecycleRefusal``). Nothing changed.
    case refused(L.Refusal)
    /// There is no record under the id.
    case notFound
    /// Another writer committed first on every attempt.
    case conflict(attempts: Int)
    /// The store failed.
    case storage(Failure)
    /// The caller was cancelled before an attempt.
    case cancelled

    /// Whether the caller's cancellation ended this: ``cancelled``, or a
    /// store failure that is a cancellation.
    public var isCancellation: Bool {
        switch self {
        case .cancelled: true
        case .storage(let failure): containsCancellation(failure)
        case .refused, .notFound, .conflict: false
        }
    }
}

extension LifecycleUpdateError: Sendable where Failure: Sendable {}

extension LifecycleUpdateError: Retryable {
    /// A conflict asks for a retry (another writer finished, nothing is
    /// overloaded); a refusal, a missing record and a cancellation stop; a
    /// store's failure classifies as that failure does.
    public var retryDecision: RetryDecision {
        switch self {
        case .conflict: .retry
        case .refused, .notFound, .cancelled: .stop
        case .storage(let failure): containsDefect(failure) ? .stop : (standardDecision(for: failure) ?? .retry)
        }
    }
}

extension LifecycleUpdateError: RejectionCarrying {
    var carriedRejection: Rejection? {
        if case .cancelled = self { return Rejection(.cancelled) }
        return nil
    }

    var carriedFailure: (any Error)? {
        if case .storage(let failure) = self { return failure }
        return nil
    }
}

extension LifecycleStore {
    /// Loads the record under `id`, makes a change of it with `change`, and
    /// commits it; on a conflict, makes the change again from the record as
    /// it now is.
    ///
    /// It tries at most `attempts` times and does not wait between them: a
    /// conflict means another writer finished, not that something is
    /// overloaded. Re-applying is cheap and correct because `change` is
    /// pure: two staff pressing "send" at once compute the same change, the
    /// first commits, and the second meets the state the first left, where
    /// the definition decides (one email, not two).
    ///
    /// A store's failure is not retried here: a store that wants retries
    /// performs its I/O through a declared operation, so retrying happens at
    /// one layer. Reports `lifecycle.applied`, `lifecycle.refused`,
    /// `lifecycle.invalid`, `lifecycle.conflict` and the rest (design/27,
    /// Events); the pure functions report nothing.
    ///
    /// - Parameters:
    ///   - id: The record to change.
    ///   - attempts: How many times to try; at least 1.
    ///   - change: Makes the change from the record as stored: usually
    ///     ``LifecycleRecord/applying(_:by:because:at:)``.
    /// - Returns: The record as committed.
    /// - Throws: ``LifecycleUpdateError``.
    @discardableResult
    public func update(
        _ id: ID, attempts: Int = 3,
        _ change: (Definition.Record) throws(Definition.Refusal) -> Definition.Change
    ) async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record {
        try await update(id, attempts: attempts) { (record) throws(Definition.Refusal) -> Definition.Change? in
            try change(record)
        }
    }

    /// Applies `event` to the record under `id`, by `by`, because
    /// `because`, at the store's moment for now: the compliant path for one
    /// event. See ``update(_:attempts:_:)``.
    @discardableResult
    public func apply(
        _ event: Definition.Event, to id: ID, by: Definition.Principal, because: String
    ) async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record {
        let now = await moment(for: .now)
        return try await update(id) { (record) throws(Definition.Refusal) -> Definition.Change in
            try record.applying(event, by: by, because: because, at: now)
        }
    }

    /// Applies `event` by a principal a verifier authenticated, recording
    /// the principal's value (design/28). See ``apply(_:to:by:because:)``.
    ///
    /// A server's write path takes this one, so "who did it" is never an
    /// argument the caller chose. History read back is the store's record of
    /// whom the service authenticated at the time: data, not a proof.
    @discardableResult
    public func apply<E: PrincipalEvidence>(
        _ event: Definition.Event, to id: ID, by principal: Verified<Definition.Principal, E>, because: String
    ) async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record {
        try await apply(event, to: id, by: principal.value, because: because)
    }

    /// Commits the timeouts of the record under `id` that are due at the
    /// store's moment for now, and returns the record; a record with
    /// nothing due is returned as stored, and nothing is written.
    @discardableResult
    public func settle(_ id: ID) async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record {
        let now = await moment(for: .now)
        return try await update(id, attempts: 3) { (record) throws(Definition.Refusal) -> Definition.Change? in
            try record.settling(at: now)
        }
    }

    /// The record under `id` read at the store's moment for `now`, or `nil`
    /// if there is none.
    public func read(_ id: ID, at now: Moment = .now) async throws(Failure) -> LifecycleReading<Definition>? {
        guard let record = try await load(id) else { return nil }
        return record.read(at: await moment(for: now))
    }

    /// `change` returning `nil` means nothing to commit: the record is
    /// returned as it is.
    private func update(
        _ id: ID, attempts: Int,
        change: (Definition.Record) throws(Definition.Refusal) -> Definition.Change?
    ) async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record {
        precondition(attempts >= 1, "update needs at least one attempt")
        // Loaded once; after a conflict, the store's current record is the
        // one to make the change from again.
        var latest: Definition.Record?
        var loaded = false
        for attempt in 1...attempts {
            if Task.isCancelled { throw .cancelled }
            if !loaded {
                do throws(Failure) {
                    latest = try await load(id)
                } catch {
                    throw .storage(error)
                }
                loaded = true
            }
            guard let current = latest else { throw .notFound }
            let made: Definition.Change?
            do throws(Definition.Refusal) {
                made = try change(current)
            } catch {
                LifecycleEvents.refused(error)
                throw .refused(error)
            }
            guard let made else { return current }
            let outcome: LifecycleCommit<Definition>
            do throws(Failure) {
                outcome = try await commit(made, to: id)
            } catch {
                throw .storage(error)
            }
            switch outcome {
            case .committed:
                LifecycleEvents.committed(made)
                return made.record
            case .conflict(let current):
                LifecycleEvents.conflict(Definition.self, attempt: attempt, of: attempts)
                latest = current
            }
        }
        throw .conflict(attempts: attempts)
    }
}

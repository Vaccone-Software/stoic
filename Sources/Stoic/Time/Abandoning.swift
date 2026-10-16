public import Dispatch
internal import Synchronization

/// Runs blocking work and stops waiting for it at a deadline, leaving it
/// running, accounted for.
///
/// Some work cannot be cancelled: a synchronous CoreAudio call on a wedged
/// queue, an Accessibility call into a process that has stopped answering, a
/// C library that blocks on a socket. A cooperative timeout waits for such
/// work forever, because it never notices it was cancelled. This one does
/// not: at the deadline it throws `.rejected(.deadlineExceeded)` (or
/// `.cancelled`, if the caller was cancelled) and *abandons* the work.
///
/// Abandoning is dangerous, so it is bounded:
///
/// - **Off the cooperative pool.** The operation is synchronous by
///   signature and runs on a Dispatch queue, never on Swift's cooperative
///   thread pool — which is only about as wide as the core count, so a few
///   blocked calls there would stall every task in the process.
/// - **Capped.** A label never occupies more than `limit` threads, running
///   or abandoned: a call holds its slot until its operation actually
///   returns, however long after the deadline that is. Callers past the cap
///   wait for a slot, bounded by their deadline and cancellation. When every
///   slot is held by abandoned work, the label is *wedged*: new calls are
///   refused at once (`.rejected(.abandonmentLimit)`) and reported
///   (`abandoned.wedged`, error level) — a system framework that has stopped
///   answering will not start answering because it is asked again, and the
///   cure (restarting the process) belongs to whatever supervises the app.
///   A label's limit is fixed by its first call while the label is live; the
///   last call or operation under a label retires its slots, so labels built at
///   runtime leave nothing behind.
/// - **Counted.** Every abandoned operation is listed in a process-wide
///   ledger (``AbandonedWork/current``) with its label and age, and its
///   eventual completion is reported with how late it was.
/// - **Never started late.** A caller that is already cancelled, or whose
///   deadline has passed, is refused before anything is dispatched.
///
/// A deadline that passes is `.deadlineExceeded`, whether it is this call's
/// or an enclosing one that cancelled the caller; other cancellation is
/// `.cancelled`.
///
/// The work's result, if it arrives after the deadline, is discarded. Do not
/// abandon work that holds a resource another part of the app will release
/// meanwhile.
///
/// For async work that cannot be cancelled, see
/// ``abandoningAsyncAfter(_:label:limit:clock:fileID:line:operation:)``.
public nonisolated(nonsending) func abandoningAfter<R: Sendable, Failure: Error>(
    _ duration: Duration,
    label: String,
    limit: Int = 2,
    clock: AnyClock? = nil,
    qos: DispatchQoS.QoSClass = .userInitiated,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: @escaping @Sendable () throws(Failure) -> R
) async throws(PolicyError<Failure>) -> R {
    try await abandonable(duration, label: label, limit: limit, clock: clock, fileID: fileID, line: line) { ambient, finish in
        let tag = ambient.ledgerTag
        ExternalWork.begin(tag: tag)
        DispatchQueue.global(qos: qos).async {
            let result = Result<R, Failure> { () throws(Failure) -> R in try operation() }
            ExternalWork.end(tag: tag)
            finish(result)
        }
        // A blocked thread cannot be told to stop.
        return { _ in }
    }
}

/// Runs async work that may never finish and stops waiting for it at a
/// deadline, leaving it running, accounted for.
///
/// The async sibling of
/// ``abandoningAfter(_:label:limit:clock:qos:fileID:line:operation:)``, for
/// work that does not honour cancellation because it is not Swift's to
/// cancel: a `withCheckedContinuation` around a CoreAudio or Speech start
/// whose callback may never come. A cooperative timeout would wait for it
/// forever. This one throws `.rejected(.deadlineExceeded)` (or `.cancelled`,
/// if the caller was cancelled) at the deadline and *abandons* the work.
///
/// Everything about abandoning in the synchronous form holds here, with a
/// task in place of a thread: the label's `limit` bounds work running or
/// abandoned, a call holds its slot until its operation actually returns, a
/// label with every slot abandoned is wedged (`.rejected(.abandonmentLimit)`,
/// `abandoned.wedged`), abandoned work is listed in ``AbandonedWork/current``,
/// counted in `scope.abandonedWork`, and reported when it finally finishes
/// (`abandoned.completed`), and work is never started for a caller that is
/// already cancelled or past its deadline. Its result, if it arrives late,
/// is discarded.
///
/// At the deadline the work's task is also cancelled, with cause
/// ``CancellationCause/deadline`` (or the caller's own cause, if the caller
/// was cancelled), in case it does check. It stays in the ledger until it
/// returns, cancelled or not.
///
/// The operation runs in an unstructured task off the caller's actor, so the
/// caller may be isolated to the main actor and is never blocked by it. The
/// task inherits the caller's task-locals and sees the narrowed deadline.
public nonisolated(nonsending) func abandoningAsyncAfter<R: Sendable, Failure: Error>(
    _ duration: Duration,
    label: String,
    limit: Int = 2,
    clock: AnyClock? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: @escaping @concurrent @Sendable () async throws(Failure) -> R
) async throws(PolicyError<Failure>) -> R {
    let deadline = Deadline.after(duration, clock: clock).narrowedByCurrent
    return try await abandonable(duration, label: label, limit: limit, clock: clock, fileID: fileID, line: line, deadline: deadline) { _, finish in
        let cause = CancellationCauseBox()
        let task = Task.stoic {
            await CancellationCauseBox.$current.withValue(cause) {
                await Deadline.$stored.withValue(deadline) {
                    let result: Result<R, Failure>
                    do throws(Failure) {
                        result = .success(try await operation())
                    } catch {
                        result = .failure(error)
                    }
                    finish(result)
                }
            }
        }
        return { reason in
            if reason == .deadlineExceeded { cause.record(.deadline) }
            task.cancel()
        }
    }
}

/// What both forms of abandoning share: admission, the ledger, the wait, and
/// the abandonment. `launch` starts the work, calls `finish` with its result
/// whenever that comes, and returns how to cancel it.
private nonisolated(nonsending) func abandonable<R: Sendable, Failure: Error>(
    _ duration: Duration,
    label: String,
    limit: Int,
    clock: AnyClock?,
    fileID: String,
    line: UInt,
    deadline narrowed: Deadline? = nil,
    launch: (Ambient, @escaping @Sendable (Result<R, Failure>) -> Void) -> @Sendable (Rejection.Reason) -> Void
) async throws(PolicyError<Failure>) -> R {
    precondition(limit >= 1, "abandoningAfter \(label): limit must be at least one")
    let ambient = Ambient.current
    let deadline = narrowed ?? Deadline.after(duration, clock: clock).narrowedByCurrent
    let ledger = AbandonedWork.ledger

    if Task.isCancelled {
        throw .rejected(Rejection(cancellationReason(), label: label))
    }
    if deadline.hasPassed {
        throw .rejected(Rejection(.deadlineExceeded, label: label))
    }
    let slots = ledger.lease(label: label, limit: limit)
    defer { ledger.returnLease(label: label) }
    if ledger.abandonedCount(label: label) >= limit {
        ambient.instrumentation.record(Event("abandoned.wedged", level: .error, label: label, fields: [
            .init("limit", .int(limit)),
        ], fileID: fileID, line: line))
        throw .rejected(Rejection(.abandonmentLimit, label: label))
    }
    // The slot is held until the operation returns, not until this call
    // does: abandoned work still occupies its thread.
    if let refusal = await Deadline.$stored.withValue(deadline, operation: { await slots.acquirePermit() }) {
        throw .rejected(Rejection(refusal.reason, label: label))
    }
    if Task.isCancelled || deadline.hasPassed {
        slots.releasePermit()
        throw .rejected(Rejection(Task.isCancelled ? cancellationReason() : .deadlineExceeded, label: label))
    }
    let id = ledger.admit(label: label)

    let outcome = OnceCell<Result<R, Failure>?>()
    let instrumentation = ambient.instrumentation
    let started = ambient.clock.now
    let ambientClock = ambient.clock
    // The operation keeps the label's slots for as long as it runs, however
    // long after this call returns that is.
    ledger.addLease(label: label)
    let cancelWork = launch(ambient) { result in
        if let lateness = ledger.finish(id) {
            instrumentation.record(Event("abandoned.completed", level: .notice, label: label, fields: [
                .init("ran_for", .duration(started.duration(to: ambientClock.now))),
                .init("late_by", .duration(lateness)),
            ], fileID: fileID, line: line))
        }
        slots.releasePermit()
        ledger.returnLease(label: label)
        outcome.resolve(.some(result))
    }

    let timer = Task.stoic {
        do {
            try await deadline.clock.sleep(until: deadline.instant, tolerance: nil)
            outcome.resolve(nil)
        } catch {}
    }
    let result = await withTaskCancellationHandler {
        await outcome.value
    } onCancel: {
        outcome.resolve(nil)
    }
    timer.cancel()

    if let result {
        ledger.forget(id)
        switch result {
        case .success(let value): return value
        case .failure(let failure): throw .failed(failure)
        }
    }

    // The deadline or the caller won. Abandon the work — unless it finished
    // in the meantime, in which case its result simply goes unused.
    let reason: Rejection.Reason = Task.isCancelled ? cancellationReason() : .deadlineExceeded
    if ledger.abandon(id, deadline: deadline.instant, clock: deadline.clock, watch: AbandonmentWatch.current) {
        instrumentation.record(Event("abandoned.started", level: .warning, label: label, fields: [
            .init("reason", .string(reason.rawValue), privacy: .public),
            .init("outstanding", .int(ledger.outstanding(label: label))),
        ], fileID: fileID, line: line))
        cancelWork(reason)
    }
    throw .rejected(Rejection(reason, label: label))
}

/// Why a cancelled caller was cancelled, in a rejection's words: an
/// enclosing deadline is a deadline, anything else is cancellation.
private func cancellationReason() -> Rejection.Reason {
    CancellationCause.current == .deadline ? .deadlineExceeded : .cancelled
}

/// Work that ``abandoningAfter(_:label:limit:clock:qos:fileID:line:operation:)``
/// stopped waiting for and that has not finished yet.
public enum AbandonedWork {
    /// One abandoned operation.
    public struct Entry: Sendable, CustomStringConvertible {
        public let label: String
        /// When it was abandoned, on the clock its deadline used.
        public let abandonedAt: AnyClock.Instant

        public var description: String { "\(label) abandoned at \(abandonedAt)" }
    }

    /// Everything abandoned and still running, for diagnostics.
    public static var current: [Entry] {
        ledger.snapshot()
    }

    static let ledger = AbandonmentLedger()
}

/// The process-wide account of abandonable work.
final class AbandonmentLedger: Sendable {
    private enum Status {
        case running
        case abandoned(at: AnyClock.Instant, clock: AnyClock)
    }

    private struct Record {
        let label: String
        var status: Status
        /// The scopes counting it while it runs abandoned.
        var watch: AbandonmentWatch?
    }

    /// A label's thread budget, and how many calls and operations hold it.
    private struct Slots {
        let semaphore: AsyncSemaphore
        /// Calls in progress plus operations still running on a thread
        /// (abandoned ones included). Only at zero is the entry idle.
        var leases: Int
    }

    private struct State {
        var nextID: UInt64 = 0
        var records: [UInt64: Record] = [:]
        // One per label with a call or an operation in flight, and gone when
        // the last of them ends: a label built at runtime (a device name, a
        // path) must not leave an entry behind for every value it takes.
        var slots: [String: Slots] = [:]
    }

    private let state = Mutex(State())

    /// The semaphore bounding `label`'s threads, with a lease on it: pair
    /// every call with ``returnLease(label:)``. The limit is fixed by the
    /// first call while the label is live — that is, while any call or
    /// operation under it is in flight; a concurrent call with another limit
    /// is a programming error.
    func lease(label: String, limit: Int) -> AsyncSemaphore {
        let slots = state.withLock { state in
            var entry = state.slots[label] ?? Slots(semaphore: AsyncSemaphore(permits: limit, label: label), leases: 0)
            entry.leases += 1
            state.slots[label] = entry
            return entry.semaphore
        }
        assert(slots.capacity == limit, "abandoningAfter \(label): called with limit \(limit), but its limit is \(slots.capacity)")
        return slots
    }

    /// Another lease on a label already leased: held by the operation that
    /// outlives its call.
    func addLease(label: String) {
        state.withLock { $0.slots[label]?.leases += 1 }
    }

    /// Ends a lease; the last one retires the label's semaphore.
    func returnLease(label: String) {
        state.withLock { state in
            guard var entry = state.slots[label] else { return }
            entry.leases -= 1
            state.slots[label] = entry.leases > 0 ? entry : nil
        }
    }

    /// Whether `label` holds a thread budget now.
    func holdsSlots(label: String) -> Bool {
        state.withLock { $0.slots[label] != nil }
    }

    /// Registers a new running operation.
    func admit(label: String) -> UInt64 {
        state.withLock { state in
            defer { state.nextID += 1 }
            state.records[state.nextID] = Record(label: label, status: .running)
            return state.nextID
        }
    }

    func abandonedCount(label: String) -> Int {
        state.withLock { state in
            state.records.values.filter { record in
                guard record.label == label, case .abandoned = record.status else { return false }
                return true
            }.count
        }
    }

    /// Marks the operation abandoned, and counts it in `watch` (the scopes
    /// it was started in) until it finishes. Returns `false` if it had
    /// already finished.
    func abandon(_ id: UInt64, deadline: AnyClock.Instant, clock: AnyClock, watch: AbandonmentWatch?) -> Bool {
        state.withLock { state in
            guard state.records[id] != nil else { return false }
            state.records[id]?.status = .abandoned(at: deadline, clock: clock)
            state.records[id]?.watch = watch
            // Under the lock, as `finish` resolves it: a scope never sees
            // the end of work before its abandonment.
            watch?.record()
            return true
        }
    }

    /// Whether the operation is still running, abandoned or not.
    func isRunning(_ id: UInt64) -> Bool {
        state.withLock { $0.records[id] != nil }
    }

    /// Records that the operation finished. Returns how late it was, if it
    /// had been abandoned.
    func finish(_ id: UInt64) -> Duration? {
        state.withLock { state in
            guard let record = state.records.removeValue(forKey: id) else { return nil }
            if case .abandoned(let at, let clock) = record.status {
                record.watch?.resolve()
                return at.duration(to: clock.now)
            }
            // Finished in time: its waiter will forget it too, harmlessly.
            state.records[id] = nil
            return nil
        }
    }

    /// Removes an operation whose waiter received its result.
    func forget(_ id: UInt64) {
        state.withLock { _ = $0.records.removeValue(forKey: id) }
    }

    func outstanding(label: String) -> Int {
        state.withLock { state in
            state.records.values.filter { $0.label == label }.count
        }
    }

    func snapshot() -> [AbandonedWork.Entry] {
        state.withLock { state in
            state.records.values.compactMap { record in
                guard case .abandoned(let at, _) = record.status else { return nil }
                return AbandonedWork.Entry(label: record.label, abandonedAt: at)
            }
        }
    }
}

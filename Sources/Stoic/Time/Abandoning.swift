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
/// - **Counted.** Every abandoned operation is listed in a process-wide
///   ledger (``AbandonedWork/current``) with its label and age, and its
///   eventual completion is reported with how late it was.
/// - **Capped.** At most `limit` operations per label may be abandoned at
///   once. Past that, the label is *wedged*: new calls are refused at once
///   (`.rejected(.abandonmentLimit)`) and reported (`abandoned.wedged`,
///   error level) — a system framework that has stopped answering will not
///   start answering because it is asked again, and the cure (restarting
///   the process) belongs to whatever supervises the app.
///
/// The work's result, if it arrives after the deadline, is discarded. Do not
/// abandon work that holds a resource another part of the app will release
/// meanwhile.
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
    let ambient = Ambient.current
    let deadline = Deadline.after(duration, clock: clock).narrowedByCurrent
    let ledger = AbandonedWork.ledger

    guard let id = ledger.admit(label: label, limit: limit, now: ambient.clock.now) else {
        ambient.instrumentation.record(Event("abandoned.wedged", level: .error, label: label, fields: [
            .init("limit", .int(limit)),
        ], fileID: fileID, line: line))
        throw .rejected(Rejection(.abandonmentLimit, label: label))
    }

    let outcome = OnceCell<Result<R, Failure>?>()
    let instrumentation = ambient.instrumentation
    let started = ambient.clock.now
    let ambientClock = ambient.clock
    DispatchQueue.global(qos: qos).async {
        let result = Result<R, Failure> { () throws(Failure) -> R in try operation() }
        if let lateness = ledger.finish(id) {
            instrumentation.record(Event("abandoned.completed", level: .notice, label: label, fields: [
                .init("ran_for", .duration(started.duration(to: ambientClock.now))),
                .init("late_by", .duration(lateness)),
            ], fileID: fileID, line: line))
        }
        outcome.resolve(.some(result))
    }

    let timer = Task {
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
    let reason: Rejection.Reason = Task.isCancelled ? .cancelled : .deadlineExceeded
    if ledger.abandon(id, deadline: deadline.instant, clock: deadline.clock) {
        instrumentation.record(Event("abandoned.started", level: .warning, label: label, fields: [
            .init("reason", .string(reason.rawValue), privacy: .public),
            .init("outstanding", .int(ledger.outstanding(label: label))),
        ], fileID: fileID, line: line))
    }
    throw .rejected(Rejection(reason, label: label))
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
    }

    private struct State {
        var nextID: UInt64 = 0
        var records: [UInt64: Record] = [:]
    }

    private let state = Mutex(State())

    /// Registers a new operation unless `label` already has `limit` abandoned.
    func admit(label: String, limit: Int, now: AnyClock.Instant) -> UInt64? {
        state.withLock { state in
            let abandoned = state.records.values.filter { record in
                guard record.label == label, case .abandoned = record.status else { return false }
                return true
            }.count
            guard abandoned < limit else { return nil }
            defer { state.nextID += 1 }
            state.records[state.nextID] = Record(label: label, status: .running)
            return state.nextID
        }
    }

    /// Marks the operation abandoned. Returns `false` if it had already finished.
    func abandon(_ id: UInt64, deadline: AnyClock.Instant, clock: AnyClock) -> Bool {
        state.withLock { state in
            guard state.records[id] != nil else { return false }
            state.records[id]?.status = .abandoned(at: deadline, clock: clock)
            return true
        }
    }

    /// Records that the operation finished. Returns how late it was, if it
    /// had been abandoned.
    func finish(_ id: UInt64) -> Duration? {
        state.withLock { state in
            guard let record = state.records.removeValue(forKey: id) else { return nil }
            if case .abandoned(let at, let clock) = record.status {
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

/// What a recurring operation wants next.
public enum RecurDecision: Sendable, Hashable {
    /// Run again after the schedule's delay.
    case `continue`
    /// Run again after this delay instead of the schedule's.
    case continueAfter(Duration)
    /// Stop recurring.
    case stop
}

/// Why a recurring loop ended without failing.
public enum RecurOutcome: Sendable, Hashable {
    /// The operation returned `.stop`.
    case stopped
    /// The schedule allowed no further run.
    case scheduleEnded
    /// The task was cancelled. A loop is normally stopped this way, so it is
    /// not an error — but it is never mistaken for finishing.
    case cancelled
}

/// Runs `operation` repeatedly on `schedule`: polling, periodic refresh,
/// heartbeats.
///
/// Where ``retry(_:budget:classify:nesting:label:fileID:line:operation:)``
/// repeats after a *failure*, `recur` repeats after a *success*. The first
/// run happens at once; after each, the operation's decision and the
/// schedule choose the wait before the next. A failure ends the loop and is
/// rethrown — wrap the body in `retry` to ride out transient ones.
///
/// `recur` returns how it ended: the operation said `.stop`, the schedule
/// ended, or the task was cancelled — cancellation is how a polling loop is
/// normally stopped, so it is not an error, but the outcome says so rather
/// than passing it off as finishing. The schedule may be unbounded, which is
/// why a recurring loop belongs to something that can cancel it: a scope, a
/// task slot, a supervisor.
@discardableResult
public nonisolated(nonsending) func recur<Failure: Error>(
    _ schedule: Schedule,
    clock: AnyClock? = nil,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> RecurDecision
) async throws(Failure) -> RecurOutcome {
    let ambient = Ambient.current
    let clock = clock ?? ambient.clock
    var stepper = schedule.makeStepper(random: ambient.random.generator(fileID: fileID, line: line))
    let start = clock.now
    var number = 1

    func finish(_ outcome: RecurOutcome) -> RecurOutcome {
        ambient.instrumentation.record(Event("recur.ended", level: .debug, label: label, fields: [
            .init("outcome", .string("\(outcome)"), privacy: .public),
            .init("runs", .int(number)),
        ], fileID: fileID, line: line))
        return outcome
    }

    while true {
        if Task.isCancelled { return finish(.cancelled) }
        let decision = try await operation(Attempt(number: number, elapsed: start.duration(to: clock.now)))
        if case .stop = decision { return finish(.stopped) }
        guard let scheduled = stepper.next(elapsed: start.duration(to: clock.now)) else { return finish(.scheduleEnded) }
        let delay: Duration
        switch decision {
        case .stop: return finish(.stopped)
        case .continue: delay = scheduled
        case .continueAfter(let requested): delay = max(.zero, requested)
        }
        do {
            try await clock.sleep(until: clock.now.advanced(by: delay), tolerance: nil)
        } catch _ {
            return finish(.cancelled)
        }
        number += 1
    }
}

/// Runs `operation` repeatedly on a bounded schedule. See ``recur(_:clock:label:fileID:line:operation:)``.
@discardableResult
public nonisolated(nonsending) func recur<Failure: Error>(
    _ schedule: BoundedSchedule,
    clock: AnyClock? = nil,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> RecurDecision
) async throws(Failure) -> RecurOutcome {
    try await recur(schedule.schedule, clock: clock, label: label, fileID: fileID, line: line, operation: operation)
}

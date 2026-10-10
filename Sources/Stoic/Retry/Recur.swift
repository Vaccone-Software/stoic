/// What a recurring operation wants next.
public enum RecurDecision: Sendable, Hashable {
    /// Run again after the schedule's delay.
    case `continue`
    /// Run again after this delay instead of the schedule's.
    case continueAfter(Duration)
    /// Stop recurring.
    case stop
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
/// `recur` returns when the operation says `.stop`, when the schedule ends,
/// or when the task is cancelled; cancellation is how a polling loop is
/// normally stopped, so it is not an error. The schedule may be unbounded,
/// which is why a recurring loop belongs to something that can cancel it:
/// a scope, a task slot, a supervisor.
public nonisolated(nonsending) func recur<Failure: Error>(
    _ schedule: Schedule,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> RecurDecision
) async throws(Failure) {
    let ambient = Ambient.current
    let clock = ambient.clock
    var stepper = schedule.makeStepper(random: ambient.random.generator(fileID: fileID, line: line))
    let start = clock.now
    var number = 1
    while !Task.isCancelled {
        let decision = try await operation(Attempt(number: number, elapsed: start.duration(to: clock.now)))
        guard let scheduled = stepper.next(elapsed: start.duration(to: clock.now)) else { return }
        let delay: Duration
        switch decision {
        case .stop: return
        case .continue: delay = scheduled
        case .continueAfter(let requested): delay = max(.zero, requested)
        }
        do {
            try await clock.sleep(until: clock.now.advanced(by: delay), tolerance: nil)
        } catch _ {
            return
        }
        number += 1
    }
}

/// Runs `operation` repeatedly on a bounded schedule. See ``recur(_:fileID:line:operation:)``.
public nonisolated(nonsending) func recur<Failure: Error>(
    _ schedule: BoundedSchedule,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> RecurDecision
) async throws(Failure) {
    try await recur(schedule.schedule, fileID: fileID, line: line, operation: operation)
}

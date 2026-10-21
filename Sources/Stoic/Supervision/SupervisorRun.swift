/// One run of a supervisor: a single loop that owns all of its state.
///
/// Children, their monitors, their restart timers and the watch on an
/// abandoned run report to the loop through one stream, and only the loop
/// decides, so no decision races another. A signal from a child generation
/// that has since been stopped or replaced is stale and ignored.
struct SupervisorRun {
    private enum Signal: Sendable {
        case exited(index: Int, generation: UInt64, error: (any Error)?)
        case restartDue(index: Int, generation: UInt64)
        case hung(index: Int, generation: UInt64)
        /// An abandoned run has returned. `id` is the slot's `drainID` from
        /// the moment it was abandoned, so a late notice cannot clear a
        /// newer run.
        case drained(index: Int, id: UInt64)
    }

    private struct Slot {
        var generation: UInt64 = 0
        var task: Task<Void, Never>?
        /// `task` ignored its cancellation and is still inside `child.run`
        /// after the shutdown timeout. The slot stays occupied so a restart
        /// cannot start a second instance.
        var draining = false
        /// Bumped each time a run is abandoned. A drain notice carries the
        /// value from its own abandonment.
        var drainID: UInt64 = 0
        var cause: CancellationCauseBox?
        var monitor: Task<Void, Never>?
        var startedAt: AnyClock.Instant?
        var stepper: Schedule.Stepper
        // When the current run of failures began: the backoff schedule's
        // elapsed time counts from here, and starts over with the stepper.
        var streakStart: AnyClock.Instant?
        var restartTimer: Task<Void, Never>?
        var pendingRestart: [Int] = []
        /// While `draining`, the child whose restart timer gates our next
        /// start. Nil when no restart is waiting on this run.
        var restartWith: Int?
        var finished = false
    }

    struct Hung: Error, CustomStringConvertible {
        let child: String
        var description: String { "child \(child) stopped beating" }
    }

    let supervisor: Supervisor
    let ambient: Ambient

    private var clock: AnyClock { ambient.clock }

    init(supervisor: Supervisor, ambient: Ambient) {
        self.supervisor = supervisor
        self.ambient = ambient
    }

    func execute() async throws {
        // stoic:allow(unbounded-stream): each child generation yields at most an exit, a hang, a drain and a restart notice, and this loop drains them as they arrive
        let (signals, sink) = AsyncStream<Signal>.makeStream()
        var slots = supervisor.children.indices.map { _ in
            Slot(stepper: supervisor.backoff.makeStepper(random: ambient.random.generator()))
        }
        var restarts: [AnyClock.Instant] = []

        for index in supervisor.children.indices {
            start(index, in: &slots, sink: sink)
        }
        if supervisor.children.isEmpty {
            finish(.stopped, level: .info, child: nil, error: nil)
            return
        }

        for await signal in signals {
            switch signal {
            case .exited(let index, let generation, let error):
                guard slots[index].generation == generation, slots[index].task != nil else { continue }
                slots[index].monitor?.cancel()
                slots[index].task = nil
                slots[index].monitor = nil
                if let escalation = await handleStop(index, error: error, slots: &slots, restarts: &restarts, sink: sink) {
                    await stopAll(&slots, sink: sink)
                    finish(.escalated(child: supervisor.children[index].label), level: .error, child: index, error: error)
                    throw escalation
                }

            case .restartDue(let index, let generation):
                guard slots[index].generation == generation else { continue }
                slots[index].restartTimer = nil
                let group = slots[index].pendingRestart
                slots[index].pendingRestart = []
                for member in group {
                    // Put on the list before it was abandoned (a newer stop), or
                    // still draining from this decision. The backoff has
                    // elapsed; the start waits for the run. A restart a
                    // newer decision already recorded is left as it is.
                    if slots[member].draining {
                        if slots[member].restartWith == nil {
                            slots[member].restartWith = index
                        }
                        continue
                    }
                    start(member, in: &slots, sink: sink)
                }

            case .hung(let index, let generation):
                guard slots[index].generation == generation, slots[index].task != nil, !slots[index].draining else { continue }
                let label = supervisor.children[index].label
                supervisor.publish(.hung(child: label))
                record("supervisor.child_hung", .error, child: index)
                await stop(index, in: &slots, sink: sink, cause: .childHung)
                if let escalation = await handleStop(index, error: Hung(child: label), slots: &slots, restarts: &restarts, sink: sink) {
                    await stopAll(&slots, sink: sink)
                    finish(.escalated(child: label), level: .error, child: index, error: Hung(child: label))
                    throw escalation
                }

            case .drained(let index, let id):
                guard slots[index].draining, slots[index].drainID == id else { continue }
                slots[index].task = nil
                slots[index].draining = false
                // No restart was waiting: the child is not restarted, or the
                // supervisor has already moved on from the decision that was.
                guard let owner = slots[index].restartWith else { continue }
                slots[index].restartWith = nil
                // The backoff is the timer. It is still asleep: join the
                // group and start with it. It has already fired: the wait is
                // over, so start now that the slot is free.
                if slots[owner].restartTimer != nil {
                    if !slots[owner].pendingRestart.contains(index) {
                        slots[owner].pendingRestart.append(index)
                        slots[owner].pendingRestart.sort()
                    }
                } else {
                    start(index, in: &slots, sink: sink)
                }
            }
            // A draining run still occupies `task`, but a child that will not
            // be restarted has already been abandoned: `run()` must not wait
            // for it. A restart that is waiting (a timer, or `restartWith`)
            // keeps the supervisor up.
            if slots.allSatisfy({
                $0.finished && $0.restartTimer == nil && $0.restartWith == nil && ($0.task == nil || $0.draining)
            }) {
                finish(.stopped, level: .info, child: nil, error: nil)
                return
            }
        }
        // The stream ends only when this task is cancelled.
        await stopAll(&slots, sink: sink)
        finish(.stopped, level: .info, child: nil, error: nil)
        throw CancellationError()
    }

    // MARK: Decisions

    /// Decides what follows a child stopping. Returns an escalation when the
    /// intensity is exceeded.
    private func handleStop(
        _ index: Int,
        error: (any Error)?,
        slots: inout [Slot],
        restarts: inout [AnyClock.Instant],
        sink: AsyncStream<Signal>.Continuation
    ) async -> SupervisorEscalation? {
        let child = supervisor.children[index]
        let failed = error != nil
        supervisor.publish(.exited(child: child.label, failed: failed))
        // A child the supervisor did not stop that ends with a cancellation
        // was cancelled by something else: it stopped when it should not
        // have, so it counts as a failure, and the report says how it ended.
        let cancelledFromOutside = error.map(containsCancellation) ?? false
        record("supervisor.child_exited", failed ? .warning : .info, child: index, error: error,
               extra: cancelledFromOutside ? [.init("cause", .string("cancelled_from_outside"), privacy: .public)] : [])

        let restart: Bool
        switch child.restart {
        case .permanent: restart = true
        case .transient: restart = failed
        case .temporary: restart = false
        }
        guard restart else {
            slots[index].finished = true
            return nil
        }

        let now = clock.now
        restarts.append(now)
        restarts.removeAll { $0.duration(to: now) > supervisor.intensity.window }
        if restarts.count > supervisor.intensity.maxRestarts {
            return SupervisorEscalation(supervisor: supervisor.label, child: child.label, lastError: error)
        }

        var affected: [Int]
        switch supervisor.strategy {
        case .oneForOne: affected = [index]
        case .oneForAll: affected = Array(supervisor.children.indices)
        case .restForOne: affected = Array(index..<supervisor.children.count)
        }
        // A sibling that finished for good (a transient child that returned,
        // a temporary one) stays finished: restarting the group does not
        // resurrect it. One abandoned while it finished is still inside
        // `run`, but it is done — the slot stays occupied and is not restarted.
        affected.removeAll { member in
            member != index && slots[member].finished && slots[member].restartTimer == nil
                && (slots[member].task == nil || slots[member].draining)
        }
        // This decision supersedes any restart already pending for a member:
        // otherwise an older timer would start members out of order, and a
        // newer one would start them a second time.
        for member in affected {
            slots[member].restartTimer?.cancel()
            slots[member].restartTimer = nil
            slots[member].pendingRestart = []
        }
        for slot in slots.indices {
            if let owner = slots[slot].restartWith, affected.contains(owner) || affected.contains(slot) {
                slots[slot].restartWith = nil
            }
        }
        // Stop the siblings that restart with it, newest first. One already
        // abandoned still holds the slot; `stop` does not wait out its
        // timeout again.
        for member in affected.reversed() where member != index && slots[member].task != nil {
            await stop(member, in: &slots, sink: sink)
        }
        for member in affected { slots[member].finished = false }

        // A child that ran long enough starts its backoff over.
        if let started = slots[index].startedAt, started.duration(to: now) >= supervisor.resetAfter {
            slots[index].stepper = supervisor.backoff.makeStepper(random: ambient.random.generator())
            slots[index].streakStart = nil
        }
        let streakStart = slots[index].streakStart ?? now
        slots[index].streakStart = streakStart
        // A backoff schedule that has ended — out of attempts, or of the time
        // it allows since the failures began — means restarting should stop.
        guard let scheduled = slots[index].stepper.next(elapsed: streakStart.duration(to: now)) else {
            return SupervisorEscalation(supervisor: supervisor.label, child: child.label, lastError: error)
        }
        let delay = scheduled.saturatingMultiplied(by: ambient.conditions.current.backoffFactor)
        // The restart is due `delay` after this decision, not after the
        // timer's task first runs.
        let due = clock.now.advanced(by: delay)
        supervisor.publish(.restarting(child: child.label, after: delay))
        record("supervisor.child_restarting", .info, child: index, extra: [.init("delay", .duration(delay))])

        // A child still inside an abandoned run is left out of the group.
        // It joins when that run returns — after this delay, if the delay
        // has not already elapsed. The others do not wait for it.
        let ready = affected.filter { !slots[$0].draining }
        for member in affected where slots[member].draining {
            slots[member].restartWith = index
        }
        slots[index].pendingRestart = ready
        let generation = slots[index].generation
        let clock = clock
        slots[index].restartTimer = Task.stoic {
            do {
                try await clock.sleep(until: due, tolerance: nil)
            } catch {
                return
            }
            sink.yield(.restartDue(index: index, generation: generation))
        }
        return nil
    }

    // MARK: Children

    private func start(_ index: Int, in slots: inout [Slot], sink: AsyncStream<Signal>.Continuation) {
        // Never two instances of one child. A running child is left alone,
        // including one abandoned after its shutdown timeout whose run has
        // not returned: that task is still in the slot.
        guard slots[index].task == nil, !slots[index].draining else { return }
        slots[index].restartWith = nil
        let child = supervisor.children[index]
        slots[index].generation += 1
        let generation = slots[index].generation
        let heartbeat = Heartbeat()
        let cause = CancellationCauseBox(parent: nil)
        let ambient = ambient
        slots[index].cause = cause
        slots[index].startedAt = clock.now
        slots[index].finished = false
        slots[index].task = TaskLedger.task(.supervisorChild, label: child.label) {
            let failure: (any Error)?
            do {
                // A child lives as long as the supervisor keeps it, not as
                // long as whoever called `run()` was given: no deadline.
                try await withAmbient({ $0 = ambient }) {
                    try await Deadline.$stored.withValue(nil) {
                        try await CancellationCauseBox.$current.withValue(cause) {
                            await FaultPoint.hit("supervisor.child")
                            try await child.run(heartbeat)
                        }
                    }
                }
                failure = nil
            } catch {
                failure = error
            }
            sink.yield(.exited(index: index, generation: generation, error: failure))
        }
        if let policy = child.heartbeat {
            let clock = ambient.livenessClock
            // Checks fall on fixed instants counted from the start, so the
            // monitor's own scheduling delays neither stretch the grace
            // period nor accumulate across intervals.
            let graceEnds = clock.now.advanced(by: policy.grace)
            slots[index].monitor = Task.stoic {
                do {
                    try await clock.sleep(until: graceEnds, tolerance: nil)
                    var last = heartbeat.count
                    var misses = 0
                    var check = graceEnds
                    while true {
                        check = check.advanced(by: policy.interval)
                        try await clock.sleep(until: check, tolerance: nil)
                        let current = heartbeat.count
                        // Woken more than an interval late: the process was
                        // suspended (`kill -STOP`, an app in the background)
                        // while the liveness clock ran on, and every overdue
                        // check would come due at once, before the child can
                        // run. The gap says nothing about the child: start
                        // counting again from now, and give it an interval.
                        let now = clock.now
                        if check.duration(to: now) > policy.interval {
                            check = now
                            last = current
                            misses = 0
                            continue
                        }
                        if current == last {
                            misses += 1
                            if misses >= policy.misses {
                                sink.yield(.hung(index: index, generation: generation))
                                return
                            }
                        } else {
                            misses = 0
                            last = current
                        }
                    }
                } catch {}
            }
        }
        supervisor.publish(.started(child: child.label))
        record("supervisor.child_started", .debug, child: index)
    }

    /// Stops a running child: newer signals from it become stale, it is
    /// cancelled with `cause`, and it gets its shutdown timeout before being
    /// abandoned. The abandoned run keeps the slot until it returns.
    private func stop(
        _ index: Int,
        in slots: inout [Slot],
        sink: AsyncStream<Signal>.Continuation,
        cause: CancellationCause = .supervisorStopped
    ) async {
        guard let task = slots[index].task else { return }
        // Already abandoned. This run is still the one instance of the child,
        // and waiting out the timeout again would only delay shutdown.
        if slots[index].draining { return }
        slots[index].generation += 1
        slots[index].monitor?.cancel()
        slots[index].monitor = nil
        slots[index].cause?.record(cause)
        task.cancel()
        let timeout = supervisor.children[index].shutdownTimeout
        let clock = clock
        let outcome = await withTaskCancellationShield {
            await waitForTask(task, within: timeout, clock: clock)
        }
        if case .timedOut = outcome {
            record("supervisor.child_abandoned", .error, child: index, extra: [.init("timeout", .duration(timeout))])
            // The exit signal carries the generation just invalidated, so the
            // loop will not count it as a new failure. Keep the task: `start`
            // will not put a second instance beside this run. The watcher
            // reports when the run actually returns.
            slots[index].draining = true
            slots[index].drainID += 1
            let id = slots[index].drainID
            Task.stoic {
                await task.value
                sink.yield(.drained(index: index, id: id))
            }
        } else {
            slots[index].task = nil
        }
    }

    private func stopAll(_ slots: inout [Slot], sink: AsyncStream<Signal>.Continuation) async {
        for index in slots.indices {
            slots[index].restartTimer?.cancel()
            slots[index].restartTimer = nil
            slots[index].pendingRestart = []
            slots[index].restartWith = nil
        }
        for index in slots.indices.reversed() {
            await stop(index, in: &slots, sink: sink)
        }
    }

    // MARK: Reporting

    private func finish(_ event: SupervisorEvent, level: Event.Level, child: Int?, error: (any Error)?) {
        supervisor.publish(event)
        switch event {
        case .escalated:
            record("supervisor.escalated", level, child: child, error: error)
        default:
            record("supervisor.stopped", level, child: child, error: error)
        }
    }

    private func record(_ name: EventName, _ level: Event.Level, child: Int?, error: (any Error)? = nil, extra: [Event.Field] = []) {
        var fields: [Event.Field] = []
        if let child { fields.append(.init("child", .string(supervisor.children[child].label), privacy: .public)) }
        if let error { fields.append(.init("error", .error(error))) }
        ambient.instrumentation.record(Event(name, level: level, label: supervisor.label, fields: fields + extra))
    }
}

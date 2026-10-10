/// One run of a supervisor: a single loop that owns all of its state.
///
/// Children, their monitors and their restart timers report to the loop
/// through one stream, and only the loop decides, so no decision races
/// another. A signal from a child generation that has since been stopped or
/// replaced is stale and ignored.
struct SupervisorRun {
    private enum Signal: Sendable {
        case exited(index: Int, generation: UInt64, error: (any Error)?)
        case restartDue(index: Int, generation: UInt64)
        case hung(index: Int, generation: UInt64)
    }

    private struct Slot {
        var generation: UInt64 = 0
        var task: Task<Void, Never>?
        var cause: CancellationCauseBox?
        var monitor: Task<Void, Never>?
        var startedAt: AnyClock.Instant?
        var stepper: Schedule.Stepper
        var restartTimer: Task<Void, Never>?
        var pendingRestart: [Int] = []
        var finished = false
    }

    struct Hung: Error, CustomStringConvertible {
        let child: String
        var description: String { "child \(child) stopped beating" }
    }

    let supervisor: Supervisor
    let ambient: Ambient
    let publish: AsyncStream<SupervisorEvent>.Continuation

    private var clock: AnyClock { ambient.clock }

    init(supervisor: Supervisor, ambient: Ambient, publish: AsyncStream<SupervisorEvent>.Continuation) {
        self.supervisor = supervisor
        self.ambient = ambient
        self.publish = publish
    }

    func execute() async throws {
        // stoic:allow(unbounded-stream): each child generation yields at most an exit, a hang and a restart notice, and this loop drains them as they arrive
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
                    await stopAll(&slots)
                    finish(.escalated(child: supervisor.children[index].label), level: .error, child: index, error: error)
                    throw escalation
                }

            case .restartDue(let index, let generation):
                guard slots[index].generation == generation else { continue }
                slots[index].restartTimer = nil
                let group = slots[index].pendingRestart
                slots[index].pendingRestart = []
                for member in group {
                    start(member, in: &slots, sink: sink)
                }

            case .hung(let index, let generation):
                guard slots[index].generation == generation, slots[index].task != nil else { continue }
                let label = supervisor.children[index].label
                publish.yield(.hung(child: label))
                record("supervisor.child_hung", .error, child: index)
                await stop(index, in: &slots)
                if let escalation = await handleStop(index, error: Hung(child: label), slots: &slots, restarts: &restarts, sink: sink) {
                    await stopAll(&slots)
                    finish(.escalated(child: label), level: .error, child: index, error: Hung(child: label))
                    throw escalation
                }
            }
            if slots.allSatisfy({ $0.finished && $0.task == nil && $0.restartTimer == nil }) {
                finish(.stopped, level: .info, child: nil, error: nil)
                return
            }
        }
        // The stream ends only when this task is cancelled.
        await stopAll(&slots)
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
        publish.yield(.exited(child: child.label, failed: failed))
        record("supervisor.child_exited", failed ? .warning : .info, child: index, error: error)

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
        // resurrect it.
        affected.removeAll { $0 != index && slots[$0].finished && slots[$0].task == nil && slots[$0].restartTimer == nil }
        // This decision supersedes any restart already pending for a member:
        // otherwise an older timer would start members out of order, and a
        // newer one would start them a second time.
        for member in affected {
            slots[member].restartTimer?.cancel()
            slots[member].restartTimer = nil
            slots[member].pendingRestart = []
        }
        // Stop the siblings that restart with it, newest first.
        for member in affected.reversed() where member != index && slots[member].task != nil {
            await stop(member, in: &slots)
        }
        for member in affected { slots[member].finished = false }

        // A child that ran long enough starts its backoff over.
        if let started = slots[index].startedAt, started.duration(to: now) >= supervisor.resetAfter {
            slots[index].stepper = supervisor.backoff.makeStepper(random: ambient.random.generator())
        }
        // A backoff schedule that has ended means restarting should stop.
        guard let scheduled = slots[index].stepper.next(elapsed: .zero) else {
            return SupervisorEscalation(supervisor: supervisor.label, child: child.label, lastError: error)
        }
        let delay = scheduled.saturatingMultiplied(by: ambient.conditions.current.backoffFactor)
        publish.yield(.restarting(child: child.label, after: delay))
        record("supervisor.child_restarting", .info, child: index, extra: [.init("delay", .duration(delay))])

        slots[index].pendingRestart = affected
        let generation = slots[index].generation
        let clock = clock
        slots[index].restartTimer = Task {
            do {
                try await clock.sleep(until: clock.now.advanced(by: delay), tolerance: nil)
            } catch {
                return
            }
            sink.yield(.restartDue(index: index, generation: generation))
        }
        return nil
    }

    // MARK: Children

    private func start(_ index: Int, in slots: inout [Slot], sink: AsyncStream<Signal>.Continuation) {
        // Never two instances of one child: a running child is left alone.
        guard slots[index].task == nil else { return }
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
                try await withAmbient({ $0 = ambient }) {
                    try await CancellationCauseBox.$current.withValue(cause) {
                        try await child.run(heartbeat)
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
            slots[index].monitor = Task {
                do {
                    try await clock.sleep(until: clock.now.advanced(by: policy.grace), tolerance: nil)
                    var last = heartbeat.count
                    var misses = 0
                    while true {
                        try await clock.sleep(until: clock.now.advanced(by: policy.interval), tolerance: nil)
                        let current = heartbeat.count
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
        publish.yield(.started(child: child.label))
        record("supervisor.child_started", .debug, child: index)
    }

    /// Stops a running child: newer signals from it become stale, it is
    /// cancelled, and it gets its shutdown timeout before being abandoned.
    private func stop(_ index: Int, in slots: inout [Slot]) async {
        guard let task = slots[index].task else { return }
        slots[index].generation += 1
        slots[index].monitor?.cancel()
        slots[index].monitor = nil
        slots[index].cause?.record(.supervisorStopped)
        slots[index].task = nil
        task.cancel()
        let timeout = supervisor.children[index].shutdownTimeout
        let clock = clock
        let outcome = await withTaskCancellationShield {
            await waitForTask(task, within: timeout, clock: clock)
        }
        if case .timedOut = outcome {
            record("supervisor.child_abandoned", .error, child: index, extra: [.init("timeout", .duration(timeout))])
        }
    }

    private func stopAll(_ slots: inout [Slot]) async {
        for index in slots.indices {
            slots[index].restartTimer?.cancel()
            slots[index].restartTimer = nil
            slots[index].pendingRestart = []
        }
        for index in slots.indices.reversed() {
            await stop(index, in: &slots)
        }
    }

    // MARK: Reporting

    private func finish(_ event: SupervisorEvent, level: Event.Level, child: Int?, error: (any Error)?) {
        publish.yield(event)
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

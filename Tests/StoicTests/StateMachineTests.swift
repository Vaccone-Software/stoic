@testable import Stoic
import Observation
import StoicTesting
import Testing

@Suite("StateMachine")
struct StateMachineTests {
    enum Phase: Hashable, Sendable, CaseIterable { case idle, listening, transcribing, failed, orphan }
    enum Input: Sendable, CaseIterable { case start, heard, finished, error, timeout, cancel }

    static let transitions: @Sendable (Phase, Input) -> Transition<Phase, Input> = { phase, input in
        switch (phase, input) {
        case (.idle, .start): .to(.listening, timeout: .init(after: .seconds(13), send: .timeout))
        case (.listening, .heard): .to(.transcribing)
        case (.listening, .timeout), (.listening, .error), (.transcribing, .error): .to(.failed)
        case (.transcribing, .finished), (.listening, .cancel), (.transcribing, .cancel), (.failed, .start): .to(.idle)
        case (.idle, .finished): .invalid("nothing to finish")
        default: .ignore
        }
    }

    @Test func eventsMoveTheMachineAndAreRecorded() {
        let machine = StateMachine(initial: Phase.idle, label: "dictation", clock: TestClock().erased, transition: Self.transitions)
        machine.send(.start)
        machine.send(.heard)
        machine.send(.finished)
        #expect(machine.state == .idle)
        #expect(machine.history.map { "\($0.from)>\($0.to)" } == ["idle>listening", "listening>transcribing", "transcribing>idle"])
    }

    @Test(arguments: [0, 1, 3, 64]) func historyKeepsTheMostRecentTransitionsOldestFirst(limit: Int) {
        enum Tick: Sendable { case tick }
        let machine = StateMachine<Int, Tick>(initial: 0, label: "counter", historyLimit: limit, clock: TestClock().erased) { count, _ in
            .to(count + 1)
        }
        for sent in 1...100 {
            machine.send(.tick)
            let expected = Array(max(0, sent - limit)..<sent)
            #expect(machine.history.map(\.from) == expected, "after \(sent) events")
        }
    }

    @Test(.failureMode("design/07", "an event is invalid in the current state")) func invalidEventsAreReportedAndChangeNothing() async {
        let events = RecordingInstrumentation()
        await withTestAmbient(clock: TestClock(), events: events) {
            let machine = StateMachine(initial: Phase.idle, label: "dictation", transition: Self.transitions)
            machine.send(.finished)
            #expect(machine.state == .idle)
        }
        #expect(events.names == ["statemachine.invalid"])
    }

    @Test(.failureMode("design/07", "a state is left while its work runs")) func stateWorkIsCancelledWhenTheStateIsLeft() async {
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let stopped = AsyncGate()
        let machine = StateMachine(initial: Phase.idle, label: "dictation", clock: TestClock().erased, transition: Self.transitions)
        machine.whileIn(.listening, label: "microphone") { _ in
            started.open()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                observed.mutate { $0 = CancellationCause.current }
            }
            stopped.open()
        }
        machine.send(.start)
        await started.wait()
        machine.send(.cancel)
        await stopped.wait()
        #expect(observed.value == .stateExited)
    }

    /// Cancelling a task runs its cancellation handlers on the cancelling
    /// thread, at once. The old visit's work is cancelled after the machine
    /// releases its lock, so a handler that uses the machine — or work that
    /// observes it, whose stream ends on cancellation — is safe. A trap
    /// cannot be caught in-process, so each case runs in a child process.
    @Test(.failureMode("design/07", "state work's cancellation handler uses the machine"))
    func aCancellationHandlerInStateWorkMayUseTheMachine() async {
        await #expect(processExitsWith: .success) {
            let machine = StateMachine<Int, Int>(initial: 0, label: "reentrant", clock: AnyClock.continuous) { state, _ in
                .to(state == 0 ? 1 : 0)
            }
            let started = AsyncGate()
            machine.whileIn(0, label: "watcher") { [weak machine] _ in
                await withTaskCancellationHandler {
                    started.open()
                    try? await Task.sleep(for: .seconds(3600))
                } onCancel: {
                    _ = machine?.state
                }
            }
            await started.wait()
            // Lets the work's tasks suspend inside their cancellation handlers.
            try? await Task.sleep(for: .milliseconds(100))
            machine.send(0)
        }
    }

    @Test func stateWorkMayObserveItsOwnMachine() async {
        await #expect(processExitsWith: .success) {
            let machine = StateMachine<Int, Int>(initial: 0, label: "observer", clock: AnyClock.continuous) { state, _ in
                .to(state == 0 ? 1 : 0)
            }
            let started = AsyncGate()
            machine.whileIn(0, label: "watcher") { [weak machine] _ in
                guard let states = machine?.states() else { return }
                for await _ in states { started.open() }
            }
            await started.wait()
            try? await Task.sleep(for: .milliseconds(100))
            machine.send(0)
        }
    }

    /// A transition function runs while the machine is locked; one that uses
    /// a machine fails with a message that says why, not the lock's abort.
    @Test(.failureMode("design/07", "a transition function uses the machine"))
    func aTransitionFunctionThatUsesTheMachineFailsWithItsReason() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let holder = SendableBox<StateMachine<Int, Int>?>(nil)
            let machine = StateMachine<Int, Int>(initial: 0, label: "impure", clock: AnyClock.continuous) { state, _ in
                _ = holder.value?.state
                return .to(state + 1)
            }
            holder.mutate { $0 = machine }
            machine.send(1)
        }
        let stderr = String(decoding: try #require(result).standardErrorContent, as: UTF8.self)
        #expect(stderr.contains("StateMachine impure: a transition function or whileIn predicate must not use a state machine"))
    }

    @Test(.failureMode("design/07", "the work sends an event after its visit ended")) func eventsFromAnEarlierVisitAreDropped() async {
        let events = RecordingInstrumentation()
        let clock = TestClock()
        await withTestAmbient(clock: clock, events: events) {
            let machine = StateMachine(initial: Phase.idle, label: "dictation", transition: Self.transitions)
            let firstVisit = SendableBox<StateMachine<Phase, Input>.Sender?>(nil)
            let captured = AsyncGate()
            machine.whileIn(.listening, label: "capture sender") { sender in
                if firstVisit.value == nil {
                    firstVisit.mutate { $0 = sender }
                    captured.open()
                }
            }
            machine.send(.start)
            await captured.wait()
            machine.send(.cancel)   // leave listening
            machine.send(.start)    // a second, separate visit to listening
            firstVisit.value?.send(.heard)   // late event from the first visit
            #expect(machine.state == .listening, "the stale event must not move the machine")
        }
        #expect(events.names.contains("statemachine.stale_event"))
    }

    @Test(.failureMode("design/07", "the state is left before its timeout"), .failureMode("design/07", "a state's timeout elapses during its visit")) func aStateTimeoutFiresOnlyIfTheStateIsStillCurrent() async {
        let clock = TestClock()
        let machine = StateMachine(initial: Phase.idle, label: "dictation", clock: clock.erased, transition: Self.transitions)
        machine.send(.start)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(13))
        #expect(await eventually { machine.state == .failed })

        // A visit that ends before its timeout cancels the timer.
        machine.send(.start)          // failed -> idle
        machine.send(.start)          // idle -> listening, timer armed
        await clock.waitForSleepers(count: 1)
        machine.send(.heard)          // listening -> transcribing; timer cancelled
        #expect(await eventually { clock.sleeperCount == 0 }, "the timer of the left state is cancelled")
        await clock.advance(by: .seconds(13))
        #expect(machine.state == .transcribing)
    }

    @Test func observersSeeTheCurrentState() async {
        let machine = StateMachine(initial: Phase.idle, label: "dictation", clock: TestClock().erased, transition: Self.transitions)
        var iterator = machine.states().makeAsyncIterator()
        #expect(await iterator.next() == .idle)
        machine.send(.start)
        #expect(await iterator.next() == .listening)
    }

    @Test func observersThatStopListeningAreForgotten() async {
        let machine = StateMachine(initial: Phase.idle, label: "dictation", clock: TestClock().erased, transition: Self.transitions)
        for _ in 0..<100 {
            var iterator: AsyncStream<Phase>.Iterator? = machine.states().makeAsyncIterator()
            _ = await iterator?.next()
            iterator = nil
        }
        let kept = machine.states()
        #expect(await eventually { machine.observerCount == 1 }, "abandoned streams are removed; the live one stays")
        _ = kept
    }

    @Test func aTimeoutCountsFromEntryNotFromWhenItsTimerFirstRuns() async {
        let clock = TestClock()
        let machine = StateMachine(initial: Phase.idle, label: "dictation", clock: clock.erased, transition: Self.transitions)
        machine.send(.start)
        // No waiting for the timer to register: the clock moves at once.
        await clock.advance(by: .seconds(13))
        #expect(await eventually { machine.state == .failed })
    }

    @Test func stateWorkDoesNotInheritTheSendersDeadline() async {
        let seen = SendableBox<Bool?>(nil)
        let ran = AsyncGate()
        let machine = StateMachine(initial: Phase.idle, label: "dictation", clock: TestClock().erased, transition: Self.transitions)
        machine.whileIn(.listening, label: "probe") { _ in
            seen.mutate { $0 = Deadline.current != nil }
            ran.open()
        }
        Deadline.$stored.withValue(.after(.milliseconds(50))) {
            machine.send(.start)
        }
        await ran.wait()
        #expect(seen.value == false, "state work belongs to the state, not to the sender")
    }

    @Test(.failureMode("design/07", "a thousand tasks send events at once")) func concurrentSendersAreSerialised() async {
        enum Counter: Sendable { case tick }
        let machine = StateMachine<Int, Counter>(initial: 0, label: "counter", historyLimit: 2_000, clock: TestClock().erased) { count, _ in
            .to(count + 1)
        }
        await withTaskGroup { group in
            for _ in 0..<1_000 { group.addTask { machine.send(.tick) } }
        }
        #expect(machine.state == 1_000)
        #expect(machine.history.count == 1_000)
    }

    // MARK: StateGraph

    @Test(.failureMode("design/07", "a declared state can never be reached")) func explorationFindsReachableStatesInvalidPairsAndUnreachableOnes() {
        let graph = StateGraph.explore(from: Phase.idle, events: Input.allCases, transition: Self.transitions)
        #expect(Set(graph.states) == [.idle, .listening, .transcribing, .failed])
        #expect(graph.unreachable(of: Phase.allCases) == [.orphan])
        #expect(graph.invalid.map(\.event) == ["finished"])
        #expect(graph.deadEnds.isEmpty)
        #expect(graph.mermaid.contains("idle --> listening: start (after 13.0 seconds)"))
        #expect(!graph.truncated)
    }

    @Test func explorationFollowsTheEventsStateTimeoutsSend() {
        enum Step: Sendable { case start, expire, finish }
        // `expire` is sent only by the timeout, and appears in no event list.
        let graph = StateGraph<String, Step>.explore(from: "idle", events: [.start, .finish]) { state, step in
            switch (state, step) {
            case ("idle", .start): .to("waiting", timeout: .init(after: .seconds(5), send: .expire))
            case ("waiting", .expire): .to("timedOut")
            case ("waiting", .finish): .to("idle")
            default: .ignore
            }
        }
        #expect(Set(graph.states) == ["idle", "waiting", "timedOut"])
        #expect(graph.edges.contains { $0.from == "waiting" && $0.event == "expire" && $0.to == "timedOut" })
    }

    @Test func explorationStopsAtTheStateLimit() {
        enum Step: Sendable { case next }
        let graph = StateGraph<Int, Step>.explore(from: 0, events: [.next], maximumStates: 50) { n, _ in .to(n + 1) }
        #expect(graph.truncated)
        #expect(graph.states.count == 50)
    }
}

@Suite("Random walks")
struct RandomWalkTests {
    enum Door: Hashable, Sendable { case closed, open, locked }
    enum Action: Sendable, CaseIterable { case open, close, lock, unlock }

    static let door: @Sendable (Door, Action) -> Transition<Door, Action> = { door, action in
        switch (door, action) {
        case (.closed, .open): .to(.open)
        case (.open, .close): .to(.closed)
        case (.closed, .lock): .to(.locked)
        case (.locked, .unlock): .to(.closed)
        // The bug: a locked door opens.
        case (.locked, .open): .to(.open)
        default: .ignore
        }
    }

    @Test func findsAndShrinksAViolatingSequence() throws {
        let violation = randomWalks(from: Door.closed, events: Action.allCases, seed: 3, transition: Self.door) { door, history in
            // A door that was locked, and not unlocked since, must not open.
            guard door == .open, let lastLock = history.lastIndex(where: { if case .lock = $0 { true } else { false } }) else { return nil }
            let unlocked = history[lastLock...].contains { if case .unlock = $0 { true } else { false } }
            return unlocked ? nil : "opened while locked"
        }
        let found = try #require(violation)
        #expect(found.events.count == 2, "shrunk to lock → open, got \(found)")
        #expect(found.message == "opened while locked")
    }

    @Test func aCorrectMachinePasses() {
        let violation = randomWalks(from: Door.closed, events: Action.allCases, seed: 3, transition: { door, action in
            if door == .locked, case .open = action { return .ignore }
            return Self.door(door, action)
        }) { door, _ in nil }
        #expect(violation == nil)
    }
}

@Suite("StateMachine observation")
struct StateMachineObservationTests {
    enum Light: Hashable, Sendable { case red, green }
    enum Change: Sendable { case go, stop }

    @Test func readingTheStateRegistersForTheNextTransition() async {
        let machine = StateMachine<Light, Change>(initial: .red, label: "light") { _, change in
            switch change { case .go: .to(.green); case .stop: .to(.red) }
        }
        let changed = AsyncGate()
        withObservationTracking {
            _ = machine.state
        } onChange: {
            changed.open()
        }
        machine.send(.go)
        await changed.wait()
        #expect(machine.state == .green)
    }
}

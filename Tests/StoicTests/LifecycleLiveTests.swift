import Stoic
import StoicTesting
import Synchronization
import Testing

/// design/27 live: a definition run by `StateMachine`, on virtual time.
@Suite("Lifecycles live")
struct LifecycleLiveTests {
    @Test(.failureMode("design/27", "a lifecycle runs live"))
    func theInitialStatesTimeoutIsArmedAndAnAtIsMeasuredOnTheWallClock() async throws {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            // The initial state's own timeout, an hour on the machine's clock.
            let reminder = StateMachine(Reminder.self, initial: .waiting, clock: AnyClock(clock), perform: { _ in })
            var reminders = reminder.states().makeAsyncIterator()
            _ = await reminders.next()
            await clock.waitForSleepers(count: 1)
            #expect(clock.pendingDeadlines.map { clock.now.duration(to: $0) } == [hour])
            await clock.advance(by: hour)
            #expect(await reminders.next() == .done)
            await reminder.shutdown()

            // `.at` is measured on the wall clock at entry: two hours ahead.
            let attendance = StateMachine(Attendance.self, initial: .signedUp(eventEnds: Moment.now + hour * 2), clock: AnyClock(clock))
            var attendances = attendance.states().makeAsyncIterator()
            _ = await attendances.next()
            await clock.waitForSleepers(count: 1)
            #expect(clock.pendingDeadlines.map { clock.now.duration(to: $0) } == [hour * 2])
            attendance.send(.checkIn(closesAt: Moment.now - hour))
            // Entered after its `.at` had passed: due at once, with no time
            // passing.
            while let state = await attendances.next(), state != .closedUnattended {}
            #expect(attendance.state == .closedUnattended)
            #expect(attendance.history.map(\.to) == [.onSite(closesAt: Moment.now - hour), .closedUnattended])
            // `.refuse` reads as `.ignore` live.
            attendance.send(.checkOut)
            #expect(attendance.state == .closedUnattended)
            await attendance.shutdown()
        }
    }

    @Test(.failureMode("design/27", "a live lifecycle's transition carries effects"))
    func effectsArePerformedOnceEachInOrderAfterObservers() async throws {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let log = Mutex<[String]>([])
            let machine = StateMachine(Reminder.self, initial: .waiting, clock: AnyClock(clock)) { effect in
                log.withLock { $0.append("perform \(effect)") }
            }
            var states = machine.states().makeAsyncIterator()
            _ = await states.next()
            machine.send(.nudge)
            machine.send(.nudge)
            machine.send(.finish)
            #expect(log.withLock { $0 } == ["perform notify(\"nudged\")", "perform notify(\"nudged\")"])
            #expect(await states.next() == .done)
            await machine.shutdown()
        }
    }

    /// An effect performed from inside `perform` that sends the machine an
    /// event queues behind its own: no deadlock, and order is kept.
    @Test func anEffectThatSendsAnEventDoesNotDeadlock() async throws {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let log = Mutex<[String]>([])
            let box = Mutex<StateMachine<Reminder.State, Reminder.Event>?>(nil)
            let machine = StateMachine(Reminder.self, initial: .waiting, clock: AnyClock(clock)) { effect in
                log.withLock { $0.append("\(effect)") }
                let machine = box.withLock { $0 }
                machine?.send(.finish)
            }
            box.withLock { $0 = machine }
            machine.send(.nudge)
            #expect(machine.state == .done)
            #expect(log.withLock { $0 } == ["notify(\"nudged\")"])
            box.withLock { $0 = nil }
            await machine.shutdown()
        }
    }

    @Test func aThousandSendersPerformEveryEffectOnce() async throws {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let count = Mutex(0)
            let machine = StateMachine(Reminder.self, initial: .waiting, clock: AnyClock(clock)) { _ in count.withLock { $0 += 1 } }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<1_000 { group.addTask { machine.send(.nudge) } }
            }
            #expect(count.withLock { $0 } == 1_000)
            await machine.shutdown()
        }
    }
}

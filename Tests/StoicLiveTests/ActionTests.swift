import Stoic
@testable import StoicLive
import StoicTesting
import Synchronization
import Testing

/// design/31's failure modes for `Action`: second triggers, intents and their
/// keys, unknown outcomes, unseen failures, ownership and refreshes. On the
/// main actor, against scripted operations; without SwiftUI.
@Suite("Actions")
@MainActor
struct ActionTests {
    static func signUp(_ script: Script<Int>, whileRunning: Action<String, Int>.WhileRunning = .refuse) -> Action<String, Int> {
        Action(API.signUp, whileRunning: whileRunning) { _, attempt in try await script.call(attempt, keyed: true) }
    }

    @Test(.failureMode("design/31", "an action is triggered twice and declared .refuse"))
    func aSecondTriggerIsRefusedAndOneRequestIsSent() async throws {
        try await onLiveTime { _, events in
            let gate = TestGate()
            let script = Script<Int>(.gated(gate, 7))
            let action = Self.signUp(script)
            #expect(action.trigger("beach-clean") == .started)
            #expect(action.phase.isRunning)
            #expect(action.trigger("beach-clean") == .refused(.running))
            #expect(events.events(named: "action.refused").first?["why"]?.description == "running")
            gate.open()
            await action.waitForEnd()
            #expect(script.calls == 1)
            guard case .succeeded(7) = action.phase else { Issue.record("\(action.phase)"); return }
        }
    }

    @Test(.failureMode("design/31", "an action is triggered twice with one input and declared .join"))
    func aSecondTriggerWithTheSameInputJoinsAndBothCallersGetItsOutcome() async throws {
        try await onLiveTime { _, events in
            let gate = TestGate()
            let script = Script<Int>(.gated(gate, 7))
            let action = Self.signUp(script, whileRunning: .join)
            async let first = action.run("beach-clean")
            await script.wait(.calls, 1)
            #expect(action.trigger("beach-clean") == .joined)
            async let second = action.run("beach-clean")
            gate.open()
            let phases = await [first, second]
            #expect(script.calls == 1, "one request")
            for phase in phases {
                guard case .succeeded(7) = phase else { Issue.record("\(phase)"); return }
            }
            #expect(events.count("action.joined") == 2)
        }
    }

    @Test(.failureMode("design/31", "an action declared .join is triggered with another input while running"))
    func aJoinWithAnotherInputIsRefused() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let script = Script<Int>(.gated(gate, 7))
            let action = Self.signUp(script, whileRunning: .join)
            action.trigger("beach-clean")
            #expect(action.trigger("litter-pick") == .refused(.running), "two intents cannot share one request")
            gate.open()
            await action.waitForEnd()
            #expect(script.calls == 1)
        }
    }

    @Test(.failureMode("design/31", "a keyed action fails with an unknown outcome and is triggered again"))
    func aRetryAfterAnUnknownOutcomeIsTheSameIntentAndKey() async throws {
        try await onLiveTime { _, events in
            let script = Script<Int>(.failure(Lost()), .failure(Lost()), .value(7))
            let action = Self.signUp(script)
            let failed = await action.run("beach-clean")
            guard case .failed(let presented) = failed else { Issue.record("\(failed)"); return }
            #expect(presented.message.key == "stoic.outcome.unconfirmed")
            #expect(presented.recovery == .tryAgain)
            #expect(events.events(named: "action.failed").first?["outcome"]?.description == "unknown")
            _ = await action.run("beach-clean")   // "Try again" after a lost connection
            #expect(script.keys.count == 3)
            #expect(Set(script.keys).count == 1, "every attempt of every run within the intent")
        }
    }

    @Test(.failureMode("design/31", "an action fails with a not-executed outcome and is triggered again"))
    func aRetryAfterANotExecutedOutcomeIsTheSameIntentAndKey() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.failure(Unreached()), .value(7))
            let action = Self.signUp(script)
            _ = await action.run("beach-clean")
            _ = await action.run("beach-clean")
            #expect(script.keys.count == 2)
            #expect(Set(script.keys).count == 1)
        }
    }

    @Test(.failureMode("design/31", "an action fails with an executed outcome and is triggered again"))
    func aRetryAfterAnExecutedOutcomeIsANewIntent() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.failure(Refused()), .value(7))
            let action = Self.signUp(script)
            _ = await action.run("beach-clean")
            _ = await action.run("beach-clean")
            #expect(script.keys.count == 2)
            #expect(Set(script.keys).count == 2, "the backend answered for good: a server replays that answer to the same key")
        }
    }

    @Test(.failureMode("design/31", "an action fails and is triggered again with a different input"))
    func aTriggerWithAnotherInputAfterAFailureIsANewIntent() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.failure(Unreached()), .value(7))
            let action = Self.signUp(script)
            _ = await action.run("beach-clean")
            _ = await action.run("litter-pick")
            #expect(Set(script.keys).count == 2, "the person changed what they asked for")
        }
    }

    @Test(.failureMode("design/31", "an action succeeds and is triggered again"))
    func aTriggerAfterASuccessIsANewIntent() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.value(7))
            let action = Self.signUp(script)
            _ = await action.run("beach-clean")
            _ = await action.run("beach-clean")
            #expect(Set(script.keys).count == 2)
        }
    }

    @Test(.failureMode("design/31", "a not-repeatable action fails with an unknown outcome"))
    func anUnknownOutcomeOnANotRepeatableActionRefusesTriggersUntilReset() async throws {
        try await onLiveTime { _, events in
            let script = Script<Void>(.failure(Lost()), .value(()))
            let delete = Action<String, Void>(API.remove) { _, attempt in try await script.call(attempt) }
            let failed = await delete.run("event-3")
            guard case .failed(let presented) = failed else { Issue.record("\(failed)"); return }
            #expect(presented.recovery == .checkFirst)
            #expect(presented.message.key == "stoic.outcome.unknown")
            #expect(delete.trigger("event-3") == .refused(.outcomeUnknown), "the effect may already have happened")
            #expect(delete.trigger("event-4") == .refused(.outcomeUnknown))
            #expect(events.events(named: "action.refused").last?["why"]?.description == "outcome_unknown")
            #expect(script.calls == 1)
            delete.reset()   // the person looked
            guard case .idle = delete.phase else { Issue.record("\(delete.phase)"); return }
            _ = await delete.run("event-3")
            #expect(script.calls == 2)
        }
    }

    @Test(.failureMode("design/31", "an action's failure is never read before it is replaced or released"))
    func aFailureNobodyReadIsReportedUnseen() async throws {
        try await onLiveTime { _, events in
            let script = Script<Int>(.failure(Refused()), .failure(Refused()), .value(1))
            var action: Action<String, Int>? = Self.signUp(script)
            action?.trigger("a")
            await action?.waitForEnd()
            action?.trigger("b")   // replaced, never read: Kindora's empty catch
            await events.wait(for: "action.failure_unseen", count: 1)
            await action?.waitForEnd()
            #expect(events.events(named: "action.failure_unseen").first?.level == .warning)
            action = nil   // released, never read
            await events.wait(for: "action.failure_unseen", count: 2)
            // A failure that was read is not reported.
            let read = Self.signUp(Script<Int>(.failure(Refused()), .value(1)))
            read.trigger("a")
            await read.waitForEnd()
            _ = read.phase
            read.trigger("a")
            await read.waitForEnd()
            #expect(events.count("action.failure_unseen") == 2)
        }
    }

    @Test(.failureMode("design/31", "the view that triggered an action goes away"))
    func aCancelledCallerStopsWaitingAndTheRunGoesOn() async throws {
        try await onLiveTime { _, _ in
            let gate = TestGate()
            let script = Script<Int>(.gated(gate, 7))
            let action = Self.signUp(script)
            let view = Task { @MainActor in await action.run("beach-clean") }
            await script.wait(.calls, 1)
            view.cancel()   // the view went away
            let seen = await view.value
            #expect(seen.isRunning, "the caller got the phase as it was")
            gate.open()
            await action.waitForEnd()
            guard case .succeeded(7) = action.phase else { Issue.record("\(action.phase)"); return }
        }
    }

    @Test(.failureMode("design/31", "an Action is released while running"))
    func aReleasedActionCancelsItsRunAndAShieldedAttemptReportsItsOutcome() async throws {
        try await onLiveTime { _, events in
            // An idempotent run is cancelled at once.
            let hanging = Script<Int>(.hang)
            var rename: Action<String, Int>? = Action(API.rename) { _, attempt in try await hanging.call(attempt) }
            rename?.trigger("New name")
            await hanging.wait(.calls, 1)
            rename = nil
            await hanging.wait(.cancelled, 1)
            // A brief keyed attempt finishes, shielded, and its outcome is reported.
            let gate = TestGate()
            let paying = Script<Int>(.gated(gate, 7))
            var signUp: Action<String, Int>? = Self.signUp(paying)
            signUp?.trigger("beach-clean")
            await paying.wait(.calls, 1)
            signUp = nil
            gate.open()
            await paying.wait(.finished, 1)
            await events.wait(for: "action.orphaned", count: 2)
            let outcomes = events.events(named: "action.orphaned").compactMap { $0["outcome"]?.description }
            #expect(outcomes.contains("succeeded"), "the shielded attempt finished: \(outcomes)")
            _ = (rename, signUp)
        }
    }

    @Test(.failureMode("design/31", "an action succeeds with refreshes"))
    func aSuccessInvalidatesItsLivesTogether() async throws {
        try await onLiveTime { _, _ in
            let attendees = Live(API.roster) { _ in ["ana"] }
            let minors = Live(API.minors) { _ in [String]() }
            _ = attendees.phase
            _ = minors.phase
            await attendees.waitForLoad()
            await minors.waitForLoad()
            let signUp = Action(API.signUp, refreshes: [attendees, minors]) { (_: String, attempt: Attempt) async throws(Refused) -> Int in
                _ = attempt.idempotencyKey
                return 1
            }
            #expect(attendees.current == .fresh(["ana"]))
            _ = await signUp.run("beach-clean")
            // In the turn the run ended in: both, together.
            #expect(attendees.current == .stale(["ana"], refreshing: false))
            #expect(minors.current == .stale([], refreshing: false))
        }
    }

    @Test func aVoidActionTriggersWithoutAnInput() async throws {
        try await onLiveTime { _, _ in
            let script = Script<Int>(.value(3))
            let refresh = Action(API.rename) { attempt in try await script.call(attempt) }
            #expect(refresh.trigger() == .started)
            #expect(refresh.trigger() == .refused(.running))
            await refresh.waitForEnd()
            guard case .succeeded(3) = await refresh.run() else { Issue.record("\(refresh.phase)"); return }
            #expect(refresh.label == "test.api.events.rename")
            #expect(script.urgencies.allSatisfy { $0 == .interactive }, "a person tapped")
        }
    }
}

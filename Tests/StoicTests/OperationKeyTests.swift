@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// The idempotency key a `perform` sends: given, derived inside an enclosing
/// attempt, or drawn (design/22, Keys).
@Suite("Operation keys")
struct OperationKeyTests {
    // MARK: Relaunch

    @Test(.failureMode("design/22", "a keyed perform's derived key after an app update and relaunch"))
    func theDerivedKeyIsTheSameAfterARelaunch() async throws {
        // Two launches with nothing in common but the enclosing key (an
        // outbox entry's, a checkout's): the key a keyed perform inside sends
        // is the frozen derivation's (see DerivedKeyTests).
        let parent = IdempotencyKey(rawValue: "order-42")
        let checkout = Backend.remote("keys.relaunch-checkout").idempotent("checkout")
        let subscribe = Backend.remote("payments").keyed("subscribe")
        func launch(seed: UInt64) async throws -> [IdempotencyKey] {
            let script = Script([.succeed])
            _ = try await simulated(seed: seed) { _ in
                try? await checkout.perform(idempotencyKey: parent) { _ throws(OperationError<any Error>) in
                    _ = try await subscribe.perform { attempt throws(any Error) in try await script.call(attempt) }
                }
            }
            return script.keys
        }
        let first = try await launch(seed: 1)
        let relaunched = try await launch(seed: 99)
        #expect(first.map(\.rawValue) == ["f1538199-d383-8107-ad6a-096410d47137"])
        #expect(relaunched == first)
    }

    // MARK: Keys in enclosing attempts

    @Test(.failureMode("design/22", "two keyed performs run at one site in a loop inside one enclosing attempt"))
    func eachPerformInALoopHasItsOwnKeyOnEveryEnclosingAttempt() async throws {
        let charge = Backend.remote("keys.loop").keyed("charge")
        let perAttempt = SendableBox<[[IdempotencyKey]]>([])
        _ = try await simulated { _ in
            try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(Transient) in
                var keys: [IdempotencyKey] = []
                for _ in 0..<2 {
                    let script = Script([.succeed])
                    _ = await performing(charge, script)
                    keys += script.keys
                }
                perAttempt.mutate { $0.append(keys) }
                throw Transient()   // the enclosing attempt fails after both
            }
        }
        let attempts = perAttempt.value
        #expect(attempts.count == 3)
        #expect(attempts[0].count == 2)
        #expect(attempts[0][0] != attempts[0][1])
        #expect(attempts.allSatisfy { $0 == attempts[0] })
    }

    @Test(.failureMode("design/22", "a keyed perform without a key runs in a child task of an enclosing attempt"))
    func aKeyedPerformInAChildTaskIsAmbiguousAndNotRepeated() async throws {
        let charge = Backend.remote("keys.ambiguous").keyed("charge")
        let script = Script([.fail(Transient())])
        let events = RecordingInstrumentation()
        await withKnownIssue {
            let result = await withTestAmbient(clock: TestClock(), events: events) {
                await withUrgency(.userInitiated) {
                    await RetryContext.$active.withValue(nil) {
                        try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(Transient) -> OperationError<any Error>? in
                            async let child = performing(charge, script)
                            return await child.error
                        }
                    }
                }
            }
            let error = try #require(result ?? nil)
            #expect(error.attempts == 1)
        }
        #expect(script.count == 1)
        #expect(events.events(named: "operation.key_ambiguous").count == 1)
    }

    @Test func aKeyedPerformInAChildTaskWithAKeyIsRepeated() async throws {
        let charge = Backend.remote("keys.child-with-key").keyed("charge")
        let script = Script([.fail(Transient()), .succeed])
        let run = try await simulated { context in
            let value = await withUrgency(.userInitiated) {
                try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(Transient) -> Int? in
                    async let child = performing(charge, script, key: IdempotencyKey(rawValue: "item-9"))
                    return await child.success
                }
            }
            return (value, context.events.events(named: "operation.key_ambiguous").count)
        }
        #expect(run.value.0 == 2)
        #expect(run.value.1 == 0)
    }

    @Test func aPerformInsideAnAttemptTimeoutIsInTheAttemptsTask() async throws {
        // The deadline's single child does the attempt's work: not a child
        // task in the sense that makes a key ambiguous.
        let charge = Backend.remote("keys.timed-attempt").keyed("charge")
        let run = try await simulated { context in
            _ = await withUrgency(.userInitiated) {
                try? await retry(.fixed(.seconds(1)).attempts(2), attemptTimeout: .seconds(30), budget: .unlimited) { _ throws(Transient) in
                    _ = await performing(charge, Script([.succeed]))
                }
            }
            return context.events.events(named: "operation.key_ambiguous").count
        }
        #expect(run.value == 0)
    }

    @Test func aTopLevelKeyIsDrawnWhenFirstRead() async throws {
        let charge = Backend.remote("keys.drawn").keyed("charge")
        let scripts = [Script([.succeed]), Script([.succeed])]
        _ = try await simulated { _ in
            for script in scripts { _ = await performing(charge, script) }
        }
        #expect(scripts[0].keys.count == 1)
        #expect(scripts[0].keys != scripts[1].keys)
    }
}

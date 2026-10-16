import Dispatch
@testable import Stoic
import StoicTesting
import Synchronization
import Testing

@Suite("Quarantined releases")
struct QuarantineTests {
    enum Failure: Error { case never }

    /// A wedged synchronous call, released by the test when it is done.
    final class Wedge: Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        func block() { semaphore.wait() }   // stoic:allow(blocking-in-async): models a wedged synchronous call, on a Dispatch thread
        func release() { semaphore.signal() }
    }

    static func label(_ base: String) -> String {
        "\(base).\(IdempotencyKey.random().rawValue.prefix(8))"
    }

    /// Abandons one wedged call inside the current scope, almost at once.
    static func abandonOne(_ wedge: Wedge, label: String) async {
        _ = try? await abandoningAfter(.milliseconds(5), label: label) { () throws(Failure) -> Int in
            wedge.block()
            return 1
        }
    }

    @Test func withNothingAbandonedAQuarantinedReleaseRuns() async {
        let released = Mutex(false)
        await withScope { scope in
            scope.onExit(ifWorkAbandoned: .quarantine) { _ in released.withLock { $0 = true } }
            #expect(scope.abandonedWork == 0)
        }
        #expect(released.withLock { $0 })
    }

    @Test(.failureMode("design/04", "work started in the scope was abandoned")) func abandonedWorkQuarantinesOnlyWhatAskedFor() async {
        let events = RecordingInstrumentation()
        let wedge = Wedge()
        defer { wedge.release() }
        let closedHandle = Mutex(false)
        let flushedLog = Mutex(false)
        await withTestAmbient(clock: ContinuousClock(), events: events) {
            await withScope { scope in
                scope.onExit(label: "flush log") { _ in flushedLog.withLock { $0 = true } }
                scope.onExit(label: "close audio handle", ifWorkAbandoned: .quarantine) { _ in closedHandle.withLock { $0 = true } }
                await Self.abandonOne(wedge, label: Self.label("audio.start"))
                #expect(scope.abandonedWork == 1)
            }
        }
        #expect(!closedHandle.withLock { $0 }, "a handle a wedged call may still be using is not closed")
        #expect(flushedLog.withLock { $0 }, "everything else is released as usual")
        let quarantined = events.events(named: "scope.release_quarantined")
        #expect(quarantined.count == 1)
        #expect(quarantined.first?["abandoned"].map { "\($0)" } == "1")
    }

    @Test func workAbandonedInAnInnerScopeCountsForTheOuterOne() async {
        let wedge = Wedge()
        defer { wedge.release() }
        let closed = Mutex(false)
        await withScope { outer in
            outer.onExit(ifWorkAbandoned: .quarantine) { _ in closed.withLock { $0 = true } }
            await withScope { _ in
                await Self.abandonOne(wedge, label: Self.label("inner"))
            }
            #expect(outer.abandonedWork == 1)
        }
        #expect(!closed.withLock { $0 })
    }

    @Test func aResourceCarriesItsPolicy() async throws {
        let wedge = Wedge()
        defer { wedge.release() }
        let closed = Mutex(false)
        let handle = Resource<Int, Never>(label: "handle", ifWorkAbandoned: .quarantine) { 7 } release: { _, _ in
            closed.withLock { $0 = true }
        }
        await withScope { scope in
            _ = await scope.acquire(handle)
            await Self.abandonOne(wedge, label: Self.label("resource"))
        }
        #expect(!closed.withLock { $0 })
    }

    /// Abandonment is counted while the work runs, not for ever: work that
    /// finished after it was abandoned is using nothing, and a release
    /// decided at exit runs as usual instead of leaking.
    @Test(.failureMode("design/04", "abandoned work finishes before the scope exits")) func workThatFinishedAfterAbandonmentNoLongerQuarantines() async {
        let events = RecordingInstrumentation()
        let wedge = Wedge()
        let closed = Mutex(false)
        await withTestAmbient(clock: ContinuousClock(), events: events) {
            await withScope { outer in
                outer.onExit(ifWorkAbandoned: .quarantine) { _ in closed.withLock { $0 = true } }
                await withScope { inner in
                    await Self.abandonOne(wedge, label: Self.label("late"))
                    #expect(inner.abandonedWork == 1)
                    #expect(outer.abandonedWork == 1)
                    wedge.release()
                    #expect(await eventually { events.names.contains("abandoned.completed") })
                    #expect(inner.abandonedWork == 0)
                }
                #expect(outer.abandonedWork == 0)
            }
        }
        #expect(closed.withLock { $0 }, "the handle leaked though the abandoned work had finished")
        #expect(!events.names.contains("scope.release_quarantined"))
    }
}

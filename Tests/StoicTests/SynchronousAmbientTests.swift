import Dispatch
@testable import Stoic
import StoicTesting
import Testing

/// The synchronous `withAmbient`, which gives a synchronous entry point such as
/// an app's `main` a context. Its tests run on a plain Dispatch thread, which
/// is in no task, as `main` is: there the binding lives in the thread's own
/// storage, not a task's.
@Suite("Synchronous ambient")
struct SynchronousAmbientTests {
    enum Typed: Error, Equatable { case boom }

    static func tag() -> UInt64? { Ambient.current.ledgerTag }

    /// Runs `body` on a thread that is in no task.
    static func outsideAnyTask<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }

    @Test func aSynchronousBindingReachesSynchronousCallees() async {
        let seen = await Self.outsideAnyTask {
            let before = Self.tag()
            let inside = withAmbient({ $0.ledgerTag = 7 }) { Self.tag() }
            return [before, inside, Self.tag()]
        }
        #expect(seen == [nil, 7, nil])
    }

    @Test func aTaskStartedInsideSeesItBeforeAndAfterAnAwait() async {
        let task = await Self.outsideAnyTask {
            withAmbient({ $0.ledgerTag = 7 }) {
                Task {
                    let before = Self.tag()
                    await Task.yield()
                    return [before, Self.tag()]
                }
            }
        }
        #expect(await task.value == [7, 7])
    }

    @Test func aDetachedTaskStartedInsideDoesNot() async {
        let task = await Self.outsideAnyTask {
            withAmbient({ $0.ledgerTag = 7 }) { Task.detached { Self.tag() } }
        }
        #expect(await task.value == nil)
    }

    @Test func workOnAnotherQueueDoesNot() async {
        let seen: UInt64? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                withAmbient({ $0.ledgerTag = 7 }) {
                    DispatchQueue.global().async { continuation.resume(returning: Self.tag()) }
                }
            }
        }
        #expect(seen == nil)
    }

    @Test func anAsyncBindingInsideASynchronousOneWinsAndTheOuterIsRestored() async {
        let task = await Self.outsideAnyTask {
            withAmbient({ $0.ledgerTag = 1 }) {
                Task {
                    let inner = await withAmbient({ $0.ledgerTag = 2 }) { Self.tag() }
                    return [inner, Self.tag()]
                }
            }
        }
        #expect(await task.value == [2, 1])
    }

    @Test func aSynchronousBindingInsideAnAsyncOneWinsAndTheOuterIsRestored() async {
        let seen = await withAmbient({ $0.ledgerTag = 1 }) {
            let inner = withAmbient({ $0.ledgerTag = 2 }) { Self.tag() }
            return [inner, Self.tag()]
        }
        #expect(seen == [2, 1])
        #expect(Self.tag() == nil)
    }

    @Test func aSynchronousBindingKeepsTheRestOfTheContext() async {
        let clock = TestClock().erased
        let kept = await withAmbient({ $0.clock = clock }) {
            withAmbient({ $0.ledgerTag = 7 }) { Ambient.current.clock.isSameClock(as: clock) }
        }
        #expect(kept)
    }

    @Test func aSynchronousOperationsTypedErrorPassesThroughUnchanged() {
        do throws(Typed) {
            try withAmbient({ _ in }) { () throws(Typed) in throw Typed.boom }
            Issue.record("the operation's error was swallowed")
        } catch {
            #expect(error == .boom)
        }
        #expect(Self.tag() == nil)
    }
}

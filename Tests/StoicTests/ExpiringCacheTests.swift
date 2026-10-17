@testable import Stoic
import StoicTesting
import Synchronization
import Testing

@Suite("ExpiringCache")
struct ExpiringCacheTests {
    enum Boom: Error, Equatable { case boom }

    typealias Cache = ExpiringCache<String, String, any Error>

    /// A loader that counts its calls and can be told to hold or to fail.
    final class Loader: Sendable {
        private struct State {
            var calls: [String: Int] = [:]
            var failing = false
            var gate: TestGate?
            var cancelled = 0
        }

        private let state = Mutex(State())

        func calls(_ key: String) -> Int { state.withLock { $0.calls[key] ?? 0 } }
        var cancelled: Int { state.withLock { $0.cancelled } }
        func fail(_ failing: Bool) { state.withLock { $0.failing = failing } }

        /// Holds every load from now on until the returned gate opens.
        func hold() -> TestGate {
            let gate = TestGate()
            state.withLock { $0.gate = gate }
            return gate
        }

        func load(_ key: String) async throws -> String {
            let (number, gate) = state.withLock { state -> (Int, TestGate?) in
                state.calls[key, default: 0] += 1
                return (state.calls[key]!, state.gate)
            }
            await gate?.wait()
            if Task.isCancelled {
                state.withLock { $0.cancelled += 1 }
                throw CancellationError()
            }
            if state.withLock({ $0.failing }) { throw Boom.boom }
            return "\(key)\(number)"
        }
    }

    func cache(
        _ loader: Loader, _ clock: TestClock, scope: borrowing TaskScope,
        ttl: Duration = .seconds(10), stale: Duration = .seconds(5), max: Int = 10, negative: Duration? = nil
    ) -> Cache {
        Cache.make(in: scope, ttl: ttl, staleWindow: stale, maxEntries: max, negativeTTL: negative, label: "profiles",
                   clock: clock.erased) { key in try await loader.load(key) }
    }

    /// Waits until no refresh is running.
    func idle(_ cache: Cache) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await cache.refreshCount > 0 {
            if clock.now >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    /// What `cache.value(for:)` came to, as a string: the value, or why not.
    func get(_ cache: Cache, _ key: String) async -> String {
        do throws(PolicyError<any Error>) {
            return try await cache.value(for: key)
        } catch {
            switch error {
            case .rejected(let rejection): return "rejected:\(rejection.reason)"
            case .failed(let failure): return "failed:\(failure)"
            }
        }
    }

    @Test(.stoic(seed: 51), .timeLimit(.minutes(1)), .failureMode("design/20", "a fresh entry is read"))
    func aFreshEntryIsServedWithoutTheLoader() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope)
            #expect(await get(cache, "a") == "a1")
            await clock.advance(by: .milliseconds(9999))
            #expect(await get(cache, "a") == "a1")
            #expect(loader.calls("a") == 1)
        }
    }

    @Test(.stoic(seed: 52), .timeLimit(.minutes(1)), .failureMode("design/20", "a stale entry is read"))
    func aStaleEntryIsServedAtOnceAndRefreshedOnce() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope)
            #expect(await get(cache, "a") == "a1")
            await clock.advance(by: .seconds(12))
            let gate = loader.hold()   // the refresh will not finish yet
            for _ in 0..<5 { #expect(await get(cache, "a") == "a1") }
            #expect(await eventually { loader.calls("a") == 2 })
            #expect(loader.calls("a") == 2)
            gate.open()
            #expect(await idle(cache))
            #expect(await get(cache, "a") == "a2")   // refreshed, and fresh again
            #expect(loader.calls("a") == 2)
        }
    }

    @Test(.stoic(seed: 53), .timeLimit(.minutes(1)), .failureMode("design/20", "callers miss the same key together"))
    func callersThatMissTogetherShareOneLoad() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope)
            let gate = loader.hold()
            let callers = (0..<5).map { _ in Task { await get(cache, "a") } }
            #expect(await eventually { cache.waiterCount(for: "a") == 5 })
            gate.open()
            for caller in callers { #expect(await caller.value == "a1") }
            #expect(loader.calls("a") == 1)
        }
    }

    @Test(.stoic(seed: 54), .timeLimit(.minutes(1)), .failureMode("design/20", "a background refresh fails"))
    func aFailedRefreshKeepsTheStaleValue() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope)
            #expect(await get(cache, "a") == "a1")
            await clock.advance(by: .seconds(12))
            loader.fail(true)
            #expect(await get(cache, "a") == "a1")
            #expect(await eventually { StoicTest.events.events(named: "cache.refresh_failed").count == 1 })
            let event = try #require(StoicTest.events.events(named: "cache.refresh_failed").first)
            #expect(event.label == "profiles")
            // The value is still served, and the next read tries again.
            #expect(await idle(cache))
            #expect(await get(cache, "a") == "a1")
            #expect(await eventually { loader.calls("a") == 3 })
            loader.fail(false)
            #expect(await idle(cache))
            #expect(await get(cache, "a") == "a1")
            #expect(await eventually { loader.calls("a") == 4 })
            #expect(await idle(cache))
            #expect(await get(cache, "a") == "a4")
        }
    }

    @Test(.stoic(seed: 55), .timeLimit(.minutes(1)), .failureMode("design/20", "a load with no value to fall back on fails"))
    func aColdFailureReachesEveryWaiterAndIsNotCached() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope)
            loader.fail(true)
            let gate = loader.hold()
            let callers = (0..<3).map { _ in Task { await get(cache, "a") } }
            #expect(await eventually { cache.waiterCount(for: "a") == 3 })
            gate.open()
            for caller in callers { #expect(await caller.value == "failed:boom") }
            #expect(loader.calls("a") == 1)
            #expect(await cache.count == 0)
            loader.fail(false)
            #expect(await get(cache, "a") == "a2")
        }
    }

    @Test(.stoic(seed: 56), .timeLimit(.minutes(1)), .failureMode("design/20", "`negativeTTL` is set and a load fails"))
    func aNegativeTTLRemembersAFailure() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope, negative: .seconds(5))
            loader.fail(true)
            #expect(await get(cache, "a") == "failed:boom")
            await clock.advance(by: .seconds(2))
            #expect(await get(cache, "a") == "failed:boom")
            #expect(loader.calls("a") == 1)
            loader.fail(false)
            await clock.advance(by: .seconds(4))   // 6s: forgotten
            #expect(await get(cache, "a") == "a2")
        }
    }

    @Test(.stoic(seed: 57), .timeLimit(.minutes(1)), .failureMode("design/20", "one of several callers waiting on a load is cancelled"))
    func cancellingOneWaiterDoesNotCancelTheSharedLoad() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope)
            let gate = loader.hold()
            let first = Task { await get(cache, "a") }
            let second = Task { await get(cache, "a") }
            #expect(await eventually { cache.waiterCount(for: "a") == 2 })
            first.cancel()
            #expect(await first.value == "rejected:cancelled")
            gate.open()
            #expect(await second.value == "a1")
            #expect(loader.cancelled == 0)
            #expect(await get(cache, "a") == "a1")   // cached for the next caller
            #expect(loader.calls("a") == 1)
        }
    }

    @Test(.stoic(seed: 58), .timeLimit(.minutes(1)), .failureMode("design/20", "every caller waiting on a load is cancelled"))
    func cancellingEveryWaiterCancelsTheLoadAndCachesNothing() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope, negative: .seconds(60))
            let gate = loader.hold()
            let callers = (0..<2).map { _ in Task { await get(cache, "a") } }
            #expect(await eventually { cache.waiterCount(for: "a") == 2 })
            for caller in callers { caller.cancel() }
            for caller in callers { #expect(await caller.value == "rejected:cancelled") }
            gate.open()
            #expect(await eventually { loader.cancelled == 1 })
            #expect(await cache.count == 0)   // not even as a remembered failure
            #expect(await get(cache, "a") == "a2")
        }
    }

    @Test(.stoic(seed: 59), .timeLimit(.minutes(1)), .failureMode("design/20", "an entry is added past `maxEntries`"))
    func theLeastRecentlyUsedEntryIsEvicted() async throws {
        let clock = TestClock()
        let loader = Loader()
        try await withTaskScope { scope in
            let cache = cache(loader, clock, scope: scope, max: 2)
            _ = await get(cache, "a")
            _ = await get(cache, "b")
            _ = await get(cache, "a")   // a is now the more recent
            _ = await get(cache, "c")   // evicts b
            #expect(await cache.count == 2)
            #expect(await get(cache, "a") == "a1")
            #expect(await get(cache, "c") == "c1")
            #expect(loader.calls("b") == 1)
            #expect(await get(cache, "b") == "b2")   // reloaded
            // Hammering a small cache never grows it.
            for round in 0..<500 { _ = await get(cache, "k\(round % 7)") }
            #expect(await cache.count == 2)
        }
    }

    @Test(.stoic(seed: 60), .timeLimit(.minutes(1)), .failureMode("design/20", "the scope ends while a refresh runs"))
    func endingTheScopeCancelsARunningRefresh() async throws {
        let clock = TestClock()
        let loader = Loader()
        let gate = try await withTaskScope { scope -> TestGate in
            let cache = cache(loader, clock, scope: scope)
            #expect(await get(cache, "a") == "a1")
            await clock.advance(by: .seconds(12))
            let held = loader.hold()
            #expect(await get(cache, "a") == "a1")
            #expect(await eventually { loader.calls("a") == 2 })
            return held
        }
        // The scope returned although the refresh was stuck: it was cancelled
        // and awaited, and the load it shared was cancelled with it.
        gate.open()
        #expect(await eventually { loader.cancelled == 1 })
        #expect(StoicTest.events.events(named: "cache.refresh_failed").isEmpty)
    }

    @Test(.stoic(seed: 70), .timeLimit(.minutes(1)), .failureMode("design/20", "a stale entry is read after the cache's scope ended"))
    func aCacheThatOutlivesItsScopeStopsRefreshingQuietly() async throws {
        let clock = TestClock()
        let loader = Loader()
        let cache = try await withTaskScope { scope -> Cache in
            let cache = cache(loader, clock, scope: scope)
            for key in ["a", "b", "c"] { _ = await get(cache, key) }
            return cache
        }
        await clock.advance(by: .seconds(12))   // every entry is stale
        for _ in 0..<3 {
            for key in ["a", "b", "c"] { #expect(await get(cache, key) == "\(key)1") }
        }
        #expect(await cache.refreshCount == 0, "previously each stale key stayed marked as refreshing for good")
        #expect(loader.calls("a") == 1)
        #expect(StoicTest.events.events(named: "scope.fork_after_exit").isEmpty, "previously an error per stale key")
    }

    /// A loader whose first load ignores cancellation and returns "old" once
    /// its gate opens; every later load returns "new" at once.
    final class StubbornLoader: Sendable {
        private let state = Mutex((calls: 0, finished: 0))
        let gate = TestGate()
        var calls: Int { state.withLock { $0.calls } }
        var finished: Int { state.withLock { $0.finished } }

        func load(_ key: String) async -> String {
            let number = state.withLock { state -> Int in
                state.calls += 1
                return state.calls
            }
            if number == 1 { await gate.wait() }
            state.withLock { $0.finished += 1 }
            return number == 1 ? "old" : "new"
        }
    }

    @Test(.stoic(seed: 69), .timeLimit(.minutes(1)), .failureMode("design/20", "a load every caller left finishes anyway"))
    func anAbandonedLoadThatFinishesLateIsNotCached() async throws {
        let clock = TestClock()
        let loader = StubbornLoader()
        try await withTaskScope { scope in
            let cache = Cache.make(in: scope, ttl: .seconds(10), maxEntries: 10, label: "profiles", clock: clock.erased) { key in
                await loader.load(key)
            }
            let first = Task { await get(cache, "a") }
            #expect(await eventually { loader.calls == 1 })
            first.cancel()
            #expect(await first.value == "rejected:cancelled")   // every caller left: the load is abandoned
            #expect(await get(cache, "a") == "new")              // a newer load, cached
            loader.gate.open()                                   // the abandoned load returns anyway
            #expect(await eventually { loader.finished == 2 })
            #expect(await holdsThroughout { cache.waiterCount(for: "a") == 0 })
            #expect(await get(cache, "a") == "new", "previously the abandoned load's late result overwrote the newer one")
            #expect(loader.calls == 2)
        }
    }
}

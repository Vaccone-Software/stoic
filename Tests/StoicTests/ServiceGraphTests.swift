@testable import Stoic
import StoicTesting
import Testing

@Suite("ServiceGraph")
struct ServiceGraphTests {
    struct Database: Sendable { let name: String }
    struct Sync: Sendable { let database: Database }
    struct Failed: Error {}

    static let database = ServiceKey<Database>("database")
    static let cache = ServiceKey<Database>("cache")
    static let sync = ServiceKey<Sync>("sync")

    @Test func servicesStartInDependencyOrderAndStopInReverse() async throws {
        let log = OrderLog()
        let graph = try ServiceGraph(label: "app") {
            Provide(Self.sync, needs: [Self.database.any]) { services in
                log.append("start sync")
                return Sync(database: services[Self.database])
            } stop: { _, _ in log.append("stop sync") }
            Provide(Self.database) { _ in
                log.append("start database")
                return Database(name: "main")
            } stop: { _, _ in log.append("stop database") }
        }
        #expect(graph.startOrder.map(\.name) == ["database", "sync"])
        let name = try await graph.run { services in
            log.append("body")
            return services[Self.sync].database.name
        }
        #expect(name == "main")
        #expect(log.values == ["start database", "start sync", "body", "stop sync", "stop database"])
    }

    @Test func twoServicesOfTheSameTypeCoexist() async throws {
        let graph = try ServiceGraph(label: "app") {
            Provide(Self.database) { _ in Database(name: "main") }
            Provide(Self.cache) { _ in Database(name: "cache") }
        }
        try await graph.run { services in
            #expect(services[Self.database].name == "main")
            #expect(services[Self.cache].name == "cache")
        }
    }

    @Test func independentServicesStartConcurrently() async throws {
        let gauge = SendableBox((current: 0, peak: 0))
        let a = ServiceKey<Int>("a"), b = ServiceKey<Int>("b"), c = ServiceKey<Int>("c")
        func slow(_ value: Int) -> @Sendable (Services) async throws -> Int {
            { _ in
                gauge.mutate { $0.current += 1; $0.peak = max($0.peak, $0.current) }
                try await Task.sleep(for: .milliseconds(20))
                gauge.mutate { $0.current -= 1 }
                return value
            }
        }
        let graph = try ServiceGraph(label: "app") {
            Provide(a, start: slow(1))
            Provide(b, start: slow(2))
            Provide(c, start: slow(3))
        }
        try await graph.run { _ in }
        #expect(gauge.value.peak == 3)
    }

    @Test(.failureMode("design/08", "services need each other"), .failureMode("design/08", "a service needs one that is absent"), .failureMode("design/08", "two services share a key")) func validationCatchesDuplicatesMissingDependenciesAndCycles() {
        #expect(throws: ServiceGraphError.self) {
            try ServiceGraph(label: "dup") {
                Provide(Self.database) { _ in Database(name: "a") }
                Provide(Self.database) { _ in Database(name: "b") }
            }
        }
        do {
            _ = try ServiceGraph(label: "missing") {
                Provide(Self.sync, needs: [Self.database.any]) { services in Sync(database: services[Self.database]) }
            }
            Issue.record("expected a missing-dependency error")
        } catch {
            #expect("\(error)" == "service sync needs database, which is not in the graph")
        }
        let x = ServiceKey<Int>("x"), y = ServiceKey<Int>("y"), z = ServiceKey<Int>("z")
        do {
            _ = try ServiceGraph(label: "cycle") {
                Provide(x, needs: [y.any]) { _ in 1 }
                Provide(y, needs: [z.any]) { _ in 2 }
                Provide(z, needs: [x.any]) { _ in 3 }
            }
            Issue.record("expected a cycle error")
        } catch {
            #expect("\(error)" == "services depend on each other in a cycle: x → y → z → x")
        }
    }

    @Test(.failureMode("design/08", "a start throws or times out")) func aFailedStartStopsWhatAlreadyStarted() async {
        let log = OrderLog()
        let graph = try! ServiceGraph(label: "app") {
            Provide(Self.database) { _ in Database(name: "main") } stop: { _, _ in log.append("stop database") }
            Provide(Self.sync, needs: [Self.database.any]) { _ -> Sync in throw Failed() }
        }
        do {
            try await graph.run { _ in log.append("body must not run") }
            Issue.record("expected a start failure")
        } catch let error as ServiceGraphError {
            guard case .startFailed(let service, let underlying) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(service.name == "sync")
            #expect(underlying is Failed)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(log.values == ["stop database"])
    }

    @Test func aStartThatHangsTimesOut() async {
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                let graph = try ServiceGraph(label: "app") {
                    Provide(Self.database, startTimeout: .seconds(5)) { _ in
                        try await Ambient.sleep(for: .seconds(3600))
                        return Database(name: "never")
                    }
                }
                try await graph.run { _ in }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(5))
        await #expect(throws: ServiceGraphError.self) { try await task.value }
    }

    @Test(.failureMode("design/08", "the body throws")) func servicesStopEvenWhenTheBodyFails() async {
        let log = OrderLog()
        let graph = try! ServiceGraph(label: "app") {
            Provide(Self.database) { _ in Database(name: "main") } stop: { _, exit in log.append("stop \(exit.isFailure)") }
        }
        await #expect(throws: Failed.self) {
            try await graph.run { _ in throw Failed() }
        }
        #expect(log.values == ["stop true"])
    }

    @Test(.failureMode("design/08", "a stop hangs")) func aStopThatHangsIsAbandonedAfterItsTimeoutAndTheRestStillStop() async throws {
        let clock = TestClock()
        let log = OrderLog()
        let run = Task {
            try await withTestAmbient(clock: clock) {
                let graph = try ServiceGraph(label: "app") {
                    Provide(Self.database) { _ in Database(name: "main") } stop: { _, _ in log.append("stop database") }
                    Provide(Self.sync, needs: [Self.database.any], stopTimeout: .seconds(5)) { services in
                        Sync(database: services[Self.database])
                    } stop: { _, _ in
                        try? await Ambient.sleep(for: .seconds(3600))
                    }
                }
                try await graph.run { _ in }
            }
        }
        await clock.waitForSleepers(count: 2)   // the hung stop and its timeout
        await clock.advance(by: .seconds(5))
        try await run.value
        #expect(log.values == ["stop database"])
    }
}

@Suite("ServiceGraph: review fixes")
struct ServiceGraphReviewTests {
    struct Boom: Error {}
    static let slow = ServiceKey<Int>("slow")
    static let failing = ServiceKey<Int>("failing")

    @Test func aServiceThatFinishesStartingAfterASiblingFailsIsStillStopped() async {
        let log = OrderLog()
        let graph = try! ServiceGraph(label: "app") {
            Provide(Self.slow) { _ in
                await TestGate.opened(after: .milliseconds(30))   // ignores cancellation
                log.append("slow started")
                return 1
            } stop: { _, _ in log.append("slow stopped") }
            Provide(Self.failing) { _ -> Int in throw Boom() }
        }
        await #expect(throws: ServiceGraphError.self) { try await graph.run { _ in } }
        #expect(log.values == ["slow started", "slow stopped"], "previously: started and never stopped")
    }

    @Test func cancellingTheCallerIsReportedAsCancellation() async {
        let starting = AsyncGate()
        let graph = try! ServiceGraph(label: "app") {
            Provide(Self.slow) { _ in
                starting.open()
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        let task = Task { try await graph.run { _ in } }
        await starting.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aStartTimeoutIsADeadlineRejection() async {
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                let graph = try ServiceGraph(label: "app") {
                    Provide(Self.slow, startTimeout: .seconds(5)) { _ in
                        try await Ambient.sleep(for: .seconds(60))
                        return 1
                    }
                }
                try await graph.run { _ in }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(5))
        do {
            try await task.value
            Issue.record("expected a start failure")
        } catch let ServiceGraphError.startFailed(service, underlying) {
            #expect(service.name == "slow")
            #expect((underlying as? Rejection)?.reason == .deadlineExceeded)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

extension TestGate {
    /// Waits `duration` of real time, ignoring cancellation.
    static func opened(after duration: Duration) async {
        let gate = TestGate()
        Task { try? await Task.sleep(for: duration); gate.open() }
        await gate.wait()
    }
}

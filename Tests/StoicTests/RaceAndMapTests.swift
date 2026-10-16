@testable import Stoic
import StoicTesting
import Testing

@Suite("Race and bounded map")
struct RaceAndMapTests {
    enum Failure: Error, Equatable { case boom(Int) }

    @Test func raceReturnsTheFirstSuccessAndCancelsTheRest() async throws {
        let loserCause = SendableBox<CancellationCause?>(nil)
        let value = try await race(
            { () async throws(Failure) -> String in
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    loserCause.mutate { $0 = CancellationCause.current }
                }
                return "slow"
            },
            { () async throws(Failure) -> String in "fast" }
        )
        #expect(value == "fast")
        #expect(loserCause.value == .superseded, "the loser is cancelled and awaited before race returns")
    }

    @Test(.timeLimit(.minutes(1)), .failureMode("design/03", "a racer ignores cancellation after another won"))
    func aRacerThatIgnoresCancellationIsWaitedFor() async {
        let gate = AsyncGate()
        let returned = SendableBox(false)
        let loserCancelled = SendableBox(false)
        let task = Task {
            let value = try? await race(
                { () async throws(Failure) -> String in
                    // Cannot be cancelled, but can see that it was.
                    await withTaskCancellationHandler {
                        await gate.wait()
                    } onCancel: {
                        loserCancelled.mutate { $0 = true }
                    }
                    return "slow"
                },
                { () async throws(Failure) -> String in "fast" }
            )
            returned.mutate { $0 = true }
            return value
        }
        await waitUntil { loserCancelled.value }   // the race has a winner and has cancelled the loser
        #expect(await holdsThroughout { !returned.value })   // but the loser still runs, so race has not returned
        gate.open()
        #expect(await task.value == "fast")
    }

    @Test func raceSkipsFailuresWhileAnotherCanStillWin() async throws {
        let value = try await race(
            { () async throws(Failure) -> Int in throw .boom(1) },
            { () async throws(Failure) -> Int in
                try? await Task.sleep(for: .milliseconds(10))
                return 2
            }
        )
        #expect(value == 2)
    }

    @Test(.failureMode("design/03", "every racer fails")) func raceThrowsTheFirstFailureWhenAllFail() async {
        let events = RecordingInstrumentation()
        await #expect(throws: Failure.boom(1)) {
            try await withAmbient({ $0.instrumentation = events }) {
                try await race(
                    { () async throws(Failure) -> Int in throw .boom(1) },
                    { () async throws(Failure) -> Int in
                        try? await Task.sleep(for: .milliseconds(20))
                        throw .boom(2)
                    }
                )
            }
        }
        #expect(events.names.contains("race.all_failed"))
    }

    @Test(.stoic(seed: 71), .timeLimit(.minutes(1)), .failureMode("design/03", "the caller of a race is cancelled"))
    func aCancelledCallersRaceIsNotReportedAsFailed() async {
        let started = SendableBox(0)
        let racing = Task { () -> (any Error)? in
            do {
                _ = try await race(
                    { () async throws -> Int in started.mutate { $0 += 1 }; try await Task.sleep(for: .seconds(60)); return 1 },
                    { () async throws -> Int in started.mutate { $0 += 1 }; try await Task.sleep(for: .seconds(60)); return 2 }
                )
                return nil
            } catch {
                return error
            }
        }
        await waitUntil { started.value == 2 }
        racing.cancel()
        #expect(await racing.value is CancellationError)
        #expect(StoicTest.events.events(named: "race.all_failed").isEmpty, "previously a notice that every racer failed")
    }

    @Test func raceReportsEveryFailureInTheEvent() async throws {
        let events = RecordingInstrumentation()
        let racers = (0..<3).map { index in
            Racer<Int, Failure> { () throws(Failure) -> Int in throw .boom(index) }
        }
        var thrown: (any Error)?
        do {
            _ = try await withAmbient({ $0.instrumentation = events }) { try await race(racers) }
        } catch { thrown = error }
        let event = try #require(events.events.first { $0.name == "race.all_failed" })
        guard case .int(3)? = event["failures"] else { Issue.record("failures: \(String(describing: event["failures"]))"); return }
        // Completion order is the scheduler's; `first` is the one thrown.
        let reported = ["first", "also_1", "also_2"].compactMap { event[$0]?.description }
        #expect(reported.count == 3)
        for index in 0..<3 { #expect(reported.contains { $0.hasSuffix("boom(\(index))") }) }
        #expect(reported.first.map { first in thrown.map { first.hasSuffix(String(describing: $0)) } ?? false } == true)
    }

    @Test func raceAcceptsAnArrayOfRacers() async throws {
        let racers = (0..<5).map { index in
            Racer<Int, Failure> { () throws(Failure) -> Int in
                if index < 4 { throw .boom(index) }
                return index
            }
        }
        #expect(try await race(racers) == 4)
    }

    @Test func mapConcurrentKeepsOrderAndRespectsTheLimit() async throws {
        let gauge = SendableBox((current: 0, peak: 0))
        let results = try await mapConcurrent(Array(0..<40), limit: 4) { (value: Int) async throws(Failure) -> Int in
            gauge.mutate { $0.current += 1; $0.peak = max($0.peak, $0.current) }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 0...3)))
            gauge.mutate { $0.current -= 1 }
            return value * 2
        }
        #expect(results == (0..<40).map { $0 * 2 })
        #expect(gauge.value.peak <= 4)
        #expect(gauge.value.peak >= 2)
    }

    /// What `body` came to. A `Task` closure with a typed throw crashes the
    /// Swift 6.4 compiler (IRGen), so tasks return this instead.
    func captured<R, E: Error>(_ body: () async throws(E) -> R) async -> Result<R, E> {
        do throws(E) {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    @Test(.stoic(seed: 72)) func mapConcurrentStopsAtTheFirstFailure() async {
        let started = SendableBox(0)
        let cancelledCause = SendableBox<CancellationCause?>(nil)
        let error = await #expect(throws: PolicyError<Failure>.self) {
            try await mapConcurrent(Array(0..<100), limit: 2, label: "thumbnails") { (value: Int) async throws(Failure) -> Int in
                started.mutate { $0 += 1 }
                if value == 3 { throw .boom(3) }
                do { try await Task.sleep(for: .milliseconds(value == 2 ? 200 : 1)) } catch {
                    cancelledCause.mutate { $0 = CancellationCause.current }
                }
                return value
            }
        }
        #expect(error?.failure == .boom(3))
        #expect(started.value < 100, "elements after the failure never start")
        #expect(cancelledCause.value == .siblingFailed)
        let event = StoicTest.events.events(named: "map.failed").first
        #expect(event?.label == "thumbnails")
        #expect(event?["first"]?.description.hasSuffix("boom(3)") == true)
        #expect(event?["also_1"] == nil, "a sibling cancelled by the failure is not a failure")
    }

    @Test(.stoic(seed: 73), .timeLimit(.minutes(1)), .failureMode("design/03", "`mapConcurrent` siblings fail while the first failure winds them down"))
    func failuresSeenWhileWindingDownAreReported() async {
        let entered = SendableBox(0)
        let ready = TestGate()
        let error = await #expect(throws: PolicyError<Failure>.self) {
            try await mapConcurrent(Array(0..<3), limit: 3) { (value: Int) async throws(Failure) -> Int in
                if entered.mutate({ $0 += 1; return $0 }) == 3 { ready.open() }
                await ready.wait()
                if value == 0 { throw .boom(0) }
                // Fails of its own accord while being cancelled, not because of it.
                await waitUntil { Task.isCancelled }
                throw .boom(value)
            }
        }
        #expect(error?.failure == .boom(0))
        let event = StoicTest.events.events(named: "map.failed").first
        guard case .int(3)? = event?["failures"] else { Issue.record("failures: \(String(describing: event?["failures"]))"); return }
        let others = ["also_1", "also_2"].compactMap { event?[$0]?.description }
        #expect(others.count == 2, "previously dropped without a word")
        #expect(others.contains { $0.hasSuffix("boom(1)") } && others.contains { $0.hasSuffix("boom(2)") })
    }

    @Test func mapConcurrentResultsReportsEveryOutcome() async throws {
        let results = try await mapConcurrentResults(Array(0..<10), limit: 3) { (value: Int) async throws(Failure) -> Int in
            if value.isMultiple(of: 3) { throw .boom(value) }
            return value
        }
        #expect(results.count == 10)
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let value): #expect(value == index && !index.isMultiple(of: 3))
            case .failure(let failure): #expect(failure == .boom(index))
            }
        }
    }

    @Test func aCancelledCallerStartsNothingAndIsRejectedCancelled() async {
        let started = SendableBox(0)
        let cancelled = AsyncGate()
        let task = Task {
            await captured { () async throws(PolicyError<any Error>) -> [Int] in
                await cancelled.wait()
                return try await mapConcurrent(Array(0..<1000), limit: 4) { (value: Int) async throws -> Int in
                    started.mutate { $0 += 1 }
                    return value
                }
            }
        }
        task.cancel()
        cancelled.open()
        let error = await task.value.error
        #expect(started.value == 0)
        #expect(error?.rejection?.reason == .cancelled)
    }

    @Test func aCallerCancelledMidwayStopsStartingElements() async {
        let started = SendableBox(0)
        let entered = AsyncGate()
        let release = AsyncGate()
        let task = Task {
            await captured { () async throws(PolicyError<any Error>) -> [Int] in
                try await mapConcurrent(Array(0..<1000), limit: 4) { (value: Int) async throws -> Int in
                    if started.mutate({ $0 += 1; return $0 }) == 4 { entered.open() }
                    await release.wait()
                    return value
                }
            }
        }
        await entered.wait()
        task.cancel()
        release.open()
        let error = await task.value.error
        #expect(started.value == 4, "only the elements running when the caller was cancelled ever start")
        #expect(error?.rejection?.reason == .cancelled)
    }

    /// A typed failure cannot hold a `CancellationError`; the caller's
    /// cancellation is spelled `.rejected(.cancelled)` all the same, never
    /// as an array shorter than the input.
    @Test(.stoic(seed: 74), .timeLimit(.minutes(1)), .failureMode("design/03", "`mapConcurrent` with a typed failure is cancelled midway"))
    func aTypedFailureIsRejectedCancelledNeverGivenAShortArray() async {
        let started = SendableBox(0)
        let entered = AsyncGate()
        let release = AsyncGate()
        let task = Task {
            await captured { () async throws(PolicyError<Never>) -> [Int] in
                try await mapConcurrent(Array(0..<100), limit: 3) { (value: Int) async throws(Never) -> Int in
                    if started.mutate({ $0 += 1; return $0 }) == 3 { entered.open() }
                    await release.wait()
                    return value
                }
            }
        }
        await entered.wait()
        task.cancel()
        release.open()
        let error = await task.value.error
        #expect(error?.rejection?.reason == .cancelled, "previously returned [0, 1, 2]")
    }

    @Test(.stoic(seed: 75), .timeLimit(.minutes(1)))
    func aMapCancelledByItsDeadlineIsRejectedDeadlineExceeded() async {
        let clock = TestClock()
        let started = SendableBox(0)
        let outcome: Result<[Int], PolicyError<Never>> = await withTestAmbient(clock: clock) {
            await withTaskGroup { group in
                group.addTask {
                    await withTimeout(.seconds(1)) { () async -> Result<[Int], PolicyError<Never>> in
                        do throws(PolicyError<Never>) {
                            return .success(try await mapConcurrent(Array(0..<10), limit: 2) { (value: Int) async throws(Never) -> Int in
                                started.mutate { $0 += 1 }
                                try? await Ambient.sleep(for: .seconds(60))
                                return value
                            })
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                await clock.waitForSleepers(count: 3)   // the deadline's timer and two elements
                await clock.advance(by: .seconds(1))
                return await group.next()!
            }
        }
        guard case .failure(let error) = outcome else { Issue.record("expected a rejection, got \(outcome)"); return }
        #expect(error.rejection?.reason == .deadlineExceeded)
        #expect(started.value == 2)
    }

    @Test func aCallerCancelledOnceEveryElementStartedGetsEveryResult() async throws {
        let started = SendableBox(0)
        let entered = AsyncGate()
        let release = AsyncGate()
        let task = Task {
            await captured { () async throws(PolicyError<Never>) -> [Int] in
                try await mapConcurrent(Array(0..<5), limit: 5) { (value: Int) async throws(Never) -> Int in
                    if started.mutate({ $0 += 1; return $0 }) == 5 { entered.open() }
                    await release.wait()   // finishes despite the cancellation
                    return value
                }
            }
        }
        await entered.wait()
        task.cancel()   // too late to stop anything
        release.open()
        #expect(try await task.value.get() == [0, 1, 2, 3, 4])
    }

    @Test func mapConcurrentResultsAlsoStopsForACancelledCaller() async {
        let started = SendableBox(0)
        let entered = AsyncGate()
        let release = AsyncGate()
        let task = Task {
            await captured { () async throws(Rejection) -> [Result<Int, Failure>] in
                try await mapConcurrentResults(Array(0..<100), limit: 3) { (value: Int) async throws(Failure) -> Int in
                    if started.mutate({ $0 += 1; return $0 }) == 3 { entered.open() }
                    await release.wait()
                    return value
                }
            }
        }
        await entered.wait()
        task.cancel()
        release.open()
        let error = await task.value.error
        #expect(error?.reason == .cancelled, "previously returned the three outcomes that started")
        #expect(started.value == 3)
    }

    @Test func mapConcurrentHandlesEmptyInput() async throws {
        let results = try await mapConcurrent([Int](), limit: 3) { (value: Int) async throws(Failure) -> Int in value }
        #expect(results.isEmpty)
    }
}

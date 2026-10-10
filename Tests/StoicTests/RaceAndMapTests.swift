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

    @Test func raceThrowsTheFirstFailureWhenAllFail() async {
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

    @Test func mapConcurrentStopsAtTheFirstFailure() async {
        let started = SendableBox(0)
        let cancelledCause = SendableBox<CancellationCause?>(nil)
        await #expect(throws: Failure.boom(3)) {
            try await mapConcurrent(Array(0..<100), limit: 2) { (value: Int) async throws(Failure) -> Int in
                started.mutate { $0 += 1 }
                if value == 3 { throw .boom(3) }
                do { try await Task.sleep(for: .milliseconds(value == 2 ? 200 : 1)) } catch {
                    cancelledCause.mutate { $0 = CancellationCause.current }
                }
                return value
            }
        }
        #expect(started.value < 100, "elements after the failure never start")
        #expect(cancelledCause.value == .siblingFailed)
    }

    @Test func mapConcurrentResultsReportsEveryOutcome() async {
        let results = await mapConcurrentResults(Array(0..<10), limit: 3) { (value: Int) async throws(Failure) -> Int in
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

    @Test func mapConcurrentHandlesEmptyInput() async throws {
        let results = try await mapConcurrent([Int](), limit: 3) { (value: Int) async throws(Failure) -> Int in value }
        #expect(results.isEmpty)
    }
}


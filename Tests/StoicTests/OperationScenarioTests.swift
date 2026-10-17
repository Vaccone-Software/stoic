@testable import Stoic
import StoicTesting
import Synchronization
import Testing

// The ideal scenario of design/22, on virtual time: a podcast app whose
// catalogue is remote and whose payments go through a remote API that
// deduplicates by key. Declarations hold facts; none of the numbers the
// scenario names (two attempts, ten seconds, six patient attempts) is at a
// call site.
extension Backend {
    static let podcastCatalogue = Backend.remote("podcast.catalogue")
    static let podcastPayments = Backend.remote("podcast.payments")
}

enum PodcastCatalogue {
    static let episode = Backend.podcastCatalogue.readOnly("episode")
}

enum PodcastPayments {
    static let subscribe = Backend.podcastPayments.keyed("subscribe")
}

@Suite("Operations: the ideal scenario")
struct OperationScenarioTests {
    @Test func aTapGetsTwoQuickAttemptsAndABackgroundRefreshSixPatientOnes() async throws {
        let run = try await simulated { context in
            let tap = Script([.fail(Transient())])
            let refresh = Script([.fail(Transient())])
            let tapped = await withUrgency(.interactive) { await performing(PodcastCatalogue.episode, tap) }
            let tapElapsed = context.clock.now.offset
            let refreshed = await withUrgency(.background) { await performing(PodcastCatalogue.episode, refresh) }
            return (tapped, tap.count, tapElapsed, refreshed, refresh.count, context.clock.now.offset - tapElapsed)
        }
        let (tapped, tapAttempts, tapElapsed, refreshed, refreshAttempts, refreshElapsed) = run.value
        #expect(tapped.error?.stopName == "failed")
        #expect(tapAttempts == 2)
        #expect(tapElapsed < .seconds(10))
        #expect(refreshed.error?.stopName == "failed")
        #expect(refreshAttempts == 6)
        #expect(refreshElapsed < .seconds(10 * 60))
    }

    @Test func anOpenBreakerFailsATapAtOnceAndABackgroundRefreshWaitsItOut() async throws {
        let run = try await simulated { context in
            for _ in 0..<10 {
                _ = await withUrgency(.interactive) { await performing(PodcastCatalogue.episode, Script([.fail(Transient())])) }
            }
            let opened = context.clock.now.offset
            let tap = await withUrgency(.interactive) { await performing(PodcastCatalogue.episode, Script([.succeed])) }
            let tapElapsed = context.clock.now.offset - opened
            let refresh = await withUrgency(.background) { await performing(PodcastCatalogue.episode, Script([.succeed])) }
            return (tap, tapElapsed, refresh, context.clock.now.offset - opened)
        }
        let (tap, tapElapsed, refresh, refreshElapsed) = run.value
        #expect(tap.error?.stopName == "circuit_open")
        #expect(tapElapsed == .zero)
        #expect(refresh.success == 1)
        #expect(refreshElapsed > .zero)
    }

    @Test func aPaymentIsRetriedUnderOneKeyAndAnUnknownOutcomeSaysSo() async throws {
        let checkout = IdempotencyKey(rawValue: "checkout-1")
        let run = try await simulated { _ in
            let sent = Mutex<[IdempotencyKey?]>([])
            func subscribe(_ steps: [Step]) async -> (receipt: Int?, outcome: OperationError<Transient>.Outcome?) {
                let script = Script(steps)
                do throws(OperationError<Transient>) {
                    let receipt = try await withUrgency(.interactive) { () throws(OperationError<Transient>) in
                        try await PodcastPayments.subscribe.perform(idempotencyKey: checkout) { attempt throws(Transient) in
                            sent.withLock { $0.append(attempt.idempotencyKey) }
                            do { return try await script.call(attempt) } catch { throw Transient() }
                        }
                    }
                    return (receipt, nil)
                } catch let error where error.outcome == .unknown {
                    // It may have been charged: reconcile under the key, never re-ask.
                    return (nil, .unknown)
                } catch {
                    return (nil, error.outcome)
                }
            }
            let recovered = await subscribe([.fail(Transient()), .succeed])
            let afterRecovered = sent.withLock { $0 }
            let lost = await subscribe([.fail(Transient())])
            return (recovered, afterRecovered, lost, sent.withLock { $0 })
        }
        let (recovered, afterRecovered, lost, allSent) = run.value
        #expect(recovered.receipt == 2)
        #expect(afterRecovered == [checkout, checkout])
        #expect(lost.receipt == nil)
        #expect(lost.outcome == .unknown)
        #expect(allSent.count == afterRecovered.count + 2)
        #expect(allSent.allSatisfy { $0 == checkout })
    }
}

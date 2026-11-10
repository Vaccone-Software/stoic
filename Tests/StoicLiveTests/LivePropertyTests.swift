import Foundation
import Stoic
@testable import StoicLive
import StoicTesting
import Synchronization
import Testing

/// How much to multiply the property tests by: `STOIC_TEST_SCALE=20` hunts harder.
let testScale: Int = ProcessInfo.processInfo.environment["STOIC_TEST_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1

/// SplitMix64.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Loads a test opens one by one, in any order: each waits for its own gate
/// (ignoring cancellation, so a superseded load can finish late), then answers
/// with its tag, or fails.
final class GatedLoads: Sendable {
    private struct State {
        var gates: [TestGate] = []
        var failing: Set<Int> = []
        var tags: [Int] = []
        var inFlight = 0
        var mostInFlight = 0
    }

    private let state = Mutex(State())

    var started: Int { state.withLock { $0.gates.count } }
    var mostInFlight: Int { state.withLock { $0.mostInFlight } }

    /// Opens load `index` (an earlier or a later one): it answers.
    func open(_ index: Int) {
        state.withLock { $0.gates.indices.contains(index) ? $0.gates[index] : nil }?.open()
    }

    func load(tag: Int, fails: Bool) async throws -> Int {
        let (gate, index) = state.withLock { state -> (TestGate, Int) in
            let gate = TestGate()
            state.gates.append(gate)
            state.tags.append(tag)
            if fails { state.failing.insert(state.gates.count - 1) }
            state.inFlight += 1
            state.mostInFlight = max(state.mostInFlight, state.inFlight)
            return (gate, state.gates.count - 1)
        }
        await gate.wait()
        let failing = state.withLock { state -> Bool in
            state.inFlight -= 1
            return state.failing.contains(index)
        }
        if failing { throw Refused() }
        return tag
    }
}

@Suite("Live and Action properties")
@MainActor
struct LivePropertyTests {
    /// Over random reads, loads that succeed, fail or hang, refreshes,
    /// invalidations and clock advances: the phase never returns to pending
    /// after a value, a value is delivered only from the newest load, and
    /// `loadedAt` is nil exactly when the phase holds no value.
    @Test func phasesNeverGoBackAndOnlyTheNewestLoadDelivers() async throws {
        for seed in 0..<UInt64(60 * testScale) {
            try await onLiveTime { clock, _ in
                var random = SeededGenerator(state: seed)
                let loads = GatedLoads()
                let tags = SendableCounter()
                let failures = Mutex<[Bool]>((0..<200).map { _ in Bool.random(using: &random) && Bool.random(using: &random) })
                let live = Live(API.detail, freshFor: .seconds(30)) { _ in
                    let tag = tags.next()
                    return try await loads.load(tag: tag, fails: failures.withLock { $0[tag % 200] })
                }
                var everHeld = false
                var highest = -1
                for _ in 0..<40 {
                    switch Int.random(in: 0..<7, using: &random) {
                    case 0, 1: _ = live.phase
                    case 2: live.refresh()
                    case 3: live.invalidate()
                    case 4: await clock.advance(by: .seconds(Int.random(in: 1..<40, using: &random)))
                    default:
                        if loads.started > 0 { loads.open(Int.random(in: 0..<loads.started, using: &random)) }
                    }
                    for _ in 0..<Int.random(in: 0..<4, using: &random) { await Task.yield() }
                    let phase = live.current
                    if let value = phase.value {
                        everHeld = true
                        try #require(value >= highest, "seed \(seed): an older load (\(value)) replaced a newer one (\(highest))")
                        highest = value
                    }
                    try #require(!(everHeld && phase.isPending), "seed \(seed): pending again after a value")
                    try #require((live.loadedAt == nil) == (phase.value == nil), "seed \(seed): loadedAt and the value disagree")
                }
                for index in 0..<loads.started { loads.open(index) }
            }
        }
    }

    /// Over random interleavings of their inputs' phases: a combination's
    /// snapshot is never recomputed while an input is refreshing, and after a
    /// joint invalidation no snapshot mixes a new input with an old one.
    @Test func aCombinationNeverMixesRoundsAndNeverRecomputesMidRefresh() async throws {
        for seed in 0..<UInt64(60 * testScale) {
            try await onLiveTime { _, _ in
                var random = SeededGenerator(state: seed &+ 1_000)
                let round = Mutex(0)
                let leftLoads = GatedLoads()
                let rightLoads = GatedLoads()
                let fails = Mutex<[Bool]>((0..<400).map { _ in Int.random(in: 0..<8, using: &random) == 0 })
                let calls = SendableCounter()
                let a = Live(API.roster, label: "a") { _ in
                    try await leftLoads.load(tag: round.withLock { $0 }, fails: fails.withLock { $0[calls.next() % 400] })
                }
                let b = Live(API.minors, label: "b") { _ in
                    try await rightLoads.load(tag: round.withLock { $0 }, fails: fails.withLock { $0[calls.next() % 400] })
                }
                let violation = Mutex<String?>(nil)
                let snapshots = SendableCounter()
                let pair = Live<[Int]>.combining(a, b) { x, y in
                    // The rules call this only from values that belong together.
                    // A combination computes on the main actor, synchronously.
                    let refreshing = MainActor.assumeIsolated { a.current.isRefreshing || b.current.isRefreshing }
                    if snapshots.next() > 0, refreshing {
                        violation.withLock { $0 = $0 ?? "recomputed while an input was refreshing" }
                    }
                    return [x, y]
                }
                for _ in 0..<50 {
                    switch Int.random(in: 0..<5, using: &random) {
                    case 0, 1:
                        _ = pair.phase
                    case 2:
                        round.withLock { $0 += 1 }
                        pair.invalidate()   // a joint invalidation, as an action's refreshes make
                    default:
                        let loads = Bool.random(using: &random) ? leftLoads : rightLoads
                        if loads.started > 0 { loads.open(Int.random(in: 0..<loads.started, using: &random)) }
                    }
                    for _ in 0..<Int.random(in: 0..<4, using: &random) { await Task.yield() }
                    if let message = violation.withLock({ $0 }) { Issue.record("seed \(seed): \(message)"); return }
                    if let snapshot = pair.current.value {
                        try #require(snapshot[0] == snapshot[1], "seed \(seed): a snapshot of rounds \(snapshot) mixes new and old")
                    }
                }
                for index in 0..<leftLoads.started { leftLoads.open(index) }
                for index in 0..<rightLoads.started { rightLoads.open(index) }
            }
        }
    }

    /// A join's rows equal a dictionary join of its inputs, in left order.
    @Test func aJoinIsADictionaryJoinInLeftOrder() async throws {
        struct Left: Sendable { let key: Int; let tag: Int }
        struct Right: Sendable { let key: Int; let tag: Int }
        struct Pair: Sendable, Equatable { let left: Int; let right: Int? }
        for seed in 0..<UInt64(200 * testScale) {
            try await onLiveTime { _, _ in
                var random = SeededGenerator(state: seed &+ 7)
                let lefts = (0..<Int.random(in: 0..<15, using: &random)).map { Left(key: Int.random(in: 0..<10, using: &random), tag: $0) }
                let rights = (0..<Int.random(in: 0..<15, using: &random)).map { Right(key: Int.random(in: 0..<10, using: &random), tag: $0) }
                let left = Live(API.roster) { _ in lefts }
                let right = Live(API.minors) { _ in rights }
                let joined = Live<[Pair]>.joining(left, right, on: \.key, \.key) { Pair(left: $0.tag, right: $1?.tag) }
                await until { joined.phase.value != nil }
                var first: [Int: Int] = [:]
                for element in rights where first[element.key] == nil { first[element.key] = element.tag }
                #expect(joined.phase.value == lefts.map { Pair(left: $0.tag, right: first[$0.key]) }, "seed \(seed)")
            }
        }
    }

    /// Over random taps, joins, outcomes and resets: at most one run is in
    /// flight; the keys sent are the intents the rules define; every failure
    /// is either read or reported unseen.
    @Test func runsAreSingleKeysFollowIntentsAndFailuresAreSurfaced() async throws {
        enum Outcome: CaseIterable { case success, unknown, notExecuted, executed }
        for seed in 0..<UInt64(80 * testScale) {
            try await onLiveTime { _, events in
                var random = SeededGenerator(state: seed &+ 99)
                let plan = Mutex((0..<300).map { _ in Outcome.allCases.randomElement(using: &random) ?? .success })
                let calls = SendableCounter()
                let flight = Mutex((now: 0, most: 0))
                let keys = Mutex<[IdempotencyKey]>([])
                var action: Action<String, Int>? = Action(API.signUp, whileRunning: .join) { _, attempt in
                    keys.withLock { $0.append(attempt.idempotencyKey) }
                    flight.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
                    defer { flight.withLock { $0.now -= 1 } }
                    await Task.yield()
                    switch plan.withLock({ $0[calls.next() % 300] }) {
                    case .success: return 1
                    case .unknown: throw Lost()
                    case .notExecuted: throw Unreached()
                    case .executed: throw Refused()
                    }
                }
                // The model: the previous run's key, and what the rules say the next is.
                var previous: (key: IdempotencyKey, input: String)?
                var lastEnd: Action<String, Int>.Phase = .idle
                var lastOutcome: String?
                var seenFailures = 0
                var counted: Set<SupportReference> = []
                func noteSeen(_ phase: Action<String, Int>.Phase) {
                    if case .failed(let presented) = phase, counted.insert(presented.reference).inserted { seenFailures += 1 }
                }
                for _ in 0..<30 {
                    guard let current = action else { break }
                    switch Int.random(in: 0..<6, using: &random) {
                    case 0, 1, 2:
                        let input = Bool.random(using: &random) ? "a" : "b"
                        let mark = keys.withLock { $0.count }
                        let trigger = current.trigger(input)
                        guard trigger == .started else { continue }
                        await current.waitForEnd()
                        let sent = keys.withLock { Array($0[mark...]) }
                        let priorEnd = lastEnd
                        let priorOutcome = lastOutcome
                        lastEnd = current.current
                        lastOutcome = events.events(named: "action.failed").last?["outcome"]?.description
                        if case .succeeded = lastEnd { lastOutcome = nil }
                        // A run refused before any attempt (the breaker opened
                        // under many lost calls) sent no key: its intent's key
                        // is not known to the model.
                        guard !sent.isEmpty else {
                            previous = nil
                            continue
                        }
                        try #require(Set(sent).count == 1, "seed \(seed): one key across a run's attempts")
                        if let previous {
                            let continues: Bool = if case .failed = priorEnd {
                                priorOutcome != "executed" && previous.input == input
                            } else {
                                false
                            }
                            try #require((sent[0] == previous.key) == continues, "seed \(seed): the key does not follow the intent")
                        }
                        previous = (sent[0], input)
                    case 3:
                        let wasRunning = current.current.isRunning
                        current.reset()
                        if !wasRunning {
                            previous = nil
                            lastEnd = .idle
                            lastOutcome = nil
                        }
                    case 4:
                        noteSeen(current.phase)
                    default:
                        if Int.random(in: 0..<10, using: &random) == 0 { action = nil }
                    }
                }
                action = nil
                await Task.yield()
                try #require(flight.withLock { $0.most } <= 1, "seed \(seed): two runs in flight")
                let failures = events.count("action.failed")
                let unseen = events.count("action.failure_unseen")
                try #require(failures == seenFailures + unseen, "seed \(seed): \(failures) failures, \(seenFailures) read, \(unseen) reported unseen")
            }
        }
    }
}

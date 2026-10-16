@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// Properties of `perform` over random nestings and random scripts
/// (design/22, Testing).
@Suite("Operation properties")
struct OperationPropertyTests {
    /// A small deterministic generator, one per case.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: One layer retries

    /// One layer around the backend call.
    enum Layer: Sendable, CustomStringConvertible {
        case perform(Backend.Operation)
        case retry(Int)
        case retrying(Int)

        var description: String {
            switch self {
            case .perform(let operation): "perform(\(operation.backend.kind), \(operation.safety))"
            case .retry(let attempts): "retry(\(attempts))"
            case .retrying(let attempts): "Retrying(\(attempts))"
            }
        }
    }

    static let kinds: [Backend] = [
        .remote("property.remote"), .system("property.system"), .local("property.local"), .compute("property.compute"),
    ]

    /// Runs `layers` outermost first around `call`, counting each layer's
    /// attempts, and throws whatever the outermost throws.
    static func run(
        _ layers: ArraySlice<Layer>, attempts: SendableBox<[Int]>, depth: Int = 0,
        _ call: @escaping @Sendable (Attempt) async throws -> Void
    ) async throws {
        guard let layer = layers.first else {
            return
        }
        let rest = layers.dropFirst()
        func body(_ attempt: Attempt) async throws {
            attempts.mutate { $0[depth] += 1 }
            if rest.isEmpty {
                try await call(attempt)
            } else {
                try await run(rest, attempts: attempts, depth: depth + 1, call)
            }
        }
        switch layer {
        case .perform(let operation):
            try await operation.perform { attempt throws(any Error) in try await body(attempt) }
        case .retry(let count):
            try await retry(.fixed(.milliseconds(100)).attempts(count), budget: .unlimited) { attempt throws(any Error) in
                try await body(attempt)
            }
        case .retrying(let count):
            let stage = Retrying(.fixed(.milliseconds(100)).attempts(count), budget: .unlimited)
            do throws(PolicyError<any Error>) {
                try await stage.execute { () throws(any Error) in
                    try await body(Attempt(number: 0, elapsed: .zero, operation: OperationIdentity(fileID: #fileID, line: #line)))
                }
            } catch {
                throw error
            }
        }
    }

    @Test func randomNestingsCallTheBackendNoMoreThanTheInnermostDeclaredScheduleAllows() async throws {
        var generator = Generator(state: 22)
        for trial in 0..<(60 * testScale) {
            let depth = Int.random(in: 1...4, using: &generator)
            var layers: [Layer] = (0..<depth).map { _ in
                switch Int.random(in: 0..<3, using: &generator) {
                case 0:
                    let backend = Self.kinds.randomElement(using: &generator)!
                    let name = "op\(Int.random(in: 0..<1000, using: &generator))"
                    return .perform([backend.readOnly(name), backend.idempotent(name), backend.notRepeatable(name)]
                        .randomElement(using: &generator)!)
                case 1: return .retry(Int.random(in: 1...4, using: &generator))
                default: return .retrying(Int.random(in: 1...4, using: &generator))
                }
            }
            // At least one declared operation, and each on its own backend:
            // the property is about undeclared layers deferring to it.
            if !layers.contains(where: { if case .perform = $0 { true } else { false } }) {
                layers[Int.random(in: 0..<depth, using: &generator)] = .perform(Self.kinds[trial % 4].readOnly("forced"))
            }
            var seen: Set<String> = []
            layers = layers.map { layer in
                guard case .perform(let operation) = layer else { return layer }
                if seen.insert(operation.backend.name).inserted { return layer }
                return .retry(2)
            }
            let urgency = Urgency.allByRank.randomElement(using: &generator)!
            let innermost = layers.lastIndex { if case .perform = $0 { true } else { false } }!
            guard case .perform(let declared) = layers[innermost] else { continue }
            let allowed = declared.safety == .notRepeatable ? 1 : declared.policy(at: urgency).schedule.maximumAttempts

            let calls = SendableBox(0)
            let attempts = SendableBox([Int](repeating: 0, count: layers.count))
            let frozen = layers
            _ = try await simulated(seed: UInt64(trial)) { _ in
                await withUrgency(urgency) {
                    try? await Self.run(frozen[...], attempts: attempts) { _ in
                        calls.mutate { $0 += 1 }
                        throw Transient()
                    }
                }
            }
            let description = "trial \(trial): \(frozen) at \(urgency)"
            #expect(calls.value <= allowed, "\(description): \(calls.value) calls")
            // A settled attempt is never repeated: every layer outside the
            // innermost declaration made one attempt.
            #expect(attempts.value[..<innermost].allSatisfy { $0 == 1 }, "\(description): \(attempts.value)")
        }
    }

    // MARK: Outcome

    /// What one attempt of the scripted operation does.
    enum Act: CaseIterable, Sendable {
        case succeed, permanent, transient, offline, slow, hang
    }

    @Test func unknownIsReportedExactlyWhenAnAttemptThatReachedTheBackendWasCutOffOrTransient() async throws {
        var generator = Generator(state: 7)
        let backend = Backend.remote("property.outcome")
        let operations = [backend.keyed("charge"), backend.readOnly("fetch"), backend.notRepeatable("send"), backend.idempotent("put")]
        var seen: [String: Int] = [:]
        for trial in 0..<(150 * testScale) {
            let operation = operations.randomElement(using: &generator)!
            let urgency = Urgency.allByRank.randomElement(using: &generator)!
            let acts = (0..<6).map { _ in Act.allCases.randomElement(using: &generator)! }
            let cancelAt: Duration? = Bool.random(using: &generator)
                ? .milliseconds(Int.random(in: 0..<20_000, using: &generator)) : nil

            /// Per attempt: what it did, and whether it ran to the end.
            let log = SendableBox<[(act: Act, completed: Bool)]>([])
            let run = try await simulated(seed: UInt64(trial)) { _ in
                await withUrgency(urgency) {
                    await withTaskGroup(of: Result<Int, OperationError<any Error>>?.self) { group in
                        group.addTask {
                            await performing(operation, Script([.succeed]), key: IdempotencyKey(rawValue: "k\(trial)"), acts: acts, log: log)
                        }
                        if let cancelAt {
                            group.addTask {
                                try? await Ambient.sleep(for: cancelAt)
                                return nil
                            }
                        }
                        var result: Result<Int, OperationError<any Error>>?
                        while let next = await group.next() {
                            if let next { result = next } else { group.cancelAll() }
                            if result != nil { group.cancelAll() }
                        }
                        return result!
                    }
                }
            }
            let description = "trial \(trial): \(operation.safety) at \(urgency), \(acts), cancel at \(cancelAt.map(\.description) ?? "never"): \(log.value)"
            guard case .failure(let error) = run.value else {
                #expect(log.value.last?.act == .succeed || log.value.last?.act == .slow, "\(description)")
                seen["success", default: 0] += 1
                continue
            }
            seen["\(error.outcome)", default: 0] += 1
            // The oracle: the last attempt that reached the backend.
            let expected: OperationError<any Error>.Outcome
            if let reached = log.value.last(where: { $0.act != .offline || !$0.completed }) {
                expected = reached.act == .permanent && reached.completed ? .executed : .unknown
            } else {
                expected = .notExecuted
            }
            #expect(error.outcome == expected, "\(description): \(error)")
            if error.outcome == .unknown, operation.safety == .keyed || operation.safety == .notRepeatable {
                #expect(!error.isCancellation, "\(description)")
            }
        }
        // The scripts reached every outcome, or the property proved little.
        #expect(Set(seen.keys) == ["success", "notExecuted", "executed", "unknown"], "\(seen)")
    }
}

/// `performing`, with each attempt doing what `acts` says, and logged.
func performing(
    _ operation: Backend.Operation, _ unused: Script, key: IdempotencyKey?,
    acts: [OperationPropertyTests.Act], log: SendableBox<[(act: OperationPropertyTests.Act, completed: Bool)]>
) async -> Result<Int, OperationError<any Error>> {
    do throws(OperationError<any Error>) {
        return .success(try await operation.perform(idempotencyKey: operation.safety == .keyed ? key : nil) { attempt throws(any Error) -> Int in
            let act = acts[min(attempt.number - 1, acts.count - 1)]
            let index = log.mutate { log -> Int in
                log.append((act, false))
                return log.count - 1
            }
            func done() { log.mutate { $0[index].completed = true } }
            switch act {
            case .succeed:
                done()
                return attempt.number
            case .permanent:
                done()
                throw Permanent()
            case .transient:
                done()
                throw Transient()
            case .offline:
                done()
                throw Offline()
            case .slow:
                try await Ambient.sleep(for: .seconds(1))
                done()
                return attempt.number
            case .hang:
                try await Ambient.sleep(for: .seconds(1_000_000))
                done()
                return attempt.number
            }
        })
    } catch {
        return .failure(error)
    }
}

import Foundation
import Stoic
import StoicFoundation
import StoicTesting
import Testing

/// Foundation's bridged errors reach an `any Error` as their `NSError` on
/// Apple platforms (a real URLSession failure is an `NSURLError`), where a
/// cast to `Retryable` fails. These suites classify them only through an
/// `any Error`, the way a retry, a breaker and `perform` see them.
@Suite("Bridged platform errors")
struct BridgedErrorTests {
    /// How many attempts `classifier` makes at an operation that always
    /// throws `error`, which the operation holds only as an `any Error`.
    static func attempts(_ classifier: RetryClassifier<any Error>, failingWith error: any Error) async -> Int {
        let attempts = SendableCounter()
        await #expect(throws: (any Error).self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited, classify: classifier) { _ throws(any Error) -> Int in
                    attempts.increment()
                    throw error
                }
            }
        }
        return attempts.value
    }

    /// The attempts a `.notRepeatable` operation makes at a call that always
    /// throws `error` untyped, and what it then knows of the backend's side.
    static func send(failingWith error: any Error & Sendable) async throws -> (attempts: Int, outcome: OperationError<any Error>.Outcome) {
        let operation = Backend.remote("bridged.\(UUID().uuidString)").notRepeatable("send")
        let run = try await simulate(seed: 1, faults: .none, schedule: .uniform) { _ in
            await withUrgency(.utility) {
                do throws(OperationError<any Error>) {
                    _ = try await operation.perform { _ throws(any Error) -> Int in throw error }
                    return (attempts: 0, outcome: OperationError<any Error>.Outcome.executed)
                } catch {
                    return (attempts: error.attempts, outcome: error.outcome)
                }
            }
        }
        return run.value
    }

    @Test func standardStopsOnARefusedCertificateHeldAsAnyError() async {
        let refused: any Error = URLError(.serverCertificateUntrusted)
        #expect(await Self.attempts(.standard, failingWith: refused) == 1)
        let untyped: any Error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        #expect(await Self.attempts(.standard, failingWith: untyped) == 1)
    }

    @Test func transientOnlyRetriesATimeoutHeldAsAnyError() async {
        let timedOut: any Error = URLError(.timedOut)
        #expect(await Self.attempts(.transientOnly, failingWith: timedOut) == 3)
        let untyped: any Error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(await Self.attempts(.transientOnly, failingWith: untyped) == 3)
    }

    @Test func posixAndCocoaErrorsHeldAsAnyErrorClassifyAsTheirStructsDo() async {
        let reset: any Error = POSIXError(.ECONNRESET)
        #expect(await Self.attempts(.transientOnly, failingWith: reset) == 3)
        let missing: any Error = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.Code.ENOENT.rawValue))
        #expect(await Self.attempts(.standard, failingWith: missing) == 1)
        let locked: any Error = CocoaError(.fileLocking)
        #expect(await Self.attempts(.transientOnly, failingWith: locked) == 3)
        let unreadable: any Error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
        #expect(await Self.attempts(.standard, failingWith: unreadable) == 1)
    }

    @Test func anNSErrorInAnotherDomainClassifiesAsAnUnknownErrorDoes() async throws {
        let unknown: any Error = NSError(domain: "com.example.backend", code: NSURLErrorServerCertificateUntrusted)
        #expect(await Self.attempts(.standard, failingWith: unknown) == 3, "retried: nothing says it is permanent")
        #expect(await Self.attempts(.transientOnly, failingWith: unknown) == 1, "not retried: nothing says it is transient")
        // The code is a URLError's, the domain is not: it is not one.
        let lookalike = NSError(domain: "com.example.backend", code: NSURLErrorCannotFindHost)
        let sent = try await Self.send(failingWith: lookalike)
        #expect(sent.attempts == 1)
        #expect(sent.outcome == .unknown)
    }

    @Test(.failureMode("design/22", "an `NSError` in `NSURLErrorDomain` fails a `.notRepeatable` attempt"))
    func aNotRepeatableAttemptThatFailedToFindItsHostIsRepeated() async throws {
        let cannotFindHost = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let run = try await Self.send(failingWith: cannotFindHost)
        #expect(run.attempts == 4, "the utility schedule's attempts: nothing was sent, so each was repeated")
        #expect(run.outcome == .notExecuted)
        let refused = try await Self.send(failingWith: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.Code.ECONNREFUSED.rawValue)))
        #expect(refused.attempts == 4)
        #expect(refused.outcome == .notExecuted)
    }

    @Test func aNotRepeatableAttemptThatTimedOutIsNotRepeated() async throws {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let run = try await Self.send(failingWith: timedOut)
        #expect(run.attempts == 1, "the request may have been sent")
        #expect(run.outcome == .unknown)
    }
}

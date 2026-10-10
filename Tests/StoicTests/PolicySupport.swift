import Stoic
import Testing

/// Records a test failure from inside an operation that must not run. Returns
/// `Void`, so it can be the whole body of a closure.
func unexpected(_ message: String = "this operation must not run") {
    Issue.record(Comment(rawValue: message))
}

/// Runs `operation` under `policy` and returns what happened: its value, or
/// the `PolicyError` the policy threw.
///
/// (Closures that throw are inferred to throw `any Error`, so a closure that
/// throws a typed error must say so: `{ () throws(MyError) in … }`.)
func outcome<P: Policy, R, F: Error>(
    of policy: P,
    _ operation: nonisolated(nonsending) () async throws(F) -> R
) async -> Result<R, PolicyError<F>> {
    do throws(PolicyError<F>) {
        return .success(try await policy.execute(operation))
    } catch {
        return .failure(error)
    }
}

/// The rejection `policy` refused `operation` with, or `nil` if it ran.
func rejection<P: Policy, R, F: Error>(
    from policy: P,
    _ operation: nonisolated(nonsending) () async throws(F) -> R
) async -> Rejection? {
    switch await outcome(of: policy, operation) {
    case .success: nil
    case .failure(let error): error.rejection
    }
}

/// Yields until `condition` holds. The condition must become true without
/// further help from the caller; a bound turns a hang into a failure.
func waitUntil(_ message: @autoclosure () -> String = "the condition never became true", _ condition: () -> Bool) async {
    var spins = 0
    while !condition() {
        spins += 1
        if spins > 2_000_000 {
            Issue.record(Comment(rawValue: message()))
            return
        }
        await Task.yield()
    }
}

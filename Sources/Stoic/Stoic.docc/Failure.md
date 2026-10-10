# Failure

Know what failed, and retry on purpose.

@Metadata {
    @PageImage(purpose: card, source: "plate-failure", alt: "A mezzotint of Sisyphus carrying his boulder, set in an arched niche, printed as two-colour static.")
    @PageColor(green)
}

## What it does

@Row {
    @Column(size: 3) {
        An error says what to do about it. A ``Retryable`` error decides for itself. A
        ``Defect`` is a bug and is never retried. Any other error is retried until its
        schedule ends.

        A retry runs on a bounded ``Schedule``, with jitter, a budget that caps the extra
        load, and the caller's deadline in view. Errors that pass through `withContext`
        gain a trail of what the code was doing, and the original error stays intact in
        a ``Report``.
    }
    @Column {
        ![A mezzotint of Sisyphus carrying his boulder, set in an arched niche, printed as two-colour static.](plate-failure)
    }
}

## Use it when

- A call can fail in ways that another attempt would fix, such as a dropped connection.
- Some failures are permanent, such as bad input or a bug, and must not be retried.
- A struggling dependency must not be hit harder by every caller's retries.

## Example

```swift
extension SyncError: Retryable {
    var retryDecision: RetryDecision { self == .offline ? .retry : .stop }
}

let user = try await retry(.exponential(base: .milliseconds(200)).attempts(5)) { _ in
    try await withContext("fetching user \(id)") { try await api.fetchUser(id) }
}
```

## What happens if…

| …                                                  | Stoic                                                      |
| -------------------------------------------------- | ---------------------------------------------------------- |
| every attempt fails                                | The last error is rethrown, unwrapped                      |
| the error is a `Defect`                            | It is rethrown at once and never retried                   |
| the retry budget is empty                          | The last error is rethrown                                 |
| the next attempt cannot finish before the deadline | The last error is rethrown without sleeping                |
| a retry runs inside another retry's attempt        | One attempt only, unless `nesting: .allow`                 |
| the schedule is unbounded                          | It does not compile: `retry` takes only a bounded schedule |

The full contracts, with every case, are `design/02-schedules-and-retry.md`,
`design/05-errors.md` and `design/10-resilience-policies.md` in the repository.

## The API

- ``Schedule``
- ``BoundedSchedule``
- ``Retryable``
- ``RetryClassifier``
- ``RetryBudget``
- ``Defect``
- ``Report``
- ``PolicyError``
- ``Rejection``
- ``Pipeline``
- ``CircuitBreaker``
- ``Idempotency``

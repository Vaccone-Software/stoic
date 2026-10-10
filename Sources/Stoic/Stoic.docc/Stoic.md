# ``Stoic``

Robustness primitives for Swift apps.

## Overview

Stoic gives an app the guarantees that make long-lived, asynchronous software
dependable — resources are always released, failures are classified, retries
are policy rather than loops, every wait has an end, work never outlives what
started it, and every decision is observable — as plain `async` functions,
structs and actors over Swift's own concurrency.

Every primitive reads its clock, randomness, instrumentation, retry budgets and
device conditions from ``Ambient``, so a test replaces them once and the whole
program beneath runs on virtual time with a fixed seed.

## Topics

### Time

- ``withTimeout(_:clock:tolerance:label:fileID:line:operation:)``
- ``withDeadline(_:tolerance:label:fileID:line:operation:)``
- ``Deadline``
- ``abandoningAfter(_:label:limit:clock:qos:fileID:line:operation:)``
- ``AbandonedWork``
- ``CancellationCause``
- ``ExpiringWork``

### Retry

- ``Schedule``
- ``BoundedSchedule``
- ``Jitter``
- ``Retryable``
- ``RetryDecision``
- ``RetryClassifier``
- ``RetryBudget``
- ``RetryBudgets``
- ``RetryNesting``
- ``Attempt``
- ``RecurDecision``
- ``RecurOutcome``

### Structured concurrency

- ``TaskSlot``
- ``Racer``
- ``AsyncSemaphore``
- ``AsyncMutex``
- ``SingleFlight``
- ``Channel``

### Scopes and resources

- ``Scope``
- ``TaskScope``
- ``Resource``
- ``Saga``
- ``Exit``

### Resilience policies

- ``Policy``
- ``Pipeline``
- ``Retrying``
- ``CircuitBreaker``
- ``RateLimiter``
- ``Bulkhead``
- ``Idempotency``

### Errors

- ``Report``
- ``Defect``
- ``PolicyError``
- ``Rejection``
- ``ConcurrentFailure``

### State machines

- ``StateMachine``
- ``Transition``
- ``StateTimeout``
- ``StateGraph``

### Supervision and services

- ``Supervisor``
- ``Child``
- ``RestartPolicy``
- ``HeartbeatPolicy``
- ``Heartbeat``
- ``SupervisorEscalation``
- ``SupervisorEvent``
- ``ServiceGraph``
- ``ServiceKey``
- ``Provide``
- ``Services``
- ``ServiceGraphError``

### Context, conditions and observability

- ``Ambient``
- ``AnyClock``
- ``RandomSource``
- ``SystemConditions``
- ``SystemConditionsSource``
- ``FixedConditions``
- ``Event``
- ``EventName``
- ``EventCatalog``
- ``Instrumentation``
- ``OSLogInstrumentation``
- ``CompositeInstrumentation``
- ``NoInstrumentation``

### Diagnostics

- ``Diagnostics``
- ``EventRing``
- ``TaskLedger``

### Values

- ``Secret``
- ``IdempotencyKey``

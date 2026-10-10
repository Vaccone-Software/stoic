# 19 · HTTP

Most failures an app shows its user start on the network, and the
hand-written client is where every earlier contract gets broken at once: a
retry loop that retries a `POST` twice and charges the card twice; no
timeout, or one timeout for the whole call and none per attempt; `429`
retried at once instead of after `Retry-After`; every screen hammering a
server that is down; a 2 GB response read into memory; a decoding failure
reported as "The data couldn't be read because it isn't in the correct
format"; an `Authorization` header in a log. `StoicHTTP` is the client a
careful team would write, from the pieces Stoic already has.

## Origin

- **RFC 9110.** Safe and idempotent methods; `Retry-After` in both forms;
  which statuses mean "try again".
- **The IETF `Idempotency-Key` header draft, Stripe's practice.** An unsafe
  request becomes retryable when the server can recognise a repeat.
- **Polly, resilience4j, Envoy.** Per-upstream policies in a fixed order;
  retry budgets so retries cannot multiply an outage; outlier ejection.
- **Go's `http.Client`.** A transport behind an interface, so tests replace
  the network, not the client.

## API

```swift
let api = HTTPClient(base: URL(string: "https://api.example.com")!, policy: .standard)

let user: User = try await api.send(.get("/users/42"), decoding: User.schema)
try await api.send(.post("/orders", json: order.encoded), idempotencyKey: order.key)

// Tests: the network is a script, time is virtual.
let transport = ScriptedTransport()
transport.on(.get("/users/42"), respond: [.status(503), .status(503), .json(#"{"id": 42}"#)])
let api = HTTPClient(base: url, transport: transport)
```

## Semantics

**The policy, per host, in a fixed order** — overall deadline (the caller's
ambient deadline) → retry → circuit breaker → bulkhead → attempt timeout →
transport. `HTTPPolicy.standard`: 10 s per attempt; 3 attempts with
jittered exponential backoff from 200 ms, capped at 10 s, drawing on a
retry budget; a breaker that opens after half of at least 20 calls fail;
at most 8 requests in flight to one host. Every number is a field.

**Only what is safe to repeat is repeated.** `GET`, `HEAD`, `OPTIONS`,
`PUT` and `DELETE` are retried; `POST` and `PATCH` only with an
`idempotencyKey`, which is sent as the `Idempotency-Key` header with the
same value on every attempt. A request that fails after the server may
have acted on it (a timeout after sending, a dropped connection) is only
retried when it is idempotent.

**Statuses.** 2xx is success. 408, 429, 500, 502, 503 and 504 are retried,
after `Retry-After` when the server gives one (both the seconds and the
HTTP-date form), capped by the schedule's maximum and the caller's
deadline: a wait that would outlast the deadline is not started. Other 4xx
are the caller's fault and are not retried; other 5xx are not retried
either. Transport errors are classified by `URLError` code (design/05).
A breaker counts 5xx, timeouts and transport failures, never 4xx.

**Responses are bounded.** At most `maxResponseBytes` (10 MB by default)
are read; past that the request fails with `.responseTooLarge` and the
connection is cancelled. Decoding goes through a schema (design/06): a body
that does not match is `.decoding(ValidationFailure)` with every issue and
its path, and is never retried — asking again will not change the
server's mind.

**Coalescing.** Identical `GET`s in flight at once (same URL and the same
values of the headers that vary the response) share one request
(`SingleFlight`): ten views asking for the same avatar make one call.

**Errors are one typed value.** `HTTPError`: `.status(code, body
excerpt, retryAfter)`, `.transport(URLError.Code)`, `.timedOut(attempt:)`,
`.responseTooLarge`, `.decoding(ValidationFailure)`, `.rejected(Rejection)`
(breaker open, bulkhead full, budget exhausted, deadline). Each says
whether it was retried and how many attempts were made.

**Privacy.** Events carry the method, host, path and status; the query
string, request and response bodies are private; `Authorization`,
`Cookie`, `Set-Cookie` and `Proxy-Authorization` are never recorded.

**Testable.** `HTTPTransport` is a protocol. `URLSessionTransport` is the
real one; `ScriptedTransport` answers from a script (statuses, bodies,
delays on the ambient clock, transport errors, hangs) and records every
request, so every row below is a test on the virtual clock — and runs
inside a simulation.

## Failure modes

| What happens if…                              | Behaviour                                                                  |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| a `GET` gets 503 twice, then 200              | Two retries with backoff; the 200 is returned; `http.retry` ×2             |
| a `POST` without an idempotency key times out | Not retried: `.timedOut(attempt: 1)`                                       |
| a `POST` with a key gets 503                  | Retried with the same `Idempotency-Key`                                    |
| the server says 429 with `Retry-After: 30`    | Waits 30 s (capped), unless that outlasts the deadline: then fails at once |
| the server says 404                           | `.status(404)`; not retried; the breaker does not count it                 |
| the host keeps failing                        | The breaker opens; calls fail fast with `.rejected(circuit_open)`          |
| one attempt hangs                             | Cut at the attempt timeout; retried if idempotent                          |
| the caller's deadline passes mid-backoff      | No further attempt; `.rejected(deadline_exceeded)`                         |
| the response is 2 GB                          | `.responseTooLarge` after `maxResponseBytes`; connection cancelled         |
| the body does not match the schema            | `.decoding` with every issue; not retried                                  |
| ten identical `GET`s at once                  | One request; ten results                                                   |
| the caller is cancelled                       | The request is cancelled; `CancellationError`                              |

## Events

`http.request` (debug: method, host, path, status, duration, attempt),
`http.retry` (delay, reason), `http.failed`, `http.coalesced`,
`http.response_too_large`, `http.decoding_failed`; the breaker, bulkhead
and budget emit their own.

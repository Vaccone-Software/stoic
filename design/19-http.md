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
ambient deadline) → retry → circuit breaker → rate limit (if the policy has
one) → bulkhead → attempt timeout → transport. `HTTPPolicy.standard`: 10 s per attempt; 3 attempts with
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

**Retrying on what came back.** `HTTPPolicy.retryOnResponse` (or a call's own,
below) sees every response that arrived whole, whatever its status, and answers
with a `RetryDecision` or `nil` to leave it to the status list: `.retry` asks
again (after the response's `Retry-After` when it has one), `.retryAfter(d)`
after `d`, `.stop` makes the response final even if its status is on the list.
A `202` that says `Retry-After: 2` can be polled; a `200` whose body says
`"pending"` can be asked again; a `503` that says `Retry-After: 3600` can be
given up on. Every wait is capped by `maxRetryAfter` and bound by the deadline,
the schedule and the budget as for any retry; a request that is not safe to
repeat is never asked again (an unkeyed `POST` that was answered is answered).

**Per-call overrides.** `send(_:overrides:)` takes an `HTTPOverrides`: the
attempt timeout, the retry schedule, whether `GET`s coalesce, whether the
call passes the host's breaker, whether a `401` may run the reauthentication
hook, and a `retryOnResponse` of its own. Everything not named is the policy's;
the budget, bulkhead, rate limit and byte limits stay the client's, because
they protect the host.

**Reauthentication.** `HTTPClient(…, reauthenticate:)` takes a hook that
returns the headers to send from then on. When a request to the base URL's own
origin is answered `401`, the hook runs, the request is sent once more with the
renewed headers, and that answer is the answer. Concurrent requests refused for
the same credentials share one run of the hook; a request refused with
credentials that were renewed since it was prepared replays without running it.
A hook that throws is `.reauthenticationFailed`, and the request is not replayed.

**Rate limit.** `HTTPPolicy.rateLimit` is a token bucket for each host (a Stoic
`RateLimiter` on the ambient clock): every attempt, retries included, takes a
permit, waiting in order for one; a wait that would outlast the caller's
deadline, or a full queue, is `.rejected(rate_limited)` with the wait in
`retryAfter`.

**Responses are bounded.** At most `maxResponseBytes` (10 MB by default)
are read; past that the request fails with `.responseTooLarge` and the
connection is cancelled. Decoding goes through a schema (design/06): a body
that does not match is `.decoding(ValidationFailure)` with every issue and
its path, and is never retried — asking again will not change the
server's mind.

**Coalescing** (on by default; `coalesceGETs: false` turns it off).
Identical `GET`s in flight at once (same URL and the same name and value of
every request header) share one request (`SingleFlight`): ten views asking
for the same avatar make one call. The key covers every header, custom ones
such as `X-API-Key` included, so callers with different credentials never
share a response. A header that differs per call and changes nothing in the
answer (`X-Request-Id`, `traceparent`) would defeat sharing; list it in
`ignoreHeadersForCoalescing`.

**Errors are one typed value.** `HTTPError`: `.status(code, body
excerpt, retryAfter)`, `.transport(URLError.Code)`, `.timedOut(attempt:)`,
`.responseTooLarge`, `.decoding(ValidationFailure)`, `.rejected(Rejection)`
(breaker open, bulkhead full, rate limited, budget exhausted, deadline),
`.reauthenticationFailed(status:)`. Each says
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
| a response within the cap has one string over 1 MiB or an array over 100,000 elements | Decoded: the parser's string and container limits are raised to what `maxResponseBytes` can hold |
| a call asks for its own attempt timeout and retry schedule | That call uses them; the next call uses the policy's |
| a call opts out of the breaker while it is open | It is sent; what it sees is not counted against the host |
| a 2xx response says to ask again | Asked again after its `Retry-After` (capped) or the backoff, if the request is safe to repeat; out of attempts, `.status` for the last response |
| the server answers 401 and the client can reauthenticate | The hook runs once; the request is replayed with the renewed headers, which later requests use too |
| ten requests get 401 at once | One run of the hook; all ten are replayed |
| the reauthentication hook fails | `.reauthenticationFailed`; the request is not replayed; the next 401 runs the hook again |
| the replayed request gets 401 too | `.status(401)` after two attempts; the hook runs at most once per request |
| a host's rate limit is spent | The request waits its turn for a permit, in order; retries wait too |
| a request would wait longer than its deadline or the queue allows | `.rejected(rate_limited)` at once, with the wait in `retryAfter`; nothing is sent |
| a caller waiting for a rate-limit permit is cancelled | It leaves with `CancellationError`, takes no permit, and the next caller gets it |

## Events

`http.request` (debug: method, host, path, status, duration, attempt),
`http.retry` (delay, reason), `http.failed`, `http.coalesced`,
`http.response_too_large`, `http.decoding_failed`, `http.reauthenticated`,
`http.reauthenticate_failed` (the type of the hook's error, never its text);
the breaker, rate limiter, bulkhead and budget emit their own.

## As built

`StoicHTTP` depends on `Stoic`, `StoicFoundation` (the `URLError`
classification), `StoicSchema` and `StoicJSON`, and on no Apple framework:
it builds on Linux, over FoundationNetworking. HTTP's own semantics —
`HTTPRetry`, `HTTPStatusError` and the HTTP-date parser behind
`Retry-After` — live here, not in `StoicApple`. Everything above is built; this section records the
decisions the contract left open and the places the code differs from its
wording.

```swift
let api = HTTPClient(base: URL(string: "https://api.example.com")!, policy: .standard,
                     headers: ["Authorization": "Bearer …"])
let user = try await api.send(.get("/users/42"), decoding: User.schema)
try await api.send(.post("/orders", json: order.encoded), idempotencyKey: order.key)
```

**Types.** `HTTPRequest` (method, `.path` or `.url` target, query items,
headers, body bytes, optional `idempotencyKey`; builders `.get`, `.head`,
`.delete`, `.post(_:json:)`, `.put`, `.patch`, `.keyed(_:)`), `HTTPResponse`,
`HTTPMethod` (`isSafe`, `isIdempotent`), `HTTPHeaders` (case-insensitive;
credentials print as `<redacted>`), `HTTPTransport`, `URLSessionTransport`,
`ScriptedTransport`, `HTTPPolicy`, `HTTPClient`, `HTTPError`.

**The transport.** `send(_:maxResponseBytes:)` receives an absolute URL and
the final headers. The limit is passed *to* the transport because only the
transport can stop reading: `URLSessionTransport` collects the body from the
task's delegate callbacks, refuses a declared `Content-Length` over the limit
before the first byte, and cancels the task at the first byte over (counted
after decompression, so a compression bomb is stopped too). The client
checks the size again, for transports that do not. A redirect to another host
drops `Authorization`, `Cookie` and `Proxy-Authorization`.

**`ScriptedTransport` lives in `StoicHTTP`, not a `StoicHTTPTesting`
product,** as `SimulatedFileSystem` lives in `StoicStore`: it needs nothing
from `StoicTesting` (only the ambient clock), so an app's tests import one
module, and it costs an app a few kilobytes. Its steps are `.status`,
`.json`, `.bytes`, `.failure(URLError.Code)`, `.hang` (waits for cancellation on no clock: a
sleeping hang is a timer a simulation may fire early, and a million virtual
seconds pass at once), `.oversized(n)` (a body of `n` bytes that is never
allocated) and `.after(delay)` on any of them, on the ambient clock.
A route's steps are consumed one per request and the last repeats, or `then:`
answers; an unscripted request is a 404 and is listed. It counts requests in
flight (at most, now) and requests aborted (cancelled, or cut at the limit).

**Deviations and decisions**

- **`send` throws `any Error`:** an `HTTPError`, or `CancellationError` when
  the caller was cancelled. The contract's table says `CancellationError`, and
  AGENTS.md says cancellation is never wrapped; a typed `throws(HTTPError)`
  would have needed a `.cancelled` case. A caller whose *deadline* passes gets
  `.rejected(deadline_exceeded)`, not cancellation.
- **Attempts.** An attempt is a request that reached the transport; a request
  the breaker, bulkhead or deadline refused first has made none. Every
  `HTTPError` case carries the count (`timedOut(attempt:)` is the attempt that
  timed out).
- **`Retry-After`** is honoured for every retried status, in seconds or as an
  HTTP date (pinned in tests through `HTTPPolicy.wallClock`; the wait itself
  runs on the ambient clock). It is capped by `HTTPPolicy.maxRetryAfter`
  (default 60 s): a server that asks for an hour is waited for a minute, and
  `.status(…, retryAfter:)` still reports the hour. The contract's "the
  schedule's maximum" was ambiguous (the backoff cap is 10 s and the table
  waits 30 s), so the cap is its own field. A wait that would outlast the
  deadline is not started and the call fails at once with
  `.rejected(deadline_exceeded)` whose `Rejection.retryAfter` is the server's
  wait.
- **Budget exhaustion is `.rejected(budget_exhausted)`.** Stoic's `retry`
  rethrows the last error whatever stopped it; the client puts a watcher in
  front of the retry's events (`retry.budget_exhausted`, `retry.deadline_skip`)
  to report those two stops as the rejections they are. The budget is one
  `RetryBudget` per `HTTPPolicy` value, so per client; `HTTPPolicy.standard` is
  a new value each time.
- **Statuses.** 408, 429, 500, 502, 503 and 504, as the contract lists
  (`HTTPPolicy.retryStatuses`). `HTTPRetry`'s public table also retries 425;
  the client does not use its status table, only its `Retry-After` parser.
  Other 3xx and 4xx and 5xx are `.status` and final.
- **An unkeyed `POST` or `PATCH` is never retried,** on any failure: not on a
  503, not on a failed connection. The contract's rule is "only with a key";
  the exceptions that are safe in principle (the connection was never made)
  are not made. A request that already carries an `Idempotency-Key` header
  counts as keyed.
- **What the breaker counts:** 5xx, timeouts, and the transport failures that
  are the host's or the path's fault. Not counted: any 4xx (a 404 records as a
  success), `responseTooLarge`, a cancelled caller, a refusal by another
  policy, a decoding failure (it happens after the pipeline), and the
  device-side failures `notConnectedToInternet`, `dataNotAllowed`,
  `internationalRoamingOff` and `callIsActive`: counting them would open the
  breaker on a healthy server and keep it open after the device is back. A
  rejection (open breaker, full bulkhead) is never retried: "fail fast" means
  fail.
- **Bulkhead queue.** `queueLimitPerHost` defaults to 64, not 0: a screen that
  starts thirty downloads should wait its turn. Past it, `.rejected(bulkhead_full)`.
  Breaker and bulkhead are `nil`able fields (`breaker: nil`,
  `maxConcurrentPerHost: nil`) for a client that wants neither.
- **Per-host state** is keyed by host (and port, if the URL names one) and
  bounded at 256 hosts, least recently used forgotten first. Breakers measure time on the
  ambient clock in force when a host is first used.
- **Default headers** (`HTTPClient(headers:)`) go only to the base URL's origin.
  An absolute URL on another host never receives the app's token.
- **Nested retries.** The client keeps Stoic's default, `nesting:
  .singleAttempt`: inside another retry's attempt (an `Outbox` delivery, say)
  it makes one attempt and the outer retry owns the retrying.
- **Coalescing** applies to `GET` without a body. The key is the absolute URL
  (query included) plus every request header, names lowercased and the pairs
  sorted, so header case and order do not matter; headers named in
  `HTTPPolicy.ignoreHeadersForCoalescing` (default none) are left out. This
  replaces an allow-list of headers that vary a response (`varyHeaders`),
  which shared a response between callers that differed only in a header the
  list had not heard of. `Authorization` and `Cookie` are in the key so that
  one user can never be handed another's response. One flight runs the whole
  pipeline once. `SingleFlight` gives a flight no deadline, so the caller who
  starts it lends it theirs; a caller who joined with *more* time and finds
  the flight ended by the starter's deadline starts a new flight rather than
  inherit someone else's timeout. A caller whose own deadline passes while
  waiting on a flight gets `.rejected(deadline_exceeded)` with `attempts: 0`
  (it left before the flight reported). The request is cancelled when the last
  caller leaves.
- **Decoding** uses `Schema.decodeReporting`; only errors fail it (warnings
  and repairs are dropped). The options are `HTTPPolicy.decodeOptions`
  (client-wide) or `send(_:decoding:options:)` (per call). Unknown keys are not
  a `DecodeOptions` setting but each object schema's `UnknownKeyPolicy`, whose
  default `warn` ignores a field the server added; a schema declared `reject`
  still rejects it, which is that schema's choice. The default options
  (`decodeOptions == nil`) are strict JSON with the parser's `maxBytes`
  raised to `maxResponseBytes`, so a 9 MB response the client agreed to read is
  not refused with `size_limit` by an 8 MiB parser default; options set
  explicitly are used exactly as given. The per-string (1 MiB) and
  per-container (100,000) limits are raised the same way: to `maxResponseBytes`
  for a string (it cannot be longer than the body) and to `maxResponseBytes / 2
  + 1` for an array or object (two bytes an element is the least JSON takes),
  never lowered, so a legitimate response up to the cap is not refused by the
  decoder for what it holds; the depth limit is not about size and stays.
  `send(_:decoding:)` adds `Accept: application/json`
  unless the request names an `Accept`. An empty body fails a schema that
  wants an object.
- **`HTTPError: Retryable`** classifies the *failure* with the default
  policy's statuses and the `URLError` table. It cannot know the request's
  method, so it does not say whether an outer layer may repeat an unkeyed
  `POST`; AGENTS.md rule 2 stands.
- **Events.** `http.request` is debug, one per attempt that reached the
  transport (method, host, path public; attempt, duration, status, `outcome`;
  the query string as a *private* field only). `http.retry` (info) is recorded
  when a retry begins: attempt number, the wait since the last attempt ended,
  and why it failed (`status_503`, `timed_out`, `transport_-1005`).
  `http.failed` (warning), `http.coalesced` (debug, per caller that joined),
  `http.response_too_large` (warning) and `http.decoding_failed` (notice; the
  number of errors, never the body). Event labels are `"<client label> <host>"`.
  No event carries a header, a body, or a response excerpt: the pipeline's error
  type prints as `status_503`, not with the body excerpt that
  `HTTPError.status` holds.

**Overrides, response retry, reauthentication and the rate limit** (built after
the first version, on the same pipeline):

- **`HTTPOverrides`** is a struct of optionals (`attemptTimeout`, `schedule`,
  `coalesce`) and flags (`bypassBreaker`, `reauthenticate`), plus
  `retryOnResponse`. A call only shares a coalesced flight with calls that ask
  for the same timeout, schedule, bypass and reauthentication, compared as
  values (two schedules can share a hash), since the flight runs the
  starter's pipeline; a call with its own `retryOnResponse` is never
  coalesced, since a closure cannot be compared. A bypassing call skips the
  breaker stage entirely: it is sent while the breaker is open and its outcome
  is not recorded.
- **`retryOnResponse` was the one gap.** A status list with `Retry-After`,
  capped, already existed; what was missing was a decision about a response
  that is not a failure (2xx), or about a status the list does not know, or
  about a listed status that should not be waited for. The predicate's verdict
  rides on the pipeline's internal status error, so `Retry-After` handling,
  capping, the budget and the deadline are the existing ones. A success is only
  turned into a failure to ask again if the request is safe to repeat.
- **Reauthentication** replays any method, keyed or not: a `401` means the
  server did not act on the request. It applies only to requests that carry the
  client's own headers (the base URL's origin), so another host's `401` is
  never the client's to repair and the app's token never goes there. The hook
  returns `HTTPHeaders` that replace the same-named ones among the client's
  default headers for every later request; a request's own headers still win.
  The renewal is a `SingleFlight` keyed by the credentials generation that was
  refused, so concurrent `401`s run the hook once, a late arrival replays
  without it, and the flight is cancelled when the last waiter leaves. The
  hook's request must pass `HTTPOverrides(reauthenticate: false)` if it goes
  through the same client. The replay is a full run of the pipeline (its own
  retries) sharing the attempt count, so `HTTPError.attempts` counts both.
- **Rate limit.** One `RateLimiter` per host, created on the ambient clock in
  force when the host is first used; it sits inside the breaker (a call the
  breaker refuses takes no permit) and outside the bulkhead (waiting for a
  permit holds no slot). Refusals are `Rejection(.rateLimited)`, never retried:
  like an open breaker, "fail fast" means fail. `HTTPClient.rateLimiter(forHost:)`
  exposes it as `breaker(forHost:)` does.

**Not built.** A hedging stage (it exists as a `Policy` value and would slot
into the pipeline); streaming uploads and downloads; delivering through the
outbox (`StoicStore.Outbox` can call `send` with its entry's `IdempotencyKey`).

**Tests** (`Tests/StoicHTTPTests`; overrides, response retry, reauthentication,
rate limit and decoding limits each have a file): one per row above, on a `TestClock` and a
`ScriptedTransport` with no real sleeps (they wait on events and
`waitForSleepers`); `URLSessionTransport` against a `URLProtocol` stub on a
real `URLSession`; and `simulate(seeds:)` runs of seventeen concurrent callers
against a flaky server, under the full schedule portfolio (uniform and PCT,
early timers), which assert that no unkeyed `POST` is ever repeated, every
keyed attempt carries its key and body, attempts stay within the policy, and
the bulkhead holds; identical `GET`s are never in flight twice, and every
caller either started a request or shared one (exactly one request only on a
uniform schedule, where time cannot pass while a caller is still arriving).
A simulated body starts no unstructured `Task {}`: it would run outside the
simulation and the seed would no longer replay.

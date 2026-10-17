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
- **The WHATWG Fetch standard.** Which redirects turn a request into a
  `GET`, which headers describe a body, and that a redirect to another origin
  leaves credentials behind.

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
at most 8 requests in flight to one host; at most 10 redirects followed.
Every number is a field.

**Inside a declared operation, one attempt.** A call made inside a live
attempt of a `perform` (design/22) is that operation's attempt, and the
operation is the host's retry layer: the client skips its own retry, breaker,
bulkhead and rate limiter, and is the transport and the classification of
what came back. Redirects, header scoping, byte limits and decoding are the
same. What `perform` needs to retry correctly is on the error:
`HTTPError.retryDecision` and `neverReachedBackend` below.

**Only what is safe to repeat is repeated.** `GET`, `HEAD`, `OPTIONS`,
`PUT` and `DELETE` are retried; `POST` and `PATCH` only with an
`idempotencyKey`, which is sent as the `Idempotency-Key` header with the
same value on every attempt. A request that fails after the server may
have acted on it (a timeout after sending, a dropped connection) is only
retried when it is idempotent.

**"In progress".** A `409` or `425` answering a request that carries an
`Idempotency-Key` says an earlier attempt with this key is still being
processed: a retry after a timeout would otherwise report a charge that
succeeded as a failure. It is transient whatever the policy lists, and is
retried after at least a second: the server's `Retry-After` if that is longer,
else one second, in place of the schedule's delay. Without a key a `409` is the
server's answer, and final.

A `409` is ambiguous, and no rule that reads only the status can tell the two
meanings apart: Stripe and most payment APIs answer it for "in progress", but
Resend answers `409 invalid_idempotent_request` for the *same key with a
different body*, which no retry can fix, and the body is the server's wording,
not a contract. So the reading is the policy's to change:
`HTTPPolicy.keyedConflictIsInProgress` (default `true`, as above). Off, a keyed
`409` is final like an unkeyed one: the call fails at once with `.status`, whose
`keyed` is `false`, so `HTTPError.retryDecision` says `.stop` to an outbox or a
`perform` too (the error carries the client's reading; it has no policy to ask).
`425` is always "in progress" (Too Early is not ambiguous), and a `409` that
`retryOnResponse` asks to retry is retried as that verdict says.

**Statuses.** 2xx is success. 408, 429, 500, 502, 503 and 504 are retried,
after `Retry-After` when the server gives one (both the seconds and the
HTTP-date form), capped by the schedule's maximum and the caller's
deadline: a wait that would outlast the deadline is not started. Other 4xx
are the caller's fault and are not retried; other 5xx are not retried
either. Transport errors are classified by `URLError` code (design/05).
A breaker counts 5xx, timeouts and transport failures, never 4xx.

**Retrying on what came back.** `HTTPPolicy.retryOnResponse` (or a call's own,
below) sees every response that arrived whole, whatever its status (but a
redirect the client follows: that is the way to the answer, not the answer), and answers
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

**Redirects are the client's.** The transport follows none; the client
follows 301, 302, 303, 307 and 308 that name a `Location`, up to
`HTTPPolicy.maxRedirects` (10), each hop through the policies of the host it
goes to and under the caller's deadline. A `POST` answered 301 or 302, and
anything but `GET` or `HEAD` answered 303, is followed as a `GET` without its
body; 307 and 308 keep the method and the body. The client's headers go only
to the base URL's origin (scheme, host and port); once a redirect leaves the
request's origin, only the headers that negotiate content go along, never a
credential, a custom header or the idempotency key, and the client's headers
never return to that chain. An `https` request is never redirected to `http`.
A refusal is `.redirectRefused` with why (`downgrade`, `limit`,
`invalid_location`), the status and the `Location`, for a caller that follows
it some other way (an OAuth callback on the app's own scheme).

**Rate limit.** `HTTPPolicy.rateLimit` is a token bucket for each host (a Stoic
`RateLimiter` on the ambient clock): every attempt, retries included, takes a
permit, waiting in order for one; a wait that would outlast the caller's
deadline, or a full queue (`queueLimit`, 100 by default, and always a number:
there is no unbounded queue), is `.rejected(rate_limited)` with the wait in
`retryAfter`.

**Responses are bounded.** At most `maxResponseBytes` (10 MB by default)
are read; past that the request fails with `.responseTooLarge` and the
connection is cancelled. Decoding goes through a schema (design/06): a body
that does not match is `.decoding(ValidationFailure)` with every issue and
its path, and is never retried — asking again will not change the
server's mind.

**Streaming.** A body too large to hold (a model, an installer) is read with
`HTTPClient.stream(_:maxBytes:accepting:)`, which returns when the head has
arrived with a success status, and hands over the body as a sequence of byte
chunks (`HTTPBodyStream`, `[UInt8]` chunks, one consumer, one pass). It is one
exchange through the same pipeline as `send` — base URL and headers, redirects,
the host's breaker, rate limit and bulkhead, retry, classification as
`HTTPError` — and it differs in what a body means. **Retrying ends at the
head**: a 503, a lost connection or a timeout before the head is retried as for
`send`; a failure while the body is read is thrown by the body, never retried,
because bytes already taken cannot be sent again, and resuming is the caller's
(a `Range` request, design/23). **The attempt timeout bounds the wait for the
head**, not the body: a transfer that is progressing is not cut at a fixed
length, a stalled one is cut by the transport's own limit on silence, and the
caller's deadline bounds all of it. **The bulkhead slot, the rate-limit permit
and the breaker's verdict are the head's:** a transfer that runs for an hour
must not hold one of the host's eight slots against its API calls, and a cut
part-way through a body is not counted against the host. **The bound is the
caller's** (`maxBytes`, not `maxResponseBytes`, which is made for API
responses): a declared length over it fails before the first byte, and a body
that passes it ends with `.responseTooLarge`, the connection cancelled.
`retryOnResponse` and coalescing do not apply to a stream. A status outside 2xx
that the caller will interpret itself (a `416`) is named in `accepting:` and
comes back as a response.

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
`.reauthenticationFailed(status:)`, `.redirectRefused(reason, status:,
location:)`. Each says whether it was retried and how many attempts were
made.

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
| the body decodes with warnings or repairs     | The value; one `http.decoded_with_warnings` says what was decided          |
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
| a redirect leads to another origin | Followed without the client's headers, the request's credentials and custom headers, or its idempotency key; only `Accept`, `Accept-Language` and the like go along |
| an `https` request is redirected to `http` | `.redirectRefused(downgrade)`; nothing is sent in the clear |
| a `POST` is answered 301, 302 or 303 | Followed as a `GET`, without the body, its headers or the idempotency key |
| a request is redirected with 307 or 308 | Followed with the same method and body, keyed or not: the server has not acted on it |
| a redirect chain is longer than the limit | `.redirectRefused(limit)` once `maxRedirects` (10) have been followed |
| the caller's deadline passes during a redirect chain | `.rejected(deadline_exceeded)`: one deadline spans every hop |
| a keyed request is answered 409 or 425 | "In progress": retried after at least 1 s, or the `Retry-After`; without a key it is the server's answer, `.status` |
| a keyed request is answered 409 and the policy reads it as a refusal | `keyedConflictIsInProgress` is `false`: final at once, `.status` with `keyed: false`, which classifies as `.stop`; `425` is still "in progress" |
| a call is made under `singleAttempt`   | One attempt: a failure is the error, with no backoff and no breaker to open on it; a hung attempt is cut at the attempt timeout, `.timedOut(attempt: 1)` |
| a call runs inside a `perform` attempt | One attempt through none of the client's retry, breaker, bulkhead or rate limit; the operation retries, by `HTTPError`'s classification |
| a call inside a `perform` attempt fails before a connection exists | `neverReachedBackend`: a not-repeatable operation is tried again |
| a call inside a `perform` attempt fails after its request may have been sent | Not `neverReachedBackend` (a lost connection, a 503, a failure after a redirect): a not-repeatable operation is not repeated |
| a body too large to hold is streamed | `stream` returns at the head; the body arrives in chunks, in order, under `maxBytes` (not `maxResponseBytes`) and is never held whole |
| a streamed request gets 503 before its head | Retried as `send` retries; the body read is that of the answer that was good |
| a streamed request is answered with a failure status | `.status` with an excerpt; the rest of the body is abandoned unread; retried if the status is |
| a call accepts a status outside 2xx, such as 416 | Returned as a response with its headers and body, not thrown |
| a streamed body fails after its head | The body throws `HTTPError` (a lost connection is `.transport`) after the chunks that arrived; nothing is retried; the sequence has ended |
| a streamed body is longer than its limit | `.responseTooLarge` thrown by the body after `maxBytes`, the connection cancelled; a declared length over the limit fails before the first byte |
| a streamed body outlasts the attempt timeout | Not cut: the timeout bounds the wait for the head; a server that never answers is cut at it |
| the caller's deadline passes while a body is read | The read throws `.rejected(deadline_exceeded)` and the transfer is cancelled |
| the caller is cancelled while a body is read | The read throws `CancellationError` and the transfer is cancelled |
| a streamed response is abandoned unread | Cancelling or dropping the body cancels the transfer; a read after cancelling throws `CancellationError` |
| a streamed request is redirected | Followed as any request is; the redirect's body is dropped unread; `Range` and `If-Range` go along even to another origin |
| a streamed call runs inside a `perform` attempt | One attempt through none of the client's retry, breaker, bulkhead or rate limit; no attempt timeout cuts the body |
| a transport has no streaming of its own | The default `stream` sends, and yields the whole body as one chunk: fine for a test transport, never for a large body |
| a consumer reads slower than the body arrives | On Apple platforms `URLSessionTransport` holds a bounded buffer: past it the data task is suspended, so the server waits; it resumes when the consumer has drained the buffer (on Linux the task is never suspended: see As built) |

## Events

`http.request` (debug: method, host, path, status, duration, attempt),
`http.retry` (delay, reason), `http.failed`, `http.coalesced`,
`http.response_too_large`, `http.decoding_failed`,
`http.decoded_with_warnings` (warning: the counts of warnings and repairs and
their issue codes; the paths, which may name a key the server chose, are
private), `http.reauthenticated`,
`http.reauthenticate_failed` (the type of the hook's error, never its text),
`http.redirected` (status, hop, the method, host and path it leads to, and
whether the origin changed; never a header or a query);
the breaker, rate limiter, bulkhead and budget emit their own. A streamed
exchange records `http.request` at its head (its duration is the time to the
head, its status the head's) and `http.response_too_large` if its body passes
the limit; a failure while the body is read is the reader's to report.

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
`ScriptedTransport`, `HTTPPolicy`, `HTTPClient`, `HTTPError`; for streaming,
`HTTPStreamedResponse` (status, headers, `body`) and `HTTPBodyStream`.

**The transport.** `send(_:maxResponseBytes:)` receives an absolute URL and
the final headers. The limit is passed _to_ the transport because only the
transport can stop reading: `URLSessionTransport` collects the body from the
task's delegate callbacks, refuses a declared `Content-Length` over the limit
before the first byte, and cancels the task at the first byte over (counted
after decompression, so a compression bomb is stopped too). The client
checks the size again, for transports that do not. It follows no redirect: its
delegate declines each one, so the 3xx is the response and the client applies
the rules below. The delegate is the session's, routing each callback to the
task's collector by task identifier, not a delegate per task:
swift-corelibs-foundation never calls `URLSessionTask.delegate`, so on Linux
every request waited, unanswered, until its attempt timed out. One code path
on every platform means the transport makes its session: `init(session:)`,
whose session could not take the transport's delegate, is gone (a listed
break); `init(configuration:)` carries what a caller's own session would
(cache, cookies, proxies, timeouts).
Verified in the `swift:6.4` image against a local HTTP server: a response, the
byte limit (declared and streamed), a redirect returned rather than followed,
and the client following it without its headers. The `URLProtocol` stub suite
runs on Linux as on macOS, but for its two redirect tests: a stub can only
redirect through `wasRedirectedTo`, which swift-corelibs-foundation does not
implement.

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
  would have needed a `.cancelled` case. A caller whose _deadline_ passes gets
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
  Any other 3xx (a 304, a 300, a redirect with no `Location`) and other 4xx
  and 5xx are `.status` and final, but a `409` or `425` answering a keyed
  request ("in progress", above).
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
  ambient clock in force when a host is first used. A host with a request in
  flight (waiting for a permit or a slot included) is never forgotten: a
  bulkhead made afresh while the old one still held slots would let a second
  set of requests through, so the bound would not hold where it matters. The
  table can exceed 256 only by hosts in use at that moment, and is trimmed
  back as their requests end.
- **Default headers** (`HTTPClient(headers:)`) go only to the base URL's origin:
  scheme, host and port, with the scheme's port implied, so
  `https://api.example.com:443` is the base `https://api.example.com` (it was
  compared as written, and counted as another origin). An absolute URL on
  another host never receives the app's token, nor does a redirect once its
  chain has left that origin.
- **Nested retries.** The client keeps Stoic's default, `nesting:
  .singleAttempt`: inside another retry's attempt (an `Outbox` delivery, say)
  it makes one attempt and the outer retry owns the retrying. A client whose
  retrying lives elsewhere always says so with `HTTPPolicy.singleAttempt`: one
  attempt, no breaker (a delivery loop that comes back after minutes or hours
  needs none to protect the host, and a breaker would refuse its next run's first
  request on a verdict from the last), the attempt timeout kept (10 s, so a hung
  request is not an attempt that never ends). The rest is the standard policy's:
  the bulkhead, redirects, byte limits. Its failures are `HTTPError`s that
  classify themselves for whoever retries.
- **Inside a `perform` attempt** the client does not retry at all (design/22,
  Inside StoicHTTP). It asks the core whether the task runs inside a live
  attempt of a `perform` (a `package` function, the frame the operation
  installs), and then runs one attempt of the pipeline's last stage and no
  other: no host state is made, so no breaker, bulkhead or rate limiter
  exists to consult, and `breaker(forHost:)` and its siblings stay `nil`. Its
  own attempt timeout is not applied (the operation's timer bounds the
  attempt, and a `.long` operation has none: a download is not cut at the
  client's 10 s), but one a call asked for in `HTTPOverrides` still is; and
  `retryOnResponse`, which exists to ask again, is not consulted: a response
  that arrived is the attempt's result, or `.status`. The call is not coalesced
  (a flight runs in a task of its own, outside the attempt the operation is
  waiting on). Reauthentication, redirects, byte limits and decoding are
  unchanged. An unkeyed `POST` inside a `.notRepeatable` operation is not
  repeated on a `503`: the operation's rule is the stricter, and the client's
  "never retried" rule stands for its own retry.
- **Coalescing** applies to `GET` without a body. The key is the absolute URL
  (query included) plus every request header, names lowercased and the pairs
  sorted, so header case and order do not matter; headers named in
  `HTTPPolicy.ignoreHeadersForCoalescing` (default none) are left out. This
  replaces an allow-list of headers that vary a response (`varyHeaders`),
  which shared a response between callers that differed only in a header the
  list had not heard of. `Authorization` and `Cookie` are in the key so that
  one user can never be handed another's response. One flight runs the whole
  pipeline once. `SingleFlight` gives a flight no deadline, so the caller who
  starts it lends it theirs; a caller who joined with _more_ time and finds
  the flight ended by the starter's deadline starts a new flight rather than
  inherit someone else's timeout. A caller whose own deadline passes while
  waiting on a flight gets `.rejected(deadline_exceeded)` with `attempts: 0`
  (it left before the flight reported). The request is cancelled when the last
  caller leaves.
- **Decoding** uses `Schema.decodeReporting`; only errors fail it. Warnings and
  repairs do not, and are not dropped either: a decode that succeeded with any
  records one `http.decoded_with_warnings` (below). The options are `HTTPPolicy.decodeOptions`
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
  - 1`for an array or object (two bytes an element is the least JSON takes),
never lowered, so a legitimate response up to the cap is not refused by the
decoder for what it holds; the depth limit is not about size and stays.`send(\_:decoding:)`adds`Accept: application/json`unless the request names an`Accept`. An empty body fails a schema that
    wants an object.
- **`HTTPError: Retryable`** classifies the _failure_ with the default
  policy's statuses and the `URLError` table. It cannot know the request's
  method, so it does not say whether an outer layer may repeat an unkeyed
  `POST`; AGENTS.md rule 2 stands. It does know whether the request was keyed:
  `.status` carries `keyed` (an addition with a default, so a `.status`
  written without it still compiles; a pattern over its fields does not,
  a listed break), and a keyed `409` or `425` classifies as
  `.retryAfter(max(1 s, retryAfter))`, which is what `perform` and the client's own retry
  both read. The client's own retry applies the same rule beside the policy's
  status list, to a verdict of `retryOnResponse` as well; a wait it was
  asked for is never shortened below a second, even by `maxRetryAfter`, and
  replaces the schedule's delay as any `Retry-After` does.
  `neverReachedBackend` is true for a transport failure with the codes
  `StoicFoundation` claims for `URLError` (`cannotFindHost`, `dnsLookupFailed`,
  `cannotConnectToHost`, `notConnectedToInternet`) on the call's first request,
  and for a rejection that came before any request. After a redirect has been
  followed, or a request retried, an earlier request may have reached the
  server (a `POST` answered `303`, then a `GET` that cannot find its host), so
  the claim is not made: a `.notRepeatable` operation is repeated only on
  proof.
- **Events.** `http.request` is debug, one per attempt that reached the
  transport (method, host, path public; attempt, duration, status, `outcome`;
  the query string as a _private_ field only). `http.retry` (info) is recorded
  when a retry begins: attempt number, the wait since the last attempt ended,
  and why it failed (`status_503`, `timed_out`, `transport_-1005`).
  `http.redirected` (info) for each redirect followed: the redirected request's
  method, host and path, its status, the hop number, the method, host and path
  it leads to (never its query), and `origin_changed`; a refused redirect is an
  `http.failed`. `http.failed` (warning), `http.coalesced` (debug, per caller that joined),
  `http.response_too_large` (warning) and `http.decoding_failed` (notice: the
  number of errors and the body's size in bytes, never the body).
  `http.decoded_with_warnings` (warning) is recorded once per response that
  decoded with warnings or repairs: `warnings` and `repairs` counts, `codes` (the
  distinct issue codes, public) and `paths` (private: a path can name a key the
  server chose). Never a value or any of the body. Both carry the request's
  method, host and path and are labelled for its host, those of the request that
  answered: after a redirect, the last hop's. With coalescing, each caller
  that decodes records its own. Event labels are `"<client label> <host>"`.
  No event carries a header, a body, or a response excerpt: the pipeline's error
  type prints as `status_503`, not with the body excerpt that
  `HTTPError.status` holds.

**Streaming** (built after, for design/23's downloads):

- **A requirement with a default, not a second protocol.** `HTTPTransport`
  gained `stream(_:maxResponseBytes:)`, whose default sends and yields the
  whole body as one chunk, so every existing transport compiles and a test
  transport that only scripts `send` still works. It is documented as fine for
  tests and wrong for anything else. A requirement with a default breaks no
  type that conforms (the API check agrees). `URLSessionTransport.init(configuration:)`
  keeps its signature; `init(configuration:streamBufferBytes:)` is the new one
  (a defaulted parameter added to the old would have removed it).
- **An object, not a closure.** `stream` returns the head with an
  `HTTPBodyStream` (a class, `AsyncSequence` of `[UInt8]`, `Failure = any Error`)
  rather than taking a body closure, because the pipeline's retry, breaker and
  bulkhead stages end at the head (above), and a closure would have run the body
  inside them, holding a slot for an hour. Its lifetime is the cost: abandoning
  is `cancel()` or dropping the last reference (the deinit cancels), so a
  stream nobody reads holds no connection. After a failure further reads
  return `nil`; after `cancel()` they throw `CancellationError`.
- **`[UInt8]` chunks.** The file system's `write` and the hashers a download
  feeds take bytes; `Data` would have been converted at every chunk. The one
  copy is from the `Data` the delegate hands over.
- **`URLSessionTransport`** streams from the session delegate, never through
  `URLSession.bytes(for:)`, which pays an async hop per byte. Chunks wait in a
  buffer (`streamBufferBytes`, 4 MiB by default); when it holds that much the
  data task is _suspended_ (the system stops reading, TCP's window closes), and
  it is resumed when a quarter is left. The decision and the `suspend()` or
  `resume()` it causes are made under one lock: a resume run before the suspend
  it answers would leave a reader waiting on a task nothing wakes. Measured on
  a Mac against a loopback server with a 512 KiB buffer and a reader that had
  stopped: the server had written 1.6 MB of 256 MiB, and 917,504 bytes were the
  most held. The bound is of the order of the buffer, not exact, because what
  the system had already read when it was told to stop still arrives. **On
  Linux there is no backpressure.** The same loopback test, run in the
  `swift:6.4` image, showed swift-corelibs-foundation restarting a suspended data
  task from its first byte when it is resumed (the body began again at block 0,
  which is what Apple's documentation says of every task that is not a download),
  so the transport never suspends there and the buffer holds whatever the
  consumer has not taken: a consumer slower than the network on Linux grows
  memory. Apple platforms are the target of the pilot; a Linux transport with real
  flow control (a libcurl pause the corelibs session does not expose) is not built.
  The consumer is told of a failure only after every chunk that arrived before it.
  What `URLSession` itself drops when a connection dies (the bytes it had
  read but not yet delivered) is lost with it: the downloader resumes from what
  was delivered. `init(configuration:streamBufferBytes:)` takes the caller's
  configuration, so `waitsForConnectivity`, `allowsExpensiveNetworkAccess`,
  `allowsConstrainedNetworkAccess` and `timeoutIntervalForRequest` (the silence
  a streamed body may be held to) are the caller's, as for `send`.
- **`ScriptedTransport`** gained streamed bodies: `.streaming(bytes, chunkSize:,
chunkDelay:, fault:)` and `.serving(Resource, …)`, a file a server holds,
  answered with `Range`, `If-Range`, `206` and `Content-Range`, a `416`, an
  `ETag` and `Last-Modified`, or the whole file from a server that ignores
  ranges. A `Fault` is `.cut(after:)`, `.fail(after:, code)`,
  `.stall(after:, for:)` on the ambient clock, or `.hang(after:)`. Requests in
  flight, and requests aborted, count a body until it ends or is abandoned.
- **`If-Range` joins `Range` in the headers that cross an origin.** A resumed
  download is a `Range` request to an API that redirects to a CDN; the `Range`
  went along and its validator did not, so the CDN would have spliced a changed
  file onto the bytes already held. A validator is an `ETag` or a date the
  server itself sent, and names no one.
- **Errors.** The head's failures are `send`'s. A body throws `HTTPError`
  (`transport`, `responseTooLarge`, `timedOut`, `rejected(deadline_exceeded)`)
  or `CancellationError`, mapped as for the head; what the caller did itself
  (`cancel()`) is never a transport failure. `maxBytes` has no default: the bound
  is the caller's to name, and `HTTPPolicy.maxResponseBytes` is not it.
- **Not carried over:** `retryOnResponse` (the body has not arrived), coalescing
  (a stream is not shared), the breaker's view of a body (a cut part-way is not
  counted against the host), and the bulkhead slot past the head.

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
  exposes it as `breaker(forHost:)` does. `HTTPRateLimit.queueLimit` was an
  `Int?` whose `nil` meant no bound but cancellation and the deadline, and a
  caller with no deadline could then wait behind a queue that only grew; it is
  an `Int` now (a listed API break), as principle 2 asks.

**Redirects** (built after; `URLSession` followed them inside the transport
until then):

- **Why the client.** Followed inside the transport, a redirect was invisible to
  the client, and the transport's rule was narrow: a redirect to another host
  dropped only the four headers `HTTPHeaders.sensitiveNames` lists, so a custom
  credential set as a default header (`X-API-Key`) reached whatever host the
  API pointed at; it compared hosts, not schemes or ports, so a same-host
  downgrade to `http` or a change of port kept `Authorization`; and only Apple's
  App Transport Security refused `https` to `http`, which Linux followed. Owned
  by the client, the rules are in one place, the same on every transport and
  platform, tested on the scripted transport, and every hop is seen by the
  policies and the events.
- **Three kinds of header.** The client's (`HTTPClient(headers:)`, and what
  reauthentication returns) go only to the base URL's origin, and only while
  the chain has never left it. The request's own headers and its idempotency
  key go to the origin the request named and along redirects within it. When a
  redirect changes origin, only `Accept`, `Accept-Encoding`,
  `Accept-Language`, `User-Agent`, `Range`, `If-Range` and the body's `Content-Type`,
  `Content-Encoding` and `Content-Language` go along: an allow-list, because a
  header the client has never heard of may be a credential. What is dropped is
  never restored: a chain from the API to another host and back reaches the API
  without the client's headers, so a host the client was sent to cannot steer
  it into authenticated requests to paths of its choosing. The key stays behind
  because it names an operation to the server it was made for; the hop is then
  unkeyed, so an unsafe one is not retried there.
- **Methods,** as the Fetch standard and browsers: 301 and 302 turn a `POST`
  into a `GET`, 303 turns anything but `GET` and `HEAD` into a `GET`, and the
  body, the headers that describe it (`Content-Type`, `Content-Length`,
  `Content-Encoding`, `Content-Language`, `Content-Location`) and the
  idempotency key go with it: the key named the unsafe operation, and what
  follows is a safe request for its result. 307 and 308 keep the method and
  the body.
- **An unsafe method redirected with 307 or 308 is followed without a key.**
  The redirect says the server did not act on the request at that URI; sending
  it to the new one is not a repeat, the reasoning that lets a `401` replay any
  method. What a key protects against is a request processed twice, and this
  one has been processed no times; requiring one would refuse the commonest
  308 there is (a `POST` to a path without its trailing slash) for nothing.
- **Each hop runs through the policies of the host it goes to:** that host's
  breaker, rate-limit permit and bulkhead slot, and what it meets there counts
  against that host. A CDN that is down must not open the API's breaker, and a
  redirect must not carry a call past the breaker of a host that is failing.
  The host that redirected releases its slot before the next hop starts, so two
  hosts that redirect to each other cannot deadlock on each other's bulkheads;
  for that host the redirect is a healthy answer (a breaker success).
- **A hop is not a retry, and is bounded.** It takes nothing from the retry
  budget, records no `http.retry`, and has its own run of the schedule (a 503
  at the new location is retried as any request there would be), so a call
  makes at most `(maxRedirects + 1) × attempts` requests; the chain is bounded
  by `maxRedirects` and by the caller's deadline, which spans every hop. The
  attempt timeout is per hop, as it is per attempt, and every hop counts in
  `HTTPError.attempts`: an attempt is a request that reached the transport.
- **The limit is 10,** Go's, below `URLSession`'s 16 and Fetch's 20: an API needs
  one or two, a longer chain is a loop or a misconfiguration, and each hop is a
  round trip of the caller's time. `maxRedirects: 0` follows none, and the
  first redirect is `.redirectRefused(limit)` with its `Location`.
- **One new error case,** `redirectRefused(_:status:location:attempts:)`, for
  the three refusals, rather than `.transport(.httpTooManyRedirects)` and ATS's
  `appTransportSecurityRequiresSecureConnection`: neither is a network failure,
  the second is Apple's name for a rule this client applies everywhere, and a
  caller that follows a redirect itself needs the `Location`, which a
  `URLError.Code` cannot carry. A new case breaks an exhaustive `switch` over
  `HTTPError` (listed), as does the new `HTTPPolicy` initializer parameter.
  `location` may hold a token (an OAuth code): it is in no `description` and no
  event. A refusal is never retried.
- **The redirect's body** is read under `maxResponseBytes` and dropped;
  `retryOnResponse` never sees a redirect the client follows.

**Delivering through an outbox.** `StoicStore.Outbox` calls `send` with its
entry's `IdempotencyKey`; give it a client made with `HTTPPolicy.singleAttempt`
so that the outbox is the one layer that retries, and map the answers that will
never succeed to `.discard`, which a thrown error cannot say (design/15):

```swift
let api = HTTPClient(base: url, policy: .singleAttempt)
let outcome = try await outbox.deliver(key) { entry in
    do {
        _ = try await api.send(entry.item.request, idempotencyKey: entry.key)
        return .delivered
    } catch HTTPError.status(let code, _, _, _, _) where code == 400 || code == 422 {
        return .discard(reason: "http \(code)")
    }
}
```

**Not built.** A hedging stage (it exists as a `Policy` value and would slot
into the pipeline); streaming uploads (downloads are built, below, and
resumable ones are design/23).

**Tests** (`Tests/StoicHTTPTests`; overrides, response retry, reauthentication,
rate limit, redirects, decoding limits and the policy shortcuts (`singleAttempt`, a keyed 409) each have a file, `OperationTests` the calls
inside a `perform` attempt and the "in progress" answers, and `StreamingTests`,
`StreamTransferTests` and `URLSessionStreamingTests` streaming: the client on a
scripted transport; the delegate-side buffer driven by hand, so that what a
session does only by timing is settled; and the real transport, on a stub and on
a loopback server for what a stub cannot say, whether suspending the task makes
the server wait and what a connection that dies mid-body leaves a reader): one per row above, on a `TestClock` and a
`ScriptedTransport` with no real sleeps (they wait on events and
`waitForSleepers`); `URLSessionTransport` against a `URLProtocol` stub on a
real `URLSession` (a redirect comes back as the response, and the client
follows it without its headers); and `simulate(seeds:)` runs of seventeen concurrent callers
against a flaky server, under the full schedule portfolio (uniform and PCT,
early timers), which assert that no unkeyed `POST` is ever repeated, every
keyed attempt carries its key and body, attempts stay within the policy, and
the bulkhead holds; identical `GET`s are never in flight twice, and every
caller either started a request or shared one (exactly one request only on a
uniform schedule, where time cannot pass while a caller is still arriving).
A simulated body starts no unstructured `Task {}`: it would run outside the
simulation and the seed would no longer replay.

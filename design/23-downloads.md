# 23 · Downloads

A 20 GB model that arrives over a hotel's Wi-Fi is not one request; it is a
sequence of requests that each get part of the way. The hand-written downloader
is where the earlier contracts are broken one after another: a connection that
drops at 14 GB and starts again at zero; a `.partial` file resumed by its size
alone, so that a file that changed on the server in the meantime is spliced onto
the old bytes and is wrong in the middle; a digest computed in a second pass over
the finished file, which is a minute of disk for a 20 GB one; a file moved into
place before anyone knows it is the right one, or a directory of model files
moved one file at a time, so that a crash leaves half a model that loads and
produces garbage; progress reported ten thousand times a second to a main thread
that draws it twice; a power cut that leaves a partial file whose last
megabytes are zeros, resumed as if they were data. `StoicDownloads` is the
downloader a careful team would write, from the pieces Stoic already has: the
streaming client (design/19), atomic placement (design/15), schedules
(design/02) and declared operations (design/22).

## Origin

- **RFC 9110, ranges.** `Range`, `206` and `Content-Range`, `416`, and
  `If-Range`: the server is asked to send the rest only if the file is still the
  one the validator names, and the whole file otherwise. A strong `ETag` names
  bytes; `Last-Modified` is the fallback `If-Range` also accepts; a weak `ETag`
  is forbidden there, so it is no validator.
- **`curl -C -` and `wget -c`.** Resume by the size of the file on disk, with no
  validator: the splice problem, in the tools everyone uses. A digest is what
  makes that safe, and verification is the one thing that does not depend on
  the server being honest.
- **Git's object ids, Hugging Face's file listing.** A repository names each file
  by its SHA-256 (large files) or by git's blob id: the SHA-1 of `blob <size>\0`
  and the bytes. Both can be computed while the bytes stream, if the size is known.
- **"Files are hard", SQLite, design/15.** A rename is atomic only after the
  directory is synced, and a file that was written but not `fullSync`ed may come
  back zero-filled: so a partial file is trusted only as far as something durable
  says.
- **Apple's `URLSession` download tasks.** Resume data is opaque, belongs to the
  system and fails in ways that cannot be inspected; a partial file the app owns
  can be hashed, verified and thrown away.

## API

```swift
let downloader = Downloader(
    client: HTTPClient(base: huggingFace, transport: URLSessionTransport(configuration: configuration)),
    operation: Models.download)             // Backend.huggingFace.idempotent("download", length: .long)

// One file: resumable, verified, durable.
let result = try await downloader.download(
    Download(url, to: path, expectedSize: 3_600_000_000, digest: try .sha256(hex), fileMode: 0o644))

// A model: several files, placed as one directory.
let model = try await withDeadline(.after(.seconds(6 * 3600))) {
    try await downloader.download(
        DownloadBundle(files.map { DownloadBundle.File($0.path, baseURL.appending(path: $0.path), expectedSize: $0.size, digest: try .sha256($0.sha256)) },
                       to: modelDirectory, fileMode: 0o644),
        progress: { progress in model.progress = progress })
}

// Tests: the network is a script, the disk is simulated, time is virtual.
transport.on(.get("/model.bin"), respond: [.serving(Resource(bytes, etag: "\"v1\""), fault: .cut(after: 4_000)), .serving(Resource(bytes, etag: "\"v1\""))])
```

```swift
public struct Downloader: Sendable {
    public init(client: HTTPClient, fileSystem: any FileSystem = PosixFileSystem(), policy: DownloadPolicy = .standard,
                label: String = "download", operation: Backend.Operation? = nil)
    public func download(_ download: Download, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> DownloadResult
    public func download(_ bundle: DownloadBundle, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> DownloadBundleResult
}

public struct Download: Sendable {
    public init(_ request: HTTPRequest, to destination: String, expectedSize: Int? = nil, digest: ContentDigest? = nil, byteLimit: Int? = nil,
                partialPath: String? = nil, keepsPartialOnCancel: Bool = true, fileMode: UInt16 = 0o600, requiredFreeBytes: UInt64? = nil)
    // and init(_ url: URL, to:, …)
}

public struct ContentDigest: Sendable, Hashable {
    public struct Algorithm { public static let sha256, gitBlobSHA1 }
    public static func sha256(_ hex: String) throws(Invalid) -> ContentDigest
    public static func gitBlobSHA1(_ hex: String) throws(Invalid) -> ContentDigest
}

public struct DownloadPolicy: Sendable {      // schedule, verificationAttempts, progressInterval, checkpointBytes, writeBufferBytes, freeSpaceMargin
    public static var standard: DownloadPolicy
}
public struct DownloadBundle: Sendable { /* File(path, request, expectedSize, digest), destination, stagingPath, keepsPartialOnCancel, fileMode */ }
public struct PartialAdoption: Sendable, Equatable { /* path, validator: PartialValidator? */ }
public enum PartialValidator: Sendable, Equatable { case etag(String), lastModified(String) }
// Download.adoptingUnrecordedPartial(at:validator:), DownloadBundle.File.adoptingUnrecordedPartial(validator:)
public struct DownloadProgress: Sendable { /* phase, fileIndex, fileCount, fileBytes, fileTotalBytes, bytesDone, totalBytes, fraction */ }
public struct DownloadResult: Sendable { /* path, bytes, verifiedDigest, resumedFrom, requests, isDurable */ }
public enum DownloadError: Error, Sendable, Retryable { /* http, retriesExhausted, digestMismatch, sizeMismatch, byteLimitExceeded,
                                                           insufficientSpace, store, badResponse, deadlineExceeded, rejected */ }
```

## Semantics

**The life of one file.** (1) Check the volume has room. (2) Read the partial file
and its record, and decide how much to believe (below). (3) Ask for the rest, a
`Range` request with the validator in `If-Range`, through `HTTPClient.stream`
(design/19): the client's base URL, headers, redirects, breaker, rate limit and
classification are the download's. (4) As each chunk arrives it is hashed and
gathered into a write buffer (`writeBufferBytes`, 1 MiB by default: a system call
for every 16 KiB chunk would be a million of them for 20 GB), and written to the
partial file; every `checkpointBytes` (64 MiB) the file is `fullSync`ed and
_then_ its record says so. (5) When the body is whole, the digest is compared:
never a second pass. (6) The verified file is `fullSync`ed, renamed over the
destination, the directory synced, and the record removed. A file at the
destination is therefore always whole and verified, or the old one.

**What a response means.** `206` whose `Content-Range` starts at the offset
asked: append. `206` starting anywhere else, or whose validator is not the one held
(a redirect to a CDN that was not asked with `If-Range`): the partial file is
discarded and the next request is from zero. `200` to a request that had a
`Range`: the server ignored it, or the validator changed; the partial file is
discarded and _this_ body is the file from byte 0, with no second request. `416`:
if the partial file is the whole file (the expected size, or the `Content-Range:
bytes */N` the server sent, equals the offset) it goes to verification;
otherwise it is discarded and the file starts again. A body that ends without an
error before the declared or expected length is a cut like any other. A body
longer than the length that response declared is not that file: a `200` whose
body passes its `Content-Length`, or a `206` whose body passes the span of its
`Content-Range` (`end - start + 1`), is `.badResponse`, the connection
cancelled, and those bytes are not written or placed. What was already inside
the declared length stays in the partial file; this run does not resume from
past it, so the extra bytes cannot be spliced in. A server that says the file
is a different size from the one the download was pinned to is
`.sizeMismatch`, before a byte is fetched; one that sends more than the byte
limit is `.byteLimitExceeded`, the connection cancelled and the partial file
deleted.

**The record.** `<partial>.resume`, written with `AtomicFile` (a checksummed
envelope: whole or absent, a damaged one fails its checksum), holds which download
the partial file belongs to (a hash of the request's target, the expected size
and the digest: a URL's query is never written in the clear), the validator, the
file's size when a response said it, and `synced`: how many bytes of the partial
file are durable. A run trusts the partial file only up to `synced`, and cuts it
back to there (bytes past it may be lost, or zero-filled, by a power cut, and the
file's own size cannot say which). It is discarded, with a `download.restarted`
event saying why, when the record is missing, damaged or not a record, when it is
another download's, when the file is larger than the expected size or the limit,
when nothing was synced, and when there is nothing to resume by: **no validator and
no digest**. A strong `ETag` is preferred, `Last-Modified` is the fallback, and a
weak `ETag` is no validator. Resuming without a validator is allowed only for a
download that has a digest, which will say whether the splice was right; without
either, the file starts again, because nothing could ever say it was wrong.

**Hashing a resume.** The digest must cover the whole file, so the partial
file's trusted prefix is read once, in 1 MiB blocks, as `.verifying` progress, and
fed to the hasher before the request is made; the task is cancelled and yields
between blocks, so a 20 GB prefix does not hold a thread.

**Verification.** `ContentDigest` is an algorithm and lowercase hex:
`.sha256`, and `.gitBlobSHA1` (the SHA-1 of `blob <size>\0` and the bytes, which
needs the size first, so a download with one must have an expected size). A bad
digest string is `ContentDigest.Invalid`, not a download with no verification. A
mismatch deletes the partial file and its record and fetches the file again from
zero, `verificationAttempts` times in all (2 by default: once more, because a
damaged resumed prefix is the commonest cause); the last is
`.digestMismatch(expected:actual:attempts:)`, and the destination is untouched.

**Retrying across cuts.** The downloader is its own retry layer (design/22: one
layer retries). It asks `HTTPClient.stream` for one attempt (an `HTTPOverrides`
schedule of one) and classifies each failure with `HTTPError.retryDecision`: 408,
429, 500, 502, 503 and 504, lost connections, timeouts and a breaker's or
limiter's refusal are retried; any other 4xx, a redirect refused, a response too
large are final. A retry waits on a Stoic `Schedule` stepped on the ambient clock:
by default 10 s doubling to 300 s with equal jitter (half to all of each step) and
no bound on attempts. The server's `Retry-After` replaces the step when it is
longer (capped by the client's `maxRetryAfter`). **The schedule starts over
whenever a request got any bytes**: a download that moves between cuts is never
more than the first step behind, and one that gets nowhere backs off to the cap.
A wait that would outlast the caller's deadline is not begun
(`.deadlineExceeded`), and every wait is a cancellation point. A schedule with
`.attempts(n)` ends with `.retriesExhausted`. What escapes the downloader is
final: `DownloadError` is `Retryable` with one answer, `.stop`, so an enclosing
`retry` or declared operation does not repeat what was already repeated.

**Cancellation and deadlines.** Cancelling stops the download at once, flushes
and checkpoints what arrived, and throws `CancellationError`, not a failure and
never wrapped; the partial file is kept unless `keepsPartialOnCancel` is false. A
caller's deadline that passes is `.deadlineExceeded` (a rejection, as for `send`),
and keeps the partial file whatever the option says: the time ran out, nobody
cancelled. A failure that is not about the bytes (a 403, a full disk) also leaves
what arrived for the next run; one that is (a mismatch, a size, the limit) deletes it.

**A download is a `.long` operation** (design/22). Slow is not stuck: no attempt
timeout cuts a transfer that is progressing (`HTTPClient.stream` bounds the wait
for the head, never the body, and a stalled body is cut by the transport's own
limit on silence), and the caller's deadline is what bounds it. Give the
`Downloader` the `Backend.Operation` that declares it (`length: .long`,
`readOnly` or `idempotent`, enforced when the downloader is made) and each
download runs as one attempt of it: it holds one of the backend's slots for as
long as it runs, at the caller's urgency, under the backend's breaker; the client
inside defers to it. The operation never repeats a failed download (its
classification is `.stop`). **Set a deadline.** A caller that set none gets design/22's
default for its urgency, tripled for `.long`: 90 s at `.userInitiated`, which is
a safety net for a call and not a budget for a model.

**Space.** `Download.requiredFreeBytes` (or, with an expected size, what is left
to fetch and `freeSpaceMargin`; none without one; `0` turns it off) is checked
through `FileSystem.freeSpace` before the first request: `.insufficientSpace`,
nothing fetched. What the partial file already holds counts as room. A volume that
cannot say is not a reason to refuse. A disk that fills part-way is `.store(.diskFull)`,
not waited out, with what was written kept.

**Placement and durability.** `fullSync` the file, `rename` over the destination,
`syncDirectory`: a crash at any of these leaves the old file or the new one. If the
directory sync _after_ the rename fails (design/15's `durabilityUnknown`) the file
is in place and every reader sees it, so the download is **placed**:
`DownloadResult.isDurable` is `false`, `download.durability_unknown` says so, and
nothing is thrown, because failing a download whose file is where it should be
would only make the caller do it again. (Lodestar's `acceptingUnknownDurability`
is this policy, written once.) A failed _rename_ or earlier step is `.store`, with
the verified partial file kept: the next run verifies it and places it without
asking the server for anything.

**Bundles.** `DownloadBundle` is files that are one thing. They are fetched one
after another into `.<name>.partial/` beside the destination, each as a
`Download` of its own (resumable, verified), and placed with one
`AtomicFile.replaceItem` (on Apple platforms, a swap of the two directories in
a single step, then the old one removed): the destination is the old directory
complete or the new one complete. A run starts by finding out what is there: a
file whole at its own name, at its expected size, with a digest that checks, is
verified and not fetched (`requests == 0`; a file with no expected size or no digest
is refetched, since nothing says it is the right one); a `<name>.partial` resumes;
a missing file is fetched; and anything else in the staging directory (a file of an
earlier version) is removed. A file that fails its digest fails the bundle with
nothing placed and leaves the other files for the next run. Space is checked once
for the whole. Progress carries the file in progress and the bytes of the whole.

**Adopting a partial file Stoic did not write.** A partial file is resumed only with
its record, and one without is deleted: the right default, since nothing says what
it is. A program that fetched files before Stoic did (an earlier build, a file the
user copied in) knows more, and says so with `Download.adoptingUnrecordedPartial(at:validator:)`
(for a bundle file, `File.adoptingUnrecordedPartial(validator:)`, which means the file
at its own name in the staging directory). The caller's word is that the bytes are
the first bytes of the file this download names. The downloader needs something to
check that word by (a digest, or a validator for `If-Range`; otherwise the file is
left alone, `download.adoption_declined`), makes the bytes durable because the
record is about to vouch for them, writes the record (`synced` = all of them),
and only then renames the file to the partial path: a crash between leaves the
file where it was and a record the next run removes. Then it resumes as for any
partial file (`download.adopted`, `download.resumed`). The word is believed, not
trusted: the digest, hashed over the adopted bytes and the rest, still decides, and
a file that fails it is fetched again from nothing. A partial file of the
downloader's own, with a record, is always the one resumed; the adopted file is
then not touched. An empty file, one larger than the expected size or the byte
limit, is declined, not deleted. The adopted file takes `fileMode`.

**Progress.** `DownloadProgress` (phase `waiting`, `downloading`, `verifying`,
`placing`; the file index and count; bytes of the file and of the whole, and their
totals when known; for a single download the whole's total is the file's, so without
an expected size `totalBytes` and `fraction` appear when the response's `Content-Length`
does) is passed to a `@Sendable` callback, at most once per
`progressInterval` (0.5 s) for a phase and at every change of phase. Throttling reads
the ambient clock when a report is offered and starts no timer: it costs nothing
when nobody is listening, runs the same on a `TestClock`, and leaves nothing running
when the download ends. The callback runs on the downloading task: an `AsyncStream`
continuation with `.bufferingNewest(1)` is a one-line adapter.

**Privacy.** Events carry the method, host and path of the request, never its query,
headers or body; paths of files are private fields; an error is reported as its kind.
A URL's query reaches disk only as a hash.

## Failure modes

| What happens if…                                                          | Behaviour                                                                                                                                                                 |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a file is downloaded whole                                                | Verified while it streamed, `fullSync`ed, renamed over the destination, the directory synced; no partial file or record remains; `download.placed`                        |
| the connection is cut part-way                                            | Retried after the schedule's first step, with `Range: bytes=N-` and the validator in `If-Range`; the file is exact; `download.retry`                                      |
| a body ends short without an error                                        | A cut like any other: resumed from where it ended (`short_body`)                                                                                                          |
| a `200`'s body is longer than its `Content-Length`                        | `.badResponse`, the connection cancelled; the extra bytes are not written or placed; not retried                                                                           |
| a `206`'s body is longer than its `Content-Range`                         | `.badResponse`; nothing is written past the range; the download does not resume from beyond it or place the spliced file                                                   |
| the server ignores Range and answers 200                                  | The partial file is discarded and this body is the file from byte 0; `download.restarted` (`range_ignored`)                                                               |
| the server's file changed since the partial file was begun                | `If-Range` fails and the server sends it whole: restarted (`validator_changed`); a `206` for a validator that is not the one held, or for another range, is restarted too |
| the server answers 416 and the partial file is the whole file             | It goes to verification and placement; nothing is thrown away                                                                                                             |
| the server answers 416 and the partial file is not the whole file         | The partial file is discarded and the file is requested from the start (`range_not_satisfiable`)                                                                          |
| the server's file is not the size the download was pinned to              | `.sizeMismatch(expected:reported:)` before a byte is fetched                                                                                                              |
| the digest does not match                                                 | The partial file and record are deleted and the file is fetched again from zero; a second mismatch is `.digestMismatch(…, attempts: 2)` and the destination is untouched  |
| the body is longer than the byte limit                                    | `.byteLimitExceeded`, the connection cancelled, the partial file deleted; a declared length over the limit fails before the first byte; not retried                       |
| the server answers 404                                                    | `.http(.status(404))` at once: not retried, nothing waited for (so for 401, 403, 410 and every 4xx but 408 and 429)                                                       |
| an error response has a body larger than the byte limit                   | `.http(.status)` as for any error: the limit is for the file, so a `404` page larger than a small file's pinned size is a `404`, not `.byteLimitExceeded`; its body is read only as far as the client's excerpt |
| the server answers 429 or 503                                             | Retried on the schedule, waiting the server's `Retry-After` if that is longer (capped); the client itself does not retry                                                  |
| bytes arrive between failures                                             | The schedule starts over: 503, 503, a cut that delivered bytes, 503 wait 10 s, 20 s, 10 s, 20 s                                                                           |
| the schedule has a bound and it is spent                                  | `.retriesExhausted(attempts:last:)`; the partial file stays                                                                                                               |
| the download is cancelled                                                 | `CancellationError`, `download.cancelled`, no `download.failed`; what arrived is checkpointed and the next run resumes from it                                            |
| a cancelled download is told not to keep its partial file                 | `CancellationError`; the partial file and record are removed                                                                                                              |
| the caller's deadline passes                                              | `.deadlineExceeded`, not a cancellation; the partial file stays whatever `keepsPartialOnCancel` says                                                                      |
| a backoff would outlast the caller's deadline                             | `.deadlineExceeded` at once, nothing slept                                                                                                                                |
| the volume has too little free space                                      | `.insufficientSpace(required:available:)` before the first request; what the partial file holds counts as room                                                            |
| the disk fills part-way                                                   | `.store(.diskFull)` at the write that failed, not waited out; what was written is kept                                                                                    |
| a run is stopped by an error that is not about the file                   | A 403 after 4,000 bytes keeps them; the next run resumes from 4,000                                                                                                       |
| the partial file has no record                                            | Discarded, restarted (`record_missing`)                                                                                                                                   |
| a partial file nobody recorded is adopted                                 | Given a record on the caller's word and resumed from its end (`download.adopted`, `download.resumed`); the digest still decides, and the file takes `fileMode` |
| an adopted partial file is not a prefix of the file                       | It fails the digest like any spliced prefix: deleted, fetched again from zero; never a wrong file at the destination |
| an adopted partial file has nothing to resume it by                       | No digest and no validator: left alone, not deleted (`download.adoption_declined`: `nothing_to_resume_by`); the file is fetched whole; so for an empty file or one larger than expected |
| a partial file is offered for adoption and the downloader has one of its own | The downloader's own is resumed from its record; the offered file is not touched |
| a bundle file is half fetched by an earlier program and the bundle adopts it | Adopted before the staging sweep would remove it, then resumed by range; the other files are as for any bundle |
| the resume record is torn or garbage                                      | A checksum failure is quarantined by `AtomicFile` and the file restarted (`record_invalid`); a record that is intact but is not one is `record_invalid` too               |
| the partial file belongs to another download                              | Restarted (`different_download`): another URL, size or digest at the same path                                                                                            |
| the partial file is larger than the expected size                         | Discarded (`larger_than_expected`)                                                                                                                                        |
| the partial file holds bytes the record does not vouch for                | Cut back to `synced` and resumed from there; `download.resumed` says how many were discarded                                                                              |
| a resumed prefix was damaged                                              | Hashed with the rest, so the digest fails at the end: fetched again from zero (`verification_failed`), then the file is right                                             |
| the server gives no validator and the download has a digest               | Resumed by `Range` alone; the digest decides if the splice was right                                                                                                      |
| the server gives no validator and the download has no digest              | Not resumed: restarted (`nothing_to_resume_by`)                                                                                                                           |
| a digest is not hexadecimal or the wrong length                           | `ContentDigest.Invalid` when it is made, never a download that verifies nothing                                                                                           |
| the process dies at any step of a download                                | Whatever the disk kept, the destination is the old file or the new one, whole; the next run finishes and leaves no partial file                                           |
| the process dies at any step of placing                                   | The same: `fullSync`, rename and directory sync are each a crash point, and the verified partial file is placed by the next run                                           |
| the process dies in a download that was cut and resumed                   | The same, across checkpoints and resumes                                                                                                                                  |
| the process dies while the next run is resuming                           | The same: a crash of the recovery run is recoverable too                                                                                                                  |
| the directory sync after the rename fails                                 | The file is in place and treated as placed: `isDurable == false`, `download.durability_unknown`, no error                                                                 |
| a bundle is downloaded                                                    | Each file fetched and verified in staging; the directory swapped over the destination; the staging directory is gone; `isDurable`; progress names the file and the whole  |
| a bundle has one file whole, one part-way and one missing                 | The whole one is verified and not fetched (`requests == 0`), the partial one resumes by range, the missing one is fetched                                                 |
| a staged file does not check                                              | Removed and fetched again (`staged_file_failed_verification`; for a size, `staged_file_wrong_size`; with nothing to check it by, `staged_file_unverifiable`)              |
| the staging directory holds files that are not the bundle's               | Removed (`stale_staging_files`)                                                                                                                                           |
| the bundle's destination already exists                                   | Swapped out whole and the old directory removed; a bundle that fails leaves the old directory as it was                                                                   |
| the directory sync after a bundle's swap fails                            | The new directory is in place and treated as placed (`isDurable == false`, `download.durability_unknown`, `what` `bundle`), and the old directory, which `replaceItem` leaves at the staging path then, is removed; if that fails, `download.cleanup_failed` |
| a file of a bundle does not check                                         | The bundle fails with `.digestMismatch`; nothing is placed; the files that were right stay for the next run                                                               |
| a bundle is cancelled                                                     | `CancellationError`; the staging directory stays (or is removed, with `keepsPartialOnCancel: false`); nothing is placed                                                   |
| progress is reported                                                      | At most once per interval for a phase on the ambient clock, every change of phase, bytes that only grow                                                                   |
| a single download has no expected size and the server says its length | `totalBytes` equals `fileTotalBytes` from the response's `Content-Length` (or `Content-Range`), so `fraction` is known; before the head it is `nil` |
| a download runs as a long operation                                       | One attempt of the operation; the client inside makes one request each and defers to it; the operation retries nothing                                                    |
| a long operation has no attempt timeout                                   | A transfer whose chunks are a minute apart is not cut by a client attempt timeout of a second                                                                             |
| a download is admitted under its backend's capacity                       | It holds a slot while it runs; with capacity 1 a second waits and asks the server for nothing                                                                             |
| a download waits for its slot past the caller's deadline                  | `.deadlineExceeded`; nothing was asked of the server                                                                                                                      |
| a download that nobody gave a deadline runs under the operation's default | The default total (90 s at `.userInitiated`) ends it with `.deadlineExceeded`, partial file kept                                                                          |
| a download is cancelled inside its operation                              | `CancellationError`, not a failure                                                                                                                                        |
| a download fails inside its operation                                     | The downloader's error; neither layer repeats a 404                                                                                                                       |
| a download meets any mix of cuts, refusals and changes                    | Always the exact bytes at the destination, or a typed `DownloadError` and no file; never a placed file with the wrong digest                                              |

## Events

`download.started` (info), `download.resumed` (info: `offset`, `discarded`),
`download.restarted` (notice: `reason`, `discarded` bytes, or `removed` files),
`download.retry` (info: `attempt`, `delay`, `reason` as `status_503` or
`transport_-1005` or `short_body`, `bytes`), `download.verified` (info),
`download.verification_failed` (warning: algorithm, attempt, expected and actual
digest), `download.placed` (info: `bytes`, `durable`; for a bundle also `files`),
`download.file_reused` (info), `download.adopted` (info: `bytes`, `validator`),
`download.adoption_declined` (notice: `reason`), `download.durability_unknown` (warning: what),
`download.cancelled` (info: `bytes`, `kept`), `download.failed` (warning: `kind`
public, the error text private, `bytes`, `kept`), `download.cleanup_failed`
(warning). All are in `EventCatalog`. File events carry `request` (method, host and
path), never the query.

## As built

`StoicDownloads` depends on `Stoic`, `StoicHTTP`, `StoicStore` and swift-crypto's
`Crypto` (digests; on Apple platforms it is CryptoKit's own implementation). It is
Foundation-free apart from what `StoicHTTP`'s public types bring (`URL`, `URLError`).

- **Behind the `Crypto` trait**, with `StoicSealed` (design/24). swift-crypto is a
  dependency that is not Stoic's own, and Stoic's rule is that nobody fetches a
  package they did not ask for (`scripts/adoption.sh`: adopting every library with
  no trait resolves nothing remote; swift-log, swift-metrics and swift-syntax are
  behind traits for the same reason). So the library is a product like
  `StoicSealed`: `.package(url: …, traits: ["Crypto"])`, its sources compile to
  nothing without `STOIC_CRYPTO`, and its tests are run with
  `swift test --traits Crypto` (`scripts/check.sh` and `scripts/linux.sh` do).
- **`any Error`, not `throws(DownloadError)`.** `download` throws `DownloadError`
  or `CancellationError`, as `HTTPClient.send` throws `HTTPError` or
  `CancellationError` (design/19), because a typed error cannot also be
  cancellation, and Stoic's scopes and supervisors must see a cancelled download
  as cancelled, not as a child that failed. Inside the downloader every step is
  typed by one internal error (`Stop`).
- **One layer retries.** The client's own retry is turned off for the downloader's
  requests (a schedule of one attempt), so a 503 is retried once, by the
  downloader, on the downloader's schedule, with the downloader's resets. The client
  still applies its breaker and rate limit to each request.
- **A resumed download's `If-Range` crosses origins.** A model's URL is an API that
  redirects to a CDN; design/19's allow-list gained `If-Range` so the validator
  arrives with its `Range`.
- **Checkpoints, not a sync per chunk.** Data is `fullSync`ed every 64 MiB and the
  record follows. A process killed (not the machine) loses at most that much
  progress too, since the next run trusts only what the record vouches for; the
  alternative, trusting the file's size, resumes into zeros after a power cut. The
  cost of a checkpoint is one sync and one atomic write of a 100-byte file.
- **File mode defaults to `0o600`.** A file a download made is private until the app
  says otherwise (design/15's rule that a write never widens a file). Models, which
  anyone may read, ask for `0o644`. It is set with `fchmod` before the first byte, so
  the umask does not narrow it.
- **The default schedule reads "10 s × 6" as six doublings** (10, 20, 40, 80, 160,
  then the 300 s cap), equal jitter, no attempt bound. It is a `Schedule`, not a
  `BoundedSchedule`: a bound on a download is a decision, and it is the policy's.
- **The progress callback**, not an `AsyncStream`: a callback is the primitive, needs no
  consumer task and no buffering policy, and an `AsyncStream` continuation is one line.
- **No backpressure on Linux.** The streaming transport suspends the data task when
  the consumer lags, which swift-corelibs-foundation answers by restarting the task
  from the first byte on resume (design/19). So on Linux a download whose disk is
  slower than its network buffers the difference in memory; on Apple platforms,
  where the downloads are used, the buffer is bounded.
- **What a bundle cannot do.** A directory swap is `renamex_np`; on Linux
  `replaceItem` over an existing directory is `.unsupported` (design/15), and a
  bundle whose destination exists fails there with `.store(.unsupported)` before it
  changes anything (a first-time bundle works). The simulated file system models
  files, not directories (design/15), so a bundle's placement is tested on the real
  one and its crash safety is `replaceItem`'s, which is crash-tested in `StoicStore`;
  the placement of a single file is explored at every crash point, over a download
  that is cut and resumed, and over a crash of the recovery run.
- **No stall timer of its own.** A body that stops is cut by the transport's limit on
  silence (`URLSessionConfiguration.timeoutIntervalForRequest`, 60 s by default; with
  `waitsForConnectivity` set, the system waits for the network first) and then resumed;
  the downloader adds none, so one number decides it, the caller's.
- **Quarantined records.** A resume record that fails its checksum is renamed aside
  by `AtomicFile` (`<record>.corrupt-N`, at most 8, `store.corrupt_quarantined`). A
  bundle's staging cleanup removes them; a single download leaves them.

## Tests

`Tests/StoicDownloadsTests`, on a `ScriptedTransport`, a `SimulatedFileSystem` and a
`TestClock` (nothing sleeps in real time; the bundles' are on the real file system, in a
temporary directory): one test for every row above; the cut at offsets that fall on a
chunk, a buffer and a checkpoint boundary, and at the very end; published test vectors
for the digests; a crash explored after _every_ file operation of a download, over every
disk the simulated hardware allows (design/15), checked for "the old file or the new one"
and for "the next run finishes", including a download that was cut twice and a crash of
the recovery run itself; progress on the virtual clock; the operation's admission, deadline
and cancellation; and `simulate(seeds:)` over random cuts, stalls, refusals, changed files
and servers that ignore ranges, asserting that the destination holds the exact bytes or
nothing, and never a placed file with a wrong digest. The streaming underneath is
design/19's tests, on a loopback server for what a stub cannot say.

## Not built

- **Parallel ranges** (several connections to one file): faster on a fast link, and a
  different design for the record. Files of a bundle are fetched one at a time.
- **Background `URLSession`s** (the system downloading while the app is suspended): a
  different transport with the system's own resume; `Downloader` works with any
  `HTTPTransport`.
- **A directory swap on Linux** (`renameat2(RENAME_EXCHANGE)`), and a simulated file
  system that models directories, so that a bundle's placement can be explored at every
  crash point as a single file's is.
- **Upload.** design/19's streaming is downloads only.
- **Per-host concurrency across downloads.** That is the operation's backend capacity.

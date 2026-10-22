#if STOIC_CRYPTO
internal import Foundation
internal import Stoic
internal import StoicHTTP
internal import StoicStore

/// One file, from the first request to the verified file in place. The
/// downloader's core; `Downloader` decides what surrounds it.
///
/// The partial file is the whole of the state that outlives the process. It
/// holds the bytes received so far, in order, and a sidecar (``ResumeRecord``)
/// says how many of them are known to be durable and which version of the
/// file they came from. A run starts by reading both and trusting the bytes
/// only as far as the sidecar vouches for them; it then asks for the rest
/// (`Range`, with the validator in `If-Range`), hashing as the bytes arrive,
/// and checkpoints every so often (data `fullSync`ed first, then the record).
/// When the body is whole it is verified against its digest, and only then
/// moved over the destination.
struct FileTransfer {
    let download: Download
    let client: HTTPClient
    let disk: Disk
    let policy: DownloadPolicy
    let label: String
    let progress: ProgressReporter
    /// The fields every event about this file carries: the request's method,
    /// host and path. Never its query, which may hold a token.
    let fields: [Event.Field]

    init(
        _ download: Download, client: HTTPClient, disk: Disk, policy: DownloadPolicy, label: String, progress: ProgressReporter
    ) {
        self.download = download
        self.client = client
        self.disk = disk
        self.policy = policy
        self.label = label
        self.progress = progress
        fields = [.init("request", .string(download.request.description), privacy: .public)]
    }

    // MARK: State

    private struct State {
        var file: OpenFile?
        /// Bytes received and hashed: what is in the partial file and the buffer.
        var offset = 0
        /// Bytes written to the partial file.
        var flushed = 0
        /// Bytes of the partial file made durable and recorded.
        var synced = 0
        /// Received, not yet written.
        var buffer: [UInt8] = []
        var hasher: ContentHasher?
        var validator: Validator?
        /// The whole file's size, from the server or the caller.
        var total: Int?
        var requests = 0
        var verifications = 0
        var resumedFrom = 0
    }

    /// How an attempt, one request, ended when it did not fail the download.
    private enum Outcome {
        /// The partial file holds the whole file.
        case complete
        /// What the server said means the partial file is not this file's
        /// prefix: it was discarded, and the next request is from zero.
        case restart
        /// The request failed in a way that is worth asking again.
        case interrupted(Interruption)
    }

    private struct Interruption {
        var last: HTTPError
        /// What the server asked to wait, capped.
        var retryAfter: Duration?
        /// A short, public name for events: `status_503`, `transport_-1005`.
        var reason: String
    }

    /// One request, no retrying of its own: this loop is the retry layer.
    private static let oneAttempt = HTTPOverrides(schedule: Schedule.immediate.attempts(1))

    // MARK: The transfer

    func run() async throws(Stop) -> DownloadResult {
        var state = State()
        state.hasher = makeHasher()
        record(Event("download.started", level: .info, label: label, fields: fields))
        report(.waiting, state)
        do throws(Stop) {
            try disk.createDirectory(Paths.directory(of: download.destination))
            if Paths.directory(of: download.partialPath) != Paths.directory(of: download.destination) {
                try disk.createDirectory(Paths.directory(of: download.partialPath))
            }
            try await resume(&state)
            try preflightSpace(state)
            fetching: while true {
                try await fetch(&state)
                switch try verify(&state) {
                case .verified: break fetching
                case .refetch: continue fetching
                }
            }
            let durable = try place(&state)
            return DownloadResult(
                path: download.destination, bytes: state.offset, verifiedDigest: download.digest,
                resumedFrom: state.resumedFrom, requests: state.requests, isDurable: durable)
        } catch {
            wind(down: error, &state)
            throw error
        }
    }

    private func makeHasher() -> ContentHasher? {
        download.digest.map { ContentHasher($0.algorithm, size: download.expectedSize) }
    }

    private func report(_ phase: DownloadProgress.Phase, _ state: State) {
        progress.report(phase, fileBytes: state.offset, fileTotal: state.total ?? download.expectedSize)
    }

    private func record(_ event: Event) {
        Ambient.current.instrumentation.record(event)
    }

    // MARK: Resuming

    /// Reads what an earlier run left and decides how much of it to trust.
    /// A partial file the caller vouches for (``Download/adoption``) is first
    /// given the record Stoic would have written, so that it is read like any.
    ///
    /// The partial file is kept only if its record is whole and is this
    /// download's, it is not larger than the file or the limit, and there is
    /// something to resume it by (a validator, or a digest that will say if the
    /// splice was wrong). It is then cut back to what the record says is
    /// durable, and its bytes are hashed once to bring the digest up to the
    /// offset the request will resume from.
    private func resume(_ state: inout State) async throws(Stop) {
        try Adoption.adopt(download, disk: disk, label: label)
        let partial = download.partialPath
        guard try disk.exists(partial) else {
            try disk.removeIfPresent(download.resumeRecordPath)
            return
        }
        let found = try disk.readRecord(download.resumeRecordPath)
        let record: ResumeRecord
        switch found {
        case .found(let bytes):
            guard let decoded = ResumeRecord(decoding: bytes) else { return try discard(&state, reason: "record_invalid") }
            record = decoded
        case .missing:
            return try discard(&state, reason: "record_missing")
        case .corrupt:
            return try discard(&state, reason: "record_invalid")
        }
        guard record.identity == identity else { return try discard(&state, reason: "different_download") }

        let file = try disk.open(partial, .readWrite)
        state.file = file
        let size = try disk.size(of: file)
        if let expected = download.expectedSize, size > expected { return try discard(&state, reason: "larger_than_expected") }
        if size > download.byteLimit { return try discard(&state, reason: "larger_than_limit") }
        let trusted = min(size, record.synced)
        guard trusted > 0 else { return try discard(&state, reason: "nothing_synced") }
        guard record.validator != nil || download.digest != nil else { return try discard(&state, reason: "nothing_to_resume_by") }
        if size > trusted { try disk.truncate(file, to: trusted) }

        if var hasher = state.hasher {
            report(.verifying, state)
            let total = record.total ?? download.expectedSize
            let readable = try await disk.hash(file, count: trusted, into: &hasher) { hashed in
                progress.report(.verifying, fileBytes: hashed, fileTotal: total)
            }
            guard readable else { return try discard(&state, reason: "unreadable") }
            state.hasher = hasher
        }
        state.offset = trusted
        state.flushed = trusted
        state.synced = trusted
        state.validator = record.validator
        state.total = record.total
        state.resumedFrom = trusted
        self.record(Event("download.resumed", level: .info, label: label, fields: fields + [
            .init("offset", .int(trusted)),
            .init("discarded", .int(size - trusted)),
        ]))
    }

    /// Deletes the partial file and its record: what is in them is not a
    /// prefix of the file being fetched, or cannot be shown to be.
    private func discard(_ state: inout State, reason: String) throws(Stop) {
        let discarded = state.offset
        if let file = state.file {
            state.file = nil
            try disk.close(file)
        }
        try disk.removeIfPresent(download.resumeRecordPath)
        try disk.removeIfPresent(download.partialPath)
        state.offset = 0
        state.flushed = 0
        state.synced = 0
        state.buffer.removeAll(keepingCapacity: true)
        state.hasher = makeHasher()
        state.validator = nil
        state.total = nil
        state.resumedFrom = 0
        record(Event("download.restarted", level: .notice, label: label, fields: fields + [
            .init("reason", .string(reason), privacy: .public),
            .init("discarded", .int(discarded)),
        ]))
    }

    private var identity: String { download.resumeIdentity }

    // MARK: Space

    /// Refuses to start a download the volume cannot hold. A volume that does
    /// not say how much room it has is not a reason to refuse.
    private func preflightSpace(_ state: State) throws(Stop) {
        let required: UInt64
        if let explicit = download.requiredFreeBytes {
            required = explicit
        } else if let expected = download.expectedSize, expected > state.offset {
            required = UInt64(expected - state.offset) + policy.freeSpaceMargin
        } else {
            return
        }
        guard required > 0, let available = disk.freeSpace(at: Paths.directory(of: download.partialPath)) else { return }
        guard available >= required else { throw Stop(.insufficientSpace(required: required, available: available)) }
    }

    // MARK: Fetching

    /// Requests the file until the partial file holds all of it.
    ///
    /// An interruption (a cut, a busy server) is waited out on the policy's
    /// schedule, which starts over when a request got any bytes. What the
    /// schedule's delays are for is a server that is not answering; a download
    /// that is moving is only ever one first step behind.
    private func fetch(_ state: inout State) async throws(Stop) {
        let clock = Ambient.current.clock
        var stepper = policy.schedule.makeStepper(random: Ambient.current.random.generator())
        var stepperStart = clock.now
        var restartsWithoutBytes = 0
        while true {
            // Whole already: a crash after the last byte, or a record that says so.
            if let expected = download.expectedSize, state.offset > 0, state.offset == expected { return }
            let before = state.offset
            switch try await attempt(&state) {
            case .complete:
                return
            case .restart:
                restartsWithoutBytes += 1
                guard restartsWithoutBytes <= 2 else {
                    throw Stop(.badResponse(status: 206, reason: "the server keeps answering a range request with the wrong range"))
                }
            case .interrupted(let interruption):
                if state.offset > before {
                    // Bytes arrived: this is a new trouble, not the old one going on.
                    stepper = policy.schedule.makeStepper(random: Ambient.current.random.generator())
                    stepperStart = clock.now
                    restartsWithoutBytes = 0
                }
                try checkpoint(&state)
                // Every byte arrived and then the connection died: nothing is left to ask for.
                if let expected = download.expectedSize, state.offset == expected { return }
                guard let delay = stepper.next(elapsed: stepperStart.duration(to: clock.now)) else {
                    throw Stop(.retriesExhausted(attempts: state.requests, last: interruption.last))
                }
                let wait = max(delay, interruption.retryAfter ?? .zero)
                if let deadline = Deadline.current, deadline.remaining < wait { throw Stop(.deadlineExceeded) }
                record(Event("download.retry", level: .info, label: label, fields: fields + [
                    .init("attempt", .int(state.requests + 1)),
                    .init("delay", .duration(wait)),
                    .init("reason", .string(interruption.reason), privacy: .public),
                    .init("bytes", .int(state.offset)),
                ]))
                report(.waiting, state)
                do {
                    try await Ambient.sleep(for: wait)
                } catch {
                    throw Stop.cancellation
                }
            }
        }
    }

    /// One request, and as much of its body as arrives.
    private func attempt(_ state: inout State) async throws(Stop) -> Outcome {
        var request = download.request
        request.headers["Range"] = nil
        request.headers["If-Range"] = nil
        if state.offset > 0 {
            request.headers["Range"] = "bytes=\(state.offset)-"
            if let validator = state.validator { request.headers["If-Range"] = validator.value }
        }
        state.requests += 1
        report(.waiting, state)
        let response: HTTPStreamedResponse
        do {
            // The limit asked of the transport is the whole file's, not what is left of it: a server that
            // answers a range request with the whole file (it ignored the range) is answering properly,
            // and the file starts over. The bytes of a partial answer are counted against it here.
            response = try await client.stream(request, maxBytes: download.byteLimit, accepting: [416], overrides: Self.oneAttempt)
        } catch {
            return .interrupted(try interruption(for: error, state))
        }

        switch response.status {
        case 416:
            response.body.cancel()
            let known = download.expectedSize ?? ContentRange.unsatisfiedTotal(response.headers["Content-Range"])
            if state.offset > 0, known == state.offset { return .complete }
            guard state.offset > 0 else {
                throw Stop(.badResponse(status: 416, reason: "a request for the whole file is not a range that cannot be satisfied"))
            }
            try discard(&state, reason: "range_not_satisfiable")
            return .restart

        case 206:
            guard state.offset > 0 else {
                response.body.cancel()
                throw Stop(.badResponse(status: 206, reason: "a partial answer to a request for the whole file"))
            }
            guard let range = ContentRange(response.headers["Content-Range"]) else {
                response.body.cancel()
                throw Stop(.badResponse(status: 206, reason: "no readable Content-Range"))
            }
            guard range.start == state.offset else {
                response.body.cancel()
                try discard(&state, reason: "range_mismatch")
                return .restart
            }
            // A server that honoured `If-Range` answered 206 only for the version we hold; one that
            // cannot be asked (a redirect dropped the header) is told apart by what it says it is.
            if let held = state.validator, let sent = Validator(response.headers), sent != held {
                response.body.cancel()
                try discard(&state, reason: "validator_changed")
                return .restart
            }
            if let total = range.total { try note(total: total, state: &state, response: response) }
            // The span is the body this answer may contain. `Content-Length` can
            // be longer (a transport delivers what it says), and the file's total
            // is further on: writing past the span splices those bytes in.
            return try await consume(response.body, &state, declaredEnd: Self.exclusiveEnd(range.end), status: response.status)

        case 200:
            if state.offset > 0 {
                let changed = state.validator.map { held in Validator(response.headers).map { $0 != held } ?? false } ?? false
                try discard(&state, reason: changed ? "validator_changed" : "range_ignored")
            }
            if let length = response.headers["Content-Length"].flatMap({ Int($0) }) {
                try note(total: length, state: &state, response: response)
            }
            try begin(&state, response: response)
            return try await consume(response.body, &state, declaredEnd: state.total, status: response.status)

        default:
            response.body.cancel()
            throw Stop(.badResponse(status: response.status, reason: "a success that is not the file"))
        }
    }

    /// `end + 1` for an inclusive range end, or nil when that offset does not
    /// fit in `Int` (the range already covers every representable byte).
    private static func exclusiveEnd(_ inclusive: Int) -> Int? {
        let (end, overflow) = inclusive.addingReportingOverflow(1)
        return overflow ? nil : end
    }

    /// Records the file's size as a response gave it, and refuses a file that
    /// is not the size it was pinned to, or is past the limit.
    private func note(total: Int, state: inout State, response: HTTPStreamedResponse) throws(Stop) {
        if let expected = download.expectedSize, expected != total {
            response.body.cancel()
            throw Stop(.sizeMismatch(expected: expected, reported: total))
        }
        if total > download.byteLimit {
            response.body.cancel()
            throw Stop(.byteLimitExceeded(limit: download.byteLimit))
        }
        state.total = total
    }

    /// Starts a file from its first byte: the partial file is created empty,
    /// and its record says which version of the file is about to be written
    /// in it, before the first byte is.
    private func begin(_ state: inout State, response: HTTPStreamedResponse) throws(Stop) {
        let file = try openPartial(&state)
        if try disk.size(of: file) > 0 { try disk.truncate(file, to: 0) }
        state.validator = Validator(response.headers)
        state.synced = 0
        try writeRecord(state)
    }

    private func openPartial(_ state: inout State) throws(Stop) -> OpenFile {
        if let file = state.file { return file }
        let existed = try disk.exists(download.partialPath)
        let file = try disk.open(download.partialPath, .readWriteCreate)
        if !existed { try disk.setPermissions(file, to: download.fileMode) }
        state.file = file
        return file
    }

    /// Reads the body to its end, hashing and writing as it comes.
    ///
    /// `declaredEnd` is the file offset this response must not write past: the
    /// `Content-Length` of a `200`, or one past the last byte of a `206`'s
    /// `Content-Range`. Nil when the server declared neither. A body that ends
    /// short of it is a cut; a body that runs past it is not the file the
    /// headers named, and is not placed.
    private func consume(_ body: HTTPBodyStream, _ state: inout State, declaredEnd: Int?, status: Int) async throws(Stop) -> Outcome {
        do {
            for try await chunk in body {
                if Task.isCancelled { throw Stop.cancellation }
                // Bytes past the limit are not kept, even to see how many there are.
                if state.offset + chunk.count > download.byteLimit { throw Stop(.byteLimitExceeded(limit: download.byteLimit)) }
                // A chunk past the declared end is not part of the file. Refusing
                // the whole chunk keeps those bytes out of the partial file and
                // the hash.
                if let declaredEnd, Self.passes(declaredEnd, adding: chunk.count, at: state.offset) {
                    throw Stop(.badResponse(status: status, reason: "the body is longer than the length the server declared"))
                }
                state.buffer.append(contentsOf: chunk)
                state.hasher?.update(chunk)
                state.offset += chunk.count
                if state.buffer.count >= policy.writeBufferBytes { try flush(&state) }
                if state.flushed - state.synced >= policy.checkpointBytes { try checkpoint(&state) }
                report(.downloading, state)
            }
        } catch let stop as Stop {
            body.cancel()
            throw stop
        } catch {
            body.cancel()
            return .interrupted(try interruption(for: error, state))
        }
        try flush(&state)
        report(.downloading, state)
        // A body that ends without an error but before the end of the file is
        // a cut like any other. A body longer than declared never reaches here.
        if let total = state.total ?? download.expectedSize, state.offset < total {
            return .interrupted(Interruption(
                last: .transport(.networkConnectionLost, attempts: state.requests), retryAfter: nil, reason: "short_body"))
        }
        return .complete
    }

    /// `true` when writing `count` bytes at `offset` would pass `end`
    /// (exclusive). Compared by subtraction so a large offset cannot overflow.
    private static func passes(_ end: Int, adding count: Int, at offset: Int) -> Bool {
        if offset >= end { return count > 0 }
        return count > end - offset
    }

    /// What a failed request or body means: worth asking again (an
    /// interruption), or final (a stop).
    private func interruption(for error: any Error, _ state: State) throws(Stop) -> Interruption {
        if error is CancellationError { throw Stop.cancellation }
        guard let error = error as? HTTPError else {
            return Interruption(last: .transport(.unknown, attempts: state.requests), retryAfter: nil, reason: "unknown")
        }
        switch error {
        case .responseTooLarge:
            throw Stop(.byteLimitExceeded(limit: download.byteLimit))
        case .rejected(let rejection, _):
            if rejection.reason == .deadlineExceeded { throw Stop(.deadlineExceeded) }
            if rejection.isCancellation { throw Stop.cancelled }
        default:
            break
        }
        let reason = Self.reason(for: error)
        switch error.retryDecision {
        case .retry:
            return Interruption(last: error, retryAfter: nil, reason: reason)
        case .retryAfter(let wait):
            return Interruption(last: error, retryAfter: min(wait, client.policy.maxRetryAfter), reason: reason)
        case .stop:
            throw Stop(.http(error))
        }
    }

    /// A short, public description of a failure for events: never a body,
    /// a URL or a header.
    private static func reason(for error: HTTPError) -> String {
        switch error {
        case .status(let code, _, _, _, _): "status_\(code)"
        case .transport(let code, _): "transport_\(code.rawValue)"
        case .timedOut: "timed_out"
        case .rejected(let rejection, _): "rejected_\(rejection.reason)"
        default: "failed"
        }
    }

    // MARK: Durability

    /// Writes what is buffered at the end of the partial file.
    private func flush(_ state: inout State) throws(Stop) {
        guard !state.buffer.isEmpty else { return }
        let file = try openPartial(&state)
        try disk.write(file, state.buffer, at: state.flushed)
        state.flushed += state.buffer.count
        state.buffer.removeAll(keepingCapacity: true)
    }

    /// Makes what has been received durable, and *then* says so in the record:
    /// the record must never vouch for bytes a power cut can still take.
    private func checkpoint(_ state: inout State) throws(Stop) {
        try flush(&state)
        guard let file = state.file, state.flushed > state.synced else { return }
        try disk.fullSync(file)
        state.synced = state.flushed
        try writeRecord(state)
    }

    private func writeRecord(_ state: State) throws(Stop) {
        let record = ResumeRecord(identity: identity, validator: state.validator, synced: state.synced, total: state.total)
        if try !disk.writeRecord(record.encoded(), to: download.resumeRecordPath) {
            self.record(Event("download.durability_unknown", level: .warning, label: label, fields: fields + [
                .init("what", .string("resume_record"), privacy: .public),
            ]))
        }
    }

    // MARK: Verifying and placing

    private enum Verdict {
        case verified
        /// The digest was wrong; the partial file is gone and the file is to be fetched again.
        case refetch
    }

    private func verify(_ state: inout State) throws(Stop) -> Verdict {
        guard let digest = download.digest, let hasher = state.hasher else { return .verified }
        report(.verifying, state)
        let actual = hasher.hex
        if actual == digest.hex {
            record(Event("download.verified", level: .info, label: label, fields: fields + [
                .init("bytes", .int(state.offset)),
                .init("algorithm", .string(digest.algorithm.rawValue), privacy: .public),
                .init("attempts", .int(state.verifications + 1)),
            ]))
            return .verified
        }
        state.verifications += 1
        record(Event("download.verification_failed", level: .warning, label: label, fields: fields + [
            .init("algorithm", .string(digest.algorithm.rawValue), privacy: .public),
            .init("attempt", .int(state.verifications)),
            .init("expected", .string(digest.hex), privacy: .public),
            .init("actual", .string(actual), privacy: .public),
        ]))
        let attempts = state.verifications
        guard attempts < policy.verificationAttempts else {
            try discardQuietly(&state)
            throw Stop(.digestMismatch(expected: digest, actual: actual, attempts: attempts))
        }
        try discard(&state, reason: "verification_failed")
        return .refetch
    }

    /// Makes the verified file durable and moves it over the destination.
    ///
    /// The file's data is `fullSync`ed first, then it is renamed, then the
    /// directory is synced: a rename is atomic only once the directory is, and
    /// a crash at any step leaves the old file or the new one at the
    /// destination, never half of one. A directory sync that fails *after*
    /// the rename leaves the file in place and every reader seeing it; that is
    /// reported (`download.durability_unknown`, `isDurable`), not thrown,
    /// because failing a download whose file is where it should be would only
    /// make the caller do it again.
    private func place(_ state: inout State) throws(Stop) -> Bool {
        report(.placing, state)
        let file = try openPartial(&state)
        try disk.fullSync(file)
        state.file = nil
        try disk.close(file)
        try disk.rename(from: download.partialPath, to: download.destination)
        var durable = true
        do throws(Stop) {
            try disk.syncDirectory(Paths.directory(of: download.destination))
            if Paths.directory(of: download.partialPath) != Paths.directory(of: download.destination) {
                try disk.syncDirectory(Paths.directory(of: download.partialPath))
            }
        } catch {
            durable = false
            record(Event("download.durability_unknown", level: .warning, label: label, fields: fields + [
                .init("what", .string("file"), privacy: .public),
            ]))
        }
        removeLeftover(download.resumeRecordPath)
        record(Event("download.placed", level: .info, label: label, fields: fields + [
            .init("bytes", .int(state.offset)),
            .init("durable", .bool(durable)),
        ]))
        return durable
    }

    /// Removes a file that is no longer needed. Failing to is reported, not
    /// thrown: the next run finds it and removes it.
    private func removeLeftover(_ path: String) {
        do throws(Stop) {
            try disk.removeIfPresent(path)
        } catch {
            record(Event("download.cleanup_failed", level: .warning, label: label, fields: fields + [
                .init("what", .string("leftover"), privacy: .public),
            ]))
        }
    }

    // MARK: Ending

    /// What a transfer leaves behind when it stops.
    ///
    /// Bytes that arrived are made durable (and recorded) so that the next
    /// run resumes from them, unless they are no use (they failed their
    /// digest, or went past the limit) or the caller asked that a cancelled
    /// download leave nothing. Failing to do so is reported, never thrown: the
    /// error that stopped the transfer is the one to report.
    private func wind(down stop: Stop, _ state: inout State) {
        let keeps: Bool
        switch stop {
        case .cancelled: keeps = download.keepsPartialOnCancel
        case .failed(let error): keeps = !error.invalidatesPartial
        }
        do throws(Stop) {
            if keeps {
                try checkpoint(&state)
                if let file = state.file {
                    state.file = nil
                    try disk.close(file)
                }
            } else {
                try discardQuietly(&state)
            }
        } catch {
            record(Event("download.cleanup_failed", level: .warning, label: label, fields: fields + [
                .init("what", .string(keeps ? "checkpoint" : "discard"), privacy: .public),
            ]))
        }
        switch stop {
        case .cancelled:
            record(Event("download.cancelled", level: .info, label: label, fields: fields + [
                .init("bytes", .int(state.offset)),
                .init("kept", .bool(keeps)),
            ]))
        case .failed(let error):
            record(Event("download.failed", level: .warning, label: label, fields: fields + [
                .init("kind", .string(error.kind), privacy: .public),
                .init("error", .string(String(describing: error))),
                .init("bytes", .int(state.offset)),
                .init("kept", .bool(keeps)),
            ]))
        }
    }

    /// Deletes the partial file and its record without reporting a restart.
    private func discardQuietly(_ state: inout State) throws(Stop) {
        if let file = state.file {
            state.file = nil
            try disk.close(file)
        }
        try disk.removeIfPresent(download.resumeRecordPath)
        try disk.removeIfPresent(download.partialPath)
        state.offset = 0
    }
}
#endif

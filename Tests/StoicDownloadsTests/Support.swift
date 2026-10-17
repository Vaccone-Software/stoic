#if STOIC_CRYPTO
import Crypto
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Testing

/// Bytes that cannot be mistaken for each other: a xorshift stream, so a
/// splice at the wrong offset, a repeated block or a truncation changes the file.
func fileBytes(_ count: Int, seed: UInt64 = 1) -> [UInt8] {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    return bytes
}

/// The digests, computed with Crypto directly, not with the code under test.
func sha256Hex(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

func gitBlobHex(_ bytes: [UInt8]) -> String {
    var hasher = Insecure.SHA1()
    hasher.update(data: Array("blob \(bytes.count)\0".utf8))
    hasher.update(data: bytes)
    return hasher.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

func sha256(_ bytes: [UInt8]) throws -> ContentDigest { try .sha256(sha256Hex(bytes)) }

extension DownloadPolicy {
    /// A policy a test can predict: a backoff of 10 s, 20 s, 40 s… with no
    /// jitter, and small buffers, so a few kilobytes cross every threshold.
    static func testing(
        schedule: Schedule = Schedule.exponential(base: .seconds(10)).capped(at: .seconds(300)).unjittered(),
        verificationAttempts: Int = 2,
        progressInterval: Duration = .milliseconds(500),
        checkpointBytes: Int = 2_000,
        writeBufferBytes: Int = 500,
        freeSpaceMargin: UInt64 = 1_000
    ) -> DownloadPolicy {
        DownloadPolicy(
            schedule: schedule, verificationAttempts: verificationAttempts, progressInterval: progressInterval,
            checkpointBytes: checkpointBytes, writeBufferBytes: writeBufferBytes, freeSpaceMargin: freeSpaceMargin)
    }
}

let modelsBase = URL(string: "https://models.example.com")!

extension HTTPPolicy {
    /// The client's policy in these tests: its attempt timeout, which sleeps on the virtual clock for
    /// the length of every request, is 7 s, so that no timer left over from a request that is over (a
    /// cancelled sleep leaves the clock a moment after it is cancelled) is ever due at the same
    /// instant as a backoff of the downloader's, 10 s, which a test waits for by its deadline.
    static var forDownloadTests: HTTPPolicy { HTTPPolicy(attemptTimeout: .seconds(7)) }
}

/// A downloader on a scripted server, a simulated disk and a virtual clock,
/// with the events it recorded.
final class Harness: Sendable {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let transport = ScriptedTransport()
    let disk: SimulatedFileSystem
    let client: HTTPClient
    let downloader: Downloader

    /// - Parameter through: What the downloader sees of the disk: the simulated one itself, or a
    ///   wrapper that fails something (`FaultingFileSystem`). The tests read the disk directly.
    init(
        disk: SimulatedFileSystem = SimulatedFileSystem(), policy: DownloadPolicy = .testing(), httpPolicy: HTTPPolicy = .forDownloadTests,
        operation: Backend.Operation? = nil, through: (SimulatedFileSystem) -> any FileSystem = { $0 }
    ) {
        self.disk = disk
        client = HTTPClient(base: modelsBase, policy: httpPolicy, transport: transport)
        downloader = Downloader(client: client, fileSystem: through(disk), policy: policy, label: "test", operation: operation)
    }

    /// A downloader of the same server over another disk, as after a restart.
    func restarted(on disk: SimulatedFileSystem, policy: DownloadPolicy = .testing()) -> Downloader {
        Downloader(client: client, fileSystem: disk, policy: policy, label: "test")
    }

    /// Starts a download on its own task, which inherits the test's ambient context.
    func start(_ download: Download, progress: (@Sendable (DownloadProgress) -> Void)? = nil) -> Task<DownloadResult, any Error> {
        let downloader = downloader
        return Task { try await downloader.download(download, progress: progress) }
    }

    /// Waits until the download is waiting out a backoff of exactly `delay`,
    /// and moves the clock past it. Not "until something sleeps": the client's
    /// attempt timeout sleeps too, and a count of sleepers cannot say which
    /// sleeper it is waiting for.
    func waitOutBackoff(_ delay: Duration) async {
        await elapse(delay)
    }

    /// Waits for the download's next backoff, whatever its length (the event
    /// that announces it says), moves the clock past it, and returns how long it was.
    /// `seen` is how many `download.retry` events there were before.
    @discardableResult
    func waitOutNextBackoff(after seen: Int) async -> Duration {
        await eventually("the download never began backoff \(seen + 1)") { events.count("download.retry") > seen }
        let delay = events.events(named: "download.retry")[seen].duration("delay") ?? .zero
        await elapse(delay)
        return delay
    }

    /// Waits until something sleeps for exactly `delay` from now (a backoff, a
    /// chunk's delay), then moves the clock that far.
    func elapse(_ delay: Duration) async {
        let due = clock.now.advanced(by: delay)
        await eventually("nothing was asleep until \(due): \(clock.summary)") { clock.pendingDeadlines.contains(due) }
        await clock.advance(to: due)
    }

    func contents(_ path: String) -> [UInt8]? { disk.contents(of: path) }
}

func withHarness<R>(
    disk: SimulatedFileSystem = SimulatedFileSystem(), policy: DownloadPolicy = .testing(), httpPolicy: HTTPPolicy = .forDownloadTests,
    operation: Backend.Operation? = nil, through: (SimulatedFileSystem) -> any FileSystem = { $0 }, _ body: (Harness) async throws -> R
) async throws -> R {
    let harness = Harness(disk: disk, policy: policy, httpPolicy: httpPolicy, operation: operation, through: through)
    return try await withTestAmbient(clock: harness.clock, seed: 11, events: harness.events) { () async throws -> R in
        try await body(harness)
    }
}

typealias Step = ScriptedTransport.Step
typealias Resource = ScriptedTransport.Resource

let modelPath = "/models/model.bin"
let partialPath = "/models/model.bin.partial"
let recordPath = "/models/model.bin.partial.resume"

/// A download of `/model.bin` to `/models/model.bin`.
func download(
    _ bytes: [UInt8], digest: Bool = true, expectedSize: Bool = true, keepsPartialOnCancel: Bool = true, byteLimit: Int? = nil,
    requiredFreeBytes: UInt64? = nil, mode: UInt16 = 0o600
) throws -> Download {
    Download(
        HTTPRequest.get("/model.bin"), to: modelPath, expectedSize: expectedSize ? bytes.count : nil,
        digest: digest ? try sha256(bytes) : nil, byteLimit: byteLimit, keepsPartialOnCancel: keepsPartialOnCancel,
        fileMode: mode, requiredFreeBytes: requiredFreeBytes)
}

extension Event {
    func text(_ key: String) -> String? {
        if case .string(let value)? = self[key] { value } else { nil }
    }

    func number(_ key: String) -> Int? {
        if case .int(let value)? = self[key] { value } else { nil }
    }

    func flag(_ key: String) -> Bool? {
        if case .bool(let value)? = self[key] { value } else { nil }
    }

    func duration(_ key: String) -> Duration? {
        if case .duration(let value)? = self[key] { value } else { nil }
    }
}

extension RecordingInstrumentation {
    func count(_ name: EventName) -> Int { events(named: name).count }

    /// The reasons of every `download.restarted` event, in order.
    var restartReasons: [String] { events(named: "download.restarted").compactMap { $0.text("reason") } }
}

/// The error a download ended with, or `nil` if it succeeded.
func failure(of task: Task<DownloadResult, any Error>) async -> (any Error)? {
    do {
        _ = try await task.value
        return nil
    } catch {
        return error
    }
}

/// Polls `condition` until it holds, or fails the test after `timeout` of real time.
func eventually(
    timeout: Duration = .seconds(10), _ message: @autoclosure () -> String = "the condition never became true",
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= limit {
            Testing.Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
            return
        }
        // stoic:allow(discarded-try): a cancelled poll just checks the condition once more
        try? await clock.sleep(for: .milliseconds(1))
    }
}
#endif

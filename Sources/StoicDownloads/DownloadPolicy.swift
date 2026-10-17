#if STOIC_CRYPTO
public import Stoic

/// Every number a ``Downloader``'s behaviour is made of.
public struct DownloadPolicy: Sendable {
    /// How long to wait before asking again after a request fails, a
    /// connection is cut, or the server says it is busy: a Stoic `Schedule`
    /// stepped on the ambient clock, which starts over whenever a request got
    /// any bytes, so a download that is progressing between cuts never waits
    /// longer than the first step, and one that is getting nowhere backs off.
    /// Default: 10 s doubling to 300 s, with the lower half of each wait kept
    /// (equal jitter), and no bound on attempts: a model that takes a day on
    /// a bad connection is a download, and the caller's deadline is what ends
    /// one that should not take that long. A schedule with `.attempts(n)`
    /// ends with ``DownloadError/retriesExhausted(attempts:last:)``.
    public var schedule: Schedule

    /// How many times the file is fetched from the start before a digest
    /// mismatch is final. Default 2: when the digest is wrong the file is
    /// deleted and fetched again from zero once (a resumed prefix that was
    /// damaged is the commonest cause), and a second mismatch is
    /// ``DownloadError/digestMismatch(expected:actual:attempts:)``. 1 means
    /// no second try.
    public var verificationAttempts: Int

    /// The shortest time between two progress reports of the same phase, on
    /// the ambient clock. Default 0.5 s. A change of phase is always reported.
    public var progressInterval: Duration

    /// How many bytes may be written to the partial file before it is made
    /// durable (`fullSync`) and its resume record updated. Default 64 MiB. What
    /// follows the last checkpoint is not trusted by the next run: after a
    /// crash it resumes from the checkpoint, so this is also the most a power
    /// loss costs. (A cancelled or interrupted download checkpoints at once.)
    public var checkpointBytes: Int

    /// How many bytes are gathered before a write to the partial file; a
    /// transport's chunks are 16 to 64 KiB, and a system call for each would
    /// be a million of them for a 20 GB file. Default 1 MiB.
    public var writeBufferBytes: Int

    /// The room to leave on the volume beyond what is left to fetch, when
    /// the download does not say how much space it needs. Default 16 MiB.
    public var freeSpaceMargin: UInt64

    public init(
        schedule: Schedule = DownloadPolicy.standardSchedule,
        verificationAttempts: Int = 2,
        progressInterval: Duration = .milliseconds(500),
        checkpointBytes: Int = 64 << 20,
        writeBufferBytes: Int = 1 << 20,
        freeSpaceMargin: UInt64 = 16 << 20
    ) {
        precondition(verificationAttempts >= 1, "a file is fetched at least once")
        precondition(progressInterval >= .zero, "an interval cannot be negative")
        precondition(checkpointBytes > 0 && writeBufferBytes > 0, "a download needs room for at least one byte")
        self.schedule = schedule
        self.verificationAttempts = verificationAttempts
        self.progressInterval = progressInterval
        self.checkpointBytes = checkpointBytes
        self.writeBufferBytes = writeBufferBytes
        self.freeSpaceMargin = freeSpaceMargin
    }

    /// The defaults described on each field.
    public static var standard: DownloadPolicy { DownloadPolicy() }

    /// 10 s doubling, capped at 300 s, equal jitter, unbounded.
    public static let standardSchedule: Schedule =
        Schedule.exponential(base: .seconds(10)).capped(at: .seconds(300)).jittered(.equal)
}
#endif

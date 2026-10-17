#if STOIC_CRYPTO

/// Where a download is: what it is doing, and how far it has got.
///
/// Reported to the callback given to ``Downloader/download(_:progress:)``, at
/// most once per ``DownloadPolicy/progressInterval`` for a phase, and at every
/// change of phase. The callback runs on the downloading task, inline: keep
/// it quick, or hand the value to something that is (an `AsyncStream`'s
/// `continuation.yield`, with `.bufferingNewest(1)`, is a one-line adapter).
public struct DownloadProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable, CustomStringConvertible {
        /// Not receiving: connecting, waiting for the server's answer, or
        /// waiting out a backoff after a failure.
        case waiting
        /// Bytes are arriving.
        case downloading
        /// Checking bytes against the digest: the partial file's prefix is
        /// read once when a download resumes, and the whole is compared when
        /// it is complete.
        case verifying
        /// The verified file is being made durable and moved into place.
        case placing

        public var description: String {
            switch self {
            case .waiting: "waiting"
            case .downloading: "downloading"
            case .verifying: "verifying"
            case .placing: "placing"
            }
        }
    }

    public var phase: Phase

    /// The file in progress, from 0; always 0 for a single download.
    public var fileIndex: Int

    /// How many files there are; 1 for a single download.
    public var fileCount: Int

    /// Bytes of the current file that are in hand, including those of an
    /// earlier run that a resume kept.
    public var fileBytes: Int

    /// The current file's size, if it is known.
    public var fileTotalBytes: Int?

    /// Bytes in hand across every file: those of the files already done and
    /// of the current one.
    public var bytesDone: Int

    /// The size of everything, if every file's size is known; for a single
    /// download, ``fileTotalBytes``.
    public var totalBytes: Int?

    public init(
        phase: Phase, fileIndex: Int = 0, fileCount: Int = 1, fileBytes: Int, fileTotalBytes: Int? = nil, bytesDone: Int,
        totalBytes: Int? = nil
    ) {
        self.phase = phase
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.fileBytes = fileBytes
        self.fileTotalBytes = fileTotalBytes
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
    }

    /// `bytesDone / totalBytes`, from 0 to 1, when the total is known.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return totalBytes == 0 ? 1 : nil }
        return min(1, Double(bytesDone) / Double(totalBytes))
    }
}
#endif

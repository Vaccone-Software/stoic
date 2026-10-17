#if STOIC_CRYPTO
/// A file that was downloaded, verified and placed.
public struct DownloadResult: Sendable, Hashable {
    /// Where the file is.
    public var path: String

    /// Its size in bytes.
    public var bytes: Int

    /// The digest it was verified against; `nil` if the download had none.
    public var verifiedDigest: ContentDigest?

    /// How many bytes of an earlier run's partial file were kept (0 when the
    /// download started from the beginning).
    public var resumedFrom: Int

    /// How many requests were made for it, a resume's and a retry's included;
    /// 0 for a file that was already whole and was only verified.
    public var requests: Int

    /// Whether the file is known to survive a power loss. `false` only when
    /// the file is in place and every reader sees it, but the directory sync
    /// that makes the move durable failed (`store.durabilityUnknown`): the
    /// downloader treats the file as placed, as design/15 says to treat any
    /// change whose sync failed, and says so here and in
    /// `download.durability_unknown`.
    public var isDurable: Bool

    public init(path: String, bytes: Int, verifiedDigest: ContentDigest?, resumedFrom: Int, requests: Int, isDurable: Bool) {
        self.path = path
        self.bytes = bytes
        self.verifiedDigest = verifiedDigest
        self.resumedFrom = resumedFrom
        self.requests = requests
        self.isDurable = isDurable
    }
}

/// A bundle of files that was downloaded, verified, and placed as one directory.
public struct DownloadBundleResult: Sendable, Hashable {
    /// The directory, now holding exactly the bundle's files.
    public var path: String

    /// One result for each of the bundle's files, in order. The `path` of
    /// each is where the file is now, inside ``path``.
    public var files: [DownloadResult]

    /// Whether the directory swap is known to survive a power loss; see
    /// ``DownloadResult/isDurable``.
    public var isDurable: Bool

    public init(path: String, files: [DownloadResult], isDurable: Bool) {
        self.path = path
        self.files = files
        self.isDurable = isDurable
    }
}
#endif

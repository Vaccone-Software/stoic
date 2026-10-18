#if STOIC_CRYPTO
public import Foundation
public import StoicHTTP

/// One file to fetch: where from, where to, and what it must turn out to be.
///
/// ```swift
/// let download = Download(
///     URL(string: "https://huggingface.co/org/model/resolve/main/model.safetensors")!,
///     to: "/Models/org/model.safetensors",
///     expectedSize: 3_600_000_000,
///     digest: try .sha256(manifest.sha256),
///     fileMode: 0o644)
/// ```
///
/// The bytes stream into ``partialPath``, are hashed as they arrive, and are
/// moved to ``destination`` only when they are the size and have the digest
/// the download says: a file at the destination is always a whole, verified
/// one, never half of one. A download that was interrupted (a lost
/// connection, a quit app, a power cut) resumes from the partial file the
/// next time it runs.
public struct Download: Sendable {
    /// The most bytes a download without an expected size may fetch, 32 GiB:
    /// a bound for the caller who has none in mind. Lodestar's largest model
    /// file is 20 GB.
    public static let defaultByteLimit = 32 << 30

    /// What to ask for. A path is resolved against the ``Downloader``'s
    /// client's base URL, as for any request. Its `Range` and `If-Range`
    /// headers are the downloader's, and are replaced.
    public var request: HTTPRequest

    /// Where the verified file goes. Its directory is created if it is missing.
    public var destination: String

    /// Where the bytes go while they arrive, on the destination's volume:
    /// `<destination>.partial` unless said. A resume record (validator,
    /// how much was synced) sits beside it as `<partialPath>.resume`.
    public var partialPath: String

    /// How many bytes the file has, if the caller knows (a manifest does).
    /// A server that says another size is ``DownloadError/sizeMismatch(expected:reported:)``;
    /// a partial file larger than this is discarded; and the free-space
    /// check can say how much is left to fetch.
    public var expectedSize: Int?

    /// What the file's bytes must hash to. Without one the file is placed
    /// unverified (its size is still checked), and a partial file with no
    /// validator to resume it by is not resumed: the digest is what makes
    /// resuming safe when the server cannot say the file is unchanged.
    public var digest: ContentDigest?

    /// The most bytes the body may have: ``expectedSize`` if there is one (a
    /// file longer than it is not the file), else ``defaultByteLimit``.
    public var byteLimit: Int

    /// Whether cancelling the download leaves the partial file for the next
    /// run to resume (the default), or deletes it. A deadline that passes is
    /// not a cancellation: the partial file stays.
    public var keepsPartialOnCancel: Bool

    /// The permission bits of the finished file, which is a new file: `0o600`
    /// by default, because a file a download made is private until the app
    /// says otherwise (the downloads of a signed-in user, an export). Pass
    /// `0o644` for what every user may read, a model, say. Set exactly, so the
    /// process's umask does not narrow them.
    public var fileMode: UInt16

    /// The free space the volume must have before the download starts, if
    /// the caller knows better than the default: what is left to fetch plus
    /// ``DownloadPolicy/freeSpaceMargin``, when ``expectedSize`` is known, and
    /// no check without one. `0` turns the check off.
    public var requiredFreeBytes: UInt64?

    /// - Parameters:
    ///   - request: What to ask for.
    ///   - destination: Where the verified file goes.
    ///   - expectedSize: The file's size in bytes, if known. Required with a
    ///     ``ContentDigest/Algorithm/gitBlobSHA1`` digest, which hashes the size
    ///     in before the first byte.
    ///   - digest: What the file must hash to.
    ///   - byteLimit: The most bytes to accept. Defaults to `expectedSize`, or
    ///     ``defaultByteLimit``; it must not be less than `expectedSize`.
    ///   - partialPath: Where the bytes arrive; `<destination>.partial` by default.
    ///   - keepsPartialOnCancel: Whether a cancelled download keeps its partial file.
    ///   - fileMode: The finished file's permission bits.
    ///   - requiredFreeBytes: The free space to insist on, overriding the default.
    public init(
        _ request: HTTPRequest,
        to destination: String,
        expectedSize: Int? = nil,
        digest: ContentDigest? = nil,
        byteLimit: Int? = nil,
        partialPath: String? = nil,
        keepsPartialOnCancel: Bool = true,
        fileMode: UInt16 = 0o600,
        requiredFreeBytes: UInt64? = nil
    ) {
        precondition(!destination.isEmpty, "a download needs a destination")
        precondition(expectedSize.map { $0 >= 0 } ?? true, "a file cannot have a negative size")
        precondition(
            digest?.algorithm.needsSize != true || expectedSize != nil,
            "a git blob digest hashes the file's size before its first byte: give the download its expected size")
        let limit = byteLimit ?? expectedSize ?? Self.defaultByteLimit
        precondition(limit >= (expectedSize ?? 0), "a byte limit below the expected size could never be met")
        let partial = partialPath ?? destination + ".partial"
        precondition(partial != destination, "the partial file cannot be the destination")
        self.request = request
        self.destination = destination
        self.partialPath = partial
        self.expectedSize = expectedSize
        self.digest = digest
        self.byteLimit = limit
        self.keepsPartialOnCancel = keepsPartialOnCancel
        self.fileMode = fileMode
        self.requiredFreeBytes = requiredFreeBytes
    }

    /// A download of `url`.
    public init(
        _ url: URL,
        to destination: String,
        expectedSize: Int? = nil,
        digest: ContentDigest? = nil,
        byteLimit: Int? = nil,
        partialPath: String? = nil,
        keepsPartialOnCancel: Bool = true,
        fileMode: UInt16 = 0o600,
        requiredFreeBytes: UInt64? = nil
    ) {
        self.init(
            HTTPRequest.get(url), to: destination, expectedSize: expectedSize, digest: digest, byteLimit: byteLimit,
            partialPath: partialPath, keepsPartialOnCancel: keepsPartialOnCancel, fileMode: fileMode,
            requiredFreeBytes: requiredFreeBytes)
    }

    /// A partial file that something other than Stoic wrote, to be resumed
    /// if there is no partial file of the downloader's own; see
    /// ``adoptingUnrecordedPartial(at:validator:)``.
    public var adoption: PartialAdoption?

    /// This download, resuming a partial file that Stoic did not write: an
    /// earlier program's half-fetched file, or one a user copied in.
    ///
    /// A partial file is resumed only with a record of which download it
    /// belongs to and how much of it is durable, and one without is deleted.
    /// This is the caller's *assurance* in place of the record: the file at
    /// `path` holds the first bytes of the file this download names (its
    /// request, ``expectedSize`` and ``digest``). The downloader makes those
    /// bytes durable, writes the record, moves the file to ``partialPath``
    /// and resumes by `Range`. The assurance is believed, not trusted: the
    /// digest, computed over the adopted bytes and the rest, still decides at
    /// the end, and a file that fails it is fetched again from nothing.
    ///
    /// - It needs something to resume by: a ``digest`` on the download, or a
    ///   `validator`, which goes in `If-Range`, so that a server whose file
    ///   has changed answers the whole file. Without either the file is left
    ///   alone and `download.adoption_declined` says why.
    /// - It is for an *unrecorded* partial file only. If the downloader has a
    ///   partial file of its own with a record, that one is resumed and `path`
    ///   is not touched; `path` may be the ``partialPath`` itself, a partial
    ///   file with no record.
    /// - A file that is empty, larger than ``expectedSize`` or ``byteLimit``
    ///   is declined, not deleted.
    /// - Its permission bits become ``fileMode``.
    ///
    /// - Parameters:
    ///   - path: The existing file.
    ///   - validator: The server's validator for the version the bytes came
    ///     from, if the caller kept it.
    public func adoptingUnrecordedPartial(at path: String, validator: PartialValidator? = nil) -> Download {
        var adopted = self
        adopted.adoption = PartialAdoption(path: path, validator: validator)
        return adopted
    }

    /// The sidecar that says what the partial file holds.
    var resumeRecordPath: String { partialPath + ".resume" }

    /// Which download a partial file belongs to: what was asked for, and
    /// what it must turn out to be. A hash, so a URL's query (a token, a signed
    /// signature) is never written to disk in the clear.
    var resumeIdentity: String {
        let described = "\(request.target)|\(expectedSize.map(String.init) ?? "-")|\(digest?.description ?? "-")"
        return ContentDigest(algorithm: .sha256, of: Array(described.utf8)).hex
    }
}
#endif

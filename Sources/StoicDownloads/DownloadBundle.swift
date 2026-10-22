#if STOIC_CRYPTO
public import Foundation
public import StoicHTTP

/// Several files that are one thing, fetched and placed as a directory: what a
/// model is.
///
/// The files are fetched one after another into a staging directory beside the
/// destination (`.<name>.partial/`), each resumable and verified as a single
/// ``Download`` is, and only when every one is in, the whole directory is
/// swapped over the destination in one step (`AtomicFile.replaceItem`), and the
/// old directory, if there was one, is removed once that swap is durable. At
/// every instant the destination is the old directory complete or the new
/// directory complete: a model is never half of itself. If the directory sync
/// after the swap fails, the download is placed with `isDurable == false` and
/// the staging path is left as the swap left it, so a crash can still finish
/// from that tree.
///
/// ```swift
/// let bundle = DownloadBundle(
///     manifest.files.map { DownloadBundle.File($0.path, baseURL.appending(path: $0.path), expectedSize: $0.size, digest: try .sha256($0.sha256)) },
///     to: "/Models/org/model",
///     fileMode: 0o644)
/// let result = try await downloader.download(bundle) { progress in model.progress = progress }
/// ```
///
/// An interrupted bundle resumes where it was: a file that is whole in the
/// staging directory, at its expected size and with a digest that checks, is
/// verified and not fetched again; a file that is part-way resumes by range; a
/// file that is missing is fetched; and anything else the staging directory
/// holds (a file from an earlier version of the bundle) is removed.
public struct DownloadBundle: Sendable {
    /// One file of a bundle.
    public struct File: Sendable {
        /// Where it goes, relative to the bundle's directory: `/`-separated,
        /// never absolute, never with `..`. A subdirectory is created as needed.
        public var path: String
        public var request: HTTPRequest
        /// The file's size, if known. A file already in the staging directory
        /// is reused only when it is known, and matches.
        public var expectedSize: Int?
        /// What the file must hash to. A file already in the staging directory
        /// is reused only when it has one, and the file checks.
        public var digest: ContentDigest?
        public var byteLimit: Int?

        /// Whether a file at this one's own name in the staging directory, short
        /// of the expected size, is a partial file the caller vouches for (see
        /// ``Download/adoptingUnrecordedPartial(at:validator:)``, which this is
        /// for a bundle): resumed instead of removed. Without it, anything at
        /// the name that is not whole and verified is removed.
        public var adoptsUnrecordedPartial = false

        /// The validator for an adopted file, as for ``Download/adoptingUnrecordedPartial(at:validator:)``.
        public var adoptedValidator: PartialValidator?

        /// This file, adopting an unrecorded partial file in the staging
        /// directory if there is one.
        public func adoptingUnrecordedPartial(validator: PartialValidator? = nil) -> File {
            var adopting = self
            adopting.adoptsUnrecordedPartial = true
            adopting.adoptedValidator = validator
            return adopting
        }

        public init(_ path: String, _ request: HTTPRequest, expectedSize: Int? = nil, digest: ContentDigest? = nil, byteLimit: Int? = nil) {
            precondition(!path.isEmpty && !path.hasPrefix("/") && !path.hasSuffix("/"), "a bundle file's path is relative: \(path)")
            precondition(
                !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." },
                "a bundle file's path stays inside the bundle: \(path)")
            self.path = path
            self.request = request
            self.expectedSize = expectedSize
            self.digest = digest
            self.byteLimit = byteLimit
        }

        public init(_ path: String, _ url: URL, expectedSize: Int? = nil, digest: ContentDigest? = nil, byteLimit: Int? = nil) {
            self.init(path, HTTPRequest.get(url), expectedSize: expectedSize, digest: digest, byteLimit: byteLimit)
        }
    }

    public var files: [File]

    /// The directory the files end up in. Its parent is created if missing.
    public var destination: String

    /// Where the files are gathered, on the destination's volume:
    /// `.<name>.partial` beside the destination unless said.
    public var stagingPath: String

    /// Whether cancelling leaves the staging directory, with every partial and
    /// finished file in it, for the next run (the default), or removes it.
    public var keepsPartialOnCancel: Bool

    /// The permission bits of each file, as for ``Download/fileMode``.
    public var fileMode: UInt16

    /// The free space to insist on before starting, for the whole bundle;
    /// by default what is left to fetch of every file whose size is known,
    /// and a margin. `0` turns the check off.
    public var requiredFreeBytes: UInt64?

    public init(
        _ files: [File],
        to destination: String,
        stagingPath: String? = nil,
        keepsPartialOnCancel: Bool = true,
        fileMode: UInt16 = 0o600,
        requiredFreeBytes: UInt64? = nil
    ) {
        precondition(!files.isEmpty, "a bundle has at least one file")
        precondition(Set(files.map(\.path)).count == files.count, "a bundle's files have distinct paths")
        precondition(!destination.isEmpty, "a bundle needs a destination")
        var destination = destination
        while destination.count > 1, destination.hasSuffix("/") { destination.removeLast() }
        let staging = stagingPath ?? Paths.join(Paths.directory(of: destination), "." + Paths.name(of: destination) + ".partial")
        precondition(staging != destination, "the staging directory cannot be the destination")
        self.files = files
        self.destination = destination
        self.stagingPath = staging
        self.keepsPartialOnCancel = keepsPartialOnCancel
        self.fileMode = fileMode
        self.requiredFreeBytes = requiredFreeBytes
    }
}
#endif

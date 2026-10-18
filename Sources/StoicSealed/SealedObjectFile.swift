#if STOIC_CRYPTO
internal import Stoic
public import StoicStore

/// A whole file sealed under a key the caller holds, one for each object:
/// what ``SealedFile`` is for a keyring's keys.
///
///     let key = SealingKey.generate()                       // kept inside a sealed record
///     let blobs = SealedObjectFile(options: .init(durability: .standard))
///     try blobs.write(bytes, to: path, context: SealContext("app.clip", id), key: key)
///     let bytes = try blobs.read(path, context: SealContext("app.clip", id), key: key)
///
/// A clipboard history, a mail store, a document with a key of its own: the
/// object stops being readable when its key is dropped (crypto-shredding with
/// no ring to rotate), and rotating a ring rewrites none of them. The key is
/// the caller's to keep, sealed under something else
/// (``SealingKey/exportedForWrapping()``); nothing here stores it.
///
/// The contract is ``SealedFile``'s with the key supplied for each call: an
/// `AtomicFile` write with no envelope, so the file is exactly the sealed value
/// and holds no plaintext at any instant; a new file is `0o600` with the mode
/// set before a byte is written; a file that is there and does not open is
/// reported (``SealedStoreError``: `.seal(.tampered)`, `.torn`, `.notSealed`,
/// `.unknownKey` for a file another key sealed) and left as it is. There is no
/// previous generation and no adoption: an object has one key, and a plaintext
/// file is for ``SealedFile/adopt(path:context:)``.
///
/// ``SealedFile/Options/durability`` says what a write costs. `.full` (the
/// default) is `F_FULLFSYNC` and a directory sync; `.standard` is plain `fsync`
/// and a rename, which a blob written beside every copy can afford, and which a
/// power loss may undo (the old value, or no file) but never tear.
public struct SealedObjectFile: Sendable {
    public let fileSystem: any FileSystem
    public let options: SealedFile.Options

    public init(fileSystem: any FileSystem = PosixFileSystem(), options: SealedFile.Options = SealedFile.Options()) {
        self.fileSystem = fileSystem
        self.options = options
    }

    private var atomicFile: AtomicFile {
        AtomicFile(fileSystem: fileSystem, options: .init(
            envelope: false, keepPrevious: false, checksFreeSpace: options.checksFreeSpace, newFileMode: options.newFileMode,
            durability: options.durability
        ))
    }

    /// Seals `plaintext` under `key`, bound to `context`, and replaces the file at
    /// `path` with it, atomically, as durably as ``SealedFile/Options/durability`` says.
    ///
    /// - Throws: ``SealedStoreError``: `.store` for the file system (with
    ///   `.full`, including `.durabilityUnknown`: the new file is in place, and
    ///   a power loss may undo it). A failed write leaves the old contents.
    public func write(_ plaintext: [UInt8], to path: String, context: SealContext, key: SealingKey) throws(SealedStoreError) {
        let sealed: [UInt8]
        do throws(SealError) {
            sealed = try Sealing.seal(plaintext, context: context, key: key)
        } catch {
            throw .seal(error)
        }
        do throws(StoreError) {
            try atomicFile.write(sealed, to: path)
        } catch {
            throw .store(error)
        }
    }

    /// The plaintext in the file at `path`, or `nil` if there is no file.
    ///
    /// - Throws: ``SealedStoreError``: `.seal(.notSealed)`, `.seal(.tampered)`,
    ///   `.seal(.torn)`, or `.seal(.unknownKey)` when the file was sealed under
    ///   another key; `.store` for the file system. The file is left as it is.
    public func read(_ path: String, context: SealContext, key: SealingKey) throws(SealedStoreError) -> [UInt8]? {
        let stored: AtomicFile.Contents?
        do throws(StoreError) {
            stored = try atomicFile.read(path)
        } catch {
            throw .store(error)
        }
        guard let stored else { return nil }
        do throws(SealError) {
            return try Sealing.open(stored.bytes, context: context, key: key)
        } catch {
            SealedEvents.record(Event("sealed.open_failed", level: .warning, fields: [
                .init("purpose", .string(context.purpose)), .init("kind", .string(error.label)), .init("source", .string("file")),
            ]))
            throw .seal(error)
        }
    }
}
#endif

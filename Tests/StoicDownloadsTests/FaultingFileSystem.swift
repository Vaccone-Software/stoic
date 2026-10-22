#if STOIC_CRYPTO
import Foundation
import StoicStore
import Synchronization

/// A file system that fails one thing at one path, on top of a simulated one:
/// a rename onto `renameTarget`, or the directory syncs that follow it. What a
/// test needs when "the third rename" is not a thing it can count on (how many
/// renames a download makes depends on its chunks and checkpoints), but "the
/// rename that places the file" is.
final class FaultingFileSystem: FileSystem {
    private struct State {
        var renamedTarget = false
    }

    let base: any FileSystem
    /// A rename onto this path fails with `renameError`.
    let renameTarget: String?
    let renameError: Int32
    /// Once a rename onto this path has happened, every directory sync fails with `EIO`.
    let syncFailsAfterRenameTo: String?
    /// Once two paths have been exchanged, every directory sync fails with `EIO`: the swap of a bundle.
    let syncFailsAfterExchange: Bool
    private let state = Mutex(State())

    init(
        _ base: any FileSystem, renameTarget: String? = nil, renameError: Int32 = EACCES, syncFailsAfterRenameTo: String? = nil,
        syncFailsAfterExchange: Bool = false
    ) {
        self.base = base
        self.syncFailsAfterExchange = syncFailsAfterExchange
        self.renameTarget = renameTarget
        self.renameError = renameError
        self.syncFailsAfterRenameTo = syncFailsAfterRenameTo
    }

    func rename(from source: String, to destination: String) throws(StoreError) {
        if destination == renameTarget { throw StoreError(errno: renameError, operation: "rename", path: destination) }
        try base.rename(from: source, to: destination)
        if destination == syncFailsAfterRenameTo { state.withLock { $0.renamedTarget = true } }
    }

    func syncDirectory(_ directory: String) throws(StoreError) {
        if state.withLock({ $0.renamedTarget }) { throw StoreError(errno: EIO, operation: "fsync", path: directory) }
        try base.syncDirectory(directory)
    }

    // Everything else is the simulated file system's.
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile { try base.open(path, mode: mode) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) { try base.setPermissions(file, to: permissions) }
    func readLink(_ path: String) throws(StoreError) -> String? { try base.readLink(path) }
    func exchange(_ first: String, _ second: String) throws(StoreError) {
        try base.exchange(first, second)
        if syncFailsAfterExchange { state.withLock { $0.renamedTarget = true } }
    }
    func removeTree(_ path: String) throws(StoreError) { try base.removeTree(path) }
    func tryLock(_ file: OpenFile) throws(StoreError) -> Bool { try base.tryLock(file) }
    func unlock(_ file: OpenFile) throws(StoreError) { try base.unlock(file) }
}
#endif

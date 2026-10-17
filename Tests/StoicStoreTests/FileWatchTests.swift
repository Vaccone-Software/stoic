import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// Counts the handler's calls, and wakes whoever waits for the next.
private final class Calls: Sendable {
    private let count = SendableBox(0)
    let stream: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() {
        (stream, signal) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    var value: Int { count.value }

    var handler: @Sendable () -> Void {
        { [count, signal] in
            count.mutate { $0 += 1 }
            signal.yield()
        }
    }

    /// Waits until the handler has been called more often than `before`.
    func waitForCall(after before: Int) async {
        var calls = stream.makeAsyncIterator()
        while value <= before { await calls.next() }
    }
}

@Suite("Watching a file (simulated)")
struct SimulatedFileWatchTests {
    static let path = "/d/prefs.json"

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    @Test(.failureMode("design/15", "the watched file is replaced by a rename"))
    func aFileReplacedByRenameIsReportedAndStillWatched() throws {
        let disk = try Self.disk()
        let file = AtomicFile(fileSystem: disk, options: .init(envelope: false))
        try file.write(bytes("one"), to: Self.path)
        let calls = Calls()
        let watch = try disk.watchFile(at: Self.path, handler: calls.handler)
        try file.write(bytes("two"), to: Self.path)   // temporary file, then rename over the path
        #expect(calls.value >= 1)
        let seen = calls.value
        try file.write(bytes("three"), to: Self.path)
        #expect(calls.value > seen, "the watch follows the new file")
        _ = watch
    }

    @Test(.failureMode("design/15", "the watched file does not exist yet"))
    func aFileThatDoesNotExistYetIsReportedWhenItAppears() throws {
        let disk = try Self.disk()
        let calls = Calls()
        let watch = try disk.watchFile(at: Self.path, handler: calls.handler)
        #expect(calls.value == 0)
        try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(bytes("hi"), to: Self.path)
        #expect(calls.value >= 1)
        _ = watch
    }

    @Test(.failureMode("design/15", "the watched file is written in place"))
    func aWriteInPlaceIsReported() throws {
        let disk = try Self.disk()
        try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(bytes("one"), to: Self.path)
        let calls = Calls()
        let watch = try disk.watchFile(at: Self.path, handler: calls.handler)
        let file = try disk.open(Self.path, mode: .readWrite)
        try disk.write(file, bytes("ONE"), at: 0)
        #expect(calls.value == 1)
        try disk.truncate(file, to: 1)
        #expect(calls.value == 2)
        try disk.close(file)
        try disk.remove(Self.path)
        #expect(calls.value == 3, "and so is its removal")
        _ = watch
    }

    @Test(.failureMode("design/15", "another file in the directory changes"))
    func otherFilesAreNotReportedByTheSimulation() throws {
        let disk = try Self.disk()
        let calls = Calls()
        let watch = try disk.watchFile(at: Self.path, handler: calls.handler)
        try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(bytes("x"), to: "/d/other.json")
        #expect(calls.value == 0)
        _ = watch
    }

    @Test(.failureMode("design/15", "the watch is cancelled or dropped"))
    func aCancelledOrDroppedWatchIsSilent() throws {
        let disk = try Self.disk()
        let file = AtomicFile(fileSystem: disk, options: .init(envelope: false))
        let cancelled = Calls()
        let watch = try disk.watchFile(at: Self.path, handler: cancelled.handler)
        watch.cancel()
        watch.cancel()   // harmless twice
        let dropped = Calls()
        var second: FileWatch? = try disk.watchFile(at: Self.path, handler: dropped.handler)
        second = nil
        try file.write(bytes("x"), to: Self.path)
        #expect(cancelled.value == 0)
        #expect(dropped.value == 0)
        _ = second
    }

    @Test func aWatchThroughALinkIsToTheFileItNames() throws {
        let disk = try Self.disk()
        try disk.createDirectory("/dotfiles")
        disk.symlink(at: Self.path, to: "/dotfiles/prefs.json")
        let calls = Calls()
        let watch = try disk.watchFile(at: Self.path, handler: calls.handler)
        // A write through the link replaces the file it names, beside itself.
        try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(bytes("x"), to: Self.path)
        #expect(calls.value >= 1)
        _ = watch
    }

    @Test(.failureMode("design/15", "the directory does not exist"))
    func aMissingDirectoryIsNotFound() throws {
        let disk = SimulatedFileSystem()
        let error = #expect(throws: StoreError.self) { try disk.watchFile(at: "/nowhere/prefs.json") {} }
        #expect(error?.kind == .notFound)
    }

    @Test(.failureMode("design/15", "the file system cannot report changes"))
    func aFileSystemThatCannotWatchSaysSo() throws {
        let error = #expect(throws: StoreError.self) { try WatchlessFileSystem().watchFile(at: "/d/prefs.json") {} }
        #expect(error?.kind == .unsupported)
    }
}

/// A file system that has not implemented `watchFile`, so has the default.
private struct WatchlessFileSystem: FileSystem {
    let base = SimulatedFileSystem()
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile { try base.open(path, mode: mode) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func syncDirectory(_ directory: String) throws(StoreError) { try base.syncDirectory(directory) }
    func rename(from source: String, to destination: String) throws(StoreError) { try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
}

/// The real thing: kqueue on Apple platforms, inotify on Linux. Each step
/// waits for the handler with no fixed sleep, under the test's time limit.
@Suite("Watching a file (real file system)")
struct PosixFileWatchTests {
    let fs = PosixFileSystem()

    /// Does `action`, then waits until the handler has been called after it.
    private func expectCall(_ calls: Calls, _ what: String, _ action: () throws -> Void) async throws {
        let before = calls.value
        try action()
        await calls.waitForCall(after: before)
    }

    @Test(
        .failureMode("design/15", "the watched file does not exist yet"),
        .failureMode("design/15", "the watched file is written in place"),
        .failureMode("design/15", "the watched file is replaced by a rename"),
        .timeLimit(.minutes(1))
    )
    func createWriteInPlaceAndReplaceAreAllReported() async throws {
        let dir = try TempDirectory()
        let path = dir.file("prefs.json")
        let file = AtomicFile(fileSystem: fs, options: .init(envelope: false))
        let calls = Calls()
        let watch = try fs.watchFile(at: path, handler: calls.handler)

        try await expectCall(calls, "created") { try file.write(bytes("one"), to: path) }
        try await expectCall(calls, "written in place, as an editor that truncates does") {
            let open = try fs.open(path, mode: .readWrite)
            try fs.write(open, bytes("ONE"), at: 0)
            try fs.close(open)
        }
        try await expectCall(calls, "replaced by a rename, as an editor that saves a new file does") {
            try file.write(bytes("two"), to: path)
        }
        try await expectCall(calls, "written in place after the file was replaced: the watch followed it") {
            let open = try fs.open(path, mode: .readWrite)
            try fs.write(open, bytes("TWO"), at: 0)
            try fs.close(open)
        }
        try await expectCall(calls, "removed") { try fs.remove(path) }
        try await expectCall(calls, "created again") { try file.write(bytes("three"), to: path) }
        watch.cancel()
    }

    @Test(.failureMode("design/15", "the watch is cancelled or dropped"), .timeLimit(.minutes(1)))
    func aCancelledWatchSaysNothingMore() async throws {
        let dir = try TempDirectory()
        let path = dir.file("prefs.json")
        let file = AtomicFile(fileSystem: fs, options: .init(envelope: false))
        let cancelled = Calls()
        let control = Calls()
        let watch = try fs.watchFile(at: path, handler: cancelled.handler)
        let controlWatch = try fs.watchFile(at: path, handler: control.handler)
        watch.cancel()
        // The control watch hears the change, so it has happened and been
        // delivered; the cancelled one, watching the same file, has not.
        try await expectCall(control, "written") { try file.write(bytes("one"), to: path) }
        #expect(cancelled.value == 0)
        controlWatch.cancel()
    }

    @Test(.failureMode("design/15", "the directory does not exist"))
    func aMissingDirectoryIsNotFound() throws {
        let dir = try TempDirectory()
        let error = #expect(throws: StoreError.self) { try fs.watchFile(at: dir.file("nowhere/prefs.json")) {} }
        #expect(error?.kind == .notFound)
    }

    @Test(.timeLimit(.minutes(1)))
    func aWatchThroughALinkIsToTheFileItNames() async throws {
        let dir = try TempDirectory()
        let target = dir.file("real.json")
        let link = dir.file("link.json")
        try fs.symlink(link, to: target)
        let file = AtomicFile(fileSystem: fs, options: .init(envelope: false))
        let calls = Calls()
        let watch = try fs.watchFile(at: link, handler: calls.handler)
        try await expectCall(calls, "written through the link") { try file.write(bytes("one"), to: link) }
        #expect(try fs.readLink(link) != nil, "still a link")
        watch.cancel()
    }
}

extension PosixFileSystem {
    /// A symbolic link, made for a test with the C library.
    fileprivate func symlink(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
}

internal import Dispatch
internal import Synchronization

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#else
#error("StoicStore needs Darwin or Glibc")
#endif

extension PosixFileSystem {
    /// Watches the file's directory: kqueue (`DispatchSource` on an
    /// `O_EVTONLY` descriptor) on Apple platforms, inotify on Linux.
    ///
    /// - **Apple.** A directory descriptor reports that an entry was created,
    ///   removed or renamed, but not which, and not that a file was written
    ///   in place (a text editor that saves by truncating and writing, a
    ///   shell redirection). So the watch holds a second descriptor on the
    ///   file itself while it exists, and opens it again whenever the
    ///   directory or the file says the file may have been replaced. The
    ///   handler is called for any of it, including changes to other entries
    ///   of the directory: the caller reads the file and finds nothing
    ///   changed.
    /// - **Linux.** inotify names the entry, so changes to other files in the
    ///   directory are not reported; the directory itself going away is.
    ///   `fs.inotify.max_user_watches` bounds how many watches a user can
    ///   hold, and a volume inotify does not cover (some network and FUSE
    ///   mounts) reports nothing: nothing here polls.
    public func watchFile(at path: String, handler: @escaping @Sendable () -> Void) throws(StoreError) -> FileWatch {
        let resolved = try AtomicFile(fileSystem: self).resolvingLinks(path)
        #if canImport(Darwin)
        return try VnodeWatch.start(path: resolved, handler: handler)
        #else
        return try InotifyWatch.start(path: resolved, handler: handler)
        #endif
    }
}

#if canImport(Darwin)

/// A directory and the file in it, watched through kqueue.
///
/// Both descriptors are `O_EVTONLY`, which watches without keeping a volume
/// from being unmounted. Everything that touches the sources happens under
/// `sources`, and the handlers run on `queue`, so a re-arm never races the
/// event that caused it; `stopped` makes the last one that does a no-op.
private final class VnodeWatch: Sendable {
    private struct Sources {
        var directory: (any DispatchSourceFileSystemObject)?
        var file: (any DispatchSourceFileSystemObject)?
        var stopped = false
    }

    private let directory: String
    private let path: String
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "stoic.store.watch")
    private let sources = Mutex(Sources())

    private init(path: String, handler: @escaping @Sendable () -> Void) {
        self.path = path
        self.directory = StorePath.directory(of: path)
        self.handler = handler
    }

    static func start(path: String, handler: @escaping @Sendable () -> Void) throws(StoreError) -> FileWatch {
        let watch = VnodeWatch(path: path, handler: handler)
        try watch.watchDirectory()
        watch.watchFile()
        return FileWatch { watch.stop() }
    }

    private func watchDirectory() throws(StoreError) {
        let descriptor = CWatch.openForEvents(directory)
        guard descriptor >= 0 else { throw StoreError(errno: errno, operation: "open", path: directory) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .link, .attrib, .revoke], queue: queue)
        source.setEventHandler { [self] in
            // The entry may be a new file: watch it, then say so. The handler
            // runs after the new watch exists, so a write that follows is seen.
            watchFile()
            handler()
        }
        source.setCancelHandler { _ = CWatch.close(descriptor) }
        sources.withLock { $0.directory = source }
        source.resume()
    }

    /// Watches the file as it is now, in place of the one watched before, or
    /// nothing if there is no file: the directory says when one appears.
    private func watchFile() {
        let descriptor = CWatch.openForEvents(path)
        sources.withLock { sources in
            sources.file?.cancel()
            sources.file = nil
            guard descriptor >= 0 else { return }
            guard !sources.stopped else {
                _ = CWatch.close(descriptor)
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: queue)
            source.setEventHandler { [self, source] in
                let replaced = !source.data.isDisjoint(with: [.delete, .rename, .revoke])
                if replaced { watchFile() }
                handler()
            }
            source.setCancelHandler { _ = CWatch.close(descriptor) }
            sources.file = source
            source.resume()
        }
    }

    private func stop() {
        sources.withLock { sources in
            sources.stopped = true
            sources.directory?.cancel()
            sources.file?.cancel()
            sources.directory = nil
            sources.file = nil
        }
    }
}

/// The system calls the watch makes; see `PosixFileSystem`'s `CSys` for why
/// each is wrapped once, here.
private enum CWatch {
    static func openForEvents(_ path: String) -> Int32 {
        // The path's C string lives for the call; open copies it.
        unsafe open(path, O_EVTONLY | O_CLOEXEC)
    }

    static func close(_ descriptor: Int32) -> Int32 {
        // Not restarted on EINTR, for the reason `PosixFileSystem.close` gives.
        Darwin.close(descriptor)
    }
}

#else

/// A directory watched through inotify, reporting the one entry that matters.
///
/// A thread of its own waits in `poll` on two descriptors: the inotify
/// instance, and the read end of a pipe that `cancel` writes to, so ending the
/// watch wakes the wait at once instead of being noticed at the next timeout.
/// It owns neither a `DispatchSource` nor any other object a `Sendable` closure
/// would have to share: only descriptors, a name and the handler.
private enum InotifyWatch {
    static func start(path: String, handler: @escaping @Sendable () -> Void) throws(StoreError) -> FileWatch {
        let directory = StorePath.directory(of: path)
        let name = StorePath.name(of: path)
        let events = CWatch.initialize()
        guard events >= 0 else { throw StoreError(errno: errno, operation: "inotify_init1", path: directory) }
        guard CWatch.watch(events, directory: directory) >= 0 else {
            let failure = errno
            _ = CWatch.close(events)
            throw StoreError(errno: failure, operation: "inotify_add_watch", path: directory)
        }
        guard let (wakeRead, wakeWrite) = CWatch.makePipe() else {
            let failure = errno
            _ = CWatch.close(events)
            throw StoreError(errno: failure, operation: "pipe", path: directory)
        }
        DispatchQueue(label: "stoic.store.watch").async {
            while CWatch.waitForEvent(on: events, orWakeOn: wakeRead) {
                // Another entry's change is not ours; an empty name is the
                // directory itself, or a queue overflow that lost track.
                if CWatch.names(readFrom: events).contains(where: { $0.isEmpty || $0 == name }) { handler() }
            }
            _ = CWatch.close(events)
            _ = CWatch.close(wakeRead)
        }
        return FileWatch {
            CWatch.wake(wakeWrite)
            _ = CWatch.close(wakeWrite)
        }
    }
}

/// The system calls the watch makes; see `PosixFileSystem`'s `CSys` for why
/// each is wrapped once, here.
private enum CWatch {
    static func initialize() -> Int32 {
        inotify_init1(Int32(IN_CLOEXEC | IN_NONBLOCK))
    }

    static func watch(_ descriptor: Int32, directory: String) -> Int32 {
        let events = IN_CREATE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE | IN_ATTRIB
            | IN_DELETE_SELF | IN_MOVE_SELF
        // The path's C string lives for the call; inotify_add_watch copies it.
        return unsafe inotify_add_watch(descriptor, directory, UInt32(events))
    }

    static func close(_ descriptor: Int32) -> Int32 {
        Glibc.close(descriptor)
    }

    /// A pipe whose ends are close-on-exec and non-blocking: (read, write).
    /// (`pipe2` would do it in one call, but Glibc declares it only under
    /// `_GNU_SOURCE`.)
    static func makePipe() -> (Int32, Int32)? {
        var ends: [Int32] = [-1, -1]
        // pipe fills the two elements of `ends`, which has exactly two.
        guard ends.withUnsafeMutableBufferPointer({ unsafe pipe($0.baseAddress) }) == 0 else { return nil }
        for end in ends {
            guard fcntl(end, F_SETFD, FD_CLOEXEC) == 0, fcntl(end, F_SETFL, O_NONBLOCK) == 0 else {
                let failure = errno
                _ = close(ends[0])
                _ = close(ends[1])
                errno = failure
                return nil
            }
        }
        return (ends[0], ends[1])
    }

    /// Writes the byte that ends the wait. A full pipe already holds one.
    static func wake(_ descriptor: Int32) {
        var byte: UInt8 = 1
        // write reads one byte from `byte`, which lives for the call.
        _ = unsafe write(descriptor, &byte, 1)
    }

    /// Blocks until `events` is readable (true) or the pipe is (false: the
    /// watch was cancelled), restarting after a signal.
    static func waitForEvent(on events: Int32, orWakeOn wake: Int32) -> Bool {
        var waiting = [
            pollfd(fd: events, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            // poll reads and fills the two elements of `waiting`, and `nfds` says two.
            let ready = waiting.withUnsafeMutableBufferPointer { unsafe poll($0.baseAddress, 2, -1) }
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if waiting[1].revents != 0 { return false }
            if waiting[0].revents != 0 { return true }
        }
    }

    /// The entry names of the events waiting on `descriptor` (empty for an
    /// event about the directory itself).
    ///
    /// Each event is a 16-byte header (`wd`, `mask`, `cookie`, `len`: four
    /// 32-bit fields) followed by `len` bytes holding the NUL-padded name.
    static func names(readFrom descriptor: Int32) -> [String] {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { raw in
            // read writes at most raw.count bytes into raw's storage.
            unsafe read(descriptor, raw.baseAddress, raw.count)
        }
        guard count > 0 else { return [] }
        let header = 16
        var names: [String] = []
        var offset = 0
        while offset + header <= count {
            let length = buffer.withUnsafeBytes { raw in
                // The four bytes at offset + 12 are inside the buffer: offset + header <= count.
                Int(unsafe raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
            }
            let start = offset + header
            let end = min(count, start + length)
            names.append(String(decoding: buffer[start..<end].prefix { $0 != 0 }, as: UTF8.self))
            offset = start + length
        }
        return names
    }
}

#endif

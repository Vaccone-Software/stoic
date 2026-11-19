#if os(macOS)
internal import Stoic
internal import Darwin
internal import Synchronization

/// Where a program records the children it is running, so that its next
/// launch can stop the ones a crash left behind.
///
/// macOS has no way to say "end this child when I end" (Linux's
/// `PR_SET_PDEATHSIG`): when a program crashes or is killed, its children
/// are adopted by launchd and run on, a language model session still
/// spending, a dev server still holding its port. Each owned child started
/// with a ledger is written down while it runs, by pid, start time and
/// process group, and crossed out when it is reaped; ``reapOrphans(grace:)``,
/// called once at launch, stops everything a previous run of the program
/// recorded and did not cross out.
///
/// Each running program writes a file of its own in the ledger's
/// directory, named for its own pid and start time, so two copies of it
/// (a test run beside the app) never write the same file, and one never
/// reaps the other's children while that one is alive.
///
/// The file is written by replacing it (a temporary file renamed over it)
/// and never synced to the disk: it has to survive a crash of this program,
/// not of the machine, and a machine that loses power loses the children
/// too.
public final class ProcessLedger: Sendable {
    public let directory: String
    private let entries = Mutex<[ProcessIdentity: String]>([:])
    private let writes = Mutex(())

    /// - Parameter directory: Made (mode `0o700`) when first written.
    public init(directory: String) {
        self.directory = directory
    }

    /// Stops every child that a run of this program that is no longer
    /// running recorded and did not cross out, and returns how many were
    /// still running: `SIGTERM`, then `SIGKILL` after `grace` to any that
    /// remain. A recorded process is signalled only if it is the same one
    /// (its start time matches), and its group's members only if they
    /// started after it did.
    @discardableResult
    public func reapOrphans(grace: Duration = .seconds(3)) async -> Int {
        let own = ProcessIdentity.own
        var found: [ProcessIdentity] = []
        var files: [String] = []
        for name in Self.list(directory) {
            guard let owner = Self.owner(fromFileName: name), owner != own, !owner.isAlive else { continue }
            let path = directory + "/" + name
            files.append(path)
            for (leader, _) in Self.read(path) {
                if leader.isAlive { found.append(leader) }
                found += ProcessTable.group(ledBy: leader).filter { $0 != leader }
            }
        }
        let orphans = Array(Set(found))
        for orphan in orphans { orphan.signal(SIGTERM) }
        if !orphans.isEmpty {
            let step = Duration.milliseconds(50)
            var waited = Duration.zero
            while waited < grace, orphans.contains(where: \.isAlive) {
                do { try await Ambient.sleep(for: step) } catch { break }
                waited += step
            }
            for orphan in orphans where orphan.isAlive { orphan.signal(SIGKILL) }
            Recorder().record(Event("process.orphans_reaped", level: .notice, label: directory,
                                 fields: [.init("count", .int(orphans.count))]))
        }
        for path in files { _ = unsafe unlink(path) }
        return orphans.count
    }

    func record(_ child: ProcessIdentity, label: String, recorder: Recorder) {
        entries.withLock { $0[child] = label }
        save(recorder)
    }

    func forget(_ child: ProcessIdentity, recorder: Recorder) {
        let removed = entries.withLock { $0.removeValue(forKey: child) != nil }
        if removed { save(recorder) }
    }

    // MARK: The file

    private var path: String {
        directory + "/\(ProcessIdentity.own.pid)-\(ProcessIdentity.own.started).ledger"
    }

    /// Writes are one at a time, each the entries as they are when it runs,
    /// so the last write is always the latest state.
    private func save(_ recorder: Recorder) {
        writes.withLock { _ in
            let current = entries.withLock { $0 }
            if current.isEmpty {
                _ = unsafe unlink(path)
                return
            }
            let text = current.map { child, label in
                "\(child.pid) \(child.started) \(label.filter { $0 != "\n" && $0 != "\r" })\n"
            }.sorted().joined()
            if let failure = Self.replace(path, with: Array(text.utf8), directory: directory) {
                recorder.record(Event("process.ledger_failed", level: .warning, label: directory,
                                     fields: [.init("errno", .int(Int(failure)))]))
            }
        }
    }

    /// Nil when written, else the errno.
    private static func replace(_ path: String, with bytes: [UInt8], directory: String) -> Int32? {
        _ = unsafe mkdir(directory, 0o700)
        let temporary = path + ".tmp"
        let fd = unsafe open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return errno }
        let written = bytes.withUnsafeBytes { raw in unsafe write(fd, raw.baseAddress, raw.count) }
        let failure = written == bytes.count ? nil : errno
        _ = close(fd)
        if let failure {
            _ = unsafe unlink(temporary)
            return failure
        }
        return unsafe rename(temporary, path) == 0 ? nil : errno
    }

    static func owner(fromFileName name: String) -> ProcessIdentity? {
        guard name.hasSuffix(".ledger") else { return nil }
        let parts = name.dropLast(".ledger".count).split(separator: "-")
        guard parts.count == 2, let pid = Int32(parts[0]), let started = Int64(parts[1]) else { return nil }
        return ProcessIdentity(pid: pid, started: started)
    }

    static func read(_ path: String) -> [(ProcessIdentity, String)] {
        let fd = unsafe open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { _ = close(fd) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bytes.count < 4 * 1024 * 1024 {
            let count = buffer.withUnsafeMutableBytes { raw in unsafe Darwin.read(fd, raw.baseAddress, raw.count) }
            guard count > 0 else { break }
            bytes += buffer.prefix(count)
        }
        return String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, let pid = Int32(parts[0]), pid > 0, let started = Int64(parts[1]) else { return nil }
            return (ProcessIdentity(pid: pid, started: started), parts.count > 2 ? String(parts[2]) : "")
        }
    }

    private static func list(_ directory: String) -> [String] {
        guard let handle = unsafe opendir(directory) else { return [] }
        defer { unsafe closedir(handle) }
        var names: [String] = []
        while let entry = unsafe readdir(handle) {
            let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { raw in
                unsafe String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name.hasSuffix(".ledger") { names.append(name) }
        }
        return names
    }
}
#endif

#if os(macOS)
internal import Darwin

/// A process as the kernel knows it: its pid and when it started.
///
/// A pid alone names whatever process holds that number now. Once a process
/// has ended and been reaped its number is free, and the next process the
/// system starts may be given it: a signal sent by number then reaches a
/// stranger. Its start time, which the kernel keeps to the microsecond, does
/// not repeat, so a pid with the start time it had when it was recorded is
/// the same process or none.
struct ProcessIdentity: Sendable, Hashable, CustomStringConvertible {
    let pid: Int32
    /// Microseconds since the Unix epoch.
    let started: Int64

    /// The live process with `pid`, or nil when there is none (or it is not
    /// ours to ask about).
    static func of(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0, let info = bsdInfo(pid) else { return nil }
        return ProcessIdentity(pid: pid, started: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec))
    }

    /// This process.
    static let own: ProcessIdentity = {
        guard let own = of(getpid()) else { preconditionFailure("StoicProcess: the kernel does not know this process") }
        return own
    }()

    /// Whether the process this names is still running: its pid is held by
    /// a process that started when it did. A zombie (ended, not yet reaped)
    /// still answers, as the kernel still holds it.
    var isAlive: Bool { ProcessIdentity.of(pid) == self }

    /// Sends `signal` if, and only if, the pid still names this process.
    ///
    /// The check and the signal are two calls, so a process that ends
    /// between them and whose pid is given to another in that instant would
    /// be missed by the check. The window is microseconds, against a pid
    /// space macOS cycles through in hours or days.
    @discardableResult
    func signal(_ signal: Int32) -> Bool {
        guard isAlive else { return false }
        return kill(pid, signal) == 0
    }

    var description: String { "\(pid)@\(started)" }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}

/// Processes found by asking the kernel: never `ps` or `pgrep`, so finding
/// them waits on no other process and can be done from a cancellation
/// handler.
enum ProcessTable {
    /// The children of `pid`, at any depth, children before their parents,
    /// each with its start time. At most `limit`, so a fork bomb cannot make
    /// the walk itself unbounded.
    static func descendants(of pid: Int32, limit: Int = 4096) -> [ProcessIdentity] {
        var found: [ProcessIdentity] = []
        var pending = children(of: pid)
        var seen = Set<Int32>()
        while let next = pending.popLast(), found.count < limit {
            guard seen.insert(next).inserted, let identity = ProcessIdentity.of(next) else { continue }
            found.append(identity)
            pending += children(of: next)
        }
        return found.reversed()
    }

    /// The members of process group `group` that started at or after
    /// `since`: the ones that can have been started by the group's leader
    /// or its children. A group id is its leader's pid, and once every
    /// member has gone the number can come back as another group's; a
    /// member older than the leader we started is not one of ours.
    static func members(ofGroup group: Int32, startedSince since: Int64) -> [ProcessIdentity] {
        unsafe list(capacity: 1024) { buffer, size in unsafe proc_listpgrppids(group, buffer, size) }
            .compactMap(ProcessIdentity.of)
            .filter { $0.started >= since }
    }

    /// The members of the process group `leader` led, when that group can
    /// still be the one it led.
    ///
    /// The kernel never gives a new process a pid that is the number of a
    /// process group still in being, so while `leader`'s group has a member
    /// its number stays free, or held by `leader` itself. A different
    /// process holding it means the group ended and the number was handed
    /// on: a group of that number now is a stranger's (a terminal's shell
    /// leads one), and nothing in it is signalled.
    static func group(ledBy leader: ProcessIdentity) -> [ProcessIdentity] {
        if let holder = ProcessIdentity.of(leader.pid), holder != leader { return [] }
        return members(ofGroup: leader.pid, startedSince: leader.started)
    }

    private static func children(of pid: Int32) -> [Int32] {
        guard pid > 0 else { return [] }
        return unsafe list(capacity: 512) { buffer, size in unsafe proc_listchildpids(pid, buffer, size) }
    }

    /// `call` fills a buffer of pids and returns how many it wrote.
    private static func list(capacity: Int, _ call: (UnsafeMutableRawPointer, Int32) -> Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { raw in
            unsafe call(raw.baseAddress!, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), capacity))).filter { $0 > 0 }
    }
}
#endif

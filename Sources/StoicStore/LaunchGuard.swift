internal import Stoic

/// Notices when the app keeps dying during launch, and says so before it
/// dies again.
///
/// A crash loop at launch — a corrupt cache, a bad migration, a config that
/// crashes the first view — is the worst failure an app can have: the user
/// cannot reach the settings that would fix it, and every update that might
/// fix it has to be installed through the broken app. A launch guard is the
/// circuit breaker for the process itself:
///
///     let guard = LaunchGuard(path: support + "/launch-guard")
///     switch try guard.beginLaunch() {
///     case .normal: startEverything()
///     case .safeMode(let unclean):
///         // Skip optional services, quarantine caches and the last migration,
///         // and offer to reset.
///         startMinimally(reason: "\(unclean) launches in a row did not finish")
///     }
///     guard.markStable(after: .seconds(30))   // the launch counts as good after 30 s
///
/// A launch is *unclean* if the next launch finds it was never marked stable
/// and never exited cleanly. After `uncleanLimit` unclean launches in a row
/// (three by default), ``beginLaunch()`` answers ``Verdict/safeMode(uncleanLaunches:)``.
/// A stable launch resets the count. The state is a tiny file written with
/// ``AtomicFile``, so the guard itself survives the crashes it is counting.
public final class LaunchGuard: Sendable {
    /// What the launch should do.
    public enum Verdict: Sendable, Hashable {
        case normal
        /// Too many launches in a row did not finish: start minimally.
        case safeMode(uncleanLaunches: Int)
    }

    public let path: String
    public let uncleanLimit: Int
    private let file: AtomicFile

    public init(path: String, uncleanLimit: Int = 3, file: AtomicFile = AtomicFile(options: .init(keepPrevious: true))) {
        precondition(uncleanLimit >= 1, "the unclean-launch limit must be at least one")
        self.path = path
        self.uncleanLimit = uncleanLimit
        self.file = file
    }

    private struct Record: Equatable {
        var inProgress: Bool
        var unclean: Int

        var bytes: [UInt8] {
            Array("stoic.launch v1 in-progress=\(inProgress ? 1 : 0) unclean=\(unclean)".utf8)
        }

        init(inProgress: Bool, unclean: Int) {
            self.inProgress = inProgress
            self.unclean = unclean
        }

        init?(_ bytes: [UInt8]) {
            let text = String(decoding: bytes, as: UTF8.self)
            let fields = text.split(separator: " ")
            guard fields.count == 4, fields[0] == "stoic.launch", fields[1] == "v1",
                  fields[2].hasPrefix("in-progress="), fields[3].hasPrefix("unclean="),
                  let progress = Int(fields[2].dropFirst("in-progress=".count)),
                  let unclean = Int(fields[3].dropFirst("unclean=".count)), unclean >= 0
            else { return nil }
            self.inProgress = progress == 1
            self.unclean = unclean
        }
    }

    /// Records that a launch has begun and judges the launches before it.
    /// Call it first, before anything that could crash.
    ///
    /// An unreadable state file counts as no history: the guard must never
    /// itself be the reason an app cannot start.
    public func beginLaunch() throws(StoreError) -> Verdict {
        let previous: Record?
        do {
            previous = try file.read(path).flatMap { Record($0.bytes) }
        } catch {
            previous = nil
        }
        var unclean = previous?.unclean ?? 0
        if previous?.inProgress == true {
            unclean += 1
            Ambient.current.instrumentation.record(Event("launch.unclean_detected", level: .warning, fields: [.init("unclean", .int(unclean))]))
        }
        try file.write(Record(inProgress: true, unclean: unclean).bytes, to: path)
        if unclean >= uncleanLimit {
            Ambient.current.instrumentation.record(Event("launch.safe_mode", level: .error, fields: [
                .init("unclean", .int(unclean)),
                .init("limit", .int(uncleanLimit)),
            ]))
            return .safeMode(uncleanLaunches: unclean)
        }
        return .normal
    }

    /// Records that this launch survived: the unclean count starts over.
    public func markStable() throws(StoreError) {
        try file.write(Record(inProgress: false, unclean: 0).bytes, to: path)
        Ambient.current.instrumentation.record(Event("launch.stable", level: .info))
    }

    /// Marks the launch stable once it has run for `duration` on the ambient
    /// clock. Returns the task, which an app may cancel if it starts to fail.
    @discardableResult
    public func markStable(after duration: Duration) -> Task<Void, Never> {
        Task.stoic {
            do {
                try await Ambient.sleep(for: duration)
                try self.markStable()
            } catch {
                // Cancelled, or the write failed: the launch stays unconfirmed,
                // which is the safe direction to be wrong in.
            }
        }
    }

    /// Records a deliberate, clean exit (the user quit): not a crash.
    public func markCleanExit() throws(StoreError) {
        try file.write(Record(inProgress: false, unclean: 0).bytes, to: path)
    }
}

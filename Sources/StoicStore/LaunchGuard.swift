internal import Stoic
internal import Synchronization

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif

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
///     switch guard.beginLaunch() {
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
///
/// Not every launch that fails to finish is a crash, and counting those
/// would put a healthy iOS app into safe mode. Three kinds of ending are
/// told apart from a crash:
///
/// - **The app was sent to the background** before it became stable. The
///   system may suspend and later kill a background app without a word, and
///   so does the user swiping it away. Call ``markBackgrounded()`` when the
///   app enters the background: the launch is no longer judged, and its
///   count is kept as it was.
/// - **The device restarted** (a battery that ran flat, an OS update, a
///   reboot) while a launch was in progress. The guard compares the boot
///   session of the two launches; a different one is not counted.
/// - **A different build** is running. A crash of the previous build says
///   nothing about this one, and an update is the way out of a loop, so a
///   new `build` starts the count over.
///
/// Anything else that ends a launch before it is marked stable — a crash,
/// a watchdog kill, a jetsam while in the foreground — counts.
///
/// Safe to call from any thread: `markStable(after:)` writes from its own
/// task while the app calls `markBackgrounded()` from the main thread, and
/// every call reads, decides and writes under one lock, so none of them races
/// another on the state file or undoes another's write.
public final class LaunchGuard: Sendable {
    /// What the launch should do.
    public enum Verdict: Sendable, Hashable {
        case normal
        /// Too many launches in a row did not finish: start minimally.
        case safeMode(uncleanLaunches: Int)
    }

    public let path: String
    public let uncleanLimit: Int
    /// Identifies the running build; a launch of another build starts the count over.
    public let build: String?
    /// Identifies this boot of the device; an unfinished launch from another boot is not counted.
    public let bootSession: String?
    private let file: AtomicFile
    /// Serialises every read-decide-write of the state file. `AtomicFile`
    /// assumes one writer per path; this is that writer.
    private let lock = Mutex(())

    /// - Parameters:
    ///   - path: Where the state is kept.
    ///   - uncleanLimit: How many unclean launches in a row mean safe mode.
    ///   - build: The running build's identity (`CFBundleVersion`, say). The
    ///     core is Foundation-free, so the app supplies it. `nil` disables
    ///     the new-build reset.
    ///   - bootSession: The device's boot identity: the system's boot
    ///     session on Apple platforms by default; `nil` disables the check.
    public init(
        path: String,
        uncleanLimit: Int = 3,
        build: String? = nil,
        bootSession: String? = LaunchGuard.currentBootSession,
        file: AtomicFile = AtomicFile(options: .init(keepPrevious: true))
    ) {
        precondition(uncleanLimit >= 1, "the unclean-launch limit must be at least one")
        precondition(build.map { !$0.contains(" ") } ?? true, "the build identity cannot contain a space")
        precondition(bootSession.map { !$0.contains(" ") } ?? true, "the boot session cannot contain a space")
        self.path = path
        self.uncleanLimit = uncleanLimit
        self.build = build
        self.bootSession = bootSession
        self.file = file
    }

    /// The system's identifier for this boot of the device, or `nil` where
    /// there is none.
    public static var currentBootSession: String? {
        #if canImport(Darwin)
        var size = 0
        guard unsafe sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard unsafe sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        // The value is NUL-terminated.
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        #else
        return nil
        #endif
    }

    private struct Record: Equatable {
        var inProgress: Bool
        var unclean: Int
        var build: String?
        var bootSession: String?

        var bytes: [UInt8] {
            Array("stoic.launch v2 in-progress=\(inProgress ? 1 : 0) unclean=\(unclean) build=\(build ?? "-") boot=\(bootSession ?? "-")".utf8)
        }

        init(inProgress: Bool, unclean: Int, build: String?, bootSession: String?) {
            self.inProgress = inProgress
            self.unclean = unclean
            self.build = build
            self.bootSession = bootSession
        }

        /// Reads the current format, and the first one (which had no build or boot).
        init?(_ bytes: [UInt8]) {
            let text = String(decoding: bytes, as: UTF8.self)
            let fields = text.split(separator: " ")
            guard fields.count >= 4, fields[0] == "stoic.launch",
                  fields[2].hasPrefix("in-progress="), fields[3].hasPrefix("unclean="),
                  let progress = Int(fields[2].dropFirst("in-progress=".count)),
                  let unclean = Int(fields[3].dropFirst("unclean=".count)), unclean >= 0
            else { return nil }
            func value(_ field: Substring, _ name: String) -> String?? {
                guard field.hasPrefix(name) else { return .none }
                let text = field.dropFirst(name.count)
                return .some(text == "-" ? nil : String(text))
            }
            switch fields[1] {
            case "v1" where fields.count == 4:
                self.build = nil
                self.bootSession = nil
            case "v2" where fields.count == 6:
                guard let build = value(fields[4], "build="), let boot = value(fields[5], "boot=") else { return nil }
                self.build = build
                self.bootSession = boot
            default:
                return nil
            }
            self.inProgress = progress == 1
            self.unclean = unclean
        }
    }

    private func record(inProgress: Bool, unclean: Int) -> [UInt8] {
        Record(inProgress: inProgress, unclean: unclean, build: build, bootSession: bootSession).bytes
    }

    /// Records that a launch has begun and judges the launches before it.
    /// Call it first, before anything that could crash.
    ///
    /// It never throws: the guard must never itself be the reason an app
    /// cannot start. An unreadable state file counts as no history, and a
    /// launch that cannot be recorded (a full or read-only disk) is reported
    /// as `launch.record_failed` and judged on the history that could be read.
    /// Not throwing loses nothing: the file is the same either way, and so is
    /// this launch's verdict; the one consequence, that the next launch will
    /// not count this one, is what the event reports.
    public func beginLaunch() -> Verdict {
        var events: [Event] = []
        let unclean = lock.withLock { _ -> Int in
            let previous: Record?
            do {
                previous = try file.read(path).flatMap { Record($0.bytes) }
            } catch {
                previous = nil
            }
            var unclean = previous?.unclean ?? 0
            if let previous, let build, let before = previous.build, before != build {
                // A new build: what went wrong with the last one is not evidence about this one.
                unclean = 0
                events.append(Event("launch.interrupted", level: .info, fields: [
                    .init("reason", .string("new_build"), privacy: .public),
                ]))
            } else if previous?.inProgress == true {
                if let bootSession, let before = previous?.bootSession, before != bootSession {
                    // The device restarted under the previous launch: not a crash.
                    events.append(Event("launch.interrupted", level: .info, fields: [
                        .init("reason", .string("restart"), privacy: .public),
                        .init("unclean", .int(unclean)),
                    ]))
                } else {
                    unclean += 1
                    events.append(Event("launch.unclean_detected", level: .warning, fields: [.init("unclean", .int(unclean))]))
                }
            }
            do throws(StoreError) {
                try file.write(record(inProgress: true, unclean: unclean), to: path)
            } catch {
                events.append(Event("launch.record_failed", level: .error, fields: [.init("error", .error(error))]))
            }
            return unclean
        }
        if unclean >= uncleanLimit {
            events.append(Event("launch.safe_mode", level: .error, fields: [
                .init("unclean", .int(unclean)),
                .init("limit", .int(uncleanLimit)),
            ]))
        }
        for event in events { Ambient.current.instrumentation.record(event) }
        return unclean >= uncleanLimit ? .safeMode(uncleanLaunches: unclean) : .normal
    }

    /// Records that this launch survived: the unclean count starts over.
    public func markStable() throws(StoreError) {
        try lock.withLock { _ throws(StoreError) in
            try file.write(record(inProgress: false, unclean: 0), to: path)
        }
        Ambient.current.instrumentation.record(Event("launch.stable", level: .info))
    }

    /// Marks the launch stable once it has *run* for `duration`, measured on
    /// the ambient liveness clock (a suspending clock), so time the device
    /// spent asleep does not count: a launch that slept through its 30 s has
    /// proved nothing (DESIGN.md, the two clocks). Returns the task, which an
    /// app may cancel if it starts to fail.
    @discardableResult
    public func markStable(after duration: Duration) -> Task<Void, Never> {
        Task.stoic {
            do {
                let clock = Ambient.current.livenessClock
                try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
                try self.markStable()
            } catch {  // stoic:allow(swallowed-error): unconfirmed is the safe outcome (below)
                // Cancelled, or the write failed: the launch stays unconfirmed,
                // which is the safe direction to be wrong in.
            }
        }
    }

    /// Records a deliberate, clean exit (the user quit): not a crash.
    public func markCleanExit() throws(StoreError) {
        try lock.withLock { _ throws(StoreError) in
            try file.write(record(inProgress: false, unclean: 0), to: path)
        }
    }

    /// Records that the app went to the background before its launch was
    /// marked stable (iOS: `sceneDidEnterBackground`). From then on the
    /// system or the user may end the process without any code running, so
    /// the launch is no longer judged: it is not counted as unclean, and it
    /// does not reset the count either — it proved nothing about stability.
    /// Call it from the app's background transition.
    public func markBackgrounded() throws(StoreError) {
        let marked = try lock.withLock { _ throws(StoreError) -> Int? in
            let current: Record?
            do {
                current = try file.read(path).flatMap { Record($0.bytes) }
            } catch {
                current = nil
            }
            // A launch already settled (stable, or a clean exit) stays settled.
            guard let current, current.inProgress else { return nil }
            try file.write(record(inProgress: false, unclean: current.unclean), to: path)
            return current.unclean
        }
        guard let unclean = marked else { return }
        Ambient.current.instrumentation.record(Event("launch.interrupted", level: .info, fields: [
            .init("reason", .string("backgrounded"), privacy: .public),
            .init("unclean", .int(unclean)),
        ]))
    }
}

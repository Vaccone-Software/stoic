internal import Stoic
public import StoicStore
internal import Synchronization

/// A running watch on a settings file: it calls ``SettingsStore/reload()``
/// when the file changes. From ``SettingsStore/watch(debounce:)``.
///
/// It lasts as long as this object: ``stop()`` ends it, and so does dropping
/// the last reference. It does not keep the store alive.
public final class SettingsWatch: Sendable {
    private let fileWatch: FileWatch
    private let notices: AsyncStream<Void>.Continuation
    private let task: Task<Void, Never>

    fileprivate init(fileWatch: FileWatch, notices: AsyncStream<Void>.Continuation, task: Task<Void, Never>) {
        self.fileWatch = fileWatch
        self.notices = notices
        self.task = task
    }

    deinit {
        stop()
    }

    /// Ends the watch. A reload already under way finishes; none starts after.
    public func stop() {
        fileWatch.cancel()
        notices.finish()
        task.cancel()
    }
}

extension SettingsStore {
    /// Reloads the settings when their file changes, so a value edited by a
    /// person or another process reaches the app, and ``value`` (Observable)
    /// tells whoever shows it.
    ///
    ///     let watch = try settings.watch()    // keep it as long as the settings are shown
    ///
    /// - **The directory is watched** (`FileSystem.watchFile(at:handler:)`), so
    ///   an editor that saves by writing a new file and renaming it over the
    ///   old one is seen, and so is a file that does not exist yet. A change to
    ///   another file beside it may be reported on some platforms (kqueue
    ///   cannot say which entry changed) and is filtered by what the reload
    ///   finds: the file as it was.
    /// - **A burst is one reload.** Editors write a file in several steps, and
    ///   a tool that saves twice in a row would otherwise reload twice. The
    ///   reload runs once `debounce` has passed on the ambient clock since the
    ///   *last* change (a test clock decides when), so a steady stream of
    ///   changes defers it until it stops.
    /// - **The store's own writes are reported too, and cost nothing.** The
    ///   watcher cannot tell them from an editor's, so it reloads for them as
    ///   well, and the reload finds the file exactly as the store wrote it
    ///   (``reload()`` compares what it reads with what the store last saw)
    ///   and publishes nothing and reports nothing.
    /// - **A file that cannot be used** (half-saved, not JSON) leaves the last
    ///   good value in place and sets ``fileProblem``; the next change that
    ///   fixes it clears it.
    ///
    /// The reload runs on a task of the watcher's, which does not keep the
    /// store alive: it ends when the store goes. A reload that fails (an
    /// app-owned file whose read failed) is reported as `settings.reload_failed`.
    ///
    /// - Parameter debounce: The quiet time after the last change before the
    ///   reload; positive. 0.3 seconds by default.
    /// - Throws: `.invalidArgument` for a debounce that is not positive;
    ///   whatever the file system throws when it cannot watch (`.notFound` if
    ///   the file's directory does not exist, `.unsupported`).
    public func watch(debounce: Duration = .milliseconds(300)) throws(StoreError) -> SettingsWatch {
        guard debounce > .zero else {
            throw StoreError(kind: .invalidArgument, operation: "watch", path: path, detail: "the debounce must be positive")
        }
        let clock = Ambient.current.clock
        let changes = LatestChange()
        let (notices, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let fileWatch = try file.fileSystem.watchFile(at: path) {
            changes.record(at: clock.now)
            signal.yield()
        }
        let task = Task.stoic { [weak self] in
            for await _ in notices {
                // Trailing edge: wait until `debounce` has passed since the
                // latest change, however many arrive while waiting. One sleeper
                // at a time, so a burst costs one timer.
                while let latest = changes.latest {
                    let due = latest.advanced(by: debounce)
                    if clock.now < due {
                        do {
                            try await clock.sleep(until: due, tolerance: nil)
                        } catch {
                            return   // cancelled: the watch was stopped
                        }
                        continue
                    }
                    guard changes.settle(latest) else { continue }
                    guard let store = self else { return }
                    store.reloadForWatch()
                }
            }
        }
        return SettingsWatch(fileWatch: fileWatch, notices: signal, task: task)
    }

    /// The reload a watch starts: a failure has nobody to throw to.
    func reloadForWatch() {
        do throws(StoreError) {
            try reload()
        } catch {
            Ambient.record(Event("settings.reload_failed", level: .warning, label: path, fields: [.init("error", .error(error))]))
        }
    }
}

/// When the file was last reported changed, and whether a reload is owed.
private final class LatestChange: Sendable {
    private let instant = Mutex<AnyClock.Instant?>(nil)

    /// A change was reported at `now`.
    func record(at now: AnyClock.Instant) {
        instant.withLock { $0 = now }
    }

    /// The time of the latest change not yet reloaded for.
    var latest: AnyClock.Instant? { instant.withLock { $0 } }

    /// Takes the reload owed for the change at `latest`, unless a newer change
    /// has arrived since, which owes its own, later.
    func settle(_ latest: AnyClock.Instant) -> Bool {
        instant.withLock { current in
            guard current == latest else { return false }
            current = nil
            return true
        }
    }
}

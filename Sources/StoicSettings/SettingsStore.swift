public import Observation
public import Stoic
public import StoicSchema
public import StoicStore
internal import StoicJSON
internal import Synchronization

/// An app's settings: declared by a schema, kept in a file that a crash, a
/// bad value, an old format or a newer app version cannot ruin.
///
///     struct Prefs: Sendable, Equatable {
///         var scrollSpeed = 600
///         var theme = Theme.system
///         static let schema = Schema.object(Prefs.self, default: Prefs()) { … }
///     }
///
///     let settings = try SettingsStore.open(at: supportDirectory + "/prefs.json", schema: Prefs.schema)
///     Text("\(settings.value.scrollSpeed)")                 // Observable
///     try settings.update { $0.scrollSpeed = 900 }          // validated, durable, then published
///
/// - **Loading never fails for want of a good file.** A file that cannot be
///   used is quarantined (never deleted) and the previous generation tried,
///   then the defaults; one invalid field falls back to its default alone.
///   ``source`` says which happened, ``issues`` says what was repaired.
/// - **Old formats are migrated** by the schema and, for an app-owned file,
///   written back at once; the pre-migration file stays as `.previous`.
/// - **A newer format is never touched.** A document from a newer app
///   version opens read-only (``Source/newerFormat(version:)``), and
///   ``update(_:)`` refuses, so launching an older build cannot destroy it.
/// - **Keys the schema does not declare are kept.** A field a newer build
///   added survives an older build's save, at the top level and in nested
///   objects (``UnknownKeysOnSave``).
/// - **Updates are validated, durable, then visible.** The changed value is
///   checked against the schema, written atomically (only what differs from
///   the defaults), and published only once it is on disk. Updates are
///   serialised.
///
/// ## A file a person edits
///
/// With ``Format/handEdited`` the file is the person's, and the app is one of
/// several writers (a command-line tool beside it, an editor):
///
/// - **It is never destroyed.** A file that is not JSON, not UTF-8 or cannot
///   be read is never quarantined, renamed or overwritten, on load or on
///   update. Loading keeps the last good value (the defaults, the first time)
///   and reports a ``SettingsFileProblem`` with the line and column; ``update(_:)``
///   throws ``UpdateError/fileUnusable(_:)`` and writes nothing.
/// - **The dialect is one table** (``HandEditedOptions``): comments, trailing
///   commas, a byte order mark and a key said twice are accepted (the last one
///   used, with a warning issue; comments and repeats may be refused instead),
///   and the next write has none of them.
/// - **Issues point into the text.** Each `Issue` carries the
///   `Issue.source` range of the key or value in the file.
/// - **Writes are sparse and byte-stable**, with an optional header
///   (``HandEditedOptions``), in the schema's order or one the app gives
///   (``KeyOrder``). Comments are dropped by a write; ``HandEditedOptions/Comments/refused``
///   makes them a problem instead.
/// - **An update reads the file again under a lock** on `<path>.lock`, so an
///   edit made a moment ago is not lost: ``coordinatedUpdate(lockTimeout:_:)``
///   waits for another process without blocking, ``blockingUpdate(waitingUpTo:_:)``
///   waits by blocking the thread (for a synchronous caller), ``update(_:)`` does not wait.
/// - **Outside changes arrive** through ``reload()``, and ``watch(debounce:)``
///   calls it when the file changes. ``changes(buffering:)`` says what changed,
///   from what, and why.
/// - **The file is written whole only on purpose:** ``materialize()`` creates a
///   missing file, ``replaceUnusableFile(with:keepingCopyAt:)`` replaces one that
///   cannot be read, after keeping the person's bytes.
///
/// Reads are cheap (a lock); updates do file I/O on the calling thread, so
/// make them off the main actor when latency matters.
public final class SettingsStore<Value: Sendable & Equatable>: Sendable, Observable {
    /// Who owns the file, which decides what the store may write.
    public enum Format: Sendable, Hashable {
        /// The app: checksummed, migrations written back. (A repaired value
        /// is not: it may be a newer build's, and stays until the app sets it.)
        case appOwned
        /// A person: plain JSON with comments, nothing written back on load,
        /// and a file that cannot be read is left exactly as it is. An update
        /// rewrites the file without its comments, and only after reading it
        /// again (see the type's documentation, and ``HandEditedOptions``).
        case handEdited
    }

    /// Where the current value came from.
    public enum Source: Sendable, Hashable {
        /// The file.
        case file
        /// The previous generation, because the file was missing or unusable.
        case previousGeneration
        /// The defaults.
        case defaults(DefaultsReason)
        /// A document written by a newer version of the app: read-only.
        case newerFormat(version: Int?)
    }

    public enum DefaultsReason: Sendable, Hashable {
        /// There was no file: a first launch.
        case missing
        /// Every file was unusable. An app-owned file was quarantined; a
        /// hand-edited one is left exactly as it was (``fileProblem`` says why).
        case unusable
    }

    /// Why an update was refused.
    public enum UpdateError: Error, Sendable, CustomStringConvertible {
        /// The changed value is not one the schema accepts.
        case invalid([Issue])
        /// The file belongs to a newer version of the app.
        case newerFormat
        /// The write failed; the value and the file are as they were.
        case storage(StoreError)
        /// The new value is in the file and has been published, but the disk
        /// could not confirm it is durable (`StoreError.Kind.durabilityUnknown`):
        /// a power loss may bring back the old one. Unlike every other case,
        /// the update *happened*.
        case durabilityUnknown(StoreError)
        /// Another process held the lock on a hand-edited file for the whole
        /// wait (``HandEditedOptions/lockTimeout``), or, from ``update(_:)``,
        /// at the moment it asked. Nothing was read or written; trying again is
        /// safe.
        case busy
        /// The hand-edited file, as it stands, cannot be read: it is not JSON,
        /// not UTF-8, the wrong shape, or unreadable. Writing over it would
        /// destroy what the person wrote, so nothing is written, and the file
        /// is untouched; the person fixes it, and the next update finds it so.
        case fileUnusable(SettingsFileProblem)

        public var description: String {
            switch self {
            case .invalid(let issues): "settings update refused: " + issues.map(\.description).joined(separator: "; ")
            case .newerFormat: "settings were written by a newer version of the app and are read-only"
            case .storage(let error): "settings could not be saved: \(error)"
            case .durabilityUnknown(let error): "settings were saved, but may not survive a power loss: \(error)"
            case .busy: "settings update refused: another process is writing the file"
            case .fileUnusable(let problem): "settings update refused, and the file left as it is: \(problem)"
            }
        }
    }

    /// What the store does with keys in the file that the schema does not
    /// declare (a field a newer build added, a key another tool keeps there)
    /// when it next writes.
    public enum UnknownKeysOnSave: Sendable, Hashable {
        /// Write them back unchanged, so an older build never destroys what
        /// a newer one saved. The default. Top-level keys and the keys of
        /// objects nested in declared fields are kept; unknown keys inside
        /// arrays, dictionaries and unions are not (design/18).
        case keep
        /// Write only what the schema declares: for an app whose file
        /// should not accumulate keys it will never read.
        case drop
    }

    /// How the store is opened beyond what the file means.
    public struct Options: Sendable, Hashable {
        /// Hold an advisory lock on `<path>.lock` while the store is open, so
        /// two processes cannot both write the file: a second `open` throws
        /// `.busy` (or waits, with `open(…lockTimeout:)`). The OS releases the
        /// lock when the process dies. Off by default. It keeps out only
        /// writers that take the lock too, and may not work over a network
        /// volume (see `FileLock`).
        ///
        /// Meant for an app-owned file. A hand-edited store takes a lock on
        /// the same file for each update instead (so that a command-line tool
        /// can edit beside the app), and one that also holds it for life makes
        /// every such tool wait for it for ever: with it set, the store's own
        /// hold is the lock its updates use.
        public var crossProcessLock: Bool

        /// How a ``Format/handEdited`` store reads and writes.
        public var handEdited: HandEditedOptions

        public init(crossProcessLock: Bool = false) {
            self.crossProcessLock = crossProcessLock
            handEdited = HandEditedOptions()
        }

        public init(crossProcessLock: Bool = false, handEdited: HandEditedOptions) {
            self.crossProcessLock = crossProcessLock
            self.handEdited = handEdited
        }
    }

    struct Current {
        var value: Value
        var issues: [Issue]
        var source: Source
        /// The document the value was read from (or last wrote), whose
        /// undeclared keys the next write carries. `nil` when there is
        /// nothing to carry.
        var document: JSONValue?
        /// Fields the load repaired whose file values every write puts back
        /// until the app changes them.
        var repaired: [RepairedField] = []
        /// Why the hand-edited file as it stands cannot be used, while the
        /// value is the last good one (or the defaults).
        var problem: SettingsFileProblem?
        /// What the store last saw of a hand-edited file, read or written: a
        /// reload that finds the same has nothing to do (it is how the store's
        /// own writes, which the watcher reports too, cost nothing).
        var read: FileRead?
        /// What changed in commits whose observers have not been told yet.
        var unnotified: Set<Observed> = []
        /// The changes of the value in those commits, for the streams that were
        /// listening when each was committed.
        var unannounced: [Announcement] = []
    }

    /// What reading a hand-edited file found, as far as comparing it with the
    /// last reading goes.
    enum FileRead: Equatable {
        case missing
        case bytes([UInt8])
        /// Never equal to the last reading: a read that failed is tried again.
        case unreadable
    }

    /// A change of the value, and the streams to tell of it.
    struct Announcement {
        let change: SettingsChange<Value>
        let listeners: [AsyncStream<SettingsChange<Value>>.Continuation]
    }

    /// The streams of ``changes(buffering:)`` that have not ended.
    struct Listeners {
        var next: UInt64 = 0
        var continuations: [UInt64: AsyncStream<SettingsChange<Value>>.Continuation] = [:]
    }

    /// The observable properties, for notifying only what changed.
    enum Observed: Hashable {
        case value, issues, source, problem
    }

    public let path: String
    public let schema: Schema<Value>
    public let format: Format
    public let unknownKeys: UnknownKeysOnSave
    let file: AtomicFile
    /// The cross-process lock, held for the store's lifetime.
    private let lock: FileLock?
    private let decodeOptions: DecodeOptions
    let editing: HandEditedOptions
    let current: Mutex<Current>
    // Serialises updates end to end — validate, write, commit — without
    // holding `current`'s lock across the write, so reads never wait on I/O.
    // Observers are told after it is released (`notifyObservers`), so one
    // that reacts by updating or reloading does not re-enter it.
    let writing = Mutex(())
    let listeners = Mutex(Listeners())
    // Keeps what the streams are told in the order it was committed: taken
    // before the changes are, held while they are yielded. A stream's yield
    // never calls back into the store, so no observer can re-enter it.
    private let announcing = Mutex(())
    private let registrar = ObservationRegistrar()
    /// A test seam: run between a reload's read of the file and its
    /// publication, to put another writer exactly there.
    let betweenReloadAndPublish = Mutex<(@Sendable () -> Void)?>(nil)
    /// What ``blockingUpdate(waitingUpTo:_:)`` measures and paces its wait
    /// with: real time. A test seam.
    let blockingWait = Mutex(BlockingWait.real)

    /// Opens the settings at `path`. Never fails because of what is in the
    /// file (a hand-edited file that cannot be read is a ``fileProblem``, not a
    /// throw); only when the file system itself fails, or the options
    /// contradict the schema (`.invalidArgument`: a ``HandEditedOptions/fileHeader``
    /// naming a setting, or over a schema that rejects unknown keys).
    ///
    /// - Parameters:
    ///   - path: The settings file.
    ///   - schema: The settings' declaration. Must have defaults (an object
    ///     schema with `default:`), which are used for anything missing.
    ///   - format: Who owns the file.
    ///   - unknownKeys: Whether a write keeps the keys the schema does not
    ///     declare. Kept by default.
    ///   - fileSystem: Where the file lives; a simulated one in tests.
    ///   - options: With ``Options/crossProcessLock``, throws `.busy` if
    ///     another process has the store open. ``Options/handEdited`` says how
    ///     a hand-edited file is written.
    public static func open(
        at path: String,
        schema: Schema<Value>,
        format: Format = .appOwned,
        unknownKeys: UnknownKeysOnSave = .keep,
        fileSystem: any FileSystem = PosixFileSystem(),
        options: Options = Options()
    ) throws(StoreError) -> SettingsStore {
        var lock: FileLock?
        if options.crossProcessLock {
            let candidate = FileLock(path: path + ".lock", fileSystem: fileSystem)
            guard try candidate.tryAcquire() else {
                throw StoreError(kind: .busy, operation: "flock", path: path + ".lock", detail: "another process has the settings open")
            }
            lock = candidate
        }
        return try SettingsStore(path: path, schema: schema, format: format, unknownKeys: unknownKeys, fileSystem: fileSystem, lock: lock, handEdited: options.handEdited)
    }

    /// ``open(at:schema:format:unknownKeys:fileSystem:options:)``, waiting up
    /// to `lockTimeout` for another process to let go of the store.
    ///
    /// The wait polls the ambient clock and honours cancellation and
    /// `Deadline.current`; it never blocks a thread. Without
    /// ``Options/crossProcessLock`` there is nothing to wait for.
    public static func open(
        at path: String,
        schema: Schema<Value>,
        format: Format = .appOwned,
        unknownKeys: UnknownKeysOnSave = .keep,
        fileSystem: any FileSystem = PosixFileSystem(),
        options: Options = Options(),
        lockTimeout: Duration
    ) async throws(PolicyError<StoreError>) -> SettingsStore {
        var lock: FileLock?
        if options.crossProcessLock {
            let candidate = FileLock(path: path + ".lock", fileSystem: fileSystem)
            try await candidate.acquire(timeout: lockTimeout)
            lock = candidate
        }
        do throws(StoreError) {
            return try SettingsStore(path: path, schema: schema, format: format, unknownKeys: unknownKeys, fileSystem: fileSystem, lock: lock, handEdited: options.handEdited)
        } catch {
            throw .failed(error)
        }
    }

    private init(
        path: String, schema: Schema<Value>, format: Format, unknownKeys: UnknownKeysOnSave, fileSystem: any FileSystem,
        lock: FileLock?, handEdited: HandEditedOptions
    ) throws(StoreError) {
        self.lock = lock
        guard let defaults = schema.decode(JSONValue.object([:]), options: .lenient).value else {
            preconditionFailure("SettingsStore \(path): the schema must decode an empty object, so every setting needs a default")
        }
        if format == .handEdited { try Self.check(handEdited.fileHeader, against: schema, path: path) }
        self.path = path
        self.schema = schema
        self.format = format
        self.unknownKeys = unknownKeys
        self.editing = handEdited
        var decodeOptions = format == .handEdited ? DecodeOptions.lenient : DecodeOptions(mode: .lenient)
        // The dialect of a file a person edits is one thing, written in one
        // place (``HandEditedOptions``); an app-owned file is strict JSON.
        if format == .handEdited { decodeOptions.parse = handEdited.parseOptions }
        self.decodeOptions = decodeOptions
        // A hand-edited file has one generation and no envelope: the person's
        // own text, replaced by a single rename. A previous generation would
        // move their file aside first, and for the instant between the two
        // renames a reader (the command-line tool) would find no file.
        self.file = AtomicFile(
            fileSystem: fileSystem,
            options: .init(envelope: format == .appOwned, keepPrevious: format == .appOwned, newFileMode: 0o600)
        )

        if format == .handEdited {
            // Whatever the file holds, the store opens: a file that cannot be
            // used is reported, never moved or rewritten.
            let loaded = Self.loadHandEdited(
                path: path, schema: schema, file: file, options: decodeOptions, defaults: defaults, header: handEdited.fileHeader)
            current = Mutex(Self.state(from: loaded, over: nil, unknownKeys: unknownKeys))
            Self.reportHandEdited(loaded, kept: false, path: path)
            return
        }

        let loaded = try Self.load(path: path, schema: schema, format: format, file: file, options: decodeOptions, defaults: defaults)
        current = Mutex(Current(
            value: loaded.value, issues: loaded.issues, source: loaded.source, document: Self.carried(loaded, unknownKeys),
            repaired: Self.repairs(loaded)
        ))
        Self.report(loaded, path: path)

        // Migrated, an app-owned file is brought up to date now: the old form
        // does not linger, and survives as `.previous`. A repair alone is not
        // written back: the value it replaced may be a newer build's, and the
        // file keeps it until the app changes that field.
        if loaded.source == .file || loaded.source == .previousGeneration, Self.isMigrated(loaded) {
            do throws(StoreError) {
                if let legacy = loaded.legacyBytes {
                    // Kept beside it first, durably: the plain file is the way
                    // back to the release that wrote it. It is then replaced,
                    // not demoted, since a previous generation must be enveloped.
                    try AtomicFile(fileSystem: fileSystem, options: .init(envelope: false, newFileMode: 0o600))
                        .write(legacy, to: path + ".legacy")
                }
                try write(
                    loaded.value, carrying: Self.carried(loaded, unknownKeys), repaired: [],
                    options: loaded.legacyBytes == nil ? nil : .init(envelope: true, keepPrevious: false, newFileMode: 0o600)
                )
            } catch {
                Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                    .init("error", .error(error)), .init("during", .string("load"), privacy: .public),
                ]))
            }
        }
    }

    /// Refuses a file header the store could not honour: a key that is a
    /// setting (the header would overwrite what the schema writes, and the
    /// read would ignore a setting), or a schema that rejects unknown keys
    /// (the file's header would fail every read).
    private static func check(_ header: SettingsFileHeader, against schema: Schema<Value>, path: String) throws(StoreError) {
        guard !header.members.isEmpty, case .object(let node) = schema.node else { return }
        var claimed: Set<String> = []
        for field in node.fields {
            claimed.insert(field.key)
            claimed.formUnion(field.aliases)
        }
        if let versioning = node.versioning { claimed.insert(versioning.key) }
        for key in header.keys where claimed.contains(key) {
            throw StoreError(
                kind: .invalidArgument, operation: "open", path: path,
                detail: "the file header's `\(key)` is a setting of the schema, which is written from the value, not from a header")
        }
        guard node.unknownKeys != .reject else {
            throw StoreError(
                kind: .invalidArgument, operation: "open", path: path,
                detail: "a file header is ignored on read, which a schema that rejects unknown keys cannot do")
        }
    }

    deinit {
        // A stream of changes ends with the store, after what it still holds.
        let ending = listeners.withLock { listeners in
            defer { listeners.continuations = [:] }
            return Array(listeners.continuations.values)
        }
        for continuation in ending { continuation.finish() }
    }

    // MARK: Reading

    /// The settings. Observable.
    public var value: Value {
        registrar.access(self, keyPath: \.value)
        return current.withLock { $0.value }
    }

    /// What the last load repaired, migrated or warned about — for telling
    /// the user what was ignored. Empty after an update. Observable.
    ///
    /// For a hand-edited file that could not be read, the problem's issues,
    /// each with the line and column of what is wrong (see ``fileProblem``).
    public var issues: [Issue] {
        registrar.access(self, keyPath: \.issues)
        return current.withLock { $0.issues }
    }

    /// Where the value came from. Observable.
    public var source: Source {
        registrar.access(self, keyPath: \.source)
        return current.withLock { $0.source }
    }

    /// Why the hand-edited file, as it stands, cannot be used; `nil` when it
    /// can (or is missing). While it is set, ``value`` is the last good value
    /// (the defaults, if there has been none) and ``update(_:)`` refuses; the
    /// file itself is as the person left it. It clears when a reload or an
    /// update reads the file and finds it fixed. Observable.
    public var fileProblem: SettingsFileProblem? {
        registrar.access(self, keyPath: \.fileProblem)
        return current.withLock { $0.problem }
    }

    /// The changes of the value from now on, each with what it was, what it is
    /// and why (``SettingsChange``): for an app that keeps a history, or applies
    /// a setting to something that is not Observable.
    ///
    ///     for await change in settings.changes() {
    ///         history.record(change.old, change.new, because: change.cause)
    ///     }
    ///
    /// - **Once per change of the value, in the order they were committed**,
    ///   told after the commit's lock is released (as observers are), by whichever
    ///   call committed it, so an update has been announced by the time it returns.
    ///   Updates, reloads (the watch's too) and a reset each count; **the store's
    ///   own write that the watcher re-reads is not a second change**, nor is a
    ///   write or a reload that leaves the value as it was. An update that finds
    ///   the file changed is two: the reload's, then its own, so the app can tell
    ///   what a person (or another process) did from what it did. Each change's
    ///   ``SettingsChange/old`` is the previous change's ``SettingsChange/new``.
    /// - **A stream hears of what is committed after it was made**, not before:
    ///   read ``value`` for where things stand, then listen.
    /// - **The buffer is bounded** (a stream is not allowed to grow without limit
    ///   behind an app that stopped reading): when a reader falls `buffering`
    ///   changes behind, the *oldest* it has not read are dropped, and each drop is
    ///   reported (`settings.change_dropped`). A reader that cares sees it: a
    ///   change's `old` is not the one before's `new`. Reading promptly is the
    ///   remedy; a large `buffering` is the other.
    /// - **It ends** when the store goes (after the changes it still holds), and
    ///   when the reading task is cancelled or leaves the loop; a stream that has
    ///   ended costs the store nothing.
    ///
    /// It is a stream, and not a callback, because an app records history from an
    /// `async` context in order and with a bound, and because a callback told
    /// from inside an update's thread would have to say what it may call
    /// (Observation's, told after the lock, already says so for ``value``). Use
    /// ``value`` (Observable) to show the settings, and this to learn what
    /// happened to them.
    ///
    /// - Parameter limit: How many changes a reader may be behind by; at
    ///   least 1. 64 by default.
    public func changes(buffering limit: Int = 64) -> AsyncStream<SettingsChange<Value>> {
        precondition(limit >= 1, "SettingsStore.changes: buffering must be at least 1")
        let (stream, continuation) = AsyncStream<SettingsChange<Value>>.makeStream(bufferingPolicy: .bufferingNewest(limit))
        let id = listeners.withLock { listeners -> UInt64 in
            listeners.next += 1
            listeners.continuations[listeners.next] = continuation
            return listeners.next
        }
        continuation.onTermination = { [weak self] _ in
            self?.listeners.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Updating

    /// Changes the settings: validated, written, then published.
    ///
    /// A hand-edited store first reads the file again, under a lock on
    /// `<path>.lock` (so an edit made a moment ago, by a person or another
    /// process, is the value the change is applied to, not lost). It does not
    /// wait for the lock: if another process holds it now, this throws
    /// ``UpdateError/busy``. ``coordinatedUpdate(lockTimeout:_:)`` waits.
    ///
    /// - Returns: The new value.
    /// - Throws: ``UpdateError``. On any error but
    ///   ``UpdateError/durabilityUnknown(_:)`` nothing has changed; with that
    ///   one, the new value is in the file and published, and only its
    ///   durability is in doubt.
    @discardableResult
    public func update(_ change: (inout Value) throws -> Void) throws -> Value {
        try update(source: nil, change)
    }

    /// ``update(_:)``, saying who is changing the settings: `source` rides on the
    /// ``SettingsChange`` the update makes (``SettingsChange/source``), as given.
    @discardableResult
    public func update(source: String, _ change: (inout Value) throws -> Void) throws -> Value {
        try update(source: Optional(source), change)
    }

    private func update(source: String?, _ change: (inout Value) throws -> Void) throws -> Value {
        defer { notifyObservers() }
        guard format == .handEdited else {
            return try writing.withLock { _ throws -> Value in try updateAppOwned(change, source: source) }
        }
        let held = try lockWithoutWaiting()
        defer { release(held) }
        return try writing.withLock { _ throws -> Value in try updateHandEdited(change, source: source) }
    }

    /// ``update(_:)``, waiting for another process that is writing a
    /// hand-edited file to let go of its lock.
    ///
    /// The wait polls the ambient clock (a test clock drives it) and never
    /// blocks a thread; it ends when the lock is free, after `lockTimeout`
    /// (``HandEditedOptions/lockTimeout``, two seconds, unless given here) with
    /// ``UpdateError/busy``, or when the task is cancelled, with
    /// `CancellationError`. Nothing is read or written until the lock is held.
    /// For an app-owned store there is no other writer to wait for, and this is
    /// ``update(_:)``.
    ///
    /// It is a separate method because ``update(_:)`` is synchronous and is
    /// called from places that cannot wait (a UI handler), and an `async`
    /// overload of the same name would be the one an `async` caller got
    /// without asking, and would break every such caller that does not
    /// write `await`.
    @discardableResult
    public func coordinatedUpdate(
        lockTimeout: Duration? = nil, _ change: (inout Value) throws -> Void
    ) async throws -> Value {
        try await coordinatedUpdate(lockTimeout: lockTimeout, source: nil, change)
    }

    /// ``coordinatedUpdate(lockTimeout:_:)``, saying who is changing the settings
    /// (``SettingsChange/source``).
    @discardableResult
    public func coordinatedUpdate(
        lockTimeout: Duration? = nil, source: String, _ change: (inout Value) throws -> Void
    ) async throws -> Value {
        try await coordinatedUpdate(lockTimeout: lockTimeout, source: Optional(source), change)
    }

    private func coordinatedUpdate(
        lockTimeout: Duration?, source: String?, _ change: (inout Value) throws -> Void
    ) async throws -> Value {
        guard format == .handEdited else { return try update(source: source, change) }
        defer { notifyObservers() }
        let held = try await lockWaiting(up: lockTimeout ?? editing.lockTimeout)
        defer { release(held) }
        return try writing.withLock { _ throws -> Value in try updateHandEdited(change, source: source) }
    }

    /// ``update(_:)``, waiting for another process that is writing a
    /// hand-edited file to let go of its lock, **and blocking the calling
    /// thread while it waits**.
    ///
    /// For callers that are synchronous and cannot become `async`: a command
    /// handler, a settings writer called from a place that cannot suspend. If
    /// you can `await`, use ``coordinatedUpdate(lockTimeout:_:)``, which waits
    /// without holding a thread; and **never call this on the main actor in new
    /// code**, where a wait of up to `waitingUpTo` freezes the interface. (The
    /// wait is bounded, and is as long as the other writer holds the lock, which
    /// is one small write: a few milliseconds, then the update itself.)
    ///
    /// - **The wait is real time.** It tries the lock every 25 ms by the
    ///   monotonic clock and sleeps the thread between tries. It does not use
    ///   the ambient clock: a test clock does not advance while a thread is
    ///   blocked, so waiting on it would never end, and its `sleep` is `async`.
    /// - **It ends** when the lock is free, after `waitingUpTo` with
    ///   ``UpdateError/busy`` (`settings.busy`, with how long it waited), or
    ///   when the calling task is cancelled, with `CancellationError`, checked
    ///   between tries. Nothing is read or written until the lock is held.
    /// - For an app-owned store there is no other writer, and this is
    ///   ``update(_:)``; one opened with `crossProcessLock` already holds the
    ///   lock and does not wait.
    ///
    /// - Parameters:
    ///   - wait: How long to wait for the lock (`waitingUpTo`); the store's
    ///     ``HandEditedOptions/lockTimeout`` (two seconds) when `nil`. Zero tries
    ///     once, as ``update(_:)`` does.
    ///   - change: The change to make, as for ``update(_:)``.
    @discardableResult
    public func blockingUpdate(waitingUpTo wait: Duration? = nil, _ change: (inout Value) throws -> Void) throws -> Value {
        try blockingUpdate(waitingUpTo: wait, source: nil, change)
    }

    /// ``blockingUpdate(waitingUpTo:_:)``, saying who is changing the settings
    /// (``SettingsChange/source``).
    @discardableResult
    public func blockingUpdate(
        waitingUpTo wait: Duration? = nil, source: String, _ change: (inout Value) throws -> Void
    ) throws -> Value {
        try blockingUpdate(waitingUpTo: wait, source: Optional(source), change)
    }

    private func blockingUpdate(
        waitingUpTo wait: Duration?, source: String?, _ change: (inout Value) throws -> Void
    ) throws -> Value {
        guard format == .handEdited else { return try update(source: source, change) }
        defer { notifyObservers() }
        let held = try lockBlocking(waitingUpTo: wait ?? editing.lockTimeout)
        defer { release(held) }
        return try writing.withLock { _ throws -> Value in try updateHandEdited(change, source: source) }
    }

    private func updateAppOwned(_ change: (inout Value) throws -> Void, source: String?) throws -> Value {
        let (old, held, document, repaired) = current.withLock { ($0.value, $0.source, $0.document, $0.repaired) }
        if case .newerFormat = held { throw UpdateError.newerFormat }
        var new = old
        try change(&new)
        if new == old { return old }
        return try commit(new, carrying: document, repaired: repaired, source: source)
    }

    /// The update of a hand-edited file, with the cross-process lock held:
    /// read the file as it stands, make the change to what it holds, write.
    private func updateHandEdited(_ change: (inout Value) throws -> Void, source: String?) throws -> Value {
        let state = refresh()
        if let problem = state.problem {
            Ambient.record(Event("settings.update_refused", level: .warning, label: path, fields: [
                .init("reason", .string(problem.reason), privacy: .public),
            ]))
            throw UpdateError.fileUnusable(problem)
        }
        if case .newerFormat = state.source { throw UpdateError.newerFormat }
        var new = state.value
        try change(&new)
        if new == state.value { return state.value }
        return try commit(new, carrying: state.document, repaired: state.repaired, source: source)
    }

    /// Validates `new`, writes it, and publishes it: the end of every update.
    private func commit(_ new: Value, carrying document: JSONValue?, repaired: [RepairedField], source: String?) throws -> Value {
        let problems = schema.validate(new)
        guard problems.isEmpty else {
            Ambient.record(Event("settings.rejected", level: .notice, label: path, fields: [
                .init("issues", .int(problems.count)),
            ]))
            throw UpdateError.invalid(problems)
        }
        let written: Written
        do throws(StoreError) {
            written = try write(new, carrying: document, repaired: repaired)
        } catch where error.kind == .durabilityUnknown {
            // The file holds the new value, so memory must too: the next
            // launch reads it unless the power fails first.
            let json = encoded(new, carrying: document, repaired: repaired)
            publish(committed(new, Written(json: json.json, repaired: json.repaired, bytes: bytes(for: json.json))), cause: .update, source: source)
            Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                .init("error", .error(error)), .init("during", .string("update"), privacy: .public),
            ]))
            throw UpdateError.durabilityUnknown(error)
        } catch {
            Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                .init("error", .error(error)), .init("during", .string("update"), privacy: .public),
            ]))
            throw UpdateError.storage(error)
        }
        publish(committed(new, written), cause: .update, source: source)
        Ambient.record(Event("settings.saved", level: .debug, label: path))
        return new
    }

    /// The state after `new` was written as `written`.
    func committed(_ new: Value, _ written: Written) -> Current {
        Current(
            value: new, issues: [], source: .file, document: unknownKeys == .keep ? written.json : nil, repaired: written.repaired,
            read: format == .handEdited ? .bytes(written.bytes) : nil
        )
    }

    // MARK: Locking a hand-edited file

    /// Takes the lock on `<path>.lock` if it is free; `nil` if the store holds
    /// it for its whole life (``Options/crossProcessLock``), which excludes
    /// the other writers already.
    func lockWithoutWaiting() throws(UpdateError) -> FileLock? {
        guard lock == nil else { return nil }
        guard let candidate = try tryLock() else {
            recordBusy(waited: .zero)
            throw UpdateError.busy
        }
        return candidate
    }

    /// One try at the lock on `<path>.lock`: the lock if it was free, `nil` if
    /// another holds it.
    func tryLock() throws(UpdateError) -> FileLock? {
        let candidate = FileLock(path: path + ".lock", fileSystem: file.fileSystem)
        do throws(StoreError) {
            return try candidate.tryAcquire() ? candidate : nil
        } catch {
            throw .storage(error)
        }
    }

    /// ``lockWithoutWaiting()``, trying again every ``BlockingWait/pollInterval``
    /// for up to `timeout`, on the thread. Real time, for the reason
    /// ``BlockingWait`` gives.
    func lockBlocking(waitingUpTo timeout: Duration) throws -> FileLock? {
        guard lock == nil else { return nil }
        let wait = blockingWait.withLock { $0 }
        let started = wait.now()
        while true {
            // Cancellation is cancellation, not a reason the lock was busy; and a
            // task that was cancelled does not go on to write.
            if Task.isCancelled { throw CancellationError() }
            if let held = try tryLock() { return held }
            let waited = wait.now() - started
            guard waited < timeout else {
                recordBusy(waited: waited)
                throw UpdateError.busy
            }
            wait.pause(min(BlockingWait.pollInterval, timeout - waited))
        }
    }

    func recordBusy(waited: Duration) {
        let components = waited.components
        let milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        Ambient.record(Event("settings.busy", level: .warning, label: path, fields: [.init("waitMs", .int(Int(milliseconds)))]))
    }

    private func lockWaiting(up timeout: Duration) async throws -> FileLock? {
        guard lock == nil else { return nil }
        let candidate = FileLock(path: path + ".lock", fileSystem: file.fileSystem)
        do throws(PolicyError<StoreError>) {
            try await candidate.acquire(timeout: timeout)
        } catch {
            switch error {
            case .failed(let failure):
                throw UpdateError.storage(failure)
            case .rejected(let rejection) where rejection.isCancellation:
                // Cancellation is cancellation, not a reason the lock was busy.
                throw CancellationError()
            case .rejected:
                recordBusy(waited: timeout)
                throw UpdateError.busy
            }
        }
        return candidate
    }

    /// Lets go of the lock an update took. A failure to unlock does not change
    /// the update's outcome, and the descriptor is closed either way, which
    /// the system takes as letting go.
    func release(_ held: FileLock?) {
        do throws(StoreError) {
            try held?.release()
        } catch {
            Ambient.record(Event("settings.lock_release_failed", level: .warning, label: path, fields: [
                .init("error", .error(error)),
            ]))
        }
    }

    // MARK: Reloading

    /// Reads the file again, for one edited outside the app. Changes are
    /// published like an update's.
    ///
    /// The read and the publication happen under the same lock as an update's
    /// write and publication. Were the lock released between them, an update
    /// could commit in the gap and the older value read before it would then
    /// be published over it: an acknowledged update, lost from memory.
    ///
    /// For a hand-edited file this never throws and never touches the file. A
    /// file that has not changed since the store last read or wrote it is
    /// left alone (nothing is published, nothing reported), so calling this
    /// on every change a watcher reports, the store's own writes included, is
    /// free. A file that cannot be used leaves the last good value in place
    /// and sets ``fileProblem``; one that is gone gives the defaults.
    public func reload() throws(StoreError) {
        defer { notifyObservers() }
        guard format == .appOwned else {
            writing.withLock { _ in _ = refresh() }
            return
        }
        try writing.withLock { _ throws(StoreError) in
            guard let defaults = schema.decode(JSONValue.object([:]), options: .lenient).value else {
                preconditionFailure("unreachable: checked when the store opened")
            }
            let loaded = try Self.load(path: path, schema: schema, format: format, file: file, options: decodeOptions, defaults: defaults)
            Self.report(loaded, path: path)
            betweenReloadAndPublish.withLock { $0 }?()
            publish(Current(
                value: loaded.value, issues: loaded.issues, source: loaded.source, document: Self.carried(loaded, unknownKeys),
                repaired: Self.repairs(loaded)
            ), cause: .reload)
        }
    }

    /// Reads the hand-edited file and, unless it is what the store last saw,
    /// publishes what it holds. Returns the state after. Called under
    /// `writing`, for the reason ``reload()`` gives.
    func refresh() -> Current {
        guard let defaults = schema.decode(JSONValue.object([:]), options: .lenient).value else {
            preconditionFailure("unreachable: checked when the store opened")
        }
        let loaded = Self.loadHandEdited(
            path: path, schema: schema, file: file, options: decodeOptions, defaults: defaults, header: editing.fileHeader)
        let held = current.withLock { $0 }
        guard Self.differs(loaded.read, from: held.read) else { return held }
        let next = Self.state(from: loaded, over: held, unknownKeys: unknownKeys)
        Self.reportHandEdited(loaded, kept: next.problem != nil && next.source == .file, path: path)
        if loaded.problem == nil {
            Ambient.record(Event("settings.reloaded", level: .info, label: path, fields: [
                .init("source", .string(next.source.name), privacy: .public), .init("issues", .int(next.issues.count)),
            ]))
        }
        betweenReloadAndPublish.withLock { $0 }?()
        publish(next, cause: .reload)
        return next
    }

    // MARK: Internals

    struct Loaded {
        let value: Value
        let issues: [Issue]
        let source: Source
        /// The parsed file the value came from, if there was one and its
        /// keys can be carried (see `carried`).
        let document: JSONValue?
        /// The fields that were repaired, with what the file held.
        var repaired: [RepairedField] = []
        /// The file's bytes, when it was plain JSON from before the store
        /// (an app-owned file with no envelope that the schema reads).
        var legacyBytes: [UInt8]?
        /// Why a hand-edited file could not be used. Then `value` is the
        /// defaults, and a store that holds a good value keeps it instead.
        var problem: SettingsFileProblem?
        /// What reading a hand-edited file found.
        var read: FileRead?
    }

    /// What a write put in the file, and the fields it still carries.
    struct Written {
        let json: JSONValue
        let repaired: [RepairedField]
        let bytes: [UInt8]
    }

    /// Whether `loaded` came from an older form than the one this store
    /// writes: migrated by the schema, or a plain file from before the store.
    static func isMigrated(_ loaded: Loaded) -> Bool {
        loaded.legacyBytes != nil || loaded.issues.contains { $0.code == .migrated }
    }

    /// The fields the load repaired, whose file values writes carry. None for
    /// a migrated document, for the reason `carried` gives.
    static func repairs(_ loaded: Loaded) -> [RepairedField] {
        guard !isMigrated(loaded) else { return [] }
        return loaded.repaired
    }

    /// The document whose undeclared keys a write should carry. A migrated
    /// document carries none: what the schema does not declare there is
    /// what the migration left behind, not something a newer build added.
    static func carried(_ loaded: Loaded, _ unknownKeys: UnknownKeysOnSave) -> JSONValue? {
        guard unknownKeys == .keep, !isMigrated(loaded) else { return nil }
        return loaded.document
    }

    /// Writes `value`, with the keys of `document` that the schema does not
    /// declare put back, and the file's values of the `repaired` fields the
    /// app has not changed. Returns what was written and the repaired fields
    /// still carried.
    @discardableResult
    func write(
        _ value: Value, carrying document: JSONValue?, repaired: [RepairedField], options: AtomicFile.Options? = nil
    ) throws(StoreError) -> Written {
        let written = encoded(value, carrying: document, repaired: repaired)
        let bytes = bytes(for: written.json)
        try file.write(bytes, to: path, options: options)
        return Written(json: written.json, repaired: written.repaired, bytes: bytes)
    }

    /// The document a write of `value` puts in the file.
    func encoded(
        _ value: Value, carrying document: JSONValue?, repaired: [RepairedField]
    ) -> (json: JSONValue, repaired: [RepairedField]) {
        var json = schema.encode(value, style: .sparse(includeSecrets: true))
        if let document { json = UnknownKeys.carrying(document, into: json, node: schema.node) }
        guard !repaired.isEmpty else { return (json, []) }
        return RepairedField.restoring(repaired, into: json, full: schema.encode(value, style: .init(.full, includeSecrets: true)))
    }

    /// Commits `next` as the current value. Called under `writing`, so
    /// commits happen in the order updates and reloads were serialised; what
    /// changed is remembered for ``notifyObservers()``.
    func publish(_ next: Current, cause: SettingsChange<Value>.Cause, source: String? = nil) {
        // Who is listening when the value changes, not when it is announced:
        // a stream hears of what was committed after it began, no earlier.
        let listening = listeners.withLock { Array($0.continuations.values) }
        current.withLock { current in
            var changed = current.unnotified
            var unannounced = current.unannounced
            if current.value != next.value {
                changed.insert(.value)
                if !listening.isEmpty {
                    unannounced.append(Announcement(
                        change: SettingsChange(old: current.value, new: next.value, cause: cause, source: source), listeners: listening))
                }
            }
            if current.issues != next.issues { changed.insert(.issues) }
            if current.source != next.source { changed.insert(.source) }
            if current.problem != next.problem { changed.insert(.problem) }
            current = next
            current.unnotified = changed
            current.unannounced = unannounced
        }
    }

    /// Tells observers what changed since they were last told, outside every
    /// lock: an observer may read, update or reload the store. Each change is
    /// told once, by whichever call gets here first after committing it; by
    /// then the value it reads is the latest committed, never an older one.
    func notifyObservers() {
        let (changed, dropped) = announcing.withLock { _ -> (Set<Observed>, Int) in
            let (changed, announcements) = current.withLock { current in
                defer {
                    current.unnotified = []
                    current.unannounced = []
                }
                return (current.unnotified, current.unannounced)
            }
            var dropped = 0
            for announcement in announcements {
                for listener in announcement.listeners {
                    if case .dropped = listener.yield(announcement.change) { dropped += 1 }
                }
            }
            return (changed, dropped)
        }
        if dropped > 0 {
            Ambient.record(Event("settings.change_dropped", level: .warning, label: path, fields: [.init("dropped", .int(dropped))]))
        }
        if changed.contains(.value) { registrar.withMutation(of: self, keyPath: \.value) {} }
        if changed.contains(.issues) { registrar.withMutation(of: self, keyPath: \.issues) {} }
        if changed.contains(.source) { registrar.withMutation(of: self, keyPath: \.source) {} }
        if changed.contains(.problem) { registrar.withMutation(of: self, keyPath: \.fileProblem) {} }
    }

    private static func load(
        path: String,
        schema: Schema<Value>,
        format: Format,
        file: AtomicFile,
        options: DecodeOptions,
        defaults: Value
    ) throws(StoreError) -> Loaded {
        if format == .appOwned, let legacy = try legacy(path: path, schema: schema, fileSystem: file.fileSystem, options: options) {
            return legacy
        }
        // A document from a newer app version is intact, not corrupt: it must
        // not be quarantined or fallen back over.
        let isNewer: ([UInt8]) -> Bool = { bytes in
            schema.decodeReporting(bytes, options: options).errors.contains { $0.code == .versionTooNew }
        }
        let contents: AtomicFile.Contents?
        do throws(StoreError) {
            contents = try file.read(path) { bytes in
                schema.decodeReporting(bytes, options: options).value != nil || isNewer(bytes)
            }
        } catch where error.kind == .corrupt {
            return Loaded(value: defaults, issues: [], source: .defaults(.unusable), document: nil)
        }
        guard let contents else {
            return Loaded(value: defaults, issues: [], source: .defaults(.missing), document: nil)
        }
        let decoded = schema.decodeReporting(contents.bytes, options: options)
        if let value = decoded.value {
            // A newer document the schema could read (its unknown keys
            // preserved) is still the newer app's: read-only.
            if let newer = decoded.issues.first(where: { $0.code == .versionTooNew }) {
                return Loaded(value: value, issues: decoded.issues, source: .newerFormat(version: newer.foundVersion), document: nil)
            }
            let document = try? JSONParser(options: options.parse).parseValue(contents.bytes)
            return Loaded(
                value: value, issues: decoded.issues,
                source: contents.source == .current ? .file : .previousGeneration, document: document,
                repaired: RepairedField.found(
                    in: decoded.issues, document: document, repaired: schema.encode(value, style: .init(.full, includeSecrets: true))
                ))
        }
        let newer = decoded.errors.first { $0.code == .versionTooNew }
        return Loaded(value: defaults, issues: decoded.issues, source: .newerFormat(version: newer?.foundVersion), document: nil)
    }

    /// The settings at `path`, if it is plain JSON from before the store: an
    /// app adopting it keeps the file its earlier releases wrote, rather than
    /// see it quarantined as corrupt for want of an envelope. Read through
    /// the same schema; a file it does not read is left to the usual path.
    private static func legacy(
        path: String, schema: Schema<Value>, fileSystem: any FileSystem, options: DecodeOptions
    ) throws(StoreError) -> Loaded? {
        // Without an envelope and without validation, a read never quarantines.
        guard let raw = try AtomicFile(fileSystem: fileSystem, options: .init(envelope: false)).read(path)?.bytes,
              !raw.starts(with: Array("STAF".utf8)) else { return nil }
        let decoded = schema.decodeReporting(raw, options: options)
        guard let value = decoded.value, !decoded.issues.contains(where: { $0.code == .versionTooNew }) else { return nil }
        let document = try? JSONParser(options: options.parse).parseValue(raw)
        return Loaded(value: value, issues: decoded.issues, source: .file, document: document, legacyBytes: raw)
    }

    static func report(_ loaded: Loaded, path: String) {
        let repaired = loaded.issues.filter { $0.severity == .repaired }.count
        let migrated = loaded.issues.contains { $0.code == .migrated }
        Ambient.record(Event("settings.loaded", level: .debug, label: path, fields: [
            .init("source", .string(loaded.source.name), privacy: .public),
            .init("issues", .int(loaded.issues.count)),
        ]))
        if repaired > 0 {
            Ambient.record(Event("settings.repaired", level: .warning, label: path, fields: [.init("fields", .int(repaired))]))
        }
        if loaded.legacyBytes != nil {
            Ambient.record(Event("settings.migrated", level: .info, label: path, fields: [
                .init("from", .string("plain_json"), privacy: .public),
            ]))
        } else if migrated {
            Ambient.record(Event("settings.migrated", level: .info, label: path))
        }
        switch loaded.source {
        case .previousGeneration:
            Ambient.record(Event("settings.recovered", level: .warning, label: path))
        case .defaults(.unusable):
            Ambient.record(Event("settings.reset", level: .error, label: path))
        case .newerFormat(let version):
            Ambient.record(Event("settings.newer_format", level: .warning, label: path, fields: [
                .init("version", .int(version ?? -1)),
            ]))
        case .file, .defaults(.missing):
            break
        }
    }
}

extension SettingsStore.Source {
    var name: String {
        switch self {
        case .file: "file"
        case .previousGeneration: "previous"
        case .defaults(.missing): "defaults (missing)"
        case .defaults(.unusable): "defaults (unusable)"
        case .newerFormat: "newer format"
        }
    }
}

extension Issue {
    /// The version a `version_too_new` issue found, if it says.
    var foundVersion: Int? {
        (parameters["version"]?.number?.lexeme).flatMap { Int($0) }
    }
}

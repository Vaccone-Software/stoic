public import Observation
internal import Stoic
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
/// Reads are cheap (a lock); updates do file I/O on the calling thread, so
/// make them off the main actor when latency matters.
public final class SettingsStore<Value: Sendable & Equatable>: Sendable, Observable {
    /// Who owns the file, which decides what the store may write.
    public enum Format: Sendable, Hashable {
        /// The app: checksummed, migrations and repairs written back.
        case appOwned
        /// A person: plain JSON with comments, nothing written back on load.
        /// An update rewrites the file without its comments.
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
        /// Every file was unusable, and was quarantined.
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

        public var description: String {
            switch self {
            case .invalid(let issues): "settings update refused: " + issues.map(\.description).joined(separator: "; ")
            case .newerFormat: "settings were written by a newer version of the app and are read-only"
            case .storage(let error): "settings could not be saved: \(error)"
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

    private struct Current {
        var value: Value
        var issues: [Issue]
        var source: Source
        /// The document the value was read from (or last wrote), whose
        /// undeclared keys the next write carries. `nil` when there is
        /// nothing to carry.
        var document: JSONValue?
    }

    public let path: String
    public let schema: Schema<Value>
    public let format: Format
    public let unknownKeys: UnknownKeysOnSave
    private let file: AtomicFile
    private let decodeOptions: DecodeOptions
    private let current: Mutex<Current>
    // Serialises updates end to end — validate, write, publish — without
    // holding `current`'s lock across the write, so reads never wait on I/O.
    private let writing = Mutex(())
    private let registrar = ObservationRegistrar()

    /// Opens the settings at `path`. Never fails because of what is in the
    /// file; only when the file system itself fails.
    ///
    /// - Parameters:
    ///   - path: The settings file.
    ///   - schema: The settings' declaration. Must have defaults (an object
    ///     schema with `default:`), which are used for anything missing.
    ///   - format: Who owns the file.
    ///   - unknownKeys: Whether a write keeps the keys the schema does not
    ///     declare. Kept by default.
    ///   - fileSystem: Where the file lives; a simulated one in tests.
    public static func open(
        at path: String,
        schema: Schema<Value>,
        format: Format = .appOwned,
        unknownKeys: UnknownKeysOnSave = .keep,
        fileSystem: any FileSystem = PosixFileSystem()
    ) throws(StoreError) -> SettingsStore {
        try SettingsStore(path: path, schema: schema, format: format, unknownKeys: unknownKeys, fileSystem: fileSystem)
    }

    private init(
        path: String, schema: Schema<Value>, format: Format, unknownKeys: UnknownKeysOnSave, fileSystem: any FileSystem
    ) throws(StoreError) {
        guard let defaults = schema.decode(JSONValue.object([:]), options: .lenient).value else {
            preconditionFailure("SettingsStore \(path): the schema must decode an empty object, so every setting needs a default")
        }
        self.path = path
        self.schema = schema
        self.format = format
        self.unknownKeys = unknownKeys
        self.decodeOptions = format == .handEdited ? .lenient : DecodeOptions(mode: .lenient)
        self.file = AtomicFile(
            fileSystem: fileSystem,
            options: .init(envelope: format == .appOwned, keepPrevious: true)
        )

        let loaded = try Self.load(path: path, schema: schema, file: file, options: decodeOptions, defaults: defaults)
        current = Mutex(Current(value: loaded.value, issues: loaded.issues, source: loaded.source, document: Self.carried(loaded, unknownKeys)))
        Self.report(loaded, path: path)

        // Migrated or repaired, an app-owned file is brought up to date now:
        // the old form does not linger, and survives as `.previous`.
        if format == .appOwned, loaded.source == .file || loaded.source == .previousGeneration,
           loaded.issues.contains(where: { $0.code == .migrated || $0.severity == .repaired }) {
            do throws(StoreError) {
                try write(loaded.value, carrying: Self.carried(loaded, unknownKeys))
            } catch {
                Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                    .init("error", .error(error)), .init("during", .string("load"), privacy: .public),
                ]))
            }
        }
    }

    // MARK: Reading

    /// The settings. Observable.
    public var value: Value {
        registrar.access(self, keyPath: \.value)
        return current.withLock { $0.value }
    }

    /// What the last load repaired, migrated or warned about — for telling
    /// the user what was ignored. Empty after an update. Observable.
    public var issues: [Issue] {
        registrar.access(self, keyPath: \.issues)
        return current.withLock { $0.issues }
    }

    /// Where the value came from. Observable.
    public var source: Source {
        registrar.access(self, keyPath: \.source)
        return current.withLock { $0.source }
    }

    // MARK: Updating

    /// Changes the settings: validated, written, then published.
    ///
    /// - Returns: The new value.
    /// - Throws: ``UpdateError``; on any error nothing has changed.
    @discardableResult
    public func update(_ change: (inout Value) throws -> Void) throws -> Value {
        try writing.withLock { _ throws -> Value in
            let (old, source, document) = current.withLock { ($0.value, $0.source, $0.document) }
            if case .newerFormat = source { throw UpdateError.newerFormat }
            var new = old
            try change(&new)
            if new == old { return old }
            let problems = schema.validate(new)
            guard problems.isEmpty else {
                Ambient.record(Event("settings.rejected", level: .notice, label: path, fields: [
                    .init("issues", .int(problems.count)),
                ]))
                throw UpdateError.invalid(problems)
            }
            let written: JSONValue
            do throws(StoreError) {
                written = try write(new, carrying: document)
            } catch {
                Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                    .init("error", .error(error)), .init("during", .string("update"), privacy: .public),
                ]))
                throw UpdateError.storage(error)
            }
            publish(Current(value: new, issues: [], source: .file, document: unknownKeys == .keep ? written : nil))
            Ambient.record(Event("settings.saved", level: .debug, label: path))
            return new
        }
    }

    /// Reads the file again, for one edited outside the app. Changes are
    /// published like an update's.
    public func reload() throws(StoreError) {
        let loaded = try writing.withLock { _ throws(StoreError) -> Loaded in
            guard let defaults = schema.decode(JSONValue.object([:]), options: .lenient).value else {
                preconditionFailure("unreachable: checked when the store opened")
            }
            return try Self.load(path: path, schema: schema, file: file, options: decodeOptions, defaults: defaults)
        }
        Self.report(loaded, path: path)
        publish(Current(value: loaded.value, issues: loaded.issues, source: loaded.source, document: Self.carried(loaded, unknownKeys)))
    }

    // MARK: Internals

    private struct Loaded {
        let value: Value
        let issues: [Issue]
        let source: Source
        /// The parsed file the value came from, if there was one and its
        /// keys can be carried (see `carried`).
        let document: JSONValue?
    }

    /// The document whose undeclared keys a write should carry. A migrated
    /// document carries none: what the schema does not declare there is
    /// what the migration left behind, not something a newer build added.
    private static func carried(_ loaded: Loaded, _ unknownKeys: UnknownKeysOnSave) -> JSONValue? {
        guard unknownKeys == .keep, !loaded.issues.contains(where: { $0.code == .migrated }) else { return nil }
        return loaded.document
    }

    /// Writes `value`, with the keys of `document` that the schema does not
    /// declare put back. Returns what was written.
    @discardableResult
    private func write(_ value: Value, carrying document: JSONValue?) throws(StoreError) -> JSONValue {
        var json = schema.encode(value, style: .sparse(includeSecrets: true))
        if let document { json = UnknownKeys.carrying(document, into: json, node: schema.node) }
        let bytes = json.encoded(style: format == .handEdited ? .pretty() : .canonical)
        try file.write(bytes, to: path)
        return json
    }

    private func publish(_ next: Current) {
        let previous = current.withLock { current -> Current in
            defer { current = next }
            return current
        }
        // Observers are notified outside the lock, and only of what changed.
        if previous.value != next.value { registrar.withMutation(of: self, keyPath: \.value) {} }
        if previous.issues != next.issues { registrar.withMutation(of: self, keyPath: \.issues) {} }
        if previous.source != next.source { registrar.withMutation(of: self, keyPath: \.source) {} }
    }

    private static func load(
        path: String,
        schema: Schema<Value>,
        file: AtomicFile,
        options: DecodeOptions,
        defaults: Value
    ) throws(StoreError) -> Loaded {
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
                source: contents.source == .current ? .file : .previousGeneration, document: document)
        }
        let newer = decoded.errors.first { $0.code == .versionTooNew }
        return Loaded(value: defaults, issues: decoded.issues, source: .newerFormat(version: newer?.foundVersion), document: nil)
    }

    private static func report(_ loaded: Loaded, path: String) {
        let repaired = loaded.issues.filter { $0.severity == .repaired }.count
        let migrated = loaded.issues.contains { $0.code == .migrated }
        Ambient.record(Event("settings.loaded", level: .debug, label: path, fields: [
            .init("source", .string(loaded.source.name), privacy: .public),
            .init("issues", .int(loaded.issues.count)),
        ]))
        if repaired > 0 {
            Ambient.record(Event("settings.repaired", level: .warning, label: path, fields: [.init("fields", .int(repaired))]))
        }
        if migrated {
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

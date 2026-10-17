public import StoicJSON
public import StoicSchema
public import StoicStore

/// How a ``SettingsStore/Format/handEdited`` store reads and writes its file,
/// beyond what the schema says. An app-owned store ignores all of it.
///
///     var options = SettingsStore<Prefs>.Options()
///     options.handEdited.fileHeader = ["$schema": "prefs-schema.json"]
public struct HandEditedOptions: Sendable, Hashable {
    /// What the store writes at the top of the file, before anything else, and
    /// ignores when it reads one. See ``SettingsFileHeader``.
    public var fileHeader: SettingsFileHeader

    /// How a write lays the file out. ``Layout/canonical``, by default.
    public var layout: Layout

    /// How long an update that waits (``SettingsStore/coordinatedUpdate(lockTimeout:_:)``)
    /// gives another process that is writing the file (a command-line tool
    /// beside the app, a second instance) to let go, before it throws
    /// ``SettingsStore/UpdateError/busy``. Two seconds by default: the other
    /// writer holds the lock for the length of one small write.
    public var lockTimeout: Duration

    public init(fileHeader: SettingsFileHeader = [:], layout: Layout = .canonical, lockTimeout: Duration = .seconds(2)) {
        self.fileHeader = fileHeader
        self.layout = layout
        self.lockTimeout = lockTimeout
    }

    /// The shape of the file an update writes. Both are sparse (only what
    /// differs from the defaults, and the keys the schema does not declare),
    /// pretty-printed with a two-space indent, and begin with the
    /// ``fileHeader``.
    public enum Layout: Sendable, Hashable {
        /// Byte-stable: two writers with the same value write the same bytes,
        /// whatever order their files had. Members are in the order the schema
        /// declares its fields, with the version key first; the keys it does
        /// not declare follow, alphabetically, and so do the members of every
        /// object it does not describe (what a newer build added, a `json`
        /// field). Numbers are in the canonical spelling (`1.0` is `1`), and the
        /// file ends with a newline.
        ///
        /// The default for a file a person edits and tools also write, because
        /// a file that two writers lay out differently shows up in every diff,
        /// and a repository of dotfiles shows the person only what they changed.
        case canonical

        /// ``canonical``, with the order of some objects' keys given by the
        /// app: see ``KeyOrder``. For a file whose sections have an order a
        /// reader expects (the ones people edit most first), over a schema that
        /// does not declare them (`Schema.json()`) or declares them otherwise.
        /// Still byte-stable: the order is part of the layout, so two writers
        /// that share it write the same bytes. ``canonical(order:)`` makes one.
        case ordered(KeyOrder)

        /// The order the file had: declared fields in the schema's order, then
        /// the keys it does not declare in the order the file had them, each
        /// number as it was written, and no final newline. What an earlier
        /// release wrote; for an app whose users order their own keys.
        case sourceOrder

        /// ``canonical`` with `order` applied: the keys it lists first, in its
        /// order, then everything else as ``canonical`` has it.
        public static func canonical(order: KeyOrder) -> Layout { .ordered(order) }

        /// The order ``canonical``'s writes are arranged by; `nil` for
        /// ``sourceOrder``, which arranges nothing.
        var arrangement: KeyOrder? {
            switch self {
            case .canonical: KeyOrder()
            case .ordered(let order): order
            case .sourceOrder: nil
            }
        }
    }
}

/// The order of the keys of some objects in a ``HandEditedOptions/Layout/canonical(order:)``
/// file, which the app knows and the schema does not say.
///
///     // lodestar.json: its sections in the order a person reads them, then the rest alphabetically
///     let order = KeyOrder(root: ["lode", "app", "gestures", "web", "scroll"])
///     options.handEdited.layout = .canonical(order: order)
///
/// At each object the keys are placed in this order:
///
/// 1. **A version key and a union's discriminator** (the keys that tell a reader
///    what the object is) first, unless the order lists them, in which case
///    they go where it says.
/// 2. **The keys the order lists for this object**, in the order it lists
///    them; those the object does not have are skipped.
/// 3. **The rest as ``HandEditedOptions/Layout/canonical`` has them**: the
///    schema's declared fields in declaration order, then every other key
///    alphabetically (compared as the canonical encoding compares keys).
///
/// An object is named by the keys that lead to it from the root: `[]` is the
/// document, `["web"]` its `web` member, `["web", "routes"]` that one's
/// `routes`. A path never has an index: **the elements of an array share the
/// array's path**, so an order for `["hosts"]` arranges each object in the
/// `hosts` array alike. A dictionary's own keys are named like any others
/// (`["web", "routes", "github.com"]`; there is no wildcard).
public struct KeyOrder: Sendable, Hashable {
    /// The keys of the document's top-level object that come first, in order.
    public var root: [String]

    /// For the objects below the root, the keys that come first in each, in
    /// order, by the path of keys that leads to the object.
    public var nested: [[String]: [String]]

    public init(root: [String] = [], nested: [[String]: [String]] = [:]) {
        self.root = root
        self.nested = nested
    }

    /// The keys listed for the object at `path`.
    func keys(at path: [String]) -> [String] {
        path.isEmpty ? root : nested[path] ?? []
    }
}
/// Members a hand-edited store writes first, in this order, and ignores on
/// read: the `"$schema": "app-schema.json"` that points an editor at the
/// schema, a `"version"` that the schema itself does not manage.
///
///     var options = SettingsStore<Prefs>.Options()
///     options.handEdited.fileHeader = ["$schema": "prefs-schema.json", "version": 3]
///
/// A header key is not a setting. Reading a file does not report it as an
/// unknown key (and does not carry it: the header written is the one the app
/// configured, whatever the file held). It must not name a field of the
/// schema, an alias, or the schema's version key, and the schema must not
/// reject unknown keys, or ``SettingsStore/open(at:schema:format:unknownKeys:fileSystem:options:)``
/// throws `.invalidArgument`.
public struct SettingsFileHeader: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    /// The members, in the order they are written.
    public let members: [JSONObject.Member]

    /// The keys, in order.
    public var keys: [String] { members.map(\.key) }

    /// A header of `members`. A later member whose key repeats an earlier one
    /// replaces its value and keeps its place.
    public init(_ members: [JSONObject.Member]) {
        self.members = Array(JSONObject(members))
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements.map { JSONObject.Member(key: $0.0, value: $0.1) })
    }
}

/// Why the file at a hand-edited store's path, as it stands, cannot be used.
/// The store never moves, renames or overwrites such a file: the person has to
/// fix it, or delete it, and the next reload or update finds the fix.
public enum SettingsFileProblem: Sendable, Equatable, CustomStringConvertible {
    /// The file is not what the schema reads: not JSON, not UTF-8, or the wrong
    /// shape at the top. The issues say where, each with the `Issue.source`
    /// line and column of the text; the first error is the one to show.
    case unparsable([Issue])
    /// The file exists and could not be read (permission denied, a directory in
    /// its place, an I/O error).
    case unreadable(StoreError)

    public static func == (lhs: SettingsFileProblem, rhs: SettingsFileProblem) -> Bool {
        switch (lhs, rhs) {
        case (.unparsable(let a), .unparsable(let b)): a == b
        case (.unreadable(let a), .unreadable(let b)): a.description == b.description
        default: false
        }
    }

    public var description: String {
        switch self {
        case .unparsable:
            "the settings file cannot be read" + (firstIssue.map { ": \($0)" } ?? "")
        case .unreadable(let error):
            "the settings file cannot be read: \(error)"
        }
    }

    /// Where the first problem in the text is, when there is text.
    public var location: SourceLocation? {
        firstIssue?.source?.start
    }

    private var firstIssue: Issue? {
        guard case .unparsable(let issues) = self else { return nil }
        return issues.first(where: { $0.severity == .error }) ?? issues.first
    }

    var reason: String {
        switch self {
        case .unparsable: "unparsable"
        case .unreadable: "unreadable"
        }
    }
}

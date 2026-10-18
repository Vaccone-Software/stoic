public import StoicJSON
public import StoicSchema
public import StoicStore

/// How a ``SettingsStore/Format/handEdited`` store reads and writes its file,
/// beyond what the schema says. An app-owned store ignores all of it.
///
///     var options = SettingsStore<Prefs>.Options()
///     options.handEdited.fileHeader = ["$schema": "prefs-schema.json"]
///
/// ## The dialect of the file
///
/// What the store reads is JSON as people write it by hand, and this is the one
/// place that says exactly what that is (``parseOptions`` is the same thing as
/// code, for a tool that must read the file as the app does):
///
/// | In the file                          | The store                                                                                   |
/// | ------------------------------------ | ------------------------------------------------------------------------------------------- |
/// | `//` and `/* */` comments            | reads them as whitespace and drops them at the next write; or, with ``comments`` `.refused`, makes one a problem at its line and column |
/// | a trailing comma (`[1, 2,]`)         | accepts one after the last element or member; always, and the next write has none           |
/// | a UTF-8 byte order mark              | skips it; always, and the next write has none                                               |
/// | a key said twice in one object       | with ``duplicateKeys`` `.lastWins`: uses the last, in the first one's place, and reports a warning `repeated_key` at each repeat (`SettingsStore/issues`); the next write has only that one. With `.refused`: a problem at the repeat |
/// | anything else outside RFC 8259       | a problem at its line and column (single quotes, unquoted keys, `NaN`, a leading `+`, …)    |
/// | bytes that are not UTF-8             | a problem at the first bad byte (``SettingsFileProblem/isNotUTF8``)                         |
/// | a top level that is not an object    | a problem when the schema says so (`Schema.jsonObject()`, or any object schema)             |
/// | more than 8 MiB, 64 levels, 100,000 elements in one array or members in one object, or a string of more than 1 MiB | a problem, whatever the person meant (`JSONParseOptions`) |
///
/// Nothing in this table is ever written back on load: the person's file is
/// changed only by a write the app asks for, which writes the value in the
/// canonical dialect and so drops comments, trailing commas, the byte order
/// mark and any repeated key together (``Layout``).
public struct HandEditedOptions: Sendable, Hashable {
    /// What the store writes at the top of the file, before anything else, and
    /// ignores when it reads one. See ``SettingsFileHeader``.
    public var fileHeader: SettingsFileHeader

    /// How a write lays the file out. ``Layout/canonical``, by default.
    public var layout: Layout

    /// Whether the file may hold comments. ``Comments/allowed`` by default.
    public var comments: Comments

    /// What a key said twice in one object means. ``DuplicateKeys/lastWins`` by
    /// default, with a warning issue.
    public var duplicateKeys: DuplicateKeys

    /// How long an update that waits (``SettingsStore/coordinatedUpdate(lockTimeout:_:)``,
    /// or ``SettingsStore/blockingUpdate(waitingUpTo:_:)`` without an argument)
    /// gives another process that is writing the file (a command-line tool
    /// beside the app, a second instance) to let go, before it throws
    /// ``SettingsStore/UpdateError/busy``. Two seconds by default: the other
    /// writer holds the lock for the length of one small write.
    public var lockTimeout: Duration

    public init(
        fileHeader: SettingsFileHeader = [:], layout: Layout = .canonical, comments: Comments = .allowed,
        duplicateKeys: DuplicateKeys = .lastWins, lockTimeout: Duration = .seconds(2)
    ) {
        self.fileHeader = fileHeader
        self.layout = layout
        self.comments = comments
        self.duplicateKeys = duplicateKeys
        self.lockTimeout = lockTimeout
    }

    /// The options the store parses its file with: the dialect in the table
    /// above, as code. A command-line tool that reads the app's file with
    /// `JSONDocument` should use these, so that both mean the same
    /// by it.
    public var parseOptions: JSONParseOptions {
        var options = JSONParseOptions.jsonc
        options.allowComments = comments == .allowed
        options.duplicateKeys = duplicateKeys == .lastWins ? .lastWins : .reject
        return options
    }

    /// What a key said twice in one object means.
    ///
    /// RFC 8259 says only that names "SHOULD be unique", and parsers disagree
    /// about which wins; that is why the strict parser refuses them, for data
    /// that crosses a trust boundary. A file a person edits is not that: it is
    /// theirs, the likely cause is a line added below one they forgot, the
    /// later one is the one they meant, and the readers that came before (every
    /// `JSONSerialization`, `JSON.parse`, and most editors' tooling) take it.
    /// An app that moves to the store from one of them must not turn a file
    /// that worked into a refusal.
    public enum DuplicateKeys: Sendable, Hashable {
        /// The last occurrence is the value, in the first one's place, and the
        /// store says so: a `repeated_key` warning in ``SettingsStore/issues`` at
        /// each repeat, with the line and column of both, and an event
        /// (`settings.repeated_keys`). Never silent. The file is not changed on
        /// load; the next update writes it with only the last, and the warning
        /// says so. The default.
        case lastWins

        /// A repeat is a problem with the file, at the repeat's line and column,
        /// like any text the store cannot read: the last good value stays,
        /// ``SettingsStore/update(_:)`` throws ``SettingsStore/UpdateError/fileUnusable(_:)``,
        /// and the file is never touched. For an app whose people would rather
        /// be told than have a line they wrote ignored.
        case refused
    }

    /// What a comment in the file means. A write never keeps one: the store
    /// reads the file into a value and writes the value, so a comment is
    /// dropped at the next update. For a file whose owner would rather be told
    /// than lose a note, refuse them.
    public enum Comments: Sendable, Hashable {
        /// `//` and `/* */` are read as whitespace, and dropped by the next
        /// write (say so in the UI that offers the file). The default.
        case allowed

        /// A comment is a problem with the file, at its line and column: the
        /// store reports it as it reports any text it cannot read
        /// (``SettingsFileProblem/unparsable(_:)``), keeps the last good value,
        /// and refuses an update (``SettingsStore/UpdateError/fileUnusable(_:)``),
        /// never touching the file. The person removes the comment, or the app
        /// replaces the file on purpose
        /// (``SettingsStore/replaceUnusableFile(with:keepingCopyAt:)``).
        /// Trailing commas stay allowed.
        case refused
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

    /// Whether the file is not text: its bytes are not well-formed UTF-8
    /// (``location`` is the first bad byte). What an app shows differently:
    /// "this file is not a text file" is not "this file has a typo".
    public var isNotUTF8: Bool {
        parseCode == .invalidUTF8
    }

    /// The parser's code for why the text could not be read (`.invalidUTF8`,
    /// `.commentNotAllowed`, `.duplicateKey`, `.unexpectedCharacter`, …), when
    /// that is the reason; `nil` when the text parsed and the schema refused
    /// its shape, and for ``unreadable(_:)``.
    public var parseCode: JSONParseError.Code? {
        firstIssue?.parseCode
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

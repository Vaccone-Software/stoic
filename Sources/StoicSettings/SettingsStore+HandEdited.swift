internal import Stoic
internal import StoicJSON
internal import StoicSchema
internal import StoicStore

/// Reading and writing the file a person edits.
///
/// The rule under all of it: the store may *add to* what the person wrote only
/// through a write that replaces the file whole, atomically, after reading it
/// again, and never when what is there cannot be read. Reading is by plain
/// `read`, never through anything that sets a file aside as corrupt.
extension SettingsStore {
    /// What reading the hand-edited file at `path` leads to. Never throws, and
    /// never changes anything on disk: a file that is missing, cannot be read,
    /// is not JSON or not UTF-8, or is not the shape the schema reads is a
    /// ``SettingsFileProblem`` (or the defaults, if missing), and the file stays.
    static func loadHandEdited(
        path: String, schema: Schema<Value>, file: AtomicFile, options: DecodeOptions, defaults: Value, header: SettingsFileHeader
    ) -> Loaded {
        let contents: AtomicFile.Contents?
        do throws(StoreError) {
            contents = try file.read(path)
        } catch {
            return Loaded(
                value: defaults, issues: [], source: .defaults(.unusable), document: nil, problem: .unreadable(error), read: .unreadable)
        }
        guard let bytes = contents?.bytes else {
            return Loaded(value: defaults, issues: [], source: .defaults(.missing), document: nil, read: .missing)
        }
        let document: JSONDocument
        do throws(JSONParseError) {
            // The header is the app's, not a setting: the schema never sees it
            // (a `json` schema would otherwise hold it in its value, and the
            // next write would put the app's header over a value that says
            // another), and what it reports is about the rest of the text.
            document = try JSONDocument(parsing: bytes, options: options.parse).removingRootMembers(header.keys)
        } catch {
            // The schema turns the parse failure into its typed issue, with the
            // line and column of the character the parser stopped at.
            let issues = schema.decodeReporting(bytes, options: options).issues
            return Loaded(
                value: defaults, issues: issues, source: .defaults(.unusable), document: nil, problem: .unparsable(issues),
                read: .bytes(bytes))
        }
        let decoded = schema.decode(document, options: options)
        let issues = annotatingRepeats(decoded.issues)
        // A newer document is intact, not unusable: read what can be read, and
        // leave the file alone, as an app-owned store does.
        if let newer = issues.first(where: { $0.code == .versionTooNew }) {
            return Loaded(
                value: decoded.value ?? defaults, issues: issues, source: .newerFormat(version: newer.foundVersion), document: nil,
                read: .bytes(bytes))
        }
        guard let value = decoded.value else {
            return Loaded(
                value: defaults, issues: issues, source: .defaults(.unusable), document: nil, problem: .unparsable(issues),
                read: .bytes(bytes))
        }
        return Loaded(
            value: value, issues: issues, source: .file, document: document.value,
            repaired: RepairedField.found(
                in: issues, document: document.value, repaired: schema.encode(value, style: .init(.full, includeSecrets: true))),
            read: .bytes(bytes))
    }

    /// `issues`, with what a repeated key's warning owes the person who reads
    /// it: that the file is as it was, and what the next update does to it.
    /// Said here, not by the schema, which does not know it is a file's.
    static func annotatingRepeats(_ issues: [Issue]) -> [Issue] {
        issues.map { issue in
            guard issue.code == .repeatedKey else { return issue }
            var noted = issue
            noted.parameters["note"] = .string("the file is not changed until the next update, which writes only that one")
            return noted
        }
    }

    /// The state a reading of a hand-edited file leads to: what the file
    /// holds, or, if it cannot be used and the store holds a good value, that
    /// value with the problem beside it. With no good value (the first reading,
    /// or after the defaults) it is the defaults, and `source` says so.
    static func state(from loaded: Loaded, over held: Current?, unknownKeys: UnknownKeysOnSave) -> Current {
        if loaded.problem != nil, var kept = held, kept.source == .file {
            kept.issues = loaded.issues
            kept.problem = loaded.problem
            kept.read = loaded.read
            return kept
        }
        return Current(
            value: loaded.value, issues: loaded.issues, source: loaded.source, document: carried(loaded, unknownKeys),
            repaired: repairs(loaded), problem: loaded.problem, read: loaded.read)
    }

    /// Whether a reading differs from the last, so that there is something to
    /// publish. A read that failed is always tried again.
    static func differs(_ now: FileRead?, from before: FileRead?) -> Bool {
        guard let now, let before, now != .unreadable else { return true }
        return now != before
    }

    /// Reports a reading, with `settings.unparsed` when the file cannot be used
    /// (and not `settings.reset`: nothing was quarantined). `kept` says the
    /// last good value stands.
    static func reportHandEdited(_ loaded: Loaded, kept: Bool, path: String) {
        guard let problem = loaded.problem else {
            report(loaded, path: path)
            let repeats = loaded.issues.filter { $0.code == .repeatedKey }.count
            if repeats > 0 {
                Ambient.record(Event("settings.repeated_keys", level: .warning, label: path, fields: [
                    .init("keys", .int(repeats)), .init("used", .string("last"), privacy: .public),
                ]))
            }
            return
        }
        var fields: [Event.Field] = [
            .init("reason", .string(problem.reason), privacy: .public),
            .init("kept", .string(kept ? "last_good" : "defaults"), privacy: .public),
        ]
        if let location = problem.location {
            fields.append(.init("line", .int(location.line)))
            fields.append(.init("column", .int(location.column)))
        }
        if case .unreadable(let error) = problem { fields.append(.init("error", .error(error))) }
        Ambient.record(Event("settings.unparsed", level: .warning, label: path, fields: fields))
    }

    // MARK: Writing

    /// The bytes a write puts in the file for `json`: for an app-owned file
    /// the canonical encoding (the envelope is the file's business), for a
    /// hand-edited one the layout its options say, with the file header first.
    func bytes(for json: JSONValue) -> [UInt8] {
        guard format == .handEdited else { return json.encoded(style: .canonical) }
        let arrangement = editing.layout.arrangement
        let body = arrangement.map { CanonicalLayout.arranged(json, as: schema.node, order: $0) } ?? json
        var bytes = withFileHeader(body).encoded(style: .pretty(indent: 2))
        if arrangement != nil { bytes.append(UInt8(ascii: "\n")) }
        return bytes
    }

    /// `body` with the file header's members before its own. The header's
    /// value wins over a member of the same name that the file carried.
    private func withFileHeader(_ body: JSONValue) -> JSONValue {
        guard !editing.fileHeader.members.isEmpty, case .object(let object) = body else { return body }
        var result = JSONObject(editing.fileHeader.members)
        for member in object where !result.contains(key: member.key) { result[member.key] = member.value }
        return .object(result)
    }
}

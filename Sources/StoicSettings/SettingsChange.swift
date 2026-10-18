/// A change of a settings store's value, with what it was and why: what an app
/// needs to keep a history (who changed what, from what), and to tell its own
/// writes from the ones that arrived from outside. From
/// ``SettingsStore/changes(buffering:)``.
///
/// There is one for each time the *value* changed. A write that changes nothing
/// is none, and neither is a reload that finds the file as the store last saw it
/// (which is what the store's own write looks like to a file watcher: no second
/// change for the same edit). A change of ``SettingsStore/issues`` or
/// ``SettingsStore/source`` alone is none either.
public struct SettingsChange<Value: Sendable & Equatable>: Sendable, Equatable {
    /// What the value was.
    public var old: Value

    /// What it is.
    public var new: Value

    /// Why it changed.
    public var cause: Cause

    /// Who the app says did it: the `source` its caller gave the update
    /// (``SettingsStore/update(source:_:)``, ``SettingsStore/coordinatedUpdate(lockTimeout:source:_:)``,
    /// ``SettingsStore/blockingUpdate(waitingUpTo:source:_:)`` and
    /// ``SettingsStore/blockingReplaceUnusableFile(with:keepingCopyAt:waitingUpTo:source:)``),
    /// so a history can say "the settings window", "the `lodestar config` command",
    /// "an import" without a side channel that has to be kept in step with the
    /// order changes are announced in.
    ///
    /// The store never reads it: it is carried from the call to the change it
    /// made, as given, and is `nil` when the caller gave none. A change that
    /// came from the file (``Cause/reload``) has none, even when the update
    /// that found it carried one: the edit was not the app's. Not in the
    /// events (a tag is the app's, and may say what the store would not log).
    public var source: String?

    public init(old: Value, new: Value, cause: Cause, source: String? = nil) {
        self.old = old
        self.new = new
        self.cause = cause
        self.source = source
    }

    /// Why the value of a store changed.
    public enum Cause: Sendable, Hashable {
        /// The app changed it: ``SettingsStore/update(_:)``, ``SettingsStore/coordinatedUpdate(lockTimeout:_:)``
        /// or ``SettingsStore/blockingUpdate(waitingUpTo:_:)``, validated and written.
        case update

        /// It arrived from the file: ``SettingsStore/reload()`` (or the watch that
        /// calls it) read a file somebody else changed, or an update read the file
        /// again under its lock and found it had moved. The app did not do it;
        /// an update that finds a changed file is *two* changes, this and then
        /// its own.
        case reload

        /// The app replaced an unusable file on purpose
        /// (``SettingsStore/replaceUnusableFile(with:keepingCopyAt:)``).
        case reset
    }
}

/// A change of a hand-edited file's usability: it stopped parsing, parses again,
/// or is wrong in another way than before. What an app that shows "your settings
/// file has a problem at line 12" needs to learn, without Observation: from
/// ``SettingsStore/problems(buffering:)``.
///
/// There is one for each time ``SettingsStore/fileProblem`` changed. A reload
/// that finds the same problem again (a person saving the same typo twice) is
/// none, and neither is one that finds the file as the store last saw it.
/// Nothing is announced for the state a store opened in: read
/// ``SettingsStore/fileProblem``, then listen.
public struct SettingsProblemChange: Sendable, Equatable {
    /// What was wrong with the file; `nil` if nothing was.
    public var old: SettingsFileProblem?

    /// What is wrong with it now; `nil` if it can be used (or is gone, which
    /// gives the defaults and is no problem).
    public var new: SettingsFileProblem?

    /// How the store found out.
    public var cause: Cause

    public init(old: SettingsFileProblem?, new: SettingsFileProblem?, cause: Cause) {
        self.old = old
        self.new = new
        self.cause = cause
    }

    /// The file could be used and no longer can: it stopped parsing (or became
    /// unreadable). The last good value stands.
    public var began: Bool { old == nil && new != nil }

    /// The file could not be used and now can: it parses again. The value is
    /// the file's, and a change of it (``SettingsStore/changes(buffering:)``) comes
    /// with this one if the fix changed anything.
    public var ended: Bool { old != nil && new == nil }

    /// How the store learned that the file's problem changed.
    public enum Cause: Sendable, Hashable {
        /// It read the file and found it so: ``SettingsStore/reload()`` or the
        /// watch that calls it, or an update that read the file again under
        /// its lock (which is then refused if the file is unusable).
        case reload

        /// The app replaced the unusable file on purpose
        /// (``SettingsStore/replaceUnusableFile(with:keepingCopyAt:)``), which
        /// ends the problem.
        case reset
    }
}

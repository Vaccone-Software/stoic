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

    public init(old: Value, new: Value, cause: Cause) {
        self.old = old
        self.new = new
        self.cause = cause
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

internal import Synchronization

/// A running watch on a file, from ``FileSystem/watchFile(at:handler:)``.
///
/// The watch lasts as long as this object: ``cancel()`` ends it, and so does
/// dropping the last reference, so a watch cannot outlive the code that
/// meant to keep it. Cancelling is idempotent. The handler is not called for
/// anything that happens after `cancel` returns, but a call already under way
/// when it is called may still arrive: a caller that cannot tolerate that
/// keeps a flag of its own.
public final class FileWatch: Sendable {
    private let onCancel: Mutex<(@Sendable () -> Void)?>

    /// - Parameter onCancel: What ends the watch; run once, by the first
    ///   ``cancel()`` or when the watch is dropped.
    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = Mutex(onCancel)
    }

    deinit {
        cancel()
    }

    /// Ends the watch. The handler is not called again.
    public func cancel() {
        // Taken out under the lock and run outside it: what ends a watch may
        // wait for a handler call that is itself waiting to take this lock.
        let end = onCancel.withLock { end in
            defer { end = nil }
            return end
        }
        end?()
    }
}

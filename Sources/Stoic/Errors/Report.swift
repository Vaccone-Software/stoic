/// An error together with the story of how it happened.
///
/// A bare error says *what* failed — "No such file or directory" — but not
/// what the app was doing when it did. A report keeps the original error
/// (its ``root``) and adds a frame for each layer the error passed through on
/// its way up, innermost first, each with a message and its source location:
///
///     loading settings  (Settings.swift:42)
///     ╰─ reading ~/Library/…/settings.json  (FileStore.swift:88)
///        ╰─ POSIXError: No such file or directory
///
/// Frames are added with `withContext(_:)`
/// around a call, or with ``Swift/Error/context(_:metadata:fileID:line:)`` at
/// a `throw`. Wrapping a report adds a frame to it rather than nesting
/// reports, so a chain stays one flat, readable list.
///
/// The root stays reachable: ``first(_:)`` and ``contains(_:)`` look through
/// the report, and Stoic's own classification — retry decisions, defect and
/// cancellation checks — looks through it too. Cancellation is never wrapped
/// in the first place: it passes through `withContext` as itself, so
/// `catch is CancellationError` keeps working.
public struct Report: Error, CustomStringConvertible, CustomDebugStringConvertible {
    /// The original error. Never itself a `Report`.
    public let root: any Error

    /// What the app was doing, innermost first.
    public private(set) var frames: [Frame]

    /// Errors that happened while handling this one — a cleanup that also
    /// failed, say — kept rather than lost.
    public private(set) var suppressed: [any Error]

    /// One layer of context.
    public struct Frame: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let message: String
        public let metadata: [Event.Field]
        public let fileID: String
        public let line: UInt

        public init(_ message: String, metadata: [Event.Field] = [], fileID: String = #fileID, line: UInt = #line) {
            self.message = message
            self.metadata = metadata
            self.fileID = fileID
            self.line = line
        }

        /// The frame as it may appear in a log: a private field's value is
        /// replaced by `<private>`, as ``Diagnostics`` does for events.
        public var description: String {
            render(includePrivate: false)
        }

        /// The frame with every field's value, for a debugger or a local console.
        public var debugDescription: String {
            render(includePrivate: true)
        }

        fileprivate func render(includePrivate: Bool) -> String {
            var text = message
            if !metadata.isEmpty {
                let fields = metadata.map { field in
                    field.privacy == .private && !includePrivate ? "\(field.key)=<private>" : field.description
                }
                text += " [" + fields.joined(separator: ", ") + "]"
            }
            return text + "  (\(fileID):\(line))"
        }
    }

    /// A report of `error` with no context yet. Reporting a report returns it.
    public init(_ error: any Error) {
        if let report = error as? Report {
            self = report
        } else {
            root = error
            frames = []
            suppressed = []
        }
    }

    /// This report with one more frame of context, outside the existing ones.
    public func adding(_ frame: Frame) -> Report {
        var copy = self
        copy.frames.append(frame)
        return copy
    }

    /// This report with `error` recorded as having happened while handling it.
    public func suppressing(_ error: any Error) -> Report {
        var copy = self
        copy.suppressed.append(error)
        return copy
    }

    /// The root, if it is an `E`, or the first `E` found inside the policy
    /// and concurrency wrappers it passed through.
    public func first<E: Error>(_ type: E.Type) -> E? {
        firstError(of: type, in: root)
    }

    /// Whether the root is, or wraps, an `E`.
    public func contains<E: Error>(_ type: E.Type) -> Bool {
        first(type) != nil
    }

    /// Whether the root is, or wraps, a `CancellationError`.
    public var isCancellation: Bool {
        containsCancellation(root)
    }

    /// Whether the root is a ``Defect``, directly or inside a wrapper.
    public var isDefect: Bool {
        containsDefect(root)
    }

    /// The report as it may appear in a log: frames' private metadata and the
    /// root error's description are redacted (`<private>`; the root's type
    /// name stays, as it does for an error in an event), and suppressed
    /// errors are left out.
    public var description: String {
        render(includePrivate: false)
    }

    /// Everything: private metadata values, the root's description and the
    /// suppressed errors.
    public var debugDescription: String {
        render(includePrivate: true)
    }

    private func render(includePrivate: Bool) -> String {
        var lines: [String] = []
        var indent = ""
        for frame in frames.reversed() {
            let text = frame.render(includePrivate: includePrivate)
            lines.append(lines.isEmpty ? text : indent + "╰─ " + text)
            if lines.count > 1 { indent += "   " }
        }
        // An error's description is private by default (``Event/Value/error(_:)``):
        // it may carry a path, a URL or a name the frames' metadata took care to hide.
        let rootLine = "\(String(reflecting: type(of: root))): \(includePrivate ? "\(root)" : "<private>")"
        lines.append(lines.isEmpty ? rootLine : indent + "╰─ " + rootLine)
        if includePrivate {
            for error in suppressed {
                lines.append("  suppressed: \(error)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs `operation`, adding a frame of context to any error it throws.
///
///     let settings = try await withContext("loading settings") {
///         try await store.read(Settings.self)
///     }
///
/// A `CancellationError` passes through unwrapped. Any other error becomes a
/// ``Report`` (or gains a frame, if it already is one) — so a `catch
/// MyError.missing` outside no longer matches. Match with
/// ``Report/first(_:)`` instead: `(error as? Report)?.first(MyError.self)`.
///
/// This form throws `any Error`, so it cannot be used inside a function that
/// declares a typed throw. Annotate the closure's error type
/// (`{ () async throws(MyError) in … }`) to get the `throws(Report)` form.
public nonisolated(nonsending) func withContext<R>(
    _ message: @autoclosure () -> String,
    metadata: [Event.Field] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) () async throws -> R
) async throws -> R {
    do {
        return try await operation()
    } catch {
        throw error.context(message(), metadata: metadata, fileID: fileID, line: line)
    }
}

/// Runs `operation`, adding a frame of context to any error it throws.
/// The synchronous form of `withContext(_:)`.
public func withContext<R>(
    _ message: @autoclosure () -> String,
    metadata: [Event.Field] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    operation: () throws -> R
) throws -> R {
    do {
        return try operation()
    } catch {
        throw error.context(message(), metadata: metadata, fileID: fileID, line: line)
    }
}

/// Runs `operation`, adding a frame of context to any error it throws, and
/// throws a ``Report`` — the form for a function that itself declares
/// `throws(Report)`.
///
///     func load() async throws(Report) -> Settings {
///         try await withContext("loading settings") { () async throws(StoreError) in
///             try await store.read(Settings.self)
///         }
///     }
///
/// This is chosen over the untyped `withContext` only when the closure
/// declares its error type, as above: Swift 6.4 does not infer a typed throw
/// from a closure body, and an unannotated closure keeps the untyped form
/// (which throws `any Error` and cannot be used in a `throws(Report)`
/// function). Because `Report` is the only error the call can throw,
/// a `CancellationError` cannot pass through as itself here: it arrives as
/// the report's ``Report/root``. Test for it with ``Report/isCancellation``
/// (or `first(CancellationError.self)`), and rethrow it as itself where the
/// function's error type allows.
///
/// Like the untyped form, this turns any error into a report. A `catch
/// MyError.missing` stops matching what comes out; `report.first(MyError.self)`
/// still finds it.
public nonisolated(nonsending) func withContext<R, Failure: Error>(
    _ message: @autoclosure () -> String,
    metadata: [Event.Field] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Report) -> R {
    do throws(Failure) {
        return try await operation()
    } catch {
        throw Report(error).adding(Report.Frame(message(), metadata: metadata, fileID: fileID, line: line))
    }
}

/// Runs `operation`, adding a frame of context to any error it throws, and
/// throws a ``Report``. The synchronous form of the typed `withContext`.
public func withContext<R, Failure: Error>(
    _ message: @autoclosure () -> String,
    metadata: [Event.Field] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    operation: () throws(Failure) -> R
) throws(Report) -> R {
    do throws(Failure) {
        return try operation()
    } catch {
        throw Report(error).adding(Report.Frame(message(), metadata: metadata, fileID: fileID, line: line))
    }
}

extension Error {
    /// This error with a frame of context, as a ``Report``.
    ///
    ///     guard let data else { throw SettingsError.missing.context("reading \(path)") }
    ///
    /// A `CancellationError` is returned unchanged: cancellation is not a
    /// failure, and wrapping it would hide it from `catch is CancellationError`.
    public func context(
        _ message: String,
        metadata: [Event.Field] = [],
        fileID: String = #fileID,
        line: UInt = #line
    ) -> any Error {
        if self is CancellationError { return self }
        return Report(self).adding(Report.Frame(message, metadata: metadata, fileID: fileID, line: line))
    }
}

/// The first `E` in `error` or the wrappers around it.
func firstError<E: Error>(of type: E.Type, in error: any Error) -> E? {
    if let match = error as? E { return match }
    if let report = error as? Report { return firstError(of: type, in: report.root) }
    if let policy = error as? any RejectionCarrying {
        if let rejection = policy.carriedRejection, let match = rejection as? E { return match }
        if let inner = policy.carriedFailure { return firstError(of: type, in: inner) }
    }
    if let concurrent = error as? any PrimaryFailureCarrying {
        for failure in concurrent.allFailures {
            if let match = firstError(of: type, in: failure) { return match }
        }
    }
    return nil
}

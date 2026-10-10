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
    public struct Frame: Sendable, CustomStringConvertible {
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

        public var description: String {
            var text = message
            if !metadata.isEmpty {
                text += " [" + metadata.map(\.description).joined(separator: ", ") + "]"
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

    /// Whether the root is a ``Defect``, directly or inside a wrapper.
    public var isDefect: Bool {
        containsDefect(root)
    }

    public var description: String {
        render(includeSuppressed: false)
    }

    public var debugDescription: String {
        render(includeSuppressed: true)
    }

    private func render(includeSuppressed: Bool) -> String {
        var lines: [String] = []
        var indent = ""
        for frame in frames.reversed() {
            lines.append(lines.isEmpty ? frame.description : indent + "╰─ " + frame.description)
            if lines.count > 1 { indent += "   " }
        }
        let rootLine = "\(String(reflecting: type(of: root))): \(root)"
        lines.append(lines.isEmpty ? rootLine : indent + "╰─ " + rootLine)
        if includeSuppressed {
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
/// ``Report`` (or gains a frame, if it already is one).
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

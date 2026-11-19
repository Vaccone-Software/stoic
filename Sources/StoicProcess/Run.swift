#if os(macOS)
internal import Stoic

/// What a program run to its end left: how it ended and the end of what it
/// wrote.
public struct ProcessResult: Sendable {
    /// How it ended; nil only when it could not be ended (see
    /// ``ChildProcess/stop(grace:)``).
    public let exit: ProcessExit?
    /// Whether the deadline ended it.
    public let timedOut: Bool
    /// The last bytes of its standard output (with its errors, if they were
    /// merged), at most the `keepingLast` it was run with.
    public let output: [UInt8]
    /// Whether the start of the output was dropped to keep within that.
    public let outputTruncated: Bool
    /// The last bytes of its standard error, when that was a pipe of its own.
    public let errors: [UInt8]

    /// Exited with status 0, in time.
    public var succeeded: Bool { exit?.succeeded == true && !timedOut }

    /// The output as UTF-8 text.
    public var outputText: String { String(decoding: output, as: UTF8.self) }

    /// The errors as UTF-8 text.
    public var errorsText: String { String(decoding: errors, as: UTF8.self) }
}

extension ChildProcess {
    /// Runs `command` to its end, or until `timeout` (or an enclosing
    /// deadline) passes, and returns how it ended and what it wrote.
    ///
    /// Output and errors that are pipes are read as they come, the last
    /// `keepingLast` bytes of each kept, and `onOutput` handed every chunk of
    /// the output. Past the deadline the child and everything it started are
    /// stopped (``ChildProcess/stop(grace:)``) and the result says
    /// `timedOut`, with what it wrote until then.
    ///
    /// - Throws: ``ProcessError`` when it cannot be started;
    ///   `CancellationError` when the caller is cancelled for any reason
    ///   other than a deadline (the child is stopped first all the same).
    public static func run(
        _ command: Command,
        timeout: Duration,
        keepingLast: Int = 64 * 1024,
        options: Options = Options(),
        onOutput: (@Sendable ([UInt8]) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = try start(command, options: options)
        return try await withTimeout(timeout, label: options.label.map { "process.run.\($0)" } ?? "process.run") {
            try await process.runToEnd(keepingLast: keepingLast, onOutput: onOutput)
        }
    }

    private func runToEnd(keepingLast: Int, onOutput: (@Sendable ([UInt8]) -> Void)?) async throws -> ProcessResult {
        // Read in tasks of their own, which the caller's cancellation does
        // not reach: after a stop the output is still read to its end, so a
        // timed-out result has what was written before it.
        let output = output
        let errors = errors
        let reading = Task { await output?.collect(keepingLast: keepingLast, onChunk: onOutput) }
        let readingErrors = Task { await errors?.collect(keepingLast: keepingLast) }
        let core = core
        var ended: ProcessExit?
        do {
            ended = try await withTaskCancellationHandler {
                try await core.waitForExit()
            } onCancel: {
                core.beginStop(grace: core.options.stopGrace)
            }
        } catch {
            ended = await core.stop(grace: core.options.stopGrace)
        }
        let collected = await reading.value
        let collectedErrors = await readingErrors.value
        let timedOut = Task.isCancelled && CancellationCause.current == .deadline
        if Task.isCancelled, !timedOut { throw CancellationError() }
        return ProcessResult(exit: ended, timedOut: timedOut,
                             output: collected?.bytes ?? [], outputTruncated: collected?.truncated ?? false,
                             errors: collectedErrors?.bytes ?? [])
    }
}
#endif

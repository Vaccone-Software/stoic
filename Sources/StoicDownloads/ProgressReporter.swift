#if STOIC_CRYPTO
internal import Stoic
internal import Synchronization

/// Turns the transfer's steady stream of "this many bytes now" into the
/// reports a caller wants: at most one per interval for a phase, and every
/// change of phase.
///
/// Throttling reads the ambient clock when a report is offered and starts no
/// timer, so it costs a tick of the clock per chunk, runs the same on a
/// `TestClock`, and leaves nothing running when the download ends.
final class ProgressReporter: Sendable {
    private struct State {
        var fileIndex = 0
        var fileCount = 1
        /// The bytes of the files before the current one.
        var bytesBefore = 0
        /// The size of everything, when every file's size is known.
        var totalBytes: Int?
        var lastPhase: DownloadProgress.Phase?
        var lastReport: AnyClock.Instant?
    }

    private let callback: (@Sendable (DownloadProgress) -> Void)?
    private let interval: Duration
    private let state = Mutex(State())

    init(interval: Duration, callback: (@Sendable (DownloadProgress) -> Void)?) {
        self.interval = interval
        self.callback = callback
    }

    /// The transfer is about to begin file `index` of `count`, after `bytesBefore`
    /// bytes of the others; `totalBytes` is the size of everything, if known.
    func beginFile(index: Int, of count: Int, bytesBefore: Int, totalBytes: Int?) {
        state.withLock { state in
            state.fileIndex = index
            state.fileCount = count
            state.bytesBefore = bytesBefore
            state.totalBytes = totalBytes
            state.lastPhase = nil
        }
    }

    /// Offers a report. It is made if the phase changed since the last one,
    /// or `interval` has passed since it.
    func report(_ phase: DownloadProgress.Phase, fileBytes: Int, fileTotal: Int?) {
        guard let callback else { return }
        let now = Ambient.current.clock.now
        let progress = state.withLock { state -> DownloadProgress? in
            if state.lastPhase == phase, let last = state.lastReport, last.advanced(by: interval) > now { return nil }
            state.lastPhase = phase
            state.lastReport = now
            return DownloadProgress(
                phase: phase, fileIndex: state.fileIndex, fileCount: state.fileCount, fileBytes: fileBytes,
                fileTotalBytes: fileTotal, bytesDone: state.bytesBefore + fileBytes, totalBytes: state.totalBytes)
        }
        if let progress { callback(progress) }
    }
}
#endif

#if os(macOS)
internal import Stoic
internal import Darwin
internal import Synchronization

/// What a child writes to one of its pipes, read as it is asked for.
///
/// It is an `AsyncSequence` of byte chunks (each what one read returned, at
/// most ``chunkSize``), with ``lines(maxLength:)`` and
/// ``lineBatches(maxLength:)`` on top. Nothing is read ahead of the reader:
/// a child that writes faster than it is read waits on the pipe, and this
/// process holds no more of its output than the chunk being read.
///
/// The sequence ends at the pipe's end of file. A pipe can outlive the
/// child that was given it: a program it started in the background holds
/// its own copy of the write end, and the end of file comes only when that
/// program ends too. So the output also ends ``ChildProcess/Options/drainGrace``
/// after the child itself has ended, once whatever had been written by then
/// is read (`process.output_cut` says so). It ends, too, when the task
/// reading it is cancelled, as a `Channel`'s `receive` does.
///
/// Read it from one task. Two reading at once would each get some of the
/// chunks, in no useful order.
public struct ProcessOutput: AsyncSequence, Sendable {
    public typealias Element = [UInt8]
    public typealias Failure = Never

    /// The most one read returns.
    public static let chunkSize = 64 * 1024

    let reader: Reader

    public struct AsyncIterator: AsyncIteratorProtocol {
        let reader: Reader

        public mutating func next() async -> [UInt8]? {
            await reader.next()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> [UInt8]? {
            await reader.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(reader: reader) }

    /// Each line, without its newline, decoded as UTF-8 (a malformed byte
    /// becomes U+FFFD). A last line with no newline is yielded at the end.
    /// A line longer than `maxLength` bytes is yielded in pieces of that
    /// length (`process.line_split`), so one runaway line cannot hold an
    /// unbounded buffer.
    public func lines(maxLength: Int = 64 * 1024 * 1024) -> ProcessLines {
        ProcessLines(reader: reader, maxLength: maxLength)
    }

    /// Every line one read completed, together: a child that streams a line
    /// per word is handed on a chunk at a time, so a consumer that hops to
    /// another actor for each element hops once per read, not once per line.
    /// Never empty. As ``lines(maxLength:)`` otherwise.
    public func lineBatches(maxLength: Int = 64 * 1024 * 1024) -> ProcessLineBatches {
        ProcessLineBatches(reader: reader, maxLength: maxLength)
    }

    /// Reads to the end, keeping the last `limit` bytes; `onChunk` sees
    /// every chunk as it arrives. `truncated` says whether anything was
    /// dropped from the front.
    public func collect(keepingLast limit: Int, onChunk: (([UInt8]) -> Void)? = nil) async -> (bytes: [UInt8], truncated: Bool) {
        var kept: [UInt8] = []
        var truncated = false
        for await chunk in self {
            onChunk?(chunk)
            kept += chunk
            if kept.count > limit {
                kept.removeFirst(kept.count - limit)
                truncated = true
            }
        }
        return (kept, truncated)
    }
}

/// The lines of a ``ProcessOutput``.
public struct ProcessLines: AsyncSequence, Sendable {
    public typealias Element = String
    public typealias Failure = Never

    let reader: Reader
    let maxLength: Int

    public struct AsyncIterator: AsyncIteratorProtocol {
        var splitter: LineSplitter
        var ready: [String] = []
        var index = 0

        public mutating func next() async -> String? {
            while index == ready.count {
                guard let batch = await splitter.nextBatch() else { return nil }
                ready = batch
                index = 0
            }
            defer { index += 1 }
            return ready[index]
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> String? {
            await next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(splitter: LineSplitter(reader: reader, maxLength: maxLength))
    }
}

/// The lines of a ``ProcessOutput``, a read's worth at a time.
public struct ProcessLineBatches: AsyncSequence, Sendable {
    public typealias Element = [String]
    public typealias Failure = Never

    let reader: Reader
    let maxLength: Int

    public struct AsyncIterator: AsyncIteratorProtocol {
        var splitter: LineSplitter

        public mutating func next() async -> [String]? {
            await splitter.nextBatch()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> [String]? {
            await splitter.nextBatch()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(splitter: LineSplitter(reader: reader, maxLength: maxLength))
    }
}

/// Splits chunks into lines, carrying a partial line from one chunk to the
/// next.
struct LineSplitter {
    let reader: Reader
    let maxLength: Int
    private var pending: [UInt8] = []
    private var ended = false

    init(reader: Reader, maxLength: Int) {
        precondition(maxLength > 0, "maxLength must be positive")
        self.reader = reader
        self.maxLength = maxLength
    }

    /// The lines the next read completes (reading on while a read completes
    /// none), or nil once the output has ended and nothing is left.
    mutating func nextBatch() async -> [String]? {
        while !ended {
            guard let chunk = await reader.next() else {
                ended = true
                break
            }
            let lines = split(chunk)
            if !lines.isEmpty { return lines }
        }
        guard !pending.isEmpty else { return nil }
        defer { pending = [] }
        return [String(decoding: pending, as: UTF8.self)]
    }

    private mutating func split(_ chunk: [UInt8]) -> [String] {
        var lines: [String] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            if pending.isEmpty {
                append(chunk[start..<newline], to: &lines)
            } else {
                pending += chunk[start..<newline]
                append(pending[...], to: &lines)
                pending = []
            }
            start = chunk.index(after: newline)
        }
        pending += chunk[start...]
        while pending.count > maxLength {
            lines.append(String(decoding: pending.prefix(maxLength), as: UTF8.self))
            pending.removeFirst(maxLength)
            reader.recordSplit(maxLength)
        }
        return lines
    }

    private func append(_ line: ArraySlice<UInt8>, to lines: inout [String]) {
        var rest = line
        while rest.count > maxLength {
            lines.append(String(decoding: rest.prefix(maxLength), as: UTF8.self))
            rest = rest.dropFirst(maxLength)
            reader.recordSplit(maxLength)
        }
        lines.append(String(decoding: rest, as: UTF8.self))
    }
}

/// The reading end of one of a child's pipes.
final class Reader: Sendable {
    let descriptor: Descriptor
    let label: String?
    let stream: String
    let recorder: Recorder

    init(_ descriptor: Descriptor, label: String?, stream: String, recorder: Recorder) {
        self.descriptor = descriptor
        self.label = label
        self.stream = stream
        self.recorder = recorder
    }

    /// The next chunk, or nil at the end.
    func next() async -> [UInt8]? {
        while true {
            let outcome: ReadOutcome? = descriptor.use { fd in
                var buffer = [UInt8](repeating: 0, count: ProcessOutput.chunkSize)
                let count = buffer.withUnsafeMutableBytes { raw in unsafe read(fd, raw.baseAddress, raw.count) }
                if count > 0 { return .bytes(Array(buffer.prefix(count))) }
                if count == 0 { return .end }
                switch errno {
                case EINTR: return .again
                case EAGAIN: return .wouldBlock
                default: return .end
                }
            }
            switch outcome {
            case nil:
                return nil
            case .bytes(let bytes):
                return bytes
            case .end:
                descriptor.close()
                return nil
            case .again:
                continue
            case .wouldBlock:
                // Nothing there now. Once the child has ended and its grace
                // is over, nothing more is coming that this process can wait
                // for: whatever still holds the pipe is not the child.
                if descriptor.isNudged {
                    descriptor.close()
                    recorder.record(Event("process.output_cut", level: .notice, label: label,
                                         fields: [.init("stream", .string(stream), privacy: .public)]))
                    return nil
                }
                if Task.isCancelled { return nil }
                await descriptor.wait()
            }
        }
    }

    /// The child has ended and its grace is over: once the pipe is empty,
    /// the output ends.
    func endWhenIdle() { descriptor.nudge() }

    func recordSplit(_ length: Int) {
        recorder.record(Event("process.line_split", level: .warning, label: label, fields: [
            .init("stream", .string(stream), privacy: .public),
            .init("max_length", .int(length)),
        ]))
    }

    private enum ReadOutcome { case bytes([UInt8]), end, again, wouldBlock }
}
#endif

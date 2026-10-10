public import Stoic
public import Testing

extension RecordingInstrumentation {
    /// The decisions recorded so far as text, one event per line, in a form
    /// stable enough to compare against a golden copy:
    ///
    ///     info retry.attempt_failed label=sync attempt=1 error=<private> delay=0.2 seconds timed_out=false decision=retry
    ///     info retry.succeeded label=sync attempts=2 elapsed=0.2 seconds
    ///
    /// Debug events are left out by default: they describe mechanics, which
    /// may change without the behaviour changing. Private values are written
    /// `<private>`, so a trace can be committed.
    ///
    /// - Parameters:
    ///   - minimumLevel: The least severe level included.
    ///   - excluding: Event names to leave out.
    public func trace(minimumLevel: Event.Level = .info, excluding: Set<EventName> = []) -> String {
        events
            .filter { $0.level >= minimumLevel && !excluding.contains($0.name) }
            .map(Self.line)
            .joined(separator: "\n")
    }

    private static func line(_ event: Event) -> String {
        var parts = ["\(event.level) \(event.name)"]
        if let label = event.label { parts.append("label=\(label)") }
        for field in event.fields {
            parts.append("\(field.key)=\(field.privacy == .public ? field.value.description : "<private>")")
        }
        return parts.joined(separator: " ")
    }
}

/// Checks that a scenario made exactly the decisions `expected` lists — a
/// golden trace (see ``RecordingInstrumentation/trace(minimumLevel:excluding:)``).
///
///     let events = RecordingInstrumentation()
///     try await withTestAmbient(clock: clock, seed: 1, events: events) { … }
///     expectTrace(events, """
///         info retry.attempt_failed label=sync attempt=1 error=<private> delay=0.2 seconds timed_out=false decision=retry
///         info retry.succeeded label=sync attempts=2 elapsed=0.2 seconds
///         """)
///
/// An assertion on the result says the scenario ended well; a golden trace
/// says it got there the way it was meant to: retried twice rather than
/// five times, opened the breaker once, abandoned nothing. On a mismatch
/// the issue shows the first differing line and the whole actual trace,
/// ready to paste in once it has been read and found right.
public func expectTrace(
    _ events: RecordingInstrumentation,
    _ expected: String,
    minimumLevel: Event.Level = .info,
    excluding: Set<EventName> = [],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = events.trace(minimumLevel: minimumLevel, excluding: excluding)
    let want = expected.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: " ") }
        .filter { !$0.isEmpty }
    let got = actual.split(separator: "\n").map(String.init)
    guard want != got else { return }
    let index = zip(want, got).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(want.count, got.count)
    var message = "trace differs at line \(index + 1)\n"
    message += "  expected: \(index < want.count ? want[index] : "(nothing)")\n"
    message += "    actual: \(index < got.count ? got[index] : "(nothing)")\n"
    message += "actual trace:\n" + (got.isEmpty ? "(empty)" : got.joined(separator: "\n"))
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}

extension Substring {
    fileprivate func trimmingCharacters(in set: Character) -> String {
        var slice = self[...]
        while slice.first == set { slice = slice.dropFirst() }
        while slice.last == set { slice = slice.dropLast() }
        return String(slice)
    }
}

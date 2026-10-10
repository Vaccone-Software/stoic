import Foundation
import Stoic
import StoicHTTP
import StoicTesting
import Testing

/// Polls `condition` until it holds, or fails the test after `timeout` of
/// real time. For waiting on work that runs on other tasks and needs no help
/// from the test; anything waiting on the virtual clock uses
/// `TestClock.waitForSleepers` instead.
func eventually(
    timeout: Duration = .seconds(10),
    _ message: @autoclosure () -> String = "the condition never became true",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= limit {
            Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
            return
        }
        // stoic:allow(discarded-try): a cancelled poll just checks the condition once more
        try? await clock.sleep(for: .milliseconds(1))
    }
}

extension RecordingInstrumentation {
    func count(_ name: EventName) -> Int { events(named: name).count }
}

extension Event {
    func text(_ key: String) -> String? {
        if case .string(let value)? = self[key] { value } else { nil }
    }

    func number(_ key: String) -> Int? {
        if case .int(let value)? = self[key] { value } else { nil }
    }

    func duration(_ key: String) -> Duration? {
        if case .duration(let value)? = self[key] { value } else { nil }
    }
}

let apiBase = URL(string: "https://api.example.com")!

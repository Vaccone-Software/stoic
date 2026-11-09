import Darwin
import Foundation
import IntegrationAPI
import Stoic
import StoicXPC
import Synchronization

// The app's side of the real-process check: each scenario against the real
// service, with the events the peer reports. Prints one line per check and
// exits 1 if any failed.

final class Recorder: Instrumentation {
    private let events = Mutex<[Event]>([])

    func record(_ event: Event) {
        events.withLock { $0.append(event) }
    }

    func count(_ name: EventName) -> Int {
        events.withLock { $0.count { $0.name == name } }
    }

    func last(_ name: EventName) -> Event? {
        events.withLock { $0.last { $0.name == name } }
    }
}

let recorder = Recorder()
let failures = Atomic<Int>(0)
let clock = ContinuousClock()

func check(_ condition: Bool, _ what: String) {
    print("\(condition ? "  ok  " : "  FAIL") \(what)")
    if !condition { failures.add(1, ordering: .relaxed) }
}

/// Waits up to `limit` for `condition`.
func waitFor(_ limit: Duration, _ condition: () -> Bool) async -> Bool {
    let end = clock.now.advanced(by: limit)
    while !condition() {
        if clock.now >= end { return false }
        do {
            try await clock.sleep(for: .milliseconds(10))
        } catch {
            return condition()
        }
    }
    return true
}

func pid(_ peer: XPCPeer) async throws -> Int32 {
    // Long enough for launchd's restart delay after a short run.
    try await withTimeout(.seconds(30)) { try await peer.call(IntegrationAPI.pid, XPCEmpty()) }
}

func scenarios() async throws {
    let peer = XPCPeer(service: "com.stoic.xpc-integration.service", build: Build.id)
    defer { peer.shutdown() }

    print("handshake")
    let first = try await pid(peer)
    check(first > 1 && peer.run?.pid == first, "the run is the process that answered (pid \(first))")
    check(recorder.count("xpc.run_started") == 1, "one run started")

    print("payload")
    let blob = try await peer.call(IntegrationAPI.blob, 1_000_000)
    check(blob.count == 1_000_000, "a megabyte of Data came back")

    print("cancellation")
    let waiting = Task { try await peer.call(IntegrationAPI.wait, XPCEmpty()) }
    try await clock.sleep(for: .milliseconds(200))
    let cancelledAt = clock.now
    waiting.cancel()
    _ = await waiting.result
    check(cancelledAt.duration(to: clock.now) < .milliseconds(200), "the caller returned at once")
    check(await waitFor(.seconds(3)) { recorder.count("xpc.late_reply") == 1 }, "the handler was cancelled and its late reply dropped")

    print("end")
    let ended = await peer.end(reason: "integration")
    check(ended == .exited, "the run exited as asked (\(ended))")
    let second = try await pid(peer)
    check(second != first, "the next call reached a new process (pid \(second))")
    check(recorder.count("xpc.relaunch_throttled") >= 1, "launchd's restart delay was reported")

    print("crash")
    do {
        _ = try await peer.call(IntegrationAPI.crash, XPCEmpty())
        check(false, "a crash mid-request failed the call")
    } catch {
        check(error.last == .lost(afterSending: true) && error.outcome == .unknown, "a crash mid-request: lost after sending, outcome unknown (\(error))")
    }
    let third = try await pid(peer)
    check(third != second, "the next call reached a new process (pid \(third))")

    print("watchdog")
    let lostBefore = recorder.count("xpc.run_lost")
    do {
        _ = try await withTimeout(.seconds(1)) { () async throws(OperationError<XPCCallError<Never>>) -> XPCEmpty in
            try await peer.call(IntegrationAPI.block, 20)
        }
        check(false, "the blocked call ended at its deadline")
    } catch {
        check(error.rejection?.reason == .deadlineExceeded, "the blocked call ended at its deadline")
    }
    check(await waitFor(.seconds(8)) { recorder.count("xpc.run_lost") > lostBefore }, "the service's watchdog ended the process")
    let fourth = try await pid(peer)
    check(fourth != third, "the next call reached a new process (pid \(fourth))")

    print("kill")
    _ = try await peer.call(IntegrationAPI.refuseToExit, XPCEmpty())
    let killed = await peer.end(reason: "integration kill")
    check(killed == .killed, "a run that would not exit was killed (\(killed))")
    check(recorder.last("xpc.end_escalated")?["killed"].map { "\($0)" } == "true", "the kill was permitted and reported")
    let fifth = try await pid(peer)
    check(fifth != fourth, "the next call reached a new process (pid \(fifth))")
}

let started = clock.now
do {
    try await withAmbient({ $0.instrumentation = recorder }) {
        try await scenarios()
    }
} catch {
    check(false, "the scenarios threw: \(error)")
}
let failed = failures.load(ordering: .relaxed)
print(failed == 0 ? "xpc integration: all checks passed in \(started.duration(to: clock.now))" : "xpc integration: \(failed) check(s) failed")
exit(failed == 0 ? 0 : 1)

#if os(macOS)
import Foundation
import Stoic
@testable import StoicXPC
import StoicTesting
import Testing

/// The app's side (design/25): runs, calls, losses, ending.
@Suite("XPC peer")
struct XPCPeerTests {
    // MARK: Starting

    @Test func aCallStartsARunAndReachesTheHandler() async throws {
        try await withRig { (rig) async throws in
            #expect(rig.peer.run == nil)
            let reply = try await rig.peer.call(Probe.echo, "hello")
            #expect(reply == "hello")
            #expect(rig.peer.run == XPCRun(number: 1, pid: 1000, build: "1"))
            #expect(rig.service.runs == 1)
            #expect(rig.events.count("xpc.run_started") == 1)
        }
    }

    @Test(.failureMode("design/25", "the service is not in the app's bundle"))
    func aServiceNotInTheBundleIsUnavailableAndNotRepeated() async throws {
        try await withRig { (rig) async throws in
            rig.service.refusesConnections = "no such service"
            let error = try #require(await rig.failure(of: rig.start(Probe.echo, "x"), Never.self))
            #expect(error.last == .unavailable(.noSession("no such service")))
            #expect(error.attempts == 1)
            #expect(error.outcome == .notExecuted)
            #expect(rig.events.count("xpc.handshake_failed") == 1)
        }
    }

    @Test(.failureMode("design/25", "many calls arrive while no run is live"))
    func manyCallsShareOneHandshake() async throws {
        try await withRig { (rig) async throws in
            let calls = (0..<10).map { rig.start(Probe.echo, "call \($0)") }
            for (index, call) in calls.enumerated() {
                #expect(try await call.value == "call \(index)")
            }
            #expect(rig.service.sessions == 1)
            #expect(rig.service.runs == 1)
            #expect(rig.events.count("xpc.run_started") == 1)
        }
    }

    @Test(.failureMode("design/25", "the caller's deadline is shorter than the handshake"))
    func aShortDeadlineFailsOnlyItsCaller() async throws {
        try await withRig { (rig) async throws in
            rig.service.launchDelay = .seconds(3)
            let peer = rig.peer
            let hurried = Task {
                try await withTimeout(.seconds(1)) { try await peer.call(Probe.echo, "hurried") }
            }
            let patient = rig.start(Probe.echo, "patient")
            await eventually { rig.service.sessions == 1 }
            await rig.advance(by: .seconds(1))
            let error = try #require(await rig.failure(of: hurried, Never.self))
            #expect(error.rejection?.reason == .deadlineExceeded)
            await rig.advance(by: .seconds(2))
            #expect(try await patient.value == "patient")
            #expect(rig.service.sessions == 1, "the handshake went on for the patient caller")
        }
    }

    @Test(.failureMode("design/25", "ifRunning is asked with no live run"))
    func ifRunningStartsNothing() async throws {
        try await withRig { (rig) async throws in
            let error = try #require(await rig.failure(of: rig.start(Probe.echo, "x", ifRunning: true), Never.self))
            #expect(error.last == .notRunning)
            #expect(error.outcome == .notExecuted)
            #expect(rig.service.sessions == 0)
            _ = try await rig.peer.call(Probe.echo, "start")
            #expect(try await rig.peer.call(Probe.echo, "read", ifRunning: true) == "read")
        }
    }

    @Test(.failureMode("design/25", "the service is another build"))
    func anotherBuildIsRefusedAndNotRepeated() async throws {
        try await withRig(build: "1", hostBuild: "2") { (rig) async throws in
            let error = try #require(await rig.failure(of: rig.start(Probe.echo, "x"), Never.self))
            #expect(error.last == .buildMismatch(expected: "1", found: "2"))
            #expect(error.attempts == 1)
            let again = try #require(await rig.failure(of: rig.start(Probe.echo, "x"), Never.self))
            #expect(again.last == .buildMismatch(expected: "1", found: "2"))
            #expect(rig.service.sessions == 1, "refused at once: no second session")
            let mismatch = try #require(rig.events.events(named: "xpc.build_mismatch").first { $0.label == "xpc.tests" })
            #expect(mismatch.level == .error)
            #expect(rig.control.count("echo") == 0)
        }
    }

    @Test func aKeyedMethodSendsItsKey() async throws {
        try await withRig { (rig) async throws in
            let key = IdempotencyKey(rawValue: "checkout-7")
            #expect(try await rig.peer.call(Probe.keyed, "x", idempotencyKey: key) == "checkout-7")
        }
    }

    // MARK: Losing a run

    @Test(.failureMode("design/25", "the run is lost before a request is sent"))
    func aRequestNeverSentGoesToTheNextRun() async throws {
        try await withRig { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            // The process dies; its session's end is held at the fault point,
            // so the peer still thinks the run is live and its send fails.
            let crash = Task {
                await withAmbient({ $0.faultPolicy = HoldAtLossOrder() }) {
                    FaultPoint.install()
                    defer { FaultPoint.uninstall() }
                    await rig.service.crash()
                }
            }
            await eventually { rig.service.pid == nil }
            let call = rig.start(Probe.charge, "second")
            await rig.passBackoff(after: 1)
            await eventually { rig.control.count("charge") == 1 }
            rig.control.pause.open()
            let reply = try await call.value
            #expect(reply == "second", "a not-repeatable request that was never sent is sent again")
            #expect(rig.service.runs == 2)
            await crash.value
        }
    }

    @Test(.failureMode("design/25", "the run is lost after an idempotent request is sent"))
    func anIdempotentRequestLostAfterSendingIsResentToANewRun() async throws {
        try await withRig { (rig) async throws in
            let call = rig.start(Probe.store, "value")
            await eventually { rig.control.count("store") == 1 }
            await rig.service.crash()
            await rig.passBackoff(after: 1)
            #expect(try await call.value == "value")
            #expect(rig.service.runs == 2)
            #expect(rig.control.count("store") == 2)
            #expect(rig.events.count("xpc.run_lost") == 1)
        }
    }

    @Test(.failureMode("design/25", "the run is lost after a not-repeatable request is sent"))
    func aNotRepeatableRequestLostAfterSendingIsNotResent() async throws {
        try await withRig { (rig) async throws in
            let call = rig.start(Probe.charge, "payment")
            await eventually { rig.control.count("charge") == 1 }
            await rig.service.crash()
            let error = try #require(await rig.failure(of: call, Never.self))
            #expect(error.last == .lost(afterSending: true))
            #expect(error.outcome == .unknown)
            #expect(error.attempts == 1)
            #expect(rig.service.runs == 1, "no new run was started for it")
        }
    }

    @Test(
        .failureMode("design/25", "the reply's failure and the session's end arrive in either order"),
        arguments: [false, true])
    func aLossIsOneEventInEitherOrder(sessionsEndFirst: Bool) async throws {
        try await withRig { (rig) async throws in
            let calls = [rig.start(Probe.charge, "a"), rig.start(Probe.charge, "b")]
            await eventually { rig.control.count("charge") == 2 }
            await rig.service.crash(sessionsEndFirst: sessionsEndFirst)
            for call in calls {
                let error = try #require(await rig.failure(of: call, Never.self))
                #expect(error.last == .lost(afterSending: true))
            }
            #expect(rig.events.count("xpc.run_lost") == 1)
            let lost = try #require(rig.events.events(named: "xpc.run_lost").first)
            #expect(lost.level == .warning)
            #expect(rig.peer.run == nil)
        }
    }

    @Test(.failureMode("design/25", "the run before lived under ten seconds"))
    func aShortRunMakesTheNextStartReportedAsThrottled() async throws {
        try await withRig { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "a")
            await rig.service.crash()
            _ = try await rig.peer.call(Probe.echo, "b")
            let throttled = try #require(rig.events.events(named: "xpc.relaunch_throttled").first)
            #expect(throttled.level == .notice)
            // A run that lived longer is not.
            await rig.advance(by: .seconds(11))
            await rig.service.crash()
            _ = try await rig.peer.call(Probe.echo, "c")
            #expect(rig.events.count("xpc.relaunch_throttled") == 1)
        }
    }

    // MARK: Cancellation

    @Test(.failureMode("design/25", "the caller is cancelled before its request is sent"))
    func aCallerCancelledBeforeSendingSendsNothing() async throws {
        try await withRig { (rig) async throws in
            rig.service.launchDelay = .seconds(3)
            let call = rig.start(Probe.echo, "never")
            await eventually { rig.service.sessions == 1 }
            call.cancel()
            let error = try #require(await rig.failure(of: call, Never.self))
            #expect(error.outcome == .notExecuted)
            await rig.advance(by: .seconds(3))
            await eventually { rig.peer.run != nil }
            #expect(rig.control.count("echo") == 0)
        }
    }

    @Test(.failureMode("design/25", "the caller is cancelled after its request is sent"))
    func aCallerCancelledAfterSendingReturnsAtOnceAndTheHandlerIsCancelled() async throws {
        try await withRig { (rig) async throws in
            let call = rig.start(Probe.hang, XPCEmpty())
            await eventually { rig.control.count("hang") == 1 }
            call.cancel()
            let error = try #require(await rig.failure(of: call, Never.self))
            #expect(error.last == .cancelled(afterSending: true))
            await eventually("the handler was never cancelled") { rig.control.count("hang.cancelled") == 1 }
        }
    }

    @Test(.failureMode("design/25", "a reply arrives after its caller left"))
    func aLateReplyIsDroppedAndReported() async throws {
        try await withRig { (rig) async throws in
            let call = rig.start(Probe.slow, XPCEmpty())
            await eventually { rig.control.count("slow") == 1 }
            call.cancel()
            _ = await rig.failure(of: call, Never.self)
            rig.control.pause.open()
            await eventually { rig.events.count("xpc.late_reply") == 1 }
        }
    }

    @Test(.failureMode("design/25", "a cancelled request stays unanswered past ifStuck"))
    func aStuckRequestEndsTheRun() async throws {
        try await withRig { (rig) async throws in
            let call = rig.start(Probe.wedge, XPCEmpty())
            await eventually { rig.control.count("wedge") == 1 }
            call.cancel()
            _ = await rig.failure(of: call, Never.self)
            await rig.advance(by: .seconds(1))
            await eventually { rig.events.count("xpc.run_ended") == 1 }
            #expect(rig.events.count("xpc.call_stuck") == 1)
            let ended = try #require(rig.events.events(named: "xpc.run_ended").first)
            #expect(ended.text("reason") == "xpc.tests.wedge was stuck")
            #expect(rig.service.exits == [0])
        }
    }

    @Test(.failureMode("design/25", "the app ends a run with other calls in flight"))
    func callsOnARunTheAppEndedFailEndedAndTheBreakerIgnoresThem() async throws {
        try await withRig { (rig) async throws in
            let wedged = rig.start(Probe.wedge, XPCEmpty())
            let payment = rig.start(Probe.charge, "in flight")
            await eventually { rig.control.count("wedge") == 1 && rig.control.count("charge") == 1 }
            wedged.cancel()
            _ = await rig.failure(of: wedged, Never.self)
            await rig.advance(by: .seconds(1))
            let error = try #require(await rig.failure(of: payment, Never.self))
            #expect(error.last == .ended(afterSending: true))
            #expect(error.outcome == .unknown)
            #expect(rig.events.count("breaker.recorded") == 0, "neither call was counted against the service")
            #expect(rig.events.events(named: "breaker.ignored").contains { $0.text("reason") == "caller_decided" })
        }
    }

    // MARK: Ending

    @Test(.failureMode("design/25", "a call is made while an ended run is still exiting"))
    func aCallDuringAnExitWaitsForTheNextRun() async throws {
        try await withRig(policy: XPCPeerPolicy(endGrace: .seconds(10)), exitLag: .seconds(5)) { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            let peer = rig.peer
            let end = Task { await peer.end(reason: "reload") }
            await eventually { rig.events.count("xpc.host_exiting") == 1 }
            let call = rig.start(Probe.echo, "second")
            await rig.advance(by: .seconds(5))
            #expect(try await call.value == "second")
            #expect(await end.value == .exited)
            #expect(rig.service.runs == 2)
            #expect(rig.peer.run?.number == 2)
            #expect(rig.control.count("echo") == 2)
        }
    }

    @Test(.failureMode("design/25", "the run does not exit when asked"))
    func aRunThatDoesNotExitIsKilled() async throws {
        try await withRig(exitLag: .seconds(30)) { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            let peer = rig.peer
            let end = Task { await peer.end(reason: "reload") }
            await eventually { rig.events.count("xpc.host_exiting") == 1 }
            await rig.advance(by: .seconds(2))
            #expect(await end.value == .killed)
            #expect(rig.service.exits == [-9])
            let escalated = try #require(rig.events.events(named: "xpc.end_escalated").first)
            #expect(escalated.flag("killed") == true)
        }
    }

    @Test(.failureMode("design/25", "the run cannot be killed (a sandbox) and does not exit"))
    func aRunThatCannotBeKilledIsWedgedUntilItGoes() async throws {
        try await withRig(exitLag: .seconds(30), permitsKill: false) { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            let peer = rig.peer
            let end = Task { await peer.end(reason: "reload") }
            await eventually { rig.events.count("xpc.host_exiting") == 1 }
            await rig.advance(by: .seconds(2))
            #expect(await end.value == .wedged)
            #expect(rig.events.events(named: "xpc.run_wedged").first?.level == .error)
            let refused = try #require(await rig.failure(of: rig.start(Probe.echo, "refused"), Never.self))
            #expect(refused.last == .unavailable(.wedged))
            #expect(refused.attempts == 1)
            await rig.advance(by: .seconds(28))
            await eventually { rig.service.pid == nil }
            await eventually { rig.peer.run == nil && rig.events.count("xpc.run_ended") == 1 }
            #expect(try await rig.peer.call(Probe.echo, "again") == "again")
            #expect(rig.service.runs == 2)
        }
    }

    @Test(.failureMode("design/25", "the peer is shut down with calls waiting"))
    func shuttingDownFailsWaitingCallsAndCancelsTheSession() async throws {
        try await withRig { (rig) async throws in
            let payment = rig.start(Probe.charge, "in flight")
            let hang = rig.start(Probe.hang, XPCEmpty())
            await eventually { rig.control.count("charge") == 1 && rig.control.count("hang") == 1 }
            rig.peer.shutdown()
            let error = try #require(await rig.failure(of: payment, Never.self))
            #expect(error.last == .ended(afterSending: true), "it was sent: the service may have acted")
            #expect(error.outcome == .unknown)
            await eventually("the session was not cancelled") { rig.control.count("hang.cancelled") == 1 }
            await rig.passBackoff(after: 1)
            let read = try #require(await rig.failure(of: hang, Never.self))
            #expect(read.last == .unavailable(.shutDown), "a read is tried again, and finds the peer shut down")
            let after = try #require(await rig.failure(of: rig.start(Probe.echo, "x"), Never.self))
            #expect(after.last == .unavailable(.shutDown))
            #expect(after.outcome == .notExecuted)
        }
    }

    @Test(.failureMode("design/25", "the app ends a run while it is starting"))
    func endingARunThatIsStartingWaitsForItsHandshake() async throws {
        try await withRig { (rig) async throws in
            rig.service.launchDelay = .seconds(3)
            let call = rig.start(Probe.echo, "waiting")
            await eventually { rig.service.sessions == 1 }
            let peer = rig.peer
            let end = Task { await peer.end(reason: "reload") }
            await rig.advance(by: .seconds(3))
            rig.service.launchDelay = .zero
            #expect(await end.value == .exited)
            #expect(rig.events.count("xpc.host_exiting") == 1, "the process was asked to exit, not left running")
            // Whether the waiting call reached the run before the end, or was
            // held back and sent to the next: it is answered either way.
            #expect(try await rig.value(of: call) == "waiting", "the waiting call was not failed for the end")
            #expect(rig.service.exits.first == 0)
        }
    }

    @Test(.failureMode("design/25", "a new session reaches a process that is exiting"))
    func aSessionToAnExitingProcessWaitsForTheNextOne() async throws {
        try await withRig(
            policy: XPCPeerPolicy(endGrace: .seconds(10)), host: XPCHostPolicy(idleExit: .seconds(10)), exitLag: .seconds(3)
        ) { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            await rig.advance(by: .seconds(10))
            await eventually { rig.events.count("xpc.idle_exit") == 1 }
            // The process lingers (short of the call's 5 s attempt timeout);
            // its session ends, so the next call opens a new one, which
            // reaches the same, exiting process.
            await rig.service.dropSessions()
            await eventually { rig.peer.run == nil }
            let call = rig.start(Probe.echo, "second")
            await eventually { rig.service.sessions == 2 }
            await eventually { rig.events.count("xpc.run_ended") == 0 && rig.peer.run == nil }
            await rig.advance(by: .seconds(3))
            #expect(try await call.value == "second")
            #expect(rig.service.runs == 2)
            #expect(rig.control.count("echo") == 2)
        }
    }

    @Test(.failureMode("design/25", "a second peer is made for the same service"))
    func aSecondPeerForOneServiceIsReported() async throws {
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) { () async throws in
            let first = XPCPeer(service: "com.stoic.tests.duplicate", build: "1")
            let second = XPCPeer(service: "com.stoic.tests.duplicate", build: "1")
            #expect(events.events(named: "xpc.peer_duplicate").first?.level == .error)
            first.shutdown()
            second.shutdown()
            let third = XPCPeer(service: "com.stoic.tests.duplicate", build: "1")
            #expect(events.count("xpc.peer_duplicate") == 1, "a peer shut down gives the service up")
            third.shutdown()
        }
    }

    // MARK: The kill check

    @Test func onlyThisAppsServicesMayBeKilled() {
        let app = URL(filePath: "/Applications/Example.app")
        let service = "/Applications/Example.app/Contents/XPCServices/Models.xpc/Contents/MacOS/Models"
        #expect(ServiceProcess.mayKill(4242, executable: service, app: app, me: 100))
        #expect(!ServiceProcess.mayKill(4242, executable: "/usr/bin/top", app: app, me: 100))
        #expect(!ServiceProcess.mayKill(4242, executable: "/Applications/Example.app/Contents/MacOS/Example", app: app, me: 100))
        #expect(!ServiceProcess.mayKill(4242, executable: "/Applications/Example.app/Contents/XPCServices/../../../Other.app/x", app: app, me: 100))
        #expect(!ServiceProcess.mayKill(4242, executable: nil, app: app, me: 100))
        #expect(!ServiceProcess.mayKill(100, executable: service, app: app, me: 100), "never the app itself")
        for pid: Int32 in [1, 0, -1, -4242] {
            #expect(!ServiceProcess.mayKill(pid, executable: service, app: app, me: 100), "never launchd, a process group or every process")
        }
    }
}

/// Holds the end of a crashed process's sessions at the fault point for a
/// second of virtual time.
struct HoldAtLossOrder: FaultPolicy {
    func action(at site: String) -> FaultAction {
        site == "xpc.loss_order" ? .delay(.seconds(1)) : .proceed
    }
}
#endif

#if os(macOS)
import Foundation
import Stoic
@testable import StoicXPC
import StoicTesting
import Synchronization
import Testing

/// The service's side (design/25): answering, refusing, the watchdog, idle
/// exit.
@Suite("XPC host")
struct XPCHostTests {
    // MARK: Answers and refusals

    @Test(.failureMode("design/25", "a handler throws its declared failure"))
    func aDeclaredFailureArrivesTypedAndIsNotRepeated() async throws {
        try await withRig { (rig) async throws in
            let error = try #require(await rig.failure(of: rig.start(Probe.decline, "card declined"), Declined.self))
            #expect(error.last == .failed(Declined(why: "card declined")))
            #expect(error.last?.failure == Declined(why: "card declined"))
            #expect(error.outcome == .executed)
            #expect(error.attempts == 1)
        }
    }

    @Test(.failureMode("design/25", "a request names a method the service does not handle"))
    func anUnknownMethodIsAProtocolViolation() async throws {
        try await withRig { (rig) async throws in
            let error = try #require(await rig.failure(of: rig.start(Probe.missing, XPCEmpty()), Never.self))
            #expect(error.last == .protocolViolation("the service has no method xpc.tests.missing"))
            #expect(error.attempts == 1)
            #expect(rig.events.events(named: "xpc.request_refused").first?.text("reason") == "unknownMethod")
        }
    }

    @Test(.failureMode("design/25", "a request does not decode as the method's type"))
    func aMistypedRequestIsAProtocolViolation() async throws {
        try await withRig { (rig) async throws in
            let error = try #require(await rig.failure(of: rig.start(Probe.mistyped, 42), Never.self))
            guard case .protocolViolation? = error.last else {
                Issue.record("expected a protocol violation, got \(String(describing: error.last))")
                return
            }
            #expect(error.attempts == 1)
            #expect(rig.events.events(named: "xpc.request_refused").first?.text("reason") == "undecodable")
        }
    }

    @Test(.failureMode("design/25", "the client is another build"))
    func aClientOfAnotherBuildIsRefused() async throws {
        try await withRig { (rig) async throws in
            let connection = try rig.service.connect(onEnd: {})
            let welcome = Box<Answer<Welcome, XPCEmpty>>()
            try connection.send(Outgoing<XPCEmpty>(kind: .hello, build: "0")) { (result: Result<Answer<Welcome, XPCEmpty>, XPCDeliveryFailure>) in
                welcome.set(result)
            }
            await eventually { welcome.value != nil }
            #expect(welcome.value?.status == .welcome, "the client learns the service's build, and decides")
            let answer = Box<Answer<String, Never>>()
            try connection.send(Outgoing(kind: .call, id: 1, method: Probe.echo.name, payload: "x")) { (result: Result<Answer<String, Never>, XPCDeliveryFailure>) in
                answer.set(result)
            }
            await eventually { answer.value != nil }
            #expect(answer.value?.status == .buildMismatch)
            #expect(answer.value?.detail == "1")
            #expect(rig.control.count("echo") == 0)
            connection.cancel()
        }
    }

    @Test(.failureMode("design/25", "a cancel arrives for a request the service no longer holds"))
    func aCancelForAnUnknownRequestIsDropped() async throws {
        try await withRig { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "x")
            let connection = try rig.service.connect(onEnd: {})
            try connection.send(Outgoing<XPCEmpty>(kind: .cancel, id: 4242))
            await eventually { rig.events.count("xpc.cancel_unknown") == 1 }
            #expect(rig.events.events(named: "xpc.cancel_unknown").first?.level == .debug)
            #expect(try await rig.peer.call(Probe.echo, "still here") == "still here")
            connection.cancel()
        }
    }

    @Test(.failureMode("design/25", "a client's session ends with handlers running"))
    func aSessionThatEndsCancelsItsHandlers() async throws {
        try await withRig { (rig) async throws in
            let connection = try rig.service.connect(onEnd: {})
            try connection.send(Outgoing(kind: .call, id: 1, method: Probe.hang.name, payload: XPCEmpty())) { (_: Result<Answer<XPCEmpty, Never>, XPCDeliveryFailure>) in }
            await eventually { rig.control.count("hang") == 1 }
            connection.cancel()
            await eventually("the handler was never cancelled") { rig.control.count("hang.cancelled") == 1 }
        }
    }

    // MARK: Exiting

    @Test(.failureMode("design/25", "a request reaches a run that has decided to exit"))
    func aRequestToAnExitingRunIsRefusedAndResent() async throws {
        try await withRig(
            policy: XPCPeerPolicy(endGrace: .seconds(10)), host: XPCHostPolicy(idleExit: .seconds(10)), exitLag: .seconds(5)
        ) { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            // Long enough that the next run, started within the advances
            // below, is not idle-exiting too.
            await rig.clock.advance(by: .seconds(10))
            await eventually { rig.events.count("xpc.idle_exit") == 1 }
            // The process lingers for its exit lag; the peer still thinks it live.
            let call = rig.start(Probe.echo, "second")
            await rig.passBackoff(after: 1)
            // To the exit, and short of the second attempt's own timeout
            // (5 s, from t = 11): a timeout there would repeat the read.
            await rig.clock.advance(by: .seconds(4))
            #expect(try await call.value == "second")
            #expect(rig.control.count("echo") == 2, "the refused request never ran in the exiting process")
            #expect(rig.service.runs == 2)
            #expect(rig.events.events(named: "xpc.request_refused").first?.text("reason") == "exiting")
        }
    }

    @Test(.failureMode("design/25", "a handler ignores cancellation past its budget and the grace"))
    func theWatchdogEndsAServiceWhoseHandlerIgnoresCancellation() async throws {
        try await withRig { (rig) async throws in
            let peer = rig.peer
            let call = Task {
                try await withTimeout(.seconds(2)) { try await peer.call(Probe.slow, XPCEmpty()) }
            }
            await eventually { rig.control.count("slow") == 1 }
            await rig.clock.advance(by: .seconds(2))
            _ = await rig.failure(of: call, Never.self)
            // The handler's budget was two seconds; the grace is one.
            await rig.clock.advance(by: .seconds(1))
            await eventually { rig.service.exits == [1] }
            let watchdog = try #require(rig.events.events(named: "xpc.watchdog_exit").first)
            #expect(watchdog.level == .error)
            #expect(watchdog.text("method") == "xpc.tests.slow")
            await eventually { rig.events.count("xpc.run_lost") == 1 }
        }
    }

    @Test(.failureMode("design/25", "the service is idle and holds nothing for the idle period"))
    func anIdleServiceExitsAndTheNextCallStartsANewRun() async throws {
        try await withRig(host: XPCHostPolicy(idleExit: .seconds(10))) { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            await rig.clock.advance(by: .seconds(10))
            await eventually { rig.service.exits == [0] }
            #expect(rig.events.count("xpc.idle_exit") == 1)
            await eventually { rig.peer.run == nil }
            #expect(rig.events.events(named: "xpc.run_lost").first?.level == .notice, "nothing was in flight")
            #expect(try await rig.peer.call(Probe.echo, "second") == "second")
            #expect(rig.service.runs == 2)
        }
    }

    @Test(.failureMode("design/25", "a request arrives during the idle period"))
    func aRequestPutsOffTheIdleExit() async throws {
        try await withRig(host: XPCHostPolicy(idleExit: .seconds(10))) { (rig) async throws in
            _ = try await rig.peer.call(Probe.echo, "first")
            await rig.clock.advance(by: .seconds(6))
            _ = try await rig.peer.call(Probe.echo, "second")
            await rig.clock.advance(by: .seconds(6))
            #expect(rig.service.exits.isEmpty, "idle for six seconds since the second request")
            await rig.clock.advance(by: .seconds(4))
            await eventually { rig.service.exits == [0] }
            #expect(rig.service.runs == 1)
        }
    }

    @Test(.failureMode("design/25", "the service holds something"))
    func aHeldServiceDoesNotIdleExit() async throws {
        try await withRig(host: XPCHostPolicy(idleExit: .seconds(10))) { (rig) async throws in
            _ = try await rig.peer.call(Probe.load, "model")
            await rig.clock.advance(by: .seconds(30))
            #expect(rig.service.exits.isEmpty)
            _ = try await rig.peer.call(Probe.unload, "model")
            await rig.clock.advance(by: .seconds(10))
            await eventually { rig.service.exits == [0] }
        }
    }
}

/// A value set once from a callback.
final class Box<Value: Sendable>: Sendable {
    private let state = Mutex<Value?>(nil)

    var value: Value? {
        state.withLock { $0 }
    }

    func set(_ result: Result<Value, XPCDeliveryFailure>) {
        if case .success(let value) = result { state.withLock { $0 = value } }
    }
}
#endif

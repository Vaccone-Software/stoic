#if os(macOS)
internal import Darwin
internal import Stoic
internal import Dispatch
internal import Foundation
internal import Synchronization
internal import XPC

/// The system's side of a host: an `XPCListener` for the bundled service,
/// a watchdog timer on a queue of its own, and an exit queue no request
/// ever holds.
enum SystemListener {
    /// Where the process exits: a queue no request holds, so an exit is
    /// never stuck behind the work it ends.
    static let exitQueue = DispatchQueue(label: "stoic.xpc.exit")

    /// Where the watchdog checks: off the listener's queue and off the
    /// cooperative pool, so handlers that block every thread of the pool
    /// cannot stop the watchdog that ends them.
    static let watchdogQueue = DispatchQueue(label: "stoic.xpc.watchdog")

    /// How long a service that has decided to exit goes on refusing
    /// requests ("exiting", never run) before it exits: a request already on
    /// its way when the decision was made is answered, not lost with the
    /// process and left `.unknown`.
    static let exitDrain: UInt32 = 250_000

    static func run(_ host: XPCHost, service: String) -> Never {
        let exit = host.policy.exit
        host.attach(HostRuntime(
            pid: getpid(),
            exit: { code in
                exitQueue.async {
                    usleep(exitDrain)
                    exit(code)
                }
            },
            watch: { _ in }  // the timer below checks every half second
        ))
        let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdog.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(100))
        watchdog.setEventHandler { host.checkWatchdog() }
        watchdog.resume()
        let listener: XPCListener
        do {
            listener = try XPCListener(service: service) { request in
                let session = host.openSession()
                return request.accept(
                    incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
                        host.receive(SystemMessage(message), on: session)
                        return nil
                    },
                    cancellationHandler: { _ in host.sessionEnded(session) }
                )
            }
        } catch {
            host.report("xpc.host_exiting", .error, label: nil, [
                .init("reason", .string("no listener for \(service)"), privacy: .public), .init("error", .error(error)),
            ])
            exit(1)
        }
        withExtendedLifetime((listener, watchdog)) { dispatchMain() }
    }
}

/// A message from a session, answered once, from any queue.
///
/// `XPCReceivedMessage` is not `Sendable`, and Swift 6 refuses every way of
/// carrying it off the listener's queue: a capture in a `Task`, a move into a
/// `Mutex` (the handler's parameter is not `sending`). This wrapper is the
/// one audited exception (design/25, Origin).
// stoic:allow(unchecked-sendable): the message is decoded only on the listener's queue, before it is shared; replying is thread-safe in libxpc, and the Mutex makes it happen once.
final class SystemMessage: HostMessage, @unchecked Sendable {
    private let message: XPCReceivedMessage
    private let answered = Mutex(false)

    init(_ message: XPCReceivedMessage) {
        self.message = message
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try message.decode(as: type)
    }

    var expectsReply: Bool {
        message.expectsReply
    }

    func reply(_ answer: some Encodable & Sendable) {
        let first = answered.withLock { answered in
            defer { answered = true }
            return !answered
        }
        if first, message.expectsReply { message.reply(answer) }
    }
}
#endif

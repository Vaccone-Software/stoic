#if os(macOS)
/// Carries a peer's messages to a service's process, and tells it when that
/// process is gone.
///
/// The seam where tests replace the operating system, as `HTTPTransport` is
/// for HTTP: ``XPCPeer`` owns every decision (when to start a run, when one
/// is lost, what a call's failure means), and a transport owns none. The
/// system's is an `XPCSession` per run; ``XPCSimulatedService`` runs a real
/// ``XPCHost`` in-process instead.
public protocol XPCTransport: Sendable {
    /// Opens a session to the service: to its process if one is running,
    /// even one that is exiting, or to a new one.
    ///
    /// - Parameter onEnd: Called once, when the session ends: when the
    ///   process exits or crashes, or the session is cancelled.
    /// - Throws: ``XPCConnectFailure`` when no session can be made: the
    ///   service is not in the app's bundle.
    func connect(onEnd: @escaping @Sendable () -> Void) throws(XPCConnectFailure) -> any XPCConnection

    /// Ends the process of `run` at once, where this app may, after checking
    /// that the process at its pid is still this app's service.
    ///
    /// - Returns: Whether the process was signalled. A sandboxed app may not
    ///   signal its own service.
    func terminate(_ run: XPCRun) -> Bool
}

/// One session with a service's process.
public protocol XPCConnection: Sendable {
    /// Sends `message`, and calls `replyHandler` once with its reply, or
    /// with the failure that means there will be none.
    ///
    /// - Throws: ``XPCDeliveryFailure`` when the message was not sent: the
    ///   session has ended, or the message does not encode.
    func send<Message: Encodable & Sendable, Reply: Decodable & Sendable>(
        _ message: Message,
        replyHandler: @escaping @Sendable (Result<Reply, XPCDeliveryFailure>) -> Void
    ) throws(XPCDeliveryFailure)

    /// Sends `message`, which has no reply.
    func send<Message: Encodable & Sendable>(_ message: Message) throws(XPCDeliveryFailure)

    /// Ends the session. Its `onEnd` follows at once.
    func cancel()
}

/// Why a message did not arrive, or its reply did not.
public enum XPCDeliveryFailure: Error, Sendable, Hashable, CustomStringConvertible {
    /// The session ended: its process exited or crashed, or it was
    /// cancelled.
    case connectionLost(String)

    /// The message or its reply did not encode or decode as its type.
    case undecodable(String)

    public var description: String {
        switch self {
        case .connectionLost(let why): "connection lost: \(why)"
        case .undecodable(let why): "undecodable: \(why)"
        }
    }
}

/// Why no session could be made.
public struct XPCConnectFailure: Error, Sendable, Hashable, CustomStringConvertible {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// One run of a service: its process, from its handshake to its end.
public struct XPCRun: Sendable, Hashable, CustomStringConvertible {
    /// Counts the peer's runs, from 1.
    public let number: Int

    /// The process's pid, as it reported it.
    public let pid: Int32

    /// The service's build, as it reported it.
    public let build: String

    public init(number: Int, pid: Int32, build: String) {
        self.number = number
        self.pid = pid
        self.build = build
    }

    public var description: String {
        "run \(number) (pid \(pid), build \(build))"
    }
}
#endif

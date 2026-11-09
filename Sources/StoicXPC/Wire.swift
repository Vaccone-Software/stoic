#if os(macOS)
// The messages the peer and the host exchange. Encoded by the transport:
// XPC's own `Codable` encoding on a real session (so a `Data` field goes out
// of line), JSON in the simulation.

/// What a message from the client is.
enum WireKind: String, Codable, Sendable {
    /// The handshake: the client's build; answered with the service's.
    case hello
    /// A request: answered exactly once.
    case call
    /// Cancel request `id`. Not answered.
    case cancel
    /// Exit now. Not answered.
    case end
}

/// A message from the client.
struct Outgoing<Payload: Encodable & Sendable>: Encodable, Sendable {
    var kind: WireKind
    var id: UInt64 = 0
    var method: String? = nil
    /// The time left before the caller's deadline when the request was
    /// sent: the handler's budget.
    var budgetNanoseconds: Int64? = nil
    var key: String? = nil
    var build: String? = nil
    var payload: Payload? = nil
}

/// A message from the client, without its payload: what the host reads to
/// know which handler, and so which payload type, the message is for.
struct WireHeader: Decodable, Sendable {
    var kind: WireKind
    var id: UInt64
    var method: String?
    var budgetNanoseconds: Int64?
    var key: String?
    var build: String?
}

/// The payload of a message, once its type is known.
struct WirePayload<Payload: Decodable>: Decodable {
    var payload: Payload
}

/// What the host answers.
enum AnswerStatus: String, Codable, Sendable {
    /// The handshake's answer: ``Welcome`` in `reply`.
    case welcome
    /// The handler returned: the reply is in `reply`.
    case success
    /// The handler threw its declared failure: it is in `failure`.
    case failure
    /// The handler was cancelled before it answered.
    case cancelled
    /// The service has decided to exit: the request was not run.
    case exiting
    /// The service has no handler for the method: the request was not run.
    case unknownMethod
    /// The request did not decode as the method's type: it was not run.
    case undecodable
    /// The client is another build: the request was not run.
    case buildMismatch
    /// The handler ran, but its reply did not encode.
    case badReply
}

/// The host's answer to a hello or a call.
struct Answer<Reply: Codable & Sendable, Failure: Codable & Sendable>: Codable, Sendable {
    var status: AnswerStatus
    var reply: Reply? = nil
    var failure: Failure? = nil
    var detail: String? = nil
}

/// The service's half of the handshake.
struct Welcome: Codable, Sendable {
    var pid: Int32
    var build: String
}

extension Duration {
    /// The duration in whole nanoseconds, saturating.
    var wireNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return seconds < 0 ? .min : .max }
        return whole.addingReportingOverflow(attoseconds / 1_000_000_000).overflow ? .max : whole + attoseconds / 1_000_000_000
    }
}
#endif

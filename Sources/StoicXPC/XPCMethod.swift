#if os(macOS)
public import Stoic

/// One method a service offers: declared once, in a module the app and the
/// service both import, with its request, reply and failure types and the
/// operation it is (design/25).
///
///     extension Backend {
///         static let models = Backend.compute("models")
///         static let modelsControl = Backend.system("models.control")
///     }
///
///     enum ModelsAPI {
///         static let respond = XPCMethod<Generate, String, ModelsFailure>(
///             Backend.models.notRepeatable("respond", length: .long),
///             ifStuck: .endService(after: .seconds(20)))
///         static let stats = XPCMethod<XPCEmpty, ModelsStats, Never>(Backend.modelsControl.readOnly("stats"))
///     }
///
/// The operation decides everything a call's resilience needs, as it does
/// for any declared operation (design/22): whether a lost call may be sent
/// again (its repeat safety), how long it may take (its length), and how much
/// may run at once (its backend's capacity). Two methods on different
/// backends share one service process without sharing capacity: a
/// generation on a `compute` backend never holds up a status read on a
/// `system` one.
///
/// The failure is the handler's own: a handler throws it, and the caller
/// catches it, typed, as `.failed`. A method that cannot fail declares
/// `Never`.
public struct XPCMethod<Request: Codable & Sendable, Reply: Codable & Sendable, Failure: Error & Codable & Sendable>: Sendable {
    /// The operation a call of this method is.
    public let operation: Backend.Operation

    /// What a request still unanswered after its caller left means.
    public let ifStuck: XPCStuck

    /// - Parameters:
    ///   - operation: The operation a call is: its backend, name, repeat
    ///     safety and length.
    ///   - ifStuck: Whether a request still unanswered some time after its
    ///     caller left means the service is wedged, and should be ended.
    public init(_ operation: Backend.Operation, ifStuck: XPCStuck = .wait) {
        self.operation = operation
        self.ifStuck = ifStuck
    }

    /// The name the method has on the wire: `<backend>.<operation>`. Both
    /// sides derive it from the same declaration.
    public var name: String {
        "\(operation.backend.name).\(operation.name)"
    }
}

/// What a request still unanswered after its caller left means.
public enum XPCStuck: Sendable, Hashable {
    /// Nothing: the reply, when it comes, is dropped.
    case wait

    /// The service is wedged if the request is still unanswered this long
    /// after its caller left, measured on the liveness clock (a Mac asleep
    /// is not a wedge): the peer ends the run. `.zero` ends it as soon as
    /// the caller leaves: work whose abandonment leaves the service in a
    /// state not worth keeping.
    case endService(after: Duration)
}

/// The request or reply of a method that has none.
public struct XPCEmpty: Codable, Sendable, Hashable {
    public init() {}
}
#endif

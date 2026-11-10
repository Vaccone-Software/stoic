/// A lifecycle, declared once: the states a long-lived record can be in, the
/// events that move it, the timeouts its states carry and the effects its
/// transitions owe the world.
///
/// The conforming type is the definition, usually a caseless enum. The same
/// definition is read *at rest*, on a stored record, by ``LifecycleRecord``,
/// and *live*, in memory, by ``StateMachine/init(_:initial:label:historyLimit:clock:)``.
///
///     enum ParentWaiver: Lifecycle {
///         static let name = "kindora.parent-waiver"
///         typealias Principal = Someone
///
///         enum State: String, Hashable, Sendable, Codable, CaseIterable { case awaitingAddress, sent, signed, expired, revoked }
///         enum Event: Hashable, Sendable, Codable { case send(to: EmailAddress), sign, expire, revoke }
///         enum Effect: Hashable, Sendable, Codable { case emailSigningLink(to: EmailAddress) }
///
///         static func transition(from state: State, on event: Event) -> Step {
///             switch (state, event) {
///             case (.awaitingAddress, .send(let parent)): .to(.sent, effects: [.emailSigningLink(to: parent)])
///             case (.sent, .sign):                        .to(.signed)
///             case (.sent, .expire):                      .to(.expired)
///             case (.expired, .sign):                     .refuse("this link has expired")
///             default:                                    .ignore
///             }
///         }
///         static func timeout(in state: State) -> Timeout? {
///             state == .sent ? .after(.seconds(7 * 86_400), send: .expire) : nil
///         }
///         static func isFinal(_ state: State) -> Bool { state == .signed || state == .revoked }
///     }
///
/// **The transition function is the specification**, as design/07 has it: a
/// `switch` over state and event, total, pure and free of side effects.
///
/// **A timeout belongs to the state, not to the transition into it.** A
/// stored record keeps its state and when it entered it, and from that pair
/// any reader must be able to say when the state times out: so the timeout
/// is a function of the state alone. `.after(d)` is measured from entering;
/// `.at(m)` is a moment the state carries.
///
/// **Who and why.** Every accepted event is history, by a ``Principal`` and
/// with a reason; timed entries are by ``Initiator/timeout``.
public protocol Lifecycle: Sendable {
    /// The states a record can be in. Encoded in every record and history
    /// entry: never remove a case while stored data may hold it; retire it
    /// (``isRetired(_:)``).
    associatedtype State: Hashable & Sendable & Codable
    /// What can happen to a record. Encoded in every history entry.
    associatedtype Event: Hashable & Sendable & Codable
    /// What a transition owes the world (an email, an announcement),
    /// delivered at least once under a key derived from the record. `Never`
    /// when the lifecycle has none.
    associatedtype Effect: Sendable & Codable = Never
    /// Who acts: the app's type, recorded in history and never in an event.
    associatedtype Principal: Hashable & Sendable & Codable

    /// Names the lifecycle in records, effect keys and events. Stable
    /// forever.
    static var name: String { get }

    /// Raised when a write by an older definition would be wrong: records
    /// it wrote are then refused to older writers
    /// (``LifecycleRefusal/newerDefinition(written:current:)``) and still
    /// readable by them. 1 by default.
    static var version: Int { get }

    /// What `event` does in `state`: pure, and total over both.
    static func transition(from state: State, on event: Event) -> LifecycleStep<Self>

    /// The timeout of `state`, if it has one: a function of the state alone.
    /// `nil` by default.
    static func timeout(in state: State) -> LifecycleTimeout<Event>?

    /// Whether `state` is final: nothing should leave it, and a record in it
    /// may be purged. `false` by default.
    static func isFinal(_ state: State) -> Bool

    /// Whether `state` is retired: kept so stored data still decodes, never
    /// entered, and given a zero timeout to the state that replaces it.
    /// `false` by default.
    static func isRetired(_ state: State) -> Bool
}

extension Lifecycle {
    public static var version: Int { 1 }

    public static func timeout(in state: State) -> LifecycleTimeout<Event>? { nil }

    public static func isFinal(_ state: State) -> Bool { false }

    public static func isRetired(_ state: State) -> Bool { false }

    /// What ``transition(from:on:)`` returns.
    public typealias Step = LifecycleStep<Self>
    /// What ``timeout(in:)`` returns.
    public typealias Timeout = LifecycleTimeout<Event>
    /// A stored record of this lifecycle.
    public typealias Record = LifecycleRecord<Self>
    /// One entry of a record's history.
    public typealias Entry = LifecycleEntry<Self>
    /// What committing an event or a due timeout would write.
    public typealias Change = LifecycleChange<Self>
    /// Why an event, or a settling, was not accepted.
    public typealias Refusal = LifecycleRefusal<Self>
}

/// What a lifecycle does with an event in a state.
public enum LifecycleStep<L: Lifecycle>: Sendable {
    /// Enters `state` (or re-enters the current one, restarting its timeout),
    /// owing `effects`.
    case to(L.State, effects: [L.Effect] = [])
    /// Accepts the event without leaving the state: its visit and its
    /// timeout go on. Written to history like any accepted event.
    case stay(effects: [L.Effect] = [])
    /// The event is expected here and refused, with a reason the caller can
    /// tell a person: "this link has expired".
    case refuse(String)
    /// The event means nothing here.
    case ignore
    /// The event should be impossible here: a bug, reported at error level.
    case invalid(String)
}

/// When a state times out, and the event it then sends itself.
public enum LifecycleTimeout<Event: Hashable & Sendable>: Sendable, Hashable {
    /// `Duration` after the state was entered.
    case after(Duration, send: Event)
    /// At a moment the state itself carries: an event's end, an expiry the
    /// app computed with `ZonedDateTime`.
    case at(Moment, send: Event)

    /// The event the timeout sends.
    public var event: Event {
        switch self {
        case .after(_, let event), .at(_, let event): event
        }
    }

    /// When a state entered at `since` times out.
    public func due(since: Moment) -> Moment {
        switch self {
        case .after(let duration, _): since + duration
        case .at(let moment, _): moment
        }
    }

    /// The reason a timed entry gives: `after 604800 s`, or
    /// `at 2027-03-14T22:00:00Z`.
    var reason: String {
        switch self {
        case .after(let duration, _): "after \(Self.seconds(duration)) s"
        case .at(let moment, _): "at \(moment)"
        }
    }

    /// `duration` in seconds, as a decimal with no trailing zeros.
    static func seconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        guard attoseconds != 0 else { return String(seconds) }
        // A negative duration has negative attoseconds: write its magnitude.
        let negative = seconds < 0 || attoseconds < 0
        let whole = seconds.magnitude
        var fraction = String(attoseconds.magnitude)
        fraction = String(repeating: "0", count: 18 - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return (negative ? "-" : "") + "\(whole).\(fraction)"
    }
}

/// Who made a history entry: a principal of the app's, or a state's
/// timeout falling due.
///
/// Encoded as `{"principal": …}` or as the string `"timeout"`.
public enum Initiator<Principal: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    /// Someone the app names.
    case principal(Principal)
    /// A state's timeout fell due.
    case timeout

    private enum CodingKeys: String, CodingKey {
        case principal
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            guard text == "timeout" else {
                throw DecodingError.dataCorruptedError(
                    in: single, debugDescription: "an initiator is {\"principal\": …} or \"timeout\", not \"\(text)\"")
            }
            self = .timeout
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .principal(try container.decode(Principal.self, forKey: .principal))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .principal(let principal):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(principal, forKey: .principal)
        case .timeout:
            var container = encoder.singleValueContainer()
            try container.encode("timeout")
        }
    }
}

/// An error that can say, to a person, what happened and what they can do
/// (design/31).
///
/// The layer nearest the person knows best, so an app's error that wraps a
/// Stoic error decides how the failure reads. Say what it means once, beside
/// the error:
///
///     enum SignUpError: Error, Presentable {
///         case full, closed
///         var presentation: Presentation {
///             switch self {
///             case .full: Presentation(Wording("signup.full", default: "This event is full."), recovery: .nothing)
///             case .closed: Presentation(Wording("signup.closed", default: "Sign-up has closed."), recovery: .nothing)
///             }
///         }
///     }
///
/// A person never reads the error's description: free text in an error can
/// hold anything (an email, a token, a path with a user name in it).
/// ``Swift/Error/presented(fileID:line:)`` turns any error into what they read.
public protocol Presentable: Error {
    /// What a person reads, and what they can do about it.
    var presentation: Presentation { get }
}

/// What a person reads about a failure, before it has a reference.
public struct Presentation: Sendable, Hashable, Codable {
    /// What happened, in words for a person.
    public let message: Wording

    /// What they can do about it.
    public let recovery: Recovery

    /// A reference made elsewhere (a server's, carried in its error body),
    /// shown as it is so it matches the event that server recorded. `nil`:
    /// presenting the failure makes a new one.
    public let reference: SupportReference?

    public init(_ message: Wording, recovery: Recovery, reference: SupportReference? = nil) {
        self.message = message
        self.recovery = recovery
        self.reference = reference
    }
}

/// What a person can do about a failure: a case a screen can act on, never
/// free text.
public enum Recovery: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Do the same again.
    case tryAgain
    /// Wait, until the moment given if one is known.
    case wait(until: Moment?)
    /// Sign in again.
    case signInAgain
    /// Change what they entered; the fields, when they are known.
    case changeInput(fields: [String])
    /// It may have happened: look before trying again.
    case checkFirst
    /// This version of the app cannot do it: update.
    case updateApp
    /// Nothing they can do changes it: tell support, with the reference.
    case contactSupport
    /// Nothing to do: the answer is final.
    case nothing

    /// The case's name, as events record it.
    public var description: String {
        switch self {
        case .tryAgain: "tryAgain"
        case .wait: "wait"
        case .signInAgain: "signInAgain"
        case .changeInput: "changeInput"
        case .checkFirst: "checkFirst"
        case .updateApp: "updateApp"
        case .contactSupport: "contactSupport"
        case .nothing: "nothing"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, until, fields
    }

    /// `{"kind": "wait", "until": "2026-11-10T12:00:00Z"}`: a `kind` naming
    /// the case, beside its values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "tryAgain": self = .tryAgain
        case "wait": self = .wait(until: try container.decodeIfPresent(Moment.self, forKey: .until))
        case "signInAgain": self = .signInAgain
        case "changeInput": self = .changeInput(fields: try container.decodeIfPresent([String].self, forKey: .fields) ?? [])
        case "checkFirst": self = .checkFirst
        case "updateApp": self = .updateApp
        case "contactSupport": self = .contactSupport
        case "nothing": self = .nothing
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "\"\(kind)\" is not a recovery this build knows")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .kind)
        switch self {
        case .wait(let until): try container.encodeIfPresent(until, forKey: .until)
        case .changeInput(let fields): try container.encode(fields, forKey: .fields)
        case .tryAgain, .signInAgain, .checkFirst, .updateApp, .contactSupport, .nothing: break
        }
    }
}

/// A failure as a person sees it: the words, what to do, and the reference
/// that support can match to the `failure.presented` event.
///
/// `Codable`, so a server can send it in an error body.
public struct Presented: Sendable, Hashable, Codable {
    /// What happened.
    public let message: Wording

    /// What the person can do.
    public let recovery: Recovery

    /// The code they read to support.
    public let reference: SupportReference

    /// False when nobody classified the failure and the generic words were
    /// used ("Something went wrong."): a failure worth classifying.
    public let isClassified: Bool

    init(message: Wording, recovery: Recovery, reference: SupportReference, isClassified: Bool) {
        self.message = message
        self.recovery = recovery
        self.reference = reference
        self.isClassified = isClassified
    }

    private enum CodingKeys: String, CodingKey {
        case message, recovery, reference
        case isClassified = "classified"
    }
}

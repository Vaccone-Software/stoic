/// A value that must never appear in a log, a crash report or a debugger.
///
/// Tokens, passwords and keys leak through the paths nobody audits:
/// `print(request)`, `dump(config)`, string interpolation in an error
/// message, `po` in the debugger, an analytics event built from a struct's
/// description. A `Secret` closes all of them at once: its description, debug
/// description and mirror say only that a secret is here, and the value is
/// reachable only through ``reveal()`` — explicit, and easy to find in
/// review.
///
///     struct Credentials { let user: String; let token: Secret<String> }
///     print(Credentials(user: "ada", token: Secret("hunter2")))
///     // Credentials(user: "ada", token: Secret(<redacted>))
///
/// `Secret` deliberately does not conform to `Equatable`, `Hashable` or
/// `Codable`: comparing secrets invites timing leaks, and encoding one should
/// be a decision made where it happens (a schema field marked `secret`).
public struct Secret<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// The secret value. Every call is a place the secret leaves its box.
    public func reveal() -> Value {
        value
    }

    /// A new secret derived from this one, without revealing it to the caller.
    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> Secret<T> {
        Secret<T>(try transform(value))
    }

    public var description: String { "Secret(<redacted>)" }
    public var debugDescription: String { "Secret(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension Event.Value {
    /// A secret as an event value: always redacted, whatever the privacy.
    public static func secret<V>(_ secret: Secret<V>) -> Event.Value {
        .string("<redacted>")
    }
}

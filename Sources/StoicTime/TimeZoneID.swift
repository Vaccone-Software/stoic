internal import Stoic

/// A place's rules for its clocks, by name: `America/New_York`.
///
///     let start = try ZonedDateTime(PlainDate(2027, 3, 14), PlainTime(9, 0), in: "America/New_York")
///
/// An IANA time zone name, never an abbreviation (`EST` is not a place, and
/// means different offsets in different countries) and never an offset
/// alone, which says what the clocks read once and not what they will read
/// after the next change. The name is what is stored; the offsets come from
/// the zone rules in force (``ZoneRules/current``) whenever they are needed,
/// so a stored zone follows a government's change of mind.
///
/// Two exceptions are answered without the rules: `UTC`, whose offset is
/// zero by definition, and a fixed offset written as RFC 9557 writes one,
/// `+05:30`, for data that really has no place (an offset a server sent).
///
/// There is no ambient zone. ``device`` is the person's zone, and code
/// that means it says so.
public struct TimeZoneID: Sendable, Hashable {
    /// The name, as given: `America/New_York`, `UTC`, `+05:30`.
    public let identifier: String

    /// The zone named `identifier`, if it is spelt as a zone name can be.
    ///
    /// Whether the rules know the zone is not checked here: it is asked
    /// when the zone is used, of the rules in force then, and a name this
    /// device does not know may be one a newer device does.
    ///
    /// - Throws: ``TimeError/invalid(_:)`` for a name no zone can have: an
    ///   empty part, a space, a `..`.
    public init(_ identifier: String) throws(TimeError) {
        if let problem = Self.problem(with: identifier) {
            throw .invalid("\"\(identifier)\" is not a time zone name: \(problem)")
        }
        self.identifier = identifier
    }

    /// A name the platform gave, used as it is.
    init(unchecked identifier: String) {
        self.identifier = identifier
    }

    /// Coordinated Universal Time: offset zero, always.
    public static let utc = TimeZoneID(unchecked: "UTC")

    /// The zone the device is set to: the person's own, which a "today"
    /// for them is asked in. From the zone rules in force, so a test that
    /// scripts the rules decides it too.
    public static var device: TimeZoneID { ZoneRules.current.deviceZone }

    /// The fixed offset, in seconds east of UTC, of `UTC` and of an offset
    /// name such as `+05:30`; `nil` for a zone whose offset the rules give.
    var fixedOffset: Int? {
        if identifier == "UTC" { return 0 }
        guard let first = identifier.utf8.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") else {
            return nil
        }
        var scanner = TimeTextScanner(identifier)
        guard case .success(let seconds) = scanner.offset(allowZ: false, allowSeconds: false), scanner.isAtEnd else {
            return nil
        }
        return seconds
    }

    /// Why `identifier` cannot name a zone, or `nil` if it can: the IANA
    /// rules for names (parts of letters, digits, `.`, `_`, `+` and `-`,
    /// separated by `/`, none empty, none starting with `-`, none `.` or
    /// `..`), or an RFC 9557 offset `±hh:mm`.
    static func problem(with identifier: String) -> String? {
        if identifier.isEmpty { return "it is empty" }
        if let first = identifier.utf8.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            var scanner = TimeTextScanner(identifier)
            guard case .success = scanner.offset(allowZ: false, allowSeconds: false), scanner.isAtEnd else {
                return "an offset zone is written ±hh:mm, such as +05:30"
            }
            return nil
        }
        for part in identifier.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty { return "it has an empty part between slashes" }
            if part == "." || part == ".." { return "`\(part)` is not a part of a zone name" }
            if part.first == "-" { return "a part of a zone name does not start with `-`" }
            for byte in part.utf8 {
                let allowed = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "+")
                    || byte == UInt8(ascii: "-")
                guard allowed else {
                    return byte == UInt8(ascii: " ")
                        ? "a zone name has no spaces (`America/New_York`)" : "a zone name is letters, digits, `.`, `_`, `+` and `-`"
                }
            }
        }
        return nil
    }
}

extension TimeZoneID: ExpressibleByStringLiteral {
    /// A zone name written in the code: `"America/New_York"`.
    ///
    /// A literal is code, so a malformed one is a bug and stops the program
    /// with the reason, as a malformed regular expression literal would.
    /// Text that comes from outside is read with ``init(_:)-(String)``,
    /// which throws.
    public init(stringLiteral identifier: String) {
        if let problem = Self.problem(with: identifier) {
            preconditionFailure("\"\(identifier)\" is not a time zone name: \(problem)")
        }
        self.identifier = identifier
    }
}

extension TimeZoneID: CustomStringConvertible {
    /// The name: `America/New_York`.
    public var description: String { identifier }
}

extension TimeZoneID: Codable {
    /// Reads a zone name, refusing one no zone can have.
    public init(from decoder: any Decoder) throws {
        self = try decodeText(from: decoder, kind: "a time zone name") { text in
            Self.problem(with: text).map { .failure(TimeTextFailure($0)) } ?? .success(TimeZoneID(unchecked: text))
        }
    }

    /// Writes the zone's name.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

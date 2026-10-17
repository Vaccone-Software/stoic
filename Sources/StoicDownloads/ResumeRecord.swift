#if STOIC_CRYPTO
internal import StoicHTTP

/// What lets a partial file be resumed: a way to ask the server whether the
/// file is still the one the bytes came from.
///
/// A strong `ETag` is preferred, since it names the bytes; `Last-Modified` is
/// the fallback, which `If-Range` also accepts. A weak `ETag` (`W/"…"`) says
/// "equivalent", not "identical", and RFC 9110 forbids `If-Range` to use one:
/// it is no validator, and a response with only one has none.
struct Validator: Sendable, Equatable {
    enum Kind: String, Sendable {
        case etag
        case lastModified = "last-modified"
    }

    var kind: Kind
    /// The header's value exactly as the server sent it, which is also what
    /// `If-Range` sends back.
    var value: String

    /// The validator of a response, if it has one.
    init?(_ headers: HTTPHeaders) {
        if let etag = headers["ETag"]?.trimmed, !etag.isEmpty, !etag.hasPrefix("W/") {
            self.init(kind: .etag, value: etag)
        } else if let date = headers["Last-Modified"]?.trimmed, !date.isEmpty {
            self.init(kind: .lastModified, value: date)
        } else {
            return nil
        }
    }

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

extension String {
    fileprivate var trimmed: String {
        var scalars = Substring(self)
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(scalars)
    }
}

/// The sidecar of a partial file, written beside it with `AtomicFile`, so that
/// it is whole or absent and a damaged one fails its checksum: a record that
/// cannot be read is a download that starts over.
///
/// ``synced`` is the point of it. Bytes of the partial file past the last
/// `fullSync` may be lost, or zero-filled, by a power cut, and the file's own
/// size cannot say which; so the record is written only after the data it
/// vouches for is durable, and a resume trusts the partial file only up to it.
struct ResumeRecord: Sendable, Equatable {
    static let header = "stoic-download 1"

    /// Which download the partial file belongs to: a digest of the request's
    /// target, the expected size and the digest. A different download at the
    /// same path (a model's next revision) is not resumed from this one.
    var identity: String
    var validator: Validator?
    /// How many bytes of the partial file are durable and verified to belong
    /// to this download.
    var synced: Int
    /// The whole file's size, when a response said it.
    var total: Int?

    func encoded() -> [UInt8] {
        var lines = [Self.header, "identity \(identity)", "synced \(synced)", "total \(total.map(String.init) ?? "none")"]
        if let validator {
            lines.append("validator \(validator.kind.rawValue) \(validator.value)")
        } else {
            lines.append("validator none")
        }
        return Array(lines.joined(separator: "\n").utf8)
    }

    /// The record `bytes` hold, or `nil` for anything that is not exactly one
    /// (a later version's, a truncated one, garbage that happened to pass a checksum).
    init?(decoding bytes: [UInt8]) {
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 5, lines[0] == Self.header else { return nil }
        guard lines[1].hasPrefix("identity "), lines[2].hasPrefix("synced "), lines[3].hasPrefix("total "),
              lines[4].hasPrefix("validator ") else { return nil }
        let identity = String(lines[1].dropFirst("identity ".count))
        guard !identity.isEmpty, let synced = Int(lines[2].dropFirst("synced ".count)), synced >= 0 else { return nil }
        let totalText = lines[3].dropFirst("total ".count)
        let total: Int?
        if totalText == "none" {
            total = nil
        } else if let parsed = Int(totalText), parsed >= 0 {
            total = parsed
        } else {
            return nil
        }
        let validatorText = lines[4].dropFirst("validator ".count)
        let validator: Validator?
        if validatorText == "none" {
            validator = nil
        } else {
            let parts = validatorText.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let kind = Validator.Kind(rawValue: String(parts[0])), !parts[1].isEmpty else { return nil }
            validator = Validator(kind: kind, value: String(parts[1]))
        }
        self.init(identity: identity, validator: validator, synced: synced, total: total)
    }

    init(identity: String, validator: Validator?, synced: Int, total: Int?) {
        self.identity = identity
        self.validator = validator
        self.synced = synced
        self.total = total
    }
}

/// A `Content-Range` response header: where the bytes of a `206` start, and
/// the length of the whole file when the server says it (`*` when it does not).
struct ContentRange: Sendable, Equatable {
    var start: Int
    var end: Int
    var total: Int?

    /// `bytes 500-1999/2000`, or `bytes 500-1999/*`.
    init?(_ header: String?) {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let range = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]), start >= 0, end >= start else { return nil }
        self.start = start
        self.end = end
        if parts[1] == "*" {
            total = nil
        } else if let total = Int(parts[1]), total > end {
            self.total = total
        } else {
            return nil
        }
    }

    /// The length a `416` reports: `bytes */2000`.
    static func unsatisfiedTotal(_ header: String?) -> Int? {
        guard let header, header.hasPrefix("bytes */") else { return nil }
        return Int(header.dropFirst("bytes */".count))
    }
}
#endif

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif
internal import StoicJSON

// MARK: - URL

/// Which URLs a schema accepts.
public enum URLFormat: Sendable, Hashable, CaseIterable {
    /// A URL with a scheme: `https://example.com/a`, `mailto:a@example.com`.
    /// What an API means by "a link", and the default.
    case absolute
    /// Any URL reference, relative or absolute: `/users/42`, `../a`,
    /// `#top`, as well as everything ``absolute`` accepts.
    case relative
}

extension Schema where Value == URL {
    /// A URL, written as a string; absolute by default.
    ///
    /// The string must already be a URL: one with a space or another
    /// character a URL has to percent-encode is `invalid_format`, never
    /// quietly encoded into a different URL from the one the sender wrote. A
    /// relative reference where an absolute URL is wanted is `invalid_format`
    /// too, saying so. Written as `absoluteString`.
    public static func url(_ format: URLFormat = .absolute) -> Schema<URL> {
        let absolute = format == .absolute
        let describe = absolute ? "an absolute URL, such as \"https://example.com/a\"" : "a URL or a relative reference"
        var examples = [
            "https://example.com", "https://example.com/a/b?q=1&r=%20#top", "http://localhost:8080/",
            "mailto:someone@example.com", "file:///tmp/a.txt", "urn:isbn:0451450523", "https://[::1]:443/x",
        ]
        if !absolute { examples += ["/users/42", "a/b", "../up", "#top", "//cdn.example.com/x.js", "?page=2"] }
        var counterexamples = ["not a url", "https://exa mple.com"]
        if absolute { counterexamples.append("/relative/path") }
        return .formatted(
            name: "URL", format: absolute ? "uri" : "uri-reference", describe: describe, examples: examples,
            counterexamples: counterexamples,
            parse: { text in
                guard !text.isEmpty, let url = URL(string: text, encodingInvalidCharacters: false) else {
                    if let space = text.firstIndex(where: \.isWhitespace) {
                        let what = text[space] == " " ? "a space" : "whitespace"
                        return .failure(FormatFailure("it contains \(what), which a URL must percent-encode (`%20`)"))
                    }
                    return .failure(FormatFailure(text.isEmpty ? "it is empty" : nil))
                }
                if absolute && url.scheme == nil {
                    return .failure(
                        FormatFailure("it is a relative reference; an absolute URL starts with a scheme such as `https:`"))
                }
                return .success(url)
            },
            print: { $0.absoluteString })
    }
}

extension URL: Schematic {
    /// An absolute URL; see ``Schema/url(_:)`` for relative references.
    public static var schema: Schema<URL> { .url() }
}

// MARK: - UUID

extension Schema where Value == UUID {
    /// A UUID in its 8-4-4-4-12 hexadecimal form. Upper and lower case are
    /// read alike; it is written in lower case, the form RFC 9562 asks for.
    /// Thirty-two digits without hyphens, or a UUID in braces, are refused
    /// with the hyphenated form as the suggestion.
    public static var uuid: Schema<UUID> {
        .formatted(
            name: "UUID", format: "uuid",
            describe: #"a UUID, such as "123e4567-e89b-12d3-a456-426614174000""#,
            examples: [
                "00000000-0000-0000-0000-000000000000", "123e4567-e89b-12d3-a456-426614174000",
                "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "f47ac10b-58cc-4372-A567-0e02b2c3d479",
            ],
            counterexamples: ["not-a-uuid", "123e4567e89b12d3a456426614174000", "123e4567-e89b-12d3-a456-42661417400g"],
            parse: { text in
                if let uuid = UUID(uuidString: text) { return .success(uuid) }
                var hex = Substring(text)
                if hex.first == "{", hex.last == "}" { hex = hex.dropFirst().dropLast() }
                let bare = hex.filter { $0 != "-" }
                if bare.count == 32, bare.allSatisfy(\.isHexDigit) {
                    let digits = Array(bare.lowercased())
                    var hyphenated = ""
                    for (index, digit) in digits.enumerated() {
                        if [8, 12, 16, 20].contains(index) { hyphenated.append("-") }
                        hyphenated.append(digit)
                    }
                    return .failure(FormatFailure("it is not in the 8-4-4-4-12 form", suggestions: [hyphenated]))
                }
                return .failure(FormatFailure())
            },
            print: { $0.uuidString.lowercased() })
    }
}

extension UUID: Schematic {
    public static var schema: Schema<UUID> { .uuid }
}

// MARK: - Data

/// How bytes are spelt in a JSON string.
public enum DataFormat: Sendable, Hashable, CaseIterable {
    /// Base64 with `+`, `/` and `=` padding (RFC 4648 section 4), the
    /// default: OpenAPI's `byte`.
    case base64
    /// Base64 with `-` and `_` (RFC 4648 section 5), safe in URLs and
    /// file names. Read with or without padding, written without, as JWTs
    /// and most APIs that use it do.
    case base64url
}

extension Schema where Value == Data {
    /// Bytes, written as base64 text; standard base64 by default.
    ///
    /// Whitespace, a character from the other alphabet, and (for standard
    /// base64) missing padding are `invalid_format`, each with the reason.
    public static func data(_ format: DataFormat = .base64) -> Schema<Data> {
        let url = format == .base64url
        let examples =
            url
            ? ["", "AA", "AAE", "AAEC", "-_-_", "SGVsbG8sIHdvcmxkIQ", "SGVsbG8sIHdvcmxkIQ=="]
            : ["", "AA==", "AAE=", "AAEC", "+/+/", "SGVsbG8sIHdvcmxkIQ=="]
        return .formatted(
            name: "Data", format: url ? nil : "byte",
            describe: url ? "base64url text" : "base64 text",
            keywords: ["contentEncoding": .string(url ? "base64url" : "base64")],
            examples: examples,
            counterexamples: url ? ["not base64!", "A", "+/+/"] : ["not base64!", "AAA", "-_-_"],
            parse: { text in Base64.decode(text, url: url) },
            print: { data in
                let standard = data.base64EncodedString()
                guard url else { return standard }
                var out = ""
                out.reserveCapacity(standard.utf8.count)
                for character in standard {
                    switch character {
                    case "+": out.append("-")
                    case "/": out.append("_")
                    case "=": continue
                    default: out.append(character)
                    }
                }
                return out
            })
    }
}

extension Data: Schematic {
    /// Standard base64; see ``Schema/data(_:)`` for base64url.
    public static var schema: Schema<Data> { .data() }
}

/// Base64 in either alphabet, with a reason for what is wrong.
enum Base64 {
    static func decode(_ text: String, url: Bool) -> Result<Data, FormatFailure> {
        var standard = ""
        standard.reserveCapacity(text.utf8.count + 3)
        for character in text {
            switch character {
            case "A"..."Z", "a"..."z", "0"..."9", "=":
                standard.append(character)
            case "+", "/":
                guard !url else {
                    return .failure(FormatFailure("it uses `+` or `/`, which base64url writes as `-` and `_`; is it standard base64?"))
                }
                standard.append(character)
            case "-", "_":
                guard url else {
                    return .failure(FormatFailure("it uses `-` or `_`, which belong to base64url, not standard base64"))
                }
                standard.append(character == "-" ? "+" : "/")
            default:
                if character.isWhitespace {
                    return .failure(FormatFailure("it contains whitespace"))
                }
                return .failure(FormatFailure("`\(character)` is not a base64 character"))
            }
        }
        let count = standard.utf8.count
        if url {
            if count % 4 == 1 { return .failure(FormatFailure("its length, \(count), is not a length base64 can have")) }
            if !standard.hasSuffix("=") { standard += String(repeating: "=", count: (4 - count % 4) % 4) }
        } else if count % 4 != 0 {
            return .failure(FormatFailure("its length, \(count), is not a multiple of 4: is the `=` padding missing?"))
        }
        guard let data = Data(base64Encoded: standard) else {
            return .failure(FormatFailure("its `=` padding is misplaced"))
        }
        return .success(data)
    }
}

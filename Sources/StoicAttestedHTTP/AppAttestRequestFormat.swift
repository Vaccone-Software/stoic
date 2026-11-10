#if canImport(DeviceCheck) && canImport(CryptoKit)
internal import CryptoKit
internal import Foundation

/// The statement an App Attest key signs for an HTTP request, and the headers
/// that carry the signature: format v1 (design/29, Signing an HTTP request).
///
/// An RFC 9421 signature base over a fixed list of components, label
/// `attest`:
///
///     "@method": POST
///     "@authority": api.example.com
///     "@path": /v1/check-ins
///     "@query": ?event=e42
///     "content-digest": sha-256=:TFIG1rH3ac1z4inoc/WSdJvUoBvcPaNKY+HcrXjxBAw=:
///     "idempotency-key": 3f2a9c1e-7b40-4d1a-9e55-0c6b2d8f1a73
///     "@signature-params": ("@method" "@authority" "@path" "@query" "content-digest" "idempotency-key");keyid="…";nonce="…";alg="apple-app-attest"
///
/// one line per component and a line feed, then the parameters with no line
/// feed after them, in UTF-8. The client data hash the key signs is the
/// SHA-256 of those bytes. `idempotency-key` is covered exactly when the
/// request carries the header. A server in another language builds the same
/// base with an RFC 9421 library, and `StoicAttestation` rebuilds it from
/// what it received; both are held to the committed vectors.
public enum AppAttestRequestFormat {
    /// The signature's label in `Signature-Input` and `Signature`.
    public static let label = "attest"
    /// The `alg` parameter.
    public static let algorithm = "apple-app-attest"
    /// `Content-Digest` of a request with no body: the SHA-256 of zero bytes.
    public static let emptyBodyDigest = "sha-256=:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=:"

    /// The covered components, in order.
    public static func components(idempotencyKey: Bool) -> [String] {
        ["@method", "@authority", "@path", "@query", "content-digest"] + (idempotencyKey ? ["idempotency-key"] : [])
    }

    /// `sha-256=:<base64 of SHA-256 of body>:` (RFC 9530).
    public static func contentDigest(of body: [UInt8]) -> String {
        "sha-256=:" + Data(SHA256.hash(data: body)).base64EncodedString() + ":"
    }

    /// The signature parameters: the inner list, `keyid`, `nonce` (standard
    /// base64 with padding) and `alg`, as `Signature-Input` carries them.
    public static func signatureParameters(keyID: String, nonce: [UInt8], idempotencyKey: Bool) -> String {
        "(" + components(idempotencyKey: idempotencyKey).map { "\"\($0)\"" }.joined(separator: " ") + ")"
            + ";keyid=\"\(keyID)\";nonce=\"\(Data(nonce).base64EncodedString())\";alg=\"\(algorithm)\""
    }

    /// The signature base.
    ///
    /// - Parameters:
    ///   - method: The method as sent, upper case.
    ///   - authority: The host in lower case, with `:port` only when it is not
    ///     the scheme's default.
    ///   - path: The absolute path exactly as sent, percent-encoded; `/` when empty.
    ///   - query: The query exactly as sent, percent-encoded, without its
    ///     `?`; empty when there is none. The base writes `?` before it.
    ///   - contentDigest: The `Content-Digest` header's value.
    ///   - idempotencyKey: The `Idempotency-Key` header's value, if the
    ///     request carries one.
    ///   - keyID: The key id exactly as `generateKey` returned it.
    ///   - nonce: The request challenge.
    public static func signatureBase(
        method: String, authority: String, path: String, query: String, contentDigest: String,
        idempotencyKey: String?, keyID: String, nonce: [UInt8]
    ) -> String {
        var lines = [
            "\"@method\": \(method)",
            "\"@authority\": \(authority)",
            "\"@path\": \(path.isEmpty ? "/" : path)",
            "\"@query\": ?\(query)",
            "\"content-digest\": \(contentDigest)",
        ]
        if let idempotencyKey { lines.append("\"idempotency-key\": \(idempotencyKey)") }
        lines.append("\"@signature-params\": " + signatureParameters(keyID: keyID, nonce: nonce, idempotencyKey: idempotencyKey != nil))
        return lines.joined(separator: "\n")
    }

    /// The client data hash for `base`: SHA-256 of its UTF-8 bytes.
    public static func clientDataHash(of base: String) -> [UInt8] {
        Array(SHA256.hash(data: Array(base.utf8)))
    }

    /// Whether every byte of `value` is visible ASCII (or a space inside),
    /// which every component must be: anything else cannot be signed.
    static func isSignable(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }
}
#endif

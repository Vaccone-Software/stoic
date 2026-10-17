#if STOIC_CRYPTO
internal import Crypto
internal import Foundation

/// Seals and opens values: AES-256-GCM through swift-crypto, with a header that
/// names the key and a context that binds the value to its purpose.
///
///     let sealed = try Sealing.seal(plaintext, context: "app.notes", key: ring.current)
///     let plain = try Sealing.open(sealed, context: "app.notes", keyring: ring)
///
/// ## Format, version 1
///
///     offset  size  field
///          0     4  magic "SSL1"
///          4     1  format version (1)
///          5     1  algorithm (1: AES-256-GCM, 96-bit nonce, 128-bit tag)
///          6    16  key identifier
///         22    12  nonce, fresh and random for every seal
///         34     n  ciphertext, the plaintext's length
///       34+n    16  authentication tag
///
/// Bytes 0 to 21, the **header**, followed by the context's encoding
/// (``SealContext``), are the AES-GCM associated data: authenticated, not
/// encrypted. So the magic, the version, the algorithm and the key identifier
/// cannot be edited, and the value cannot be moved to another context, without
/// the tag failing; the nonce is authenticated by being the cipher's input. The
/// overhead is ``overhead`` bytes; the plaintext's length is not hidden.
///
/// ## What is guaranteed, and what is not
///
/// - **Nonces** come from swift-crypto's `AES.GCM` (the system's secure random
///   source), one per seal, never from Stoic's ambient randomness and never
///   chosen by a caller. Keys come only from ``SealingKey/generate()``.
/// - **A key seals at most 2³² values.** With random 96-bit nonces the chance
///   that two seals under one key share a nonce grows with the square of the
///   count, and NIST SP 800-38D (section 8.3) bounds a key at 2³² invocations
///   to keep it under 2⁻³². A repeated nonce under one key is catastrophic for
///   GCM: it reveals the XOR of the two plaintexts and forfeits authenticity.
///   The answer is rotation: a ``Keyring`` makes a new key at any time
///   (``Keyring/rotate()``), and a compaction can rotate as it folds
///   (``SealedJournal/compact(rotatingKey:unreadable:_:)``). Nothing here counts
///   seals, because a count held in memory cannot see earlier launches; an app
///   that seals millions of values a day under one key rotates on a schedule
///   (at one seal a second, 2³² is 136 years away; at a thousand a second,
///   seven weeks).
/// - **Failures are told apart** (``SealError``), and a key identifier flipped
///   in transit is reported as ``SealError/unknownKey(_:)``: it is read before
///   anything is authenticated, so it cannot be told from a lost key.
public enum Sealing {
    /// Bytes added to a plaintext: header, nonce and tag.
    public static let overhead = headerSize + nonceSize + tagSize

    static let magic: [UInt8] = Array("SSL1".utf8)
    static let formatVersion: UInt8 = 1
    static let algorithmAES256GCM: UInt8 = 1
    /// Magic, version, algorithm, key identifier: the authenticated header.
    static let headerSize = 4 + 1 + 1 + KeyID.byteCount
    static let nonceSize = 12
    static let tagSize = 16

    // MARK: Sealing

    /// `plaintext` sealed under `key`, bound to `context`.
    ///
    /// Safe to call from any thread. Each call draws a fresh random nonce.
    ///
    /// - Throws: ``SealError/encryptionFailed`` if the cipher refuses, which an
    ///   input of ordinary size never provokes.
    public static func seal(_ plaintext: [UInt8], context: SealContext, key: SealingKey) throws(SealError) -> [UInt8] {
        var sealed = magic
        sealed.append(formatVersion)
        sealed.append(algorithmAES256GCM)
        sealed.append(contentsOf: key.id.bytes)
        let associatedData = sealed + context.associatedData
        let box: AES.GCM.SealedBox
        do {
            // No nonce is passed: swift-crypto draws a fresh random one.
            box = try AES.GCM.seal(plaintext, using: key.material, authenticating: associatedData)
        } catch {
            throw .encryptionFailed
        }
        // Nonce, ciphertext and tag, in that order: the rest of the format.
        guard let combined = box.combined else { throw .encryptionFailed }
        sealed.append(contentsOf: combined)
        return sealed
    }

    // MARK: Opening

    /// The plaintext of `sealed`, if it was sealed for `context` under a key
    /// the keyring holds.
    ///
    /// - Throws: ``SealError``: ``SealError/notSealed`` for bytes with no
    ///   header, ``SealError/torn`` for a header cut short,
    ///   ``SealError/unsupportedFormat(version:algorithm:)``,
    ///   ``SealError/unknownKey(_:)`` for a key the keyring lacks, and
    ///   ``SealError/tampered`` when authentication fails.
    public static func open(_ sealed: [UInt8], context: SealContext, keyring: Keyring) throws(SealError) -> [UInt8] {
        let id = try keyID(of: sealed)
        guard let key = keyring.key(id: id) else { throw .unknownKey(id) }
        return try decrypt(sealed, context: context, key: key)
    }

    /// ``open(_:context:keyring:)`` with one key, for a value sealed under a
    /// key the caller holds itself (a per-object key kept inside a sealed
    /// record). A value that names a different key is ``SealError/unknownKey(_:)``.
    public static func open(_ sealed: [UInt8], context: SealContext, key: SealingKey) throws(SealError) -> [UInt8] {
        let id = try keyID(of: sealed)
        guard id == key.id else { throw .unknownKey(id) }
        return try decrypt(sealed, context: context, key: key)
    }

    private static func decrypt(_ sealed: [UInt8], context: SealContext, key: SealingKey) throws(SealError) -> [UInt8] {
        let associatedData = Array(sealed[..<headerSize]) + context.associatedData
        do {
            let box = try AES.GCM.SealedBox(combined: sealed[headerSize...])
            return Array(try AES.GCM.open(box, using: key.material, authenticating: associatedData))
        } catch {
            // The size was checked, so the cipher's refusal is authentication.
            throw .tampered
        }
    }

    // MARK: Looking without decrypting

    /// Whether `bytes` begin with the sealed-value magic. Nothing is
    /// authenticated: a value that passes may still be torn or altered, and
    /// plaintext that happens to begin `SSL1` passes too (a collision a caller
    /// that cares prevents by choosing what it stores).
    public static func isSealed(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: magic)
    }

    /// The identifier of the key that sealed `sealed`, read from the header
    /// without decrypting and without authenticating: it can be edited, and a
    /// value that names a key is not thereby proved to have been sealed under it.
    ///
    /// - Throws: ``SealError/notSealed``, ``SealError/torn`` or
    ///   ``SealError/unsupportedFormat(version:algorithm:)``.
    public static func keyID(of sealed: [UInt8]) throws(SealError) -> KeyID {
        guard isSealed(sealed) else { throw .notSealed }
        guard sealed.count > 5 else { throw .torn }
        guard sealed[4] == formatVersion, sealed[5] == algorithmAES256GCM else {
            throw .unsupportedFormat(version: sealed[4], algorithm: sealed[5])
        }
        guard sealed.count >= overhead, let id = KeyID(bytes: Array(sealed[6..<headerSize])) else { throw .torn }
        return id
    }
}
#endif

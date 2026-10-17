#if STOIC_CRYPTO
import Crypto

/// What a file's bytes must hash to: the digest a download is verified
/// against while it streams, never in a second pass over the finished file.
///
/// A digest is an algorithm and the lowercase hexadecimal it produces. Make
/// one from the hex a manifest gives, which can be wrong, so making one can
/// fail; a download that was given a bad digest and verified nothing would be
/// worse than one that refused it.
///
/// ```swift
/// let digest = try ContentDigest.sha256(manifest.sha256)          // a file's SHA-256
/// let blob = try ContentDigest.gitBlobSHA1(manifest.blobSHA1)     // git's object id for it
/// ```
///
/// More algorithms are one more ``Algorithm`` constant and one more case in
/// the hasher that streams them (`ContentHasher`); nothing else knows which
/// algorithms exist.
public struct ContentDigest: Sendable, Hashable, CustomStringConvertible {
    /// How the digest is computed.
    public struct Algorithm: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
        public let rawValue: String

        /// The SHA-256 of the file's bytes: 64 hexadecimal digits.
        public static let sha256 = Algorithm(known: "sha256")

        /// Git's object id for the file as a blob: the SHA-1 of `"blob <size>\0"`
        /// followed by the bytes, 40 hexadecimal digits. What a Hugging Face
        /// repository lists for a file that is not stored in Git LFS. It needs
        /// the size before the first byte, so a ``Download`` that verifies with
        /// it must know its expected size.
        public static let gitBlobSHA1 = Algorithm(known: "git-blob-sha1")

        private init(known rawValue: String) {
            self.rawValue = rawValue
        }

        /// The algorithm named `rawValue`, if there is one.
        public init?(rawValue: String) {
            switch rawValue {
            case Self.sha256.rawValue: self = .sha256
            case Self.gitBlobSHA1.rawValue: self = .gitBlobSHA1
            default: return nil
            }
        }

        /// The number of hexadecimal digits the algorithm's digests have.
        public var hexLength: Int {
            switch self {
            case .sha256: 64
            default: 40
            }
        }

        /// Whether the algorithm needs the file's size before the first byte.
        var needsSize: Bool { self == .gitBlobSHA1 }

        public var description: String { rawValue }
    }

    public enum Invalid: Error, Sendable, Hashable, CustomStringConvertible {
        /// The text has `actual` characters; `algorithm` has `expected`.
        case wrongLength(algorithm: Algorithm, expected: Int, actual: Int)
        /// The text has a character that is not a hexadecimal digit.
        case notHexadecimal(algorithm: Algorithm)

        public var description: String {
            switch self {
            case .wrongLength(let algorithm, let expected, let actual):
                "a \(algorithm) digest is \(expected) hexadecimal digits, not \(actual)"
            case .notHexadecimal(let algorithm):
                "a \(algorithm) digest is hexadecimal"
            }
        }
    }

    public let algorithm: Algorithm
    /// The digest, in lowercase hexadecimal.
    public let hex: String

    /// - Throws: ``Invalid`` if `hex` is not the right number of hexadecimal
    ///   digits for `algorithm`. Case does not matter; it is kept lowercase.
    public init(algorithm: Algorithm, hex: String) throws(Invalid) {
        let lowercase = hex.lowercased()
        guard lowercase.utf8.count == algorithm.hexLength else {
            throw .wrongLength(algorithm: algorithm, expected: algorithm.hexLength, actual: lowercase.utf8.count)
        }
        guard lowercase.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw .notHexadecimal(algorithm: algorithm)
        }
        self.algorithm = algorithm
        self.hex = lowercase
    }

    public static func sha256(_ hex: String) throws(Invalid) -> ContentDigest {
        try ContentDigest(algorithm: .sha256, hex: hex)
    }

    public static func gitBlobSHA1(_ hex: String) throws(Invalid) -> ContentDigest {
        try ContentDigest(algorithm: .gitBlobSHA1, hex: hex)
    }

    /// The digest of `bytes` under `algorithm`.
    public init(algorithm: Algorithm, of bytes: [UInt8]) {
        var hasher = ContentHasher(algorithm, size: bytes.count)
        hasher.update(bytes)
        self.algorithm = algorithm
        hex = hasher.hex
    }

    public var description: String { "\(algorithm):\(hex)" }
}

/// A digest being computed over bytes as they arrive.
///
/// A struct with a case for each algorithm, not an existential: it is updated
/// for every chunk of a download that may be 20 GB.
struct ContentHasher: Sendable {
    private enum State: Sendable {
        case sha256(SHA256)
        case gitBlobSHA1(Insecure.SHA1)
    }

    private var state: State

    /// - Parameter size: The number of bytes that will be hashed. Only the
    ///   algorithms that put it in front of the bytes (git's) use it.
    init(_ algorithm: ContentDigest.Algorithm, size: Int?) {
        switch algorithm {
        case .gitBlobSHA1:
            guard let size else { preconditionFailure("a git blob digest needs the file's size before its first byte") }
            var sha1 = Insecure.SHA1()
            sha1.update(data: Array("blob \(size)\0".utf8))
            state = .gitBlobSHA1(sha1)
        default:
            state = .sha256(SHA256())
        }
    }

    mutating func update(_ bytes: [UInt8]) {
        switch state {
        case .sha256(var hasher):
            hasher.update(data: bytes)
            state = .sha256(hasher)
        case .gitBlobSHA1(var hasher):
            hasher.update(data: bytes)
            state = .gitBlobSHA1(hasher)
        }
    }

    /// The digest of what has been hashed so far, in lowercase hexadecimal;
    /// hashing can go on.
    var hex: String {
        switch state {
        case .sha256(let hasher): Self.hexadecimal(hasher.finalize())
        case .gitBlobSHA1(let hasher): Self.hexadecimal(hasher.finalize())
        }
    }

    private static let digits = Array("0123456789abcdef".utf8)

    private static func hexadecimal(_ digest: some Sequence<UInt8>) -> String {
        var text: [UInt8] = []
        for byte in digest {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
#endif

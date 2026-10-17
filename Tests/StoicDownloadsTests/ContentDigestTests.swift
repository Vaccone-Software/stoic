#if STOIC_CRYPTO
import Foundation
import StoicDownloads
import StoicTesting
import Testing

@Suite("Content digests")
struct ContentDigestTests {
    // Published test vectors, so the code under test is not checked against itself.
    static let abc = Array("abc".utf8)

    @Test func sha256MatchesThePublishedVectors() {
        #expect(ContentDigest(algorithm: .sha256, of: []).hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ContentDigest(algorithm: .sha256, of: Self.abc).hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func gitBlobSHA1MatchesGitsObjectIds() {
        // `git hash-object` of an empty file, and of "hello\n".
        #expect(ContentDigest(algorithm: .gitBlobSHA1, of: []).hex == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        #expect(ContentDigest(algorithm: .gitBlobSHA1, of: Array("hello\n".utf8)).hex == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test func aDigestKeepsItsHexInLowercase() throws {
        let digest = try ContentDigest.sha256("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        #expect(digest.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(digest == (try .sha256(digest.hex)))
        #expect("\(digest)" == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test(.failureMode("design/23", "a digest is not hexadecimal or the wrong length"))
    func aDigestThatIsNotAHashIsRefusedNotIgnored() {
        #expect(throws: ContentDigest.Invalid.wrongLength(algorithm: .sha256, expected: 64, actual: 40)) {
            try ContentDigest.sha256("ce013625030ba8dba906f756967f9e9ca394464a")
        }
        #expect(throws: ContentDigest.Invalid.wrongLength(algorithm: .gitBlobSHA1, expected: 40, actual: 0)) {
            try ContentDigest.gitBlobSHA1("")
        }
        #expect(throws: ContentDigest.Invalid.notHexadecimal(algorithm: .gitBlobSHA1)) {
            try ContentDigest.gitBlobSHA1("zz013625030ba8dba906f756967f9e9ca394464a")
        }
        #expect(throws: ContentDigest.Invalid.notHexadecimal(algorithm: .sha256)) {
            try ContentDigest.sha256(String(repeating: "g", count: 64))
        }
    }

    @Test func algorithmsAreNamedAndNothingElseIsConstructible() {
        #expect(ContentDigest.Algorithm(rawValue: "sha256") == .sha256)
        #expect(ContentDigest.Algorithm(rawValue: "git-blob-sha1") == .gitBlobSHA1)
        #expect(ContentDigest.Algorithm(rawValue: "md5") == nil)
        #expect(ContentDigest.Algorithm.sha256.hexLength == 64)
        #expect(ContentDigest.Algorithm.gitBlobSHA1.hexLength == 40)
    }
}
#endif

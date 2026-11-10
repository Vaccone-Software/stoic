public import Stoic

/// Principal evidence for tests: "a test said so" (design/28).
///
/// Code that names its real evidence kind (`Verified<Someone, Session>`)
/// refuses it, so a test proof can only reach code that accepts any
/// principal evidence, and StoicTesting is never linked into an app.
public struct TestPrincipal: PrincipalEvidence, Hashable {
    /// Constructible only in this file.
    public struct Mint: Sendable {
        fileprivate init() {}
    }

    public static let proves = "a test said so"

    fileprivate init() {}
}

private let testMinter = Minter<TestPrincipal>(TestPrincipal.Mint())

/// Proofs minted on request, for tests of code that needs one.
public enum TestProof {
    /// `principal`, authenticated by a test.
    ///
    ///     try await store.apply(.approve, to: id, by: TestProof.principal(Staff.coordinator), because: "test")
    public static func principal<P>(_ principal: P) -> Verified<P, TestPrincipal> {
        testMinter.verified(principal, TestPrincipal())
    }
}

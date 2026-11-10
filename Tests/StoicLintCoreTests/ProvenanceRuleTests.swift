#if STOIC_LINT
import StoicLintCore
import StoicTesting
import Testing

@Suite("unverified-claim")
struct UnverifiedClaimTests {
    @Test(.failureMode("design/28", "a claim's value is read outside a verifier"))
    func takingAClaimAsAFactIsRefusedWithTheFix() throws {
        let source = """
            func age(of guest: Guest) -> Int {
                years(since: guest.dateOfBirth.unverified())
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule == .unverifiedClaim)
        #expect(found.line == 2)
        #expect(found.column == 36, "at the method's name")
        #expect(found.message.contains("without a verifier"))
        #expect(found.fixIt?.contains("stoic:allow(unverified-claim)") == true)
    }

    @Test func flagsOptionalAndChainedReceivers() {
        let source = """
            let a = claim?.unverified()
            let b = request.body.map(decode).unverified()
            let c = try await load().unverified()
            """
        #expect(rules(in: source) == ["unverified-claim", "unverified-claim", "unverified-claim"])
    }

    @Test func aReasonSilencesIt() {
        let source = """
            // stoic:allow(unverified-claim): shown back to the person who typed it
            let shown = claim.unverified()
            """
        #expect(rules(in: source).isEmpty)
    }

    @Test func testCodeIsExempt() {
        let source = "let value = claim.unverified()\n"
        #expect(rules(in: source, path: "/work/Tests/AppTests/CheckInTests.swift").isEmpty)
    }

    @Test func otherShapesAreNotTheEscape() {
        let source = """
            let a = claim.unverified(reason: "shown")
            let b = unverified()
            let c = claim.unverifiedCount()
            let d = minter.read(claim)
            """
        #expect(rules(in: source).isEmpty)
    }

    @Test func knownFalseNegativeAMethodReference() {
        // design/28, Lint rules: a reference to the method is not a call.
        #expect(rules(in: "let escape = claim.unverified\nlet value = escape()\n").isEmpty)
    }
}

@Suite("evidence-mint-access")
struct EvidenceMintAccessTests {
    @Test(.failureMode("design/28", "an evidence kind's Mint can be made outside its verifier's file"))
    func aMintWithoutAnInitialiserIsRefused() throws {
        let source = """
            struct Session: PrincipalEvidence {
                static let proves = "a live session"
                struct Mint {}
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule == .evidenceMintAccess)
        #expect(found.line == 3)
        #expect(found.column == 12, "at the Mint's name")
        #expect(found.message.contains("implicit one is internal"))
        #expect(found.fixIt?.contains("fileprivate init() {}") == true)
    }

    @Test func anOpenInitialiserIsRefusedAtItsKeyword() throws {
        let source = """
            public struct Signed: ContentEvidence {
                public struct Mint {
                    fileprivate init() {}
                    public init(anyone: Void) {}
                }
            }
            """
        let found = findings(in: source)
        #expect(found.map(\.rule) == [.evidenceMintAccess])
        #expect(found.first?.line == 4)
        #expect(found.first?.column == 16)
        #expect(found.first?.message.contains("is public") == true)
    }

    @Test func everyOtherForgeableShape() {
        let source = """
            struct A: Evidence { typealias Mint = Void }
            struct B: Stoic.Evidence { struct Mint { init() {} } }
            struct C: Evidence { enum Mint { case token } }
            final class D: PrincipalEvidence { final class Mint { package init() {} } }
            extension E: ContentEvidence { struct Mint {} }
            struct F: Hashable & PrincipalEvidence { struct Mint { internal init() {} } }
            """
        #expect(rules(in: source) == Array(repeating: "evidence-mint-access", count: 6))
    }

    @Test func aPrivateMintIsFine() {
        let source = """
            struct Session: PrincipalEvidence {
                struct Mint { fileprivate init() {} }
            }
            struct Link: PrincipalEvidence {
                struct Mint { private init() {} }
            }
            struct Never: Evidence {
                enum Mint {}
            }
            struct NotEvidence: Hashable {
                struct Mint {}
            }
            """
        #expect(rules(in: source).isEmpty)
    }

    @Test func knownFalseNegativesConformanceAndMintElsewhere() {
        // design/28, Lint rules: the conformance in another extension, and a
        // Mint declared outside the type, are not seen.
        let source = """
            struct Session { struct Mint {} }
            extension Session: PrincipalEvidence {}
            struct Link: PrincipalEvidence { typealias Mint = LinkMint }
            """
        #expect(rules(in: source) == ["evidence-mint-access"], "only the typealias, which is a shape the rule names")
        #expect(rules(in: "struct Session { struct Mint {} }\nextension Session: PrincipalEvidence {}\n").isEmpty)
    }
}

@Suite("derivation-ignores-input")
struct DerivationIgnoresInputTests {
    @Test(.failureMode("design/28", "a derivation ignores its input"))
    func ignoringTheInputIsRefusedAtTheUnderscore() throws {
        let source = """
            func forge(_ request: Verified<AttestedRequest, AppAttested>) throws -> Verified<Order, AppAttested> {
                try request.deriving { _ in Order(total: 0) }
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule == .derivationIgnoresInput)
        #expect(found.line == 2)
        #expect(found.column == 28)
        #expect(found.message.contains("ignores its input"))
    }

    @Test func aClosureThatNamesNothingAndUsesNoShorthandIsRefusedAtItsBrace() throws {
        let source = "let order = try request.deriving { Order(total: 0) }\n"
        let found = try #require(findings(in: source).first)
        #expect(found.rule == .derivationIgnoresInput)
        #expect(found.line == 1)
        #expect(found.column == 34)
    }

    @Test func typedWildcardsAndArgumentClosuresToo() {
        let source = """
            let a = try request.deriving { (_: AttestedRequest) in forged }
            let b = try request.deriving({ _ in forged })
            """
        #expect(rules(in: source) == ["derivation-ignores-input", "derivation-ignores-input"])
    }

    @Test func computingFromTheInputIsFine() {
        let source = """
            let a = try request.deriving { try CheckInBody.schema.decode($0.body) }
            let b = try request.deriving { request in request.body.count }
            let c = try request.deriving { (_ request: AttestedRequest) in request.path }
            let d = items.deriving(5)
            """
        #expect(rules(in: source).isEmpty)
    }

    @Test func knownFalseNegativesReadingThenDiscardingAndANestedShorthand() {
        // design/28, Lint rules: a closure that reads its parameter and
        // returns something else, and a `$0` that is a nested closure's.
        let source = """
            let a = try request.deriving { request in _ = request; return forged }
            let b = try request.deriving { [1, 2].map { $0 * 2 } }
            """
        #expect(rules(in: source).isEmpty)
    }
}
#endif

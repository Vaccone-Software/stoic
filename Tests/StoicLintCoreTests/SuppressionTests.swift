#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("Suppression comments")
struct SuppressionTests {
    @Test func aReasonlessAllowIsAFindingAndSuppressesNothing() {
        let source = """
            // stoic:allow(task-detached)
            let x = 1
            """
        let found = findings(in: source)
        #expect(found.map(\.rule) == [.allowWithoutReason])
        #expect(found.first?.line == 1)
        #expect(found.first?.column == 1)
    }

    @Test func anEmptyReasonCountsAsNone() {
        #expect(rules(in: "let x = 1 // stoic:allow(force-try):   \n") == ["allow-without-reason"])
        #expect(rules(in: "let x = 1 // stoic:allow(force-try)\n") == ["allow-without-reason"])
    }

    @Test func aReasonIsAccepted() {
        #expect(rules(in: "let x = 1 // stoic:allow(force-try): the literal is validated at build time\n") == [])
    }

    @Test func documentationThatMentionsTheSyntaxIsLeftAlone() {
        let source = """
            /// Write `// stoic:allow(force-try): reason` to justify it.
            // See stoic:allow(force-try) in the docs.
            let x = 1
            """
        #expect(rules(in: source) == [])
    }

    @Test func aStringContainingTheMarkerIsNotAComment() {
        #expect(rules(in: "let s = \"// stoic:allow(x)\"\n") == [])
    }

    @Test func aMalformedAllowIsReported() {
        #expect(rules(in: "// stoic:allow(\nlet x = 1\n") == ["allow-without-reason"])
    }

    @Test func allowWithoutReasonCannotBeAllowed() {
        let source = """
            // stoic:allow(allow-without-reason): trust me
            // stoic:allow(task-detached)
            let x = 1
            """
        #expect(rules(in: source) == ["allow-without-reason"])
    }
}
#endif

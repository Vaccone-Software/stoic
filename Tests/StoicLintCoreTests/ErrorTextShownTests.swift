#if STOIC_LINT
import StoicLintCore
import StoicTesting
import Testing

@Suite("error-text-shown")
struct ErrorTextShownTests {
    private let rule = "error-text-shown"

    @Test // design/31: "code shows error.localizedDescription"
    func showingAnErrorsTextIsRefusedWithTheFix() throws {
        let source = """
            func save() {
                do { try store.save() } catch {
                    alert = Alert(title: "Couldn't save", message: error.localizedDescription)
                }
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule.shortName == rule)
        #expect(found.line == 3)
        #expect(found.column == 62, "at the member read")
        #expect(found.message.contains("raw text"))
        #expect(found.fixIt?.contains("`error.presented()`") == true)
    }

    @Test func flagsEveryReadOfIt() {
        let source = """
            let a = error.localizedDescription
            let b = (error as NSError).localizedDescription
            let c = failure?.localizedDescription ?? ""
            Text(error.localizedDescription)
            let d = "Failed: \\(error.localizedDescription)"
            """
        let found = findings(in: source)
        #expect(found.map(\.rule.shortName) == Array(repeating: rule, count: 5))
        #expect(found.map(\.line) == [1, 2, 3, 4, 5])
        #expect(found.map(\.column) == [15, 28, 18, 12, 26])
    }

    @Test func testCodeAndStoicFoundationAreExempt() {
        let source = "let text = error.localizedDescription\n"
        #expect(rules(in: source, path: "/work/Tests/AppTests/SaveTests.swift").isEmpty)
        #expect(rules(in: source, path: "/work/Sources/App/SaveTests.swift").isEmpty)
        #expect(rules(in: source, path: "/work/Sources/StoicFoundation/Presentation.swift").isEmpty)
        #expect(rules(in: source, path: "/work/Sources/App/Save.swift") == [rule])
    }

    @Test func otherMembersAndDeclarationsAreFine() {
        let source = """
            let a = error.presented()
            let b = wording.description
            let c = localizedDescription
            var localizedDescription: String { "mine" }
            let d = error.localizedFailureReason
            let e = model.localizedDescription(of: value)
            """
        #expect(rules(in: source).isEmpty)
    }

    /// The rule is syntactic; these reach a person and are not seen.
    @Test func knownFalseNegativesAreNotFlagged() {
        let source = """
            Text("\\(error)")
            let shown = String(describing: error)
            """
        #expect(rules(in: source).isEmpty)
    }

    @Test func aJustificationCoversIt() {
        let source = """
            // stoic:allow(error-text-shown): a developer tool's log window, never shown to a customer
            log.append(error.localizedDescription)
            """
        #expect(rules(in: source).isEmpty)
    }
}
#endif

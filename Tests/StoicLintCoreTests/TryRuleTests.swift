#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("discarded-try")
struct DiscardedTryTests {
    private let discarded = "discarded-try"

    @Test func aStatementLevelOptionalTryIsFlagged() {
        let source = """
            func f() {
                try? save()
                try? await sync()
                await try? sync()
            }
            """
        #expect(rules(in: source) == Array(repeating: discarded, count: 3))
    }

    @Test func testCodeIsExempt() {
        let source = """
            func f() async {
                _ = try? await task.value
            }
            """
        #expect(rules(in: source, path: "/work/Tests/AppTests/FTests.swift").isEmpty)
    }

    @Test func assigningToTheWildcardIsFlagged() {
        let source = """
            func f() {
                _ = try? save()
                _ = try? await sync()
            }
            """
        #expect(rules(in: source) == [discarded, discarded])
    }

    @Test func reportsAtTheTry() throws {
        let found = findings(in: "func f() {\n    try? save()\n}\n")
        let first = try #require(found.first)
        #expect(first.line == 2)
        #expect(first.column == 5)
        #expect(first.fixIt?.contains("withContext") == true)
    }

    @Test func aUsedResultIsNotFlagged() {
        let source = """
            func f() -> Int? {
                let x = try? parse()
                var y = try? parse()
                y = try? parse()
                if let z = try? parse() { use(z) }
                guard let w = try? parse() else { return nil }
                use(try? parse())
                let v = (try? parse()) ?? 0
                let u = try? parse() ?? 0
                return try? parse()
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aSingleExpressionBodyReturnsItsValue() {
        let source = """
            func f() -> Int? { try? parse() }
            var g: Int? { try? parse() }
            let h = { try? parse() }
            let i = items.compactMap { try? parse($0) }
            let j: Int? = if c { try? a() } else { try? b() }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aStatementLevelTaskBodyIsDiscarded() {
        let source = """
            func f() {
                Task { try? await sync() }
                Task.detached { try? await sync() }
            }
            """
        #expect(rules(in: source).filter { $0 == discarded }.count == 2)
    }

    @Test func aStoredTaskBodyIsNotAssumedDiscarded() {
        #expect(rules(in: "let t = Task { try? await sync() }\n") == [])
    }

    @Test func inABlockWithOtherStatementsItIsDiscarded() {
        let source = """
            func f() {
                if cond { try? a() }
                defer { try? cleanup() }
                for _ in 0..<3 { try? tick() }
                items.forEach { item in
                    log(item)
                    try? send(item)
                }
            }
            """
        #expect(rules(in: source) == Array(repeating: discarded, count: 4))
    }

    @Test func aStatementIfInAMultiStatementBodyIsStillDiscarded() {
        let source = """
            func f() {
                log()
                if cond { try? a() } else { try? b() }
            }
            """
        #expect(rules(in: source) == [discarded, discarded])
    }

    @Test func forceTryAndPlainTryAreNotThisRule() {
        let source = """
            func f() throws {
                try save()
                try! save()
            }
            """
        #expect(!rules(in: source).contains(discarded))
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func f() {
                // stoic:allow(discarded-try): best-effort cache warmup; failure is invisible by design
                try? warm()
            }
            """
        #expect(rules(in: source) == [])
    }
}

@Suite("force-try")
struct ForceTryTests {
    @Test func flagsTryBang() {
        let source = """
            func f() {
                let data = try! load()
                try! save()
                let value = try! await fetch()
            }
            """
        #expect(rules(in: source) == ["force-try", "force-try", "force-try"])
    }

    @Test func plainAndOptionalTryAreNotThisRule() {
        let source = """
            func f() throws {
                let a = try load()
                let b = try? load()
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func testTargetsAreExempt() {
        let source = "func f() { try! save() }\n"
        #expect(rules(in: source, path: "/work/Tests/AppTests/Foo.swift") == [])
        #expect(rules(in: source, path: "/work/Sources/App/FooTests.swift") == [])
        #expect(rules(in: source, path: "/work/Sources/App/Foo.swift") == ["force-try"])
        #expect(rules(in: source, path: "/work/Sources/App/Tests.swift") == [])
        #expect(rules(in: source, path: "/work/Sources/Latests/Foo.swift") == ["force-try"])
    }

    @Test func aRegexBuiltFromALiteralIsExempt() {
        let source = """
            let a = try! Regex("[a-z]+")
            let b = try! Regex<Substring>(#"\\d+"#)
            let c = try! NSRegularExpression(pattern: "^a$")
            """
        #expect(rules(in: source) == [])
    }

    @Test func aRegexBuiltFromADynamicStringIsNot() {
        let source = """
            let a = try! Regex(userInput)
            let b = try! Regex("a\\(suffix)")
            let c = try! NSRegularExpression(pattern: pattern)
            """
        #expect(rules(in: source) == ["force-try", "force-try", "force-try"])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            // stoic:allow(force-try): the resource is bundled and validated by a build step
            let data = try! Data(contentsOf: bundled)
            """
        #expect(rules(in: source) == [])
    }
}
#endif

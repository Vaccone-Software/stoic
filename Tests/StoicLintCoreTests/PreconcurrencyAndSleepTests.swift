#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("preconcurrency")
struct PreconcurrencyTests {
    private let rule = "preconcurrency"

    @Test func flagsAnImport() {
        #expect(rules(in: "@preconcurrency import AVFoundation\n") == [rule])
    }

    @Test func flagsAConformanceAndADeclaration() {
        let source = """
            final class Delegate: NSObject, @preconcurrency AVCaptureDelegate {}
            @preconcurrency protocol Legacy {}
            @preconcurrency @MainActor func old() {}
            """
        #expect(rules(in: source) == [rule, rule, rule])
    }

    @Test func reportsAtTheAttribute() throws {
        let found = try #require(findings(in: "import Stoic\n@preconcurrency import AVFoundation\n").first)
        #expect(found.line == 2)
        #expect(found.column == 1)
        #expect(found.fixIt?.contains("stoic:allow(preconcurrency)") == true)
    }

    @Test func otherAttributesAreIgnored() {
        let source = """
            @MainActor final class Model {}
            @Sendable func f() {}
            @available(macOS 27, *) struct S {}
            @_spi(Testing) import Stoic
            """
        #expect(rules(in: source) == [])
    }

    @Test func aMentionInACommentOrStringIsIgnored() {
        let source = """
            // @preconcurrency import Foo
            let text = "@preconcurrency"
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            // stoic:allow(preconcurrency): AVFoundation's delegates predate Sendable; callbacks hop to the actor
            @preconcurrency import AVFoundation
            @preconcurrency import CoreAudio // stoic:allow(preconcurrency): only C structs cross the boundary
            """
        #expect(rules(in: source) == [])
    }

    @Test func testCodeIsNotExempt() {
        #expect(rules(in: "@preconcurrency import Foo\n", path: "/work/Tests/AppTests/FooTests.swift") == [rule])
    }
}

@Suite("bare-task-sleep")
struct BareTaskSleepTests {
    private let rule = "bare-task-sleep"

    @Test func flagsEverySpellingWithoutAClock() {
        let source = """
            func f() async throws {
                try await Task.sleep(for: .seconds(1))
                try await Task.sleep(nanoseconds: 1_000_000)
                try await Task.sleep(until: .now + .seconds(1))
                try await Task<Never, Never>.sleep(for: .seconds(1))
                try? await Task.sleep(for: .milliseconds(5))
            }
            """
        #expect(rules(in: source).filter { $0 == rule }.count == 5)
    }

    @Test func reportsAtTheMemberName() throws {
        let found = try #require(findings(in: "func f() async throws {\n    try await Task.sleep(for: .seconds(1))\n}\n").first)
        #expect(found.rule.shortName == rule)
        #expect(found.line == 2)
        #expect(found.column == 20)
        #expect(found.fixIt?.contains("Ambient.sleep") == true)
    }

    @Test func passingAClockIsFine() {
        let source = """
            func f(clock: some Clock<Duration>) async throws {
                try await Task.sleep(for: .seconds(1), clock: clock)
                try await Task.sleep(until: deadline, tolerance: nil, clock: .continuous)
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func theAmbientAndInjectedClocksAreFine() {
        let source = """
            func f(clock: AnyClock) async throws {
                try await Ambient.sleep(for: .seconds(1))
                try await clock.sleep(for: .seconds(1))
                try await self.clock.sleep(until: deadline, tolerance: nil)
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func otherSleepsAndOtherTasksAreNotThisRule() {
        let source = """
            func f() async {
                let task = Task { }
                task.sleep()
                Thread.sleep(forTimeInterval: 1)
                MyTask.sleep(for: .seconds(1))
            }
            """
        #expect(!rules(in: source).contains(rule))
    }

    @Test func testCodeIsExempt() {
        let source = "func f() async throws { try await Task.sleep(for: .seconds(1)) }\n"
        #expect(rules(in: source, path: "/work/Tests/AppTests/WaitTests.swift") == [])
        #expect(rules(in: source, path: "/work/Sources/App/WaitTests.swift") == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func f() async throws {
                // stoic:allow(bare-task-sleep): paces a demo for people watching, not logic
                try await Task.sleep(for: .seconds(1))
            }
            """
        #expect(rules(in: source) == [])
    }
}
#endif

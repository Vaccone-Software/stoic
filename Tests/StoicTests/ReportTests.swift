@testable import Stoic
import StoicTesting
import Testing

@Suite("Report")
struct ReportTests {
    enum FileError: Error, Equatable { case missing }
    struct Bug: Defect {}

    @Test func contextFramesStackInnermostFirst() async {
        do {
            try await withContext("loading settings") {
                try await withContext("reading settings.json") {
                    await Task.yield()
                    throw FileError.missing
                }
            }
            Issue.record("expected an error")
        } catch let report as Report {
            #expect(report.frames.map(\.message) == ["reading settings.json", "loading settings"])
            #expect(report.first(FileError.self) == .missing)
            #expect(report.description.hasPrefix("loading settings"))
            #expect(report.description.contains("╰─ reading settings.json"))
            #expect(report.description.contains("FileError: missing"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func cancellationPassesThroughUnwrapped() async {
        await #expect(throws: CancellationError.self) {
            try await withContext("doing work") {
                await Task.yield()
                throw CancellationError()
            }
        }
        #expect(throws: CancellationError.self) {
            try withContext("doing synchronous work") { throw CancellationError() }
        }
        #expect(CancellationError().context("anything") is CancellationError)
    }

    // MARK: Typed throws

    static func read() async throws(FileError) -> Int { throw .missing }

    static func load() async throws(Report) -> Int {
        try await withContext("loading") { () async throws(FileError) -> Int in
            try await read()
        }
    }

    @Test func withContextWorksInsideATypedThrowsFunction() async {
        do {
            _ = try await Self.load()
            Issue.record("expected an error")
        } catch {
            // `error` is a Report: the function's declared error type.
            #expect(error.frames.map(\.message) == ["loading"])
            #expect(error.first(FileError.self) == .missing)
        }
    }

    @Test func theSynchronousTypedFormThrowsAReport() {
        func load() throws(Report) -> Int {
            try withContext("parsing") { () throws(FileError) -> Int in throw .missing }
        }
        #expect(throws: Report.self) { try load() }
        do { _ = try load() } catch { #expect(error.first(FileError.self) == .missing) }
    }

    @Test func aTypedWithContextCarriesCancellationAsTheRoot() async {
        func run() async throws(Report) {
            try await withContext("working") { () async throws(CancellationError) in throw CancellationError() }
        }
        do {
            try await run()
            Issue.record("expected an error")
        } catch {
            #expect(error.isCancellation)
            #expect(error.first(CancellationError.self) != nil)
        }
        #expect(!Report(FileError.missing).isCancellation)
    }

    @Test func reportingAReportAddsAFrameInsteadOfNesting() {
        let first = FileError.missing.context("inner")
        let second = first.context("outer")
        let report = Report(second)
        #expect(report.frames.count == 2)
        #expect(report.root is FileError)
    }

    @Test func theRootIsFoundThroughPolicyWrappers() {
        let wrapped: any Error = PolicyError<Report>.failed(Report(FileError.missing).adding(.init("fetching")))
        let report = Report(wrapped.context("syncing"))
        #expect(report.contains(FileError.self))
    }

    @Test func retryClassificationSeesThroughReports() async {
        let attempts = SendableBox(0)
        await #expect(throws: Report.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(5)) { _ in
                    attempts.mutate { $0 += 1 }
                    throw Bug().context("a bug, reported")
                }
            }
        }
        #expect(attempts.value == 1, "a defect inside a report still stops retrying")
    }

    @Test func suppressedErrorsAreKept() {
        let report = Report(FileError.missing).suppressing(Bug())
        #expect(report.suppressed.count == 1)
        #expect(report.debugDescription.contains("suppressed"))
        #expect(!report.description.contains("suppressed"))
    }

    @Test func descriptionRedactsPrivateMetadataAndDebugDescriptionDoesNot() {
        let report = Report(FileError.missing.context("loading", metadata: [
            .init("token", .string("hunter2"), privacy: .private),
            .init("bytes", .int(42)),
        ]))
        #expect(report.description.contains("token=<private>"))
        #expect(report.description.contains("bytes=42"))
        #expect(!report.description.contains("hunter2"))
        #expect(!"\(report.frames[0])".contains("hunter2"))
        #expect(report.debugDescription.contains("token=hunter2"))
        #expect(report.frames[0].debugDescription.contains("token=hunter2"))
        // A string field is private unless said otherwise.
        let defaulted = Report(FileError.missing).adding(.init("opening", metadata: [.init("path", .string("/Users/ada/secret"))]))
        #expect(!defaulted.description.contains("/Users/ada"))
        #expect(defaulted.debugDescription.contains("/Users/ada/secret"))
    }

    @Test func framesCarryMetadataAndLocation() {
        let report = Report(FileError.missing.context("reading", metadata: [.init("bytes", .int(42))]))
        #expect(report.frames[0].metadata.first?.key == "bytes")
        #expect(report.frames[0].fileID.hasSuffix("ReportTests.swift"))
    }
}

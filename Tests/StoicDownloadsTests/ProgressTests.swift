#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicTesting
import Synchronization
import Testing

/// What the callback of a download is told, and when: on the virtual clock.
@Suite("Download progress", .timeLimit(.minutes(1)))
struct ProgressTests {
    typealias Report = (at: Duration, progress: DownloadProgress)

    /// The reports a download made, with the virtual time of each.
    final class Reports: Sendable {
        private let state = Mutex<[Report]>([])

        func callback(on clock: TestClock) -> @Sendable (DownloadProgress) -> Void {
            { progress in
                let now = clock.now.offset
                self.state.withLock { $0.append((now, progress)) }
            }
        }

        var all: [Report] { state.withLock { $0 } }
    }

    @Test(.failureMode("design/23", "progress is reported"))
    func progressIsThrottledOnTheAmbientClockAndEveryPhaseIsReported() async throws {
        try await withHarness(policy: .testing(progressInterval: .milliseconds(500))) { h in
            let data = fileBytes(10_000)
            // Twenty chunks, 100 ms apart: two seconds of virtual time.
            h.transport.on(.get("/model.bin"), respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500, chunkDelay: .milliseconds(100))])
            let reports = Reports()
            let task = h.start(try download(data), progress: reports.callback(on: h.clock))
            for _ in 0..<20 { await h.elapse(.milliseconds(100)) }
            _ = try await task.value

            let all = reports.all
            let phases = all.map(\.progress.phase)
            #expect(phases.first == .waiting)
            #expect(phases.last == .placing)
            #expect(phases.filter { $0 == .waiting }.count == 1, "waiting again for the same request is not news")
            #expect(phases.filter { $0 == .verifying }.count == 1)
            let downloading = all.filter { $0.progress.phase == .downloading }
            #expect(downloading.count >= 4 && downloading.count <= 6, "two seconds at one report per half second, and the first: \(downloading.count)")
            for (earlier, later) in zip(downloading, downloading.dropFirst()) {
                #expect(later.at - earlier.at >= .milliseconds(500), "reports are at least the interval apart")
            }
            let bytes = all.map(\.progress.bytesDone)
            #expect(bytes == bytes.sorted())
            #expect(all.allSatisfy { $0.progress.fileTotalBytes == 10_000 && $0.progress.totalBytes == 10_000 })
            #expect(all.allSatisfy { $0.progress.fileIndex == 0 && $0.progress.fileCount == 1 })
            #expect(downloading.last.map { $0.progress.fraction ?? 0 }.map { $0 > 0.5 } == true)
        }
    }

    @Test(.failureMode("design/23", "a single download has no expected size and the server says its length"))
    func aSingleDownloadWithoutAnExpectedSizeTakesItsTotalFromTheServer() async throws {
        try await withHarness(policy: .testing(progressInterval: .zero)) { h in
            let data = fileBytes(10_000)
            h.transport.on(.get("/model.bin"), respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let reports = Reports()
            _ = try await h.downloader.download(try download(data, expectedSize: false), progress: reports.callback(on: h.clock))
            let all = reports.all.map(\.progress)
            #expect(all.first?.phase == .waiting)
            #expect(all.first?.totalBytes == nil, "before the head, nothing says how long it is")
            let known = all.filter { $0.fileTotalBytes != nil }
            #expect(known.count > 2)
            #expect(known.allSatisfy { $0.totalBytes == 10_000 && $0.fileTotalBytes == 10_000 })
            #expect(all.last?.fraction == 1)
            #expect(all.filter { $0.phase == .downloading }.compactMap(\.fraction).count == all.filter { $0.phase == .downloading }.count)
        }
    }

    @Test func aHugeIntervalStillReportsEveryChangeOfPhase() async throws {
        try await withHarness(policy: .testing(progressInterval: .seconds(3600))) { h in
            let data = fileBytes(10_000)
            h.transport.on(.get("/model.bin"), respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 500)])
            let reports = Reports()
            _ = try await h.downloader.download(try download(data), progress: reports.callback(on: h.clock))
            #expect(reports.all.map(\.progress.phase) == [.waiting, .downloading, .verifying, .placing])
        }
    }

    @Test func aResumeReportsItsPrefixAsVerifyingThenDownloadsFromTheOffset() async throws {
        try await withHarness(policy: .testing(progressInterval: .zero)) { h in
            let data = fileBytes(10_000)
            try await ResumeTests.leavePartial(h, try download(data), server: Resource(data, etag: "\"v1\""), cut: 4_000)
            let reports = Reports()
            _ = try await h.downloader.download(try download(data), progress: reports.callback(on: h.clock))
            let all = reports.all
            let phases = all.map(\.progress.phase)
            let firstDownloading = try #require(phases.firstIndex(of: .downloading))
            #expect(all[firstDownloading].progress.fileBytes > 4_000, "the bytes of the earlier run count")
            let hashing = all[..<firstDownloading].filter { $0.progress.phase == .verifying }
            #expect(!hashing.isEmpty, "the prefix is read and hashed before the request")
            #expect(hashing.last?.progress.fileBytes == 4_000)
        }
    }

    @Test func aWaitIsReportedAsWaiting() async throws {
        try await withHarness { h in
            let data = fileBytes(1_000)
            h.transport.on(.get("/model.bin"), respond: [.status(503), .serving(Resource(data))])
            let reports = Reports()
            let task = h.start(try download(data), progress: reports.callback(on: h.clock))
            await h.waitOutBackoff(.seconds(10))
            _ = try await task.value
            #expect(reports.all.map(\.progress.phase).contains(.waiting))
            #expect(reports.all.first { $0.progress.phase == .downloading } != nil)
        }
    }

    @Test func fractionIsNilWithoutATotalAndOneForAnEmptyFile() {
        var progress = DownloadProgress(phase: .downloading, fileIndex: 0, fileCount: 1, fileBytes: 10, fileTotalBytes: nil, bytesDone: 10, totalBytes: nil)
        #expect(progress.fraction == nil)
        progress.totalBytes = 0
        #expect(progress.fraction == 1)
        progress.totalBytes = 40
        #expect(progress.fraction == 0.25)
    }
}
#endif

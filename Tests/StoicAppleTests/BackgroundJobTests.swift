import Foundation
import Stoic
import StoicApple
import StoicTesting
import Testing

struct WorkFailed: Error {}

@Suite("Background jobs")
struct BackgroundJobTests {
    static let id = "com.example.sync"
    static let epoch = Date(timeIntervalSince1970: 1_000)

    static func job(
        _ scheduler: FakeBackgroundScheduler,
        budget: Duration? = nil,
        work: @escaping @Sendable () async throws -> Void
    ) -> BackgroundJob {
        BackgroundJob(
            identifier: id, every: .seconds(900), budget: budget, scheduler: scheduler,
            now: { epoch }, work: work)
    }

    @Test(.failureMode("design/21", "the work returns"))
    func aJobThatReturnsCompletesOnceAsSuccessAndSchedulesFirst() async {
        let scheduler = FakeBackgroundScheduler()
        let submittedBeforeWork = SendableBox(-1)
        let job = Self.job(scheduler) { submittedBeforeWork.mutate { $0 = scheduler.requests.count } }
        let task = FakeBackgroundTask(identifier: Self.id)
        let report = await job.run(task)
        #expect(task.completions == [true])
        #expect(report.reportedSuccess && !report.expired)
        #expect(submittedBeforeWork.value == 1)
        #expect(scheduler.requests == [
            BackgroundTaskRequest(identifier: Self.id, kind: .appRefresh, earliestBeginDate: Self.epoch.addingTimeInterval(900))
        ])
    }

    @Test(.failureMode("design/21", "the work throws"))
    func aJobThatThrowsCompletesOnceAsFailure() async {
        let scheduler = FakeBackgroundScheduler()
        let task = FakeBackgroundTask(identifier: Self.id)
        let report = await Self.job(scheduler) { throw WorkFailed() }.run(task)
        #expect(task.completions == [false])
        #expect(!report.reportedSuccess)
        guard case .failure(let error) = report.work, error is WorkFailed else {
            Issue.record("expected the work's error in the report")
            return
        }
        #expect(scheduler.requests.count == 1)
    }

    @Test(.failureMode("design/21", "the system expires the task"))
    func expiryCancelsTheWorkAndCompletesAtOnce() async {
        let scheduler = FakeBackgroundScheduler()
        let started = Gate()
        let cause = SendableBox<CancellationCause?>(nil)
        let job = Self.job(scheduler) {
            started.open()
            do { try await Task.sleep(for: .seconds(3600)) } catch {
                cause.mutate { $0 = CancellationCause.current }
                throw error
            }
        }
        let task = FakeBackgroundTask(identifier: Self.id)
        let run = Task { await job.run(task) }
        await started.wait()
        #expect(task.hasExpirationHandler)
        task.expire()
        #expect(task.completions == [false])   // at once, before the work has unwound
        let report = await run.value
        #expect(cause.value == .systemExpiring)
        #expect(report.expired && !report.reportedSuccess)
        #expect(task.completions == [false])
    }

    @Test(.failureMode("design/21", "the work ends after the system expired the task"))
    func lateWorkDoesNotCompleteTwice() async {
        let scheduler = FakeBackgroundScheduler()
        let started = Gate()
        let release = Gate()
        let job = Self.job(scheduler) {
            started.open()
            await release.wait()   // ignores cancellation, then returns normally
        }
        let task = FakeBackgroundTask(identifier: Self.id)
        let run = Task { await job.run(task) }
        await started.wait()
        task.expire()
        release.open()
        let report = await run.value
        #expect(task.completions == [false])
        #expect(report.expired && !report.reportedSuccess)
        if case .failure = report.work { Issue.record("the work returned, so its result is success") }
    }

    @Test(.failureMode("design/21", "the system expires the task before the work starts"))
    func aTaskAlreadyOutOfTimeNeverRunsTheWork() async {
        let scheduler = FakeBackgroundScheduler()
        let ran = SendableBox(false)
        let job = Self.job(scheduler) { ran.mutate { $0 = true } }
        let task = FakeBackgroundTask(identifier: Self.id, expiringImmediately: true)
        let report = await job.run(task)
        #expect(!ran.value)
        #expect(task.completions == [false])
        #expect(report.expired)
    }

    @Test(.failureMode("design/21", "the budget runs out before the system expires the task"))
    func theBudgetCancelsTheWorkWithTheDeadlineCause() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let scheduler = FakeBackgroundScheduler()
            let cause = SendableBox<CancellationCause?>(nil)
            let job = Self.job(scheduler, budget: .seconds(20)) {
                do { try await clock.sleep(for: .seconds(3600)) } catch {
                    cause.mutate { $0 = CancellationCause.current }
                    throw error
                }
            }
            let task = FakeBackgroundTask(identifier: Self.id)
            let run = Task { await job.run(task) }
            await clock.waitForSleepers(count: 2)   // the work, and its budget
            await clock.advance(by: .seconds(20))
            let report = await run.value
            #expect(cause.value == .deadline)
            #expect(task.completions == [false])
            #expect(!report.expired)
        }
    }

    @Test(.failureMode("design/21", "the next request cannot be submitted"))
    func aRefusedRequestDoesNotStopTheWork() async {
        let scheduler = FakeBackgroundScheduler()
        scheduler.submitFailure = .tooManyPendingRequests
        let ran = SendableBox(false)
        let task = FakeBackgroundTask(identifier: Self.id)
        let report = await Self.job(scheduler) { ran.mutate { $0 = true } }.run(task)
        #expect(ran.value)
        #expect(task.completions == [true])
        if case .failure(let error) = report.reschedule {
            #expect(error == .tooManyPendingRequests)
        } else {
            Issue.record("expected the refusal in the report")
        }
        #expect(scheduler.requests.isEmpty)
    }

    @Test(.failureMode("design/21", "the identifier is registered twice"))
    func registeringTwiceThrows() throws {
        let scheduler = FakeBackgroundScheduler()
        let job = Self.job(scheduler) {}
        try job.register()
        #expect(throws: BackgroundTaskError.alreadyRegistered) { try job.register() }
        #expect(scheduler.registeredIdentifiers == [Self.id])
    }

    @Test(.failureMode("design/21", "the system refuses the registration"))
    func aRefusedRegistrationMayBeTriedAgain() throws {
        let scheduler = FakeBackgroundScheduler()
        scheduler.acceptsRegistration = false
        let job = Self.job(scheduler) {}
        #expect(throws: BackgroundTaskError.registrationRejected) { try job.register() }
        scheduler.acceptsRegistration = true
        try job.register()
        #expect(scheduler.registeredIdentifiers == [Self.id])
    }

    @Test(.failureMode("design/21", "the system expires the task before the launch handler returns"))
    func theExpirationHandlerIsInstalledBeforeLaunchReturns() async throws {
        // `SystemBackgroundTaskScheduler` is compiled out on macOS, and
        // wherever BackgroundTasks is absent. `launch` is the synchronous
        // hand-off the scheduler makes, so this runs on every platform.
        let scheduler = FakeBackgroundScheduler()
        let ran = SendableBox(false)
        let (reports, continuation) = AsyncStream.makeStream(of: BackgroundRunReport.self)
        let job = BackgroundJob(
            identifier: Self.id, every: .seconds(60), scheduler: scheduler, now: { Self.epoch },
            onReport: { continuation.yield($0) }
        ) { ran.mutate { $0 = true } }
        try job.register()
        let task = try #require(scheduler.launch(Self.id, expiringImmediately: true))
        #expect(task.expirationHandlerInstalledBeforeLaunchReturned)
        #expect(task.completionsBeforeLaunchReturned == [false])
        let report = await reports.first { _ in true }
        #expect(!ran.value)
        #expect(task.completions == [false])
        #expect(report?.expired == true)
        #expect(report?.reportedSuccess == false)
    }

    @Test func theLaunchHandlerRunsTheJob() async throws {
        let scheduler = FakeBackgroundScheduler()
        let (reports, continuation) = AsyncStream.makeStream(of: BackgroundRunReport.self)
        let job = BackgroundJob(
            identifier: Self.id, every: .seconds(60), scheduler: scheduler, now: { Self.epoch },
            onReport: { continuation.yield($0) }, work: {})
        try job.register()
        let task = try #require(scheduler.launch(Self.id))
        let report = await reports.first { _ in true }
        #expect(report?.reportedSuccess == true)
        #expect(task.completions == [true])
    }

    @Test func drainingAnOutboxIsAProcessingJobThatRunsTheDrain() async {
        let scheduler = FakeBackgroundScheduler()
        let drained = SendableBox(0)
        let job = BackgroundJob.drainingOutbox(
            identifier: Self.id, every: .seconds(600), scheduler: scheduler, now: { Self.epoch }
        ) { drained.mutate { $0 += 1 } }
        let task = FakeBackgroundTask(identifier: Self.id)
        await job.run(task)
        #expect(drained.value == 1)
        #expect(scheduler.requests.first?.kind == .processing(requiresNetworkConnectivity: true, requiresExternalPower: false))
    }
}

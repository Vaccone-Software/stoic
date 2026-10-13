#if canImport(BackgroundTasks) && !os(macOS) && !os(watchOS)
internal import BackgroundTasks
internal import Foundation

/// The real `BGTaskScheduler`, behind ``BackgroundTaskScheduling``.
///
/// Available where BackgroundTasks is (iOS, tvOS, visionOS); the protocol and
/// ``BackgroundJob`` build everywhere. Registration must happen before the
/// app finishes launching, and each identifier must be listed under
/// `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
public struct SystemBackgroundTaskScheduler: BackgroundTaskScheduling {
    public init() {}

    public func register(identifier: String, launch: @escaping @Sendable (any BackgroundTaskHandle) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            launch(SystemBackgroundTask(task))
        }
    }

    public func submit(_ request: BackgroundTaskRequest) async throws(BackgroundTaskError) {
        let system: BGTaskRequest
        switch request.kind {
        case .appRefresh:
            system = BGAppRefreshTaskRequest(identifier: request.identifier)
        case .processing(let network, let power):
            let processing = BGProcessingTaskRequest(identifier: request.identifier)
            processing.requiresNetworkConnectivity = network
            processing.requiresExternalPower = power
            system = processing
        }
        system.earliestBeginDate = request.earliestBeginDate
        do {
            try await BGTaskScheduler.shared.submitTaskRequest(system)
        } catch {
            throw BackgroundTaskError(error)
        }
    }
}

extension BackgroundTaskError {
    init(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.domain == BGTaskScheduler.errorDomain, let code = BGTaskScheduler.Error.Code(rawValue: nsError.code) else {
            self = .other(code: nsError.code)
            return
        }
        switch code {
        case .unavailable: self = .unavailable
        case .tooManyPendingTaskRequests: self = .tooManyPendingRequests
        case .notPermitted: self = .notPermitted
        case .immediateRunIneligible: self = .immediateRunIneligible
        @unknown default: self = .other(code: nsError.code)
        }
    }
}

/// A `BGTask`, as a ``BackgroundTaskHandle``.
///
/// `BGTask` is not `Sendable`, but the system documents its expiration
/// handler and completion as callable from any thread, which is all this
/// touches.
private final class SystemBackgroundTask: BackgroundTaskHandle, @unsafe @unchecked Sendable {
    private let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }

    var identifier: String { task.identifier }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
#endif

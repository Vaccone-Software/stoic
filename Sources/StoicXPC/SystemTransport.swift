#if os(macOS)
internal import Darwin
internal import Foundation
internal import XPC

/// The system's transport: one `XPCSession` per run of a bundled service.
struct SystemTransport: XPCTransport {
    let service: String

    func connect(onEnd: @escaping @Sendable () -> Void) throws(XPCConnectFailure) -> any XPCConnection {
        do {
            let session = try XPCSession(xpcService: service, cancellationHandler: { _ in onEnd() })
            return SystemConnection(session)
        } catch {
            throw XPCConnectFailure("no session with \(service): \(error)")
        }
    }

    func terminate(_ run: XPCRun) -> Bool {
        ServiceProcess.kill(run.pid)
    }
}

/// One `XPCSession`.
final class SystemConnection: XPCConnection {
    private let session: XPCSession

    init(_ session: XPCSession) {
        self.session = session
    }

    func send<Message: Encodable & Sendable, Reply: Decodable & Sendable>(
        _ message: Message,
        replyHandler: @escaping @Sendable (Result<Reply, XPCDeliveryFailure>) -> Void
    ) throws(XPCDeliveryFailure) {
        do {
            try session.send(message) { (result: Result<Reply, any Error>) in
                switch result {
                case .success(let reply):
                    replyHandler(.success(reply))
                case .failure(let error as DecodingError):
                    replyHandler(.failure(.undecodable(String(describing: error))))
                case .failure(let error):
                    replyHandler(.failure(.connectionLost(String(describing: error))))
                }
            }
        } catch let error as EncodingError {
            throw .undecodable(String(describing: error))
        } catch {
            throw .connectionLost(String(describing: error))
        }
    }

    func send<Message: Encodable & Sendable>(_ message: Message) throws(XPCDeliveryFailure) {
        do {
            try session.send(message)
        } catch let error as EncodingError {
            throw .undecodable(String(describing: error))
        } catch {
            throw .connectionLost(String(describing: error))
        }
    }

    func cancel() {
        session.cancel(reason: "ended by StoicXPC")
    }

    // Releasing a session that was never cancelled traps the process
    // (design/25, Origin). Cancelling is synchronous and idempotent, so it
    // is safe here, and the one thing deinit must do.
    deinit {
        session.cancel(reason: "released")
    }
}

/// The service's process, as the app may touch it.
enum ServiceProcess {
    /// `SIGKILL` to `pid`, only if it is not this process and its
    /// executable is inside this app's `Contents/XPCServices`: a pid from
    /// a handshake that has since been reused by another process is never
    /// signalled. False if not signalled: not this app's service, or the
    /// app may not (a sandboxed app cannot signal its own service).
    static func kill(_ pid: Int32) -> Bool {
        guard mayKill(pid, executable: executablePath(of: pid), app: Bundle.main.bundleURL, me: getpid()) else { return false }
        return Darwin.kill(pid, SIGKILL) == 0
    }

    /// Whether `pid`, whose executable is at `executable`, may be killed by
    /// the app at `app` running as `me`: a real process (above 1: `0` and
    /// negative pids name process groups, `-1` every process), not the app
    /// itself, and an executable inside the app's `Contents/XPCServices`.
    static func mayKill(_ pid: Int32, executable: String?, app: URL, me: Int32) -> Bool {
        guard pid > 1, pid != me, let executable, !executable.isEmpty else { return false }
        let services = app.resolvingSymlinksInPath().appending(path: "Contents/XPCServices").path + "/"
        let resolved = URL(filePath: executable).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(services)
    }

    /// The path of `pid`'s executable, if this process may know it.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { buffer in
            unsafe proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif

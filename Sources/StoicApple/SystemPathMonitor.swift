#if canImport(Network)
internal import Dispatch
internal import Network

/// The device's real network path, from `NWPathMonitor`.
///
///     let monitor = SystemPathMonitor()
///     let path = try await monitor.waitUntilReachable(until: .after(.seconds(30)))
///
/// Every ``updates()`` call starts its own `NWPathMonitor` on its own queue
/// and cancels it when the stream ends, so a caller that stops listening
/// leaves nothing running. The stream keeps only the newest unread path: the
/// network's state is what matters, not the history of how it got there.
///
/// `NWPath.Status.requiresConnection` (a path that would come up on demand,
/// such as a VPN or a dial-on-demand cellular link) is reported as
/// ``NetworkPath/Status/unsatisfied``: nothing can be sent yet.
public struct SystemPathMonitor: PathMonitor {
    public init() {}

    public func updates() -> AsyncStream<NetworkPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkPath(path))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "stoic.apple.path-monitor", qos: .utility))
        }
    }
}

extension NetworkPath {
    init(_ path: NWPath) {
        self.init(
            status: path.status == .satisfied ? .satisfied : .unsatisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained)
    }
}
#endif

import Darwin
import Foundation
import IntegrationAPI
import Stoic
import StoicXPC
import Synchronization

/// Set by `refuseToExit`: the exit the app asks for then never happens, so
/// the app has to kill the process.
let refusesToExit = Atomic<Bool>(false)

let host = XPCHost(build: Build.id, policy: XPCHostPolicy(watchdogGrace: .seconds(2), exit: { code in
    if code == 0, refusesToExit.load(ordering: .relaxed) {
        while true { sleep(60) }
    }
    _exit(code)
}))
host.handle(IntegrationAPI.pid) { _, _ in getpid() }
host.handle(IntegrationAPI.crash) { _, _ in _exit(3) }
host.handle(IntegrationAPI.block) { seconds, _ in
    sleep(UInt32(min(max(seconds, 0), 30)))
    return XPCEmpty()
}
host.handle(IntegrationAPI.wait) { _, _ in
    do {
        try await Task.sleep(for: .seconds(30))
        return false
    } catch {
        return true
    }
}
host.handle(IntegrationAPI.refuseToExit) { _, _ in
    refusesToExit.store(true, ordering: .relaxed)
    return XPCEmpty()
}
host.handle(IntegrationAPI.blob) { bytes, _ in Data(count: min(max(bytes, 0), 50_000_000)) }
host.run()

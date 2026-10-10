internal import Synchronization

/// Decides what happens at a fault point: the hook a simulation uses to make
/// a primitive's rare paths common (FoundationDB's `BUGGIFY`).
///
/// Stoic's primitives pass named fault points where timing decides which
/// path runs — a semaphore waiter between arriving and queueing, a channel
/// hand-off, a finalizer starting, superseded work about to deliver. In
/// production nothing is installed and a fault point costs one relaxed
/// atomic load. Under a simulation, an installed policy may stall the task
/// there for a few scheduling turns or a stretch of virtual time, so the
/// interleaving that happens once in a million real runs happens in every
/// few simulated ones.
public protocol FaultPolicy: Sendable {
    /// What to do at `site`. Called only while a policy is installed.
    func action(at site: String) -> FaultAction
}

/// What a fault point does.
public enum FaultAction: Sendable, Hashable {
    /// Nothing.
    case proceed
    /// Gives way to other work this many times.
    case yield(Int)
    /// Sleeps this long on the ambient clock.
    case delay(Duration)
}

/// The fault points compiled into Stoic's primitives.
package enum FaultPoint {
    /// How many contexts have a policy installed. While zero, a fault point
    /// is one load: nothing reads the task-local.
    private static let installed = Atomic<Int>(0)

    /// Counts a context that installs a policy; call ``uninstall()`` after.
    package static func install() {
        installed.wrappingAdd(1, ordering: .relaxed)
    }

    package static func uninstall() {
        installed.wrappingSubtract(1, ordering: .relaxed)
    }

    /// A fault point named `site`.
    package static func hit(_ site: String) async {
        guard installed.load(ordering: .relaxed) > 0, let policy = Ambient.current.faultPolicy else { return }
        switch policy.action(at: site) {
        case .proceed:
            return
        case .yield(let count):
            for _ in 0..<max(0, count) { await Task.yield() }
        case .delay(let duration):
            // A fault point never fails the work it is in: a cancelled
            // delay simply ends early.
            do {
                try await Ambient.sleep(for: duration)
            } catch {
                return
            }
        }
    }
}

/// Work a primitive has handed to something a simulation does not drive —
/// `abandoningAfter`'s operation on a Dispatch queue — and is waiting for.
/// A simulation does not move virtual time while any of its own is
/// outstanding: otherwise a timer would fire "before" work that, in real
/// time, was already almost done. Counted per ledger tag, so one run's
/// outside work never holds up another's.
package enum ExternalWork {
    private static let outstanding = Mutex<[UInt64: Int]>([:])

    package static func begin(tag: UInt64?) {
        outstanding.withLock { $0[tag ?? 0, default: 0] += 1 }
    }

    package static func end(tag: UInt64?) {
        outstanding.withLock { counts in
            let remaining = (counts[tag ?? 0] ?? 1) - 1
            counts[tag ?? 0] = remaining > 0 ? remaining : nil
        }
    }

    package static func isOutstanding(tag: UInt64?) -> Bool {
        outstanding.withLock { $0[tag ?? 0] != nil }
    }
}

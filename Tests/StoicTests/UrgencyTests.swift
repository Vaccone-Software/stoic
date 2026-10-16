@testable import Stoic
import StoicTesting
import Testing

/// `Urgency`: who is waiting, said by code or inferred from the task's base
/// priority (design/22, Urgency).
@Suite("Urgency")
struct UrgencyTests {
    @Test func theCasesAreOrderedLeastUrgentFirst() {
        #expect(Urgency.background < .utility)
        #expect(Urgency.utility < .userInitiated)
        #expect(Urgency.userInitiated < .interactive)
        #expect(min(Urgency.interactive, .utility) == .utility)
        #expect([Urgency.background, .utility, .userInitiated, .interactive].map(\.description)
            == ["background", "utility", "userInitiated", "interactive"])
    }

    @Test func theInnermostWithUrgencyWins() async {
        let seen = await withUrgency(.background) {
            let outer = Urgency.current
            let inner = await withUrgency(.interactive) { Urgency.current }
            return (outer, inner, Urgency.current)
        }
        #expect(seen.0 == .background)
        #expect(seen.1 == .interactive)
        #expect(seen.2 == .background)
    }

    @Test func childTasksInheritTheUrgency() async {
        let seen = await withUrgency(.interactive) {
            async let child = Urgency.current
            let grouped = await withTaskGroup(of: Urgency.self) { group in
                group.addTask { Urgency.current }
                return await group.next()!
            }
            return (await child, grouped)
        }
        #expect(seen.0 == .interactive)
        #expect(seen.1 == .interactive)
    }

    @Test func aDetachedTaskStartsWithoutIt() async {
        let seen = await withUrgency(.interactive) {
            await Task.detached(priority: .background) { Urgency.current }.value
        }
        #expect(seen == .background)
    }

    @Test(arguments: [
        (TaskPriority.background, Urgency.background),
        (.utility, .utility),
        (.low, .utility),
        (.medium, .userInitiated),
        (.userInitiated, .userInitiated),
        (.high, .userInitiated),
    ])
    func isInferredFromTheBasePriority(_ priority: TaskPriority, _ expected: Urgency) async {
        let seen = await Task.detached(priority: priority) { Urgency.current }.value
        #expect(seen == expected)
        #expect(Urgency.inferred(from: priority) == expected)
    }

    @Test func interactiveIsNeverInferred() {
        #expect(Urgency.inferred(from: .high) == .userInitiated)
        #expect(Urgency.inferred(from: nil) == .userInitiated)
    }

    @Test func anEscalatedTaskKeepsTheUrgencyOfItsBasePriority() async {
        // A prefetch that a person later awaits is escalated; its policy
        // must not change under it.
        let (gate, opened) = AsyncStream.makeStream(of: Void.self)
        let task = Task.detached(priority: .background) { () -> (Urgency, TaskPriority) in
            for await _ in gate { break }
            return (Urgency.current, Task.currentPriority)
        }
        task.escalatePriority(to: .high)
        opened.yield()
        let (urgency, running) = await task.value
        #expect(running >= .high)
        #expect(urgency == .background)
    }
}

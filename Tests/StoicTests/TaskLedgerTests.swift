@testable import Stoic
import StoicTesting
import Testing

@Suite("Task ledger")
struct TaskLedgerTests {
    @Test func runningWorkIsListedAndFinishedWorkIsNot() async {
        await withTestAmbient(clock: TestClock()) {
            let tag = Ambient.current.ledgerTag!
            let gate = TestGate()
            let slot = TaskSlot<Void, Never>(label: "search")
            let owner = SlotOwner()
            await SlotCaller().run(slot, for: owner) { await gate.wait() } deliver: { _, _ in }
            for _ in 0..<100 where TaskLedger.entries(tag: tag).isEmpty { await Task.yield() }
            let entries = TaskLedger.entries(tag: tag)
            #expect(entries.count == 1)
            #expect(entries.first?.kind == .slot)
            #expect(entries.first?.label == "search")
            gate.open()
            #expect(await stoicTasksStillRunning().isEmpty)
        }
    }

    @Test func aLeakedTaskIsReportedByName() async {
        await withTestAmbient(clock: TestClock()) {
            let gate = TestGate()
            let machine = StateMachine<Int, Int>(initial: 0, label: "leaky") { _, next in .to(next) }
            machine.whileIn(1, label: "stuck") { _ in await gate.wait() }   // ignores cancellation
            machine.send(1)
            machine.send(2)   // leaves state 1; its work is cancelled but never stops
            let leftover = await stoicTasksStillRunning(within: .milliseconds(50))
            #expect(leftover.map(\.label) == ["leaky.stuck"])
            gate.open()
            #expect(await stoicTasksStillRunning().isEmpty)
        }
    }

    @Test func theDiagnosticsReportListsRunningTasks() async {
        await withTestAmbient(clock: TestClock()) {
            let gate = TestGate()
            let slot = TaskSlot<Void, Never>(label: "report-me")
            let owner = SlotOwner()
            await SlotCaller().run(slot, for: owner) { await gate.wait() } deliver: { _, _ in }
            for _ in 0..<100 where TaskLedger.current.allSatisfy({ $0.label != "report-me" }) { await Task.yield() }
            #expect(Diagnostics.snapshot().contains("slot report-me running for"))
            gate.open()
            _ = await stoicTasksStillRunning()
        }
    }
}

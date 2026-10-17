#if STOIC_CRYPTO
// No `@testable` here, on purpose: this file sees only what a downstream
// package sees, so it fails to compile if a type a codec's tests need to
// build has lost its public initializer.
import StoicSealed
import StoicStore
import Testing

@Suite("SealedJournal.Replay as a value")
struct ReplayValueTests {
    /// What Lodestar's codec tests do: build a replay by hand, hand it to the
    /// function that decodes one, and compare.
    private func decode(_ replay: SealedJournal.Replay) -> [String] {
        (replay.snapshot.map { [String(decoding: $0.bytes, as: UTF8.self)] } ?? [])
            + replay.records.map { "\($0.sequence):" + String(decoding: $0.bytes, as: UTF8.self) }
    }

    @Test func aReplayIsBuiltFromItsPublicInitializers() {
        let replay = SealedJournal.Replay(
            snapshot: .init(through: 4, bytes: Array("folded".utf8)),
            records: [.init(sequence: 5, bytes: Array("five".utf8)), .init(sequence: 6, bytes: Array("six".utf8))],
            failures: [
                .init(item: .record(sequence: 7), error: .tampered),
                .init(item: .snapshot(through: 4), error: .notSealed),
            ],
            report: Journal.OpenReport(
                droppedBytes: 9, staleRecords: 1, records: 2,
                corruption: [.init(offset: 100, length: 40, lostRecords: 2, firstLostSequence: 8)], lostSnapshot: true
            )
        )
        #expect(decode(replay) == ["folded", "5:five", "6:six"])
        #expect(!replay.isComplete)
        #expect(replay.failures.map(\.error) == [.tampered, .notSealed])
        #expect(replay.report.corruptRecords == 2 && replay.report.droppedBytes == 9 && replay.report.lostSnapshot)
    }

    @Test func theDefaultsAreAnEmptyCleanReplay() {
        let replay = SealedJournal.Replay()
        #expect(replay.snapshot == nil && replay.records.isEmpty && replay.isComplete)
        #expect(replay.report == Journal.OpenReport())
        #expect(replay.report.corruption.isEmpty && !replay.report.lostSnapshot)
    }

    @Test func valuesCompareByTheirContents() {
        let one = SealedJournal.Replay(records: [.init(sequence: 1, bytes: [1])])
        #expect(one == SealedJournal.Replay(records: [.init(sequence: 1, bytes: [1])]))
        #expect(one != SealedJournal.Replay(records: [.init(sequence: 2, bytes: [1])]))
    }
}
#endif

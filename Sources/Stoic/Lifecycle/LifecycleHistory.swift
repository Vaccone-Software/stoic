/// Checks on a record's history, for an auditor or a test.
public enum LifecycleHistory {
    /// Checks that `entries` are the whole history of `record`: numbered
    /// `0..<record.sequence` with no gap, each the record's, each starting
    /// where the one before ended and dated no earlier than it, and the last
    /// ending in the written state.
    ///
    /// The first entry's `from` is not checked: creation is not an entry,
    /// and the record does not keep the state it was created in.
    ///
    /// - Throws: ``HistoryGap`` naming the first fault.
    public static func verify<L: Lifecycle>(_ entries: [LifecycleEntry<L>], of record: LifecycleRecord<L>) throws(HistoryGap) {
        for (index, entry) in entries.enumerated() {
            let expected = UInt64(index)
            guard expected < record.sequence else { throw HistoryGap(.beyondSequence(entry.sequence, record.sequence)) }
            guard entry.sequence == expected else { throw HistoryGap(.missing(expected)) }
            guard entry.record == record.key else { throw HistoryGap(.foreign(expected)) }
            if index > 0 {
                let previous = entries[index - 1]
                guard entry.from == previous.to else { throw HistoryGap(.broken(expected)) }
                guard entry.at >= previous.at else { throw HistoryGap(.backwards(expected)) }
            }
        }
        guard UInt64(entries.count) == record.sequence else { throw HistoryGap(.missing(UInt64(entries.count))) }
        if let last = entries.last, last.to != record.written.state {
            throw HistoryGap(.endsElsewhere(last.sequence))
        }
    }
}

/// The first fault ``LifecycleHistory/verify(_:of:)`` found in a history.
public struct HistoryGap: Error, Sendable, Hashable, CustomStringConvertible {
    /// What is wrong, and at which entry.
    public enum Fault: Sendable, Hashable {
        /// The entry with this sequence is missing (or out of place).
        case missing(UInt64)
        /// An entry numbered at or beyond the record's count (the first
        /// value), which is the second.
        case beyondSequence(UInt64, UInt64)
        /// The entry with this sequence belongs to another record.
        case foreign(UInt64)
        /// The entry with this sequence does not start where the one before
        /// it ended.
        case broken(UInt64)
        /// The entry with this sequence is dated before the one before it.
        case backwards(UInt64)
        /// The last entry, with this sequence, does not end in the written
        /// state.
        case endsElsewhere(UInt64)
    }

    public let fault: Fault

    public init(_ fault: Fault) {
        self.fault = fault
    }

    public var description: String {
        switch fault {
        case .missing(let sequence): "history entry \(sequence) is missing"
        case .beyondSequence(let sequence, let count): "history entry \(sequence) is beyond the record's \(count) entries"
        case .foreign(let sequence): "history entry \(sequence) belongs to another record"
        case .broken(let sequence): "history entry \(sequence) does not start where entry \(sequence - 1) ended"
        case .backwards(let sequence): "history entry \(sequence) is dated before entry \(sequence - 1)"
        case .endsElsewhere(let sequence): "history entry \(sequence), the last, does not end in the written state"
        }
    }
}

/// What a circuit breaker remembers: the outcomes of its most recent calls.
///
/// Two shapes. A *count* window holds exactly the last `N` calls. A *time*
/// window holds the calls of the last `T`, kept in ten buckets of `T / 10`
/// so that its memory does not grow with traffic; its edge is therefore
/// coarse, covering between `T − T/10` and `T`. Both answer the same three
/// questions — how many calls, how many failed, how many were slow — and
/// both are exact integers.
struct OutcomeWindow: Sendable {
    /// The number of buckets a time window is divided into.
    static let bucketCount = 10

    struct Totals: Sendable, Equatable {
        var calls = 0
        var failures = 0
        var slowCalls = 0

        /// Whether the failure rate is at least `partsPerMillion`, compared
        /// exactly: `failures / calls ≥ ppm / 1,000,000` as an integer inequality.
        func failureRate(atLeast partsPerMillion: Int) -> Bool {
            calls > 0 && Int128(failures) * 1_000_000 >= Int128(partsPerMillion) * Int128(calls)
        }

        /// Whether the slow-call rate is at least `partsPerMillion`.
        func slowCallRate(atLeast partsPerMillion: Int) -> Bool {
            calls > 0 && Int128(slowCalls) * 1_000_000 >= Int128(partsPerMillion) * Int128(calls)
        }

        var failureRate: Double { calls == 0 ? 0 : Double(failures) / Double(calls) }
        var slowCallRate: Double { calls == 0 ? 0 : Double(slowCalls) / Double(calls) }
    }

    private struct Bucket: Sendable {
        var epoch: Int?
        var totals = Totals()
    }

    private enum Kind: Sendable {
        case calls(capacity: Int)
        case time(bucketWidth: Int128)
    }

    // The arrays are stored properties, not an enum's payloads: a payload
    // bound with `var` is a copy, so mutating it copied the whole array on
    // every recorded call (a count window of a million calls cost a
    // megabyte per call). Stored properties of a window held in one place
    // mutate in place, and recording allocates nothing.
    private let kind: Kind
    // A count window's ring of the last calls; each element packs
    // bit 0 = failed, bit 1 = slow.
    private var outcomes: [UInt8] = []
    private var next = 0
    private var ringTotals = Totals()
    // A time window's buckets.
    private var buckets: [Bucket] = []

    /// A window of the last `capacity` calls.
    init(lastCalls capacity: Int) {
        precondition(capacity >= 1)
        kind = .calls(capacity: capacity)
    }

    /// A window of the last `span`, in ten buckets.
    init(lastSpan span: Duration) {
        let width = span.attoseconds / Int128(Self.bucketCount)
        precondition(width >= 1, "a time window needs a span of at least ten attoseconds")
        kind = .time(bucketWidth: width)
        buckets = Array(repeating: Bucket(), count: Self.bucketCount)
    }

    /// Forgets every call, keeping the storage for the next ones.
    mutating func clear() {
        switch kind {
        case .calls:
            outcomes.removeAll(keepingCapacity: true)
            next = 0
            ringTotals = Totals()
        case .time:
            for index in buckets.indices { buckets[index] = Bucket() }
        }
    }

    /// Adds one call that ended at `now`.
    mutating func record(failed: Bool, slow: Bool, at now: AnyClock.Instant) {
        switch kind {
        case .calls(let capacity):
            let packed: UInt8 = (failed ? 1 : 0) | (slow ? 2 : 0)
            if outcomes.count < capacity {
                outcomes.append(packed)
            } else {
                let evicted = outcomes[next]
                ringTotals.calls -= 1
                if evicted & 1 != 0 { ringTotals.failures -= 1 }
                if evicted & 2 != 0 { ringTotals.slowCalls -= 1 }
                outcomes[next] = packed
            }
            next = (next + 1) % capacity
            ringTotals.calls += 1
            if failed { ringTotals.failures += 1 }
            if slow { ringTotals.slowCalls += 1 }
        case .time(let width):
            let epoch = Self.epoch(of: now, width: width)
            let slot = Self.slot(of: epoch, count: buckets.count)
            if let existing = buckets[slot].epoch, existing > epoch {
                return   // a call from the past: the clock does not run backwards, so drop it
            }
            if buckets[slot].epoch != epoch {
                buckets[slot] = Bucket(epoch: epoch)
            }
            buckets[slot].totals.calls += 1
            if failed { buckets[slot].totals.failures += 1 }
            if slow { buckets[slot].totals.slowCalls += 1 }
        }
    }

    /// The calls remembered at `now`.
    func totals(at now: AnyClock.Instant) -> Totals {
        switch kind {
        case .calls:
            return ringTotals
        case .time(let width):
            let epoch = Self.epoch(of: now, width: width)
            var total = Totals()
            for bucket in buckets {
                guard let bucketEpoch = bucket.epoch, bucketEpoch > epoch - buckets.count, bucketEpoch <= epoch else { continue }
                total.calls += bucket.totals.calls
                total.failures += bucket.totals.failures
                total.slowCalls += bucket.totals.slowCalls
            }
            return total
        }
    }

    private static func epoch(of instant: AnyClock.Instant, width: Int128) -> Int {
        Int(clamping: instant.offset.attoseconds / width)
    }

    private static func slot(of epoch: Int, count: Int) -> Int {
        ((epoch % count) + count) % count
    }
}

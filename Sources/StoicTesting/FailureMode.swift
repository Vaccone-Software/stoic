public import Testing

/// Marks a test as the proof of one row of a design contract's failure-mode
/// table.
///
///     @Test(.failureMode("design/09", "a child stops beating"))
///     func aChildThatStopsBeatingIsRestarted() async throws { … }
///
/// Stoic's own suite checks, on every run, that every row of every table
/// in `design/` names at least one test this way, and that every trait
/// names a row that exists — so a contract cannot promise a behaviour
/// nothing tests, and a test cannot claim a row that was rewritten. The row
/// is its first column, as written, without backticks.
public struct FailureModeTrait: TestTrait, SuiteTrait {
    /// The contract, such as `design/09`.
    public let document: String
    /// The row's "What happens if…" text.
    public let row: String

    public var isRecursive: Bool { false }

    public var comments: [Comment] {
        [Comment(rawValue: "\(document): \(row)")]
    }
}

extension Trait where Self == FailureModeTrait {
    /// The row of `document`'s failure-mode table this test proves.
    public static func failureMode(_ document: String, _ row: String) -> Self {
        FailureModeTrait(document: document, row: row)
    }
}

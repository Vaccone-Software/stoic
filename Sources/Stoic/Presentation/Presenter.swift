/// How errors the app does not own are presented (design/31).
///
/// ``Swift/Error/presented(fileID:line:)`` asks an error that is
/// ``Presentable`` first; then the ambient presenter's rule for its type;
/// then Stoic's own presentation of its errors. A rule is how an app presents
/// a type it cannot conform: a library's error, a platform's.
///
///     let presenter = Presenter.standard.adding(PaymentSDKError.self, wordings: [declined]) { error in
///         error.code == .declined ? Presentation(declined, recovery: .changeInput(fields: ["card"])) : nil
///     }
///     withAmbient({ $0.presenter = presenter }) { … }
///
/// A rule that returns `nil` passes: the search goes on, inside the error and
/// then to the generic words. The rule added last is asked first, so an app
/// can override a rule it was given (StoicFoundation's, say).
public struct Presenter: Sendable {
    private struct Rule: Sendable {
        let present: @Sendable (any Error) -> Presentation?
    }

    /// Newest last; asked newest first.
    private let rules: [Rule]

    /// Every wording the presenter's rules can produce, Stoic's own first, in
    /// the order they were given: what a translation catalog must cover. A
    /// test can check that the app's `Stoic` table has a translation for each.
    public let wordings: [Wording]

    private init(rules: [Rule], wordings: [Wording]) {
        self.rules = rules
        self.wordings = wordings
    }

    /// Stoic's kernel errors, as the table in design/31 presents them, and no
    /// other rule.
    public static let standard = Presenter(rules: [], wordings: StoicWording.kernel)

    /// This presenter, with a rule for `type` asked before its others.
    ///
    /// - Parameters:
    ///   - type: The error type the rule presents. An error of another type
    ///     never reaches it.
    ///   - wordings: Every wording the rule can return, so ``wordings`` can
    ///     list them for a translation catalog.
    ///   - present: The presentation, or `nil` to pass the error on.
    public func adding<E: Error>(
        _ type: E.Type, wordings: [Wording] = [], _ present: @escaping @Sendable (E) -> Presentation?
    ) -> Presenter {
        let rule = Rule { error in (error as? E).flatMap(present) }
        var all = self.wordings
        for wording in wordings where !all.contains(wording) { all.append(wording) }
        return Presenter(rules: rules + [rule], wordings: all)
    }

    /// The newest rule's presentation of `error`, if any rule has one.
    func presentation(of error: any Error) -> Presentation? {
        for rule in rules.reversed() {
            if let presentation = rule.present(error) { return presentation }
        }
        return nil
    }
}

extension Ambient {
    /// The presenter the current task's failures are presented with.
    ///
    /// ``Presenter/standard`` unless an app installs another at its entry
    /// point (`withAmbient({ $0.presenter = .foundation }) { … }`, with
    /// StoicFoundation's rules).
    public var presenter: Presenter {
        get { storedPresenter ?? .standard }
        set { storedPresenter = newValue }
    }
}

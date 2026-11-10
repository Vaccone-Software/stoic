extension Error {
    /// The failure as a person should see it, recorded once as
    /// `failure.presented` with a ``SupportReference`` (design/31). `nil`
    /// exactly for cancellation, which presents nothing and records nothing.
    ///
    /// The search goes from the outermost layer in. At each layer, in order:
    /// a ``Presentable`` error's presentation; the ambient
    /// ``Presenter``'s rule for its type; a Stoic error whose presentation is
    /// decisive there (a rejection, an unknown outcome on a keyed or
    /// non-repeatable operation, a lifecycle refusal, a permission refusal,
    /// a ``Defect``). Otherwise it looks inside (a `Report`'s root, a
    /// `PolicyError`'s failure, an `OperationError`'s failed stop, a
    /// `ConcurrentFailure`'s primary failure, a lifecycle store's failure),
    /// and a Stoic layer passed that way leaves its fallback ("couldn't
    /// reach the service", "this is taking too long"). When nothing matches,
    /// the innermost fallback is used, or else the generic words with
    /// ``Recovery/contactSupport``, and ``Presented/isClassified`` is false.
    ///
    /// The error's description never reaches a ``Presented``: it goes only
    /// to the event, at `.private` privacy.
    ///
    /// - Parameters:
    ///   - fileID: The call site, captured for the event.
    ///   - line: The call site, captured for the event.
    public func presented(fileID: String = #fileID, line: UInt = #line) -> Presented? {
        guard !containsCancellation(self) else { return nil }
        let (presentation, classified) = presentation(of: self, presenter: Ambient.current.presenter)
        let reference = presentation.reference ?? SupportReference.make(fileID: fileID, line: line)
        let presented = Presented(
            message: presentation.message, recovery: presentation.recovery, reference: reference, isClassified: classified)
        let level: Event.Level = containsDefect(self) ? .error : (classified ? .info : .warning)
        Ambient.record(level: level) {
            var fields: [Event.Field] = [
                .init("reference", .string(reference.description), privacy: .public),
                .init("key", .string(presentation.message.key), privacy: .public),
            ]
            if let table = presentation.message.table { fields.append(.init("table", .string(table), privacy: .public)) }
            fields += [
                .init("recovery", .string(presentation.recovery.description), privacy: .public),
                .init("classified", .bool(classified)),
                // The type is public; the description is private, and is the
                // debug one: a Report's plain description hides its root, and
                // whoever reads this event is debugging the failure.
                .init("error", .error(type: String(reflecting: type(of: self)), description: String(reflecting: self))),
            ]
            return Event("failure.presented", level: level, fields: fields, fileID: fileID, line: line)
        }
        return presented
    }
}

/// What a layer of a Stoic error contributes to the search.
enum PresentationStep {
    /// This layer's presentation decides.
    case decisive(Presentation)
    /// Look at `inner`; if nothing deeper decides, `fallback` is used.
    case inside(any Error, fallback: Presentation?)
    /// Nothing here, and nothing inside.
    case opaque
}

/// A Stoic error that takes part in the search: its row of design/31's table,
/// or where to look inside it.
protocol PresentationLayer {
    var presentationStep: PresentationStep { get }
}

/// The search of ``Swift/Error/presented(fileID:line:)``, without the
/// reference and the event: the presentation, and whether anyone classified
/// the failure.
func presentation(of error: any Error, presenter: Presenter) -> (Presentation, classified: Bool) {
    var layer = error
    var fallback: Presentation?
    // An error that wraps itself, or a chain built in a loop, cannot hold the
    // search: past this many layers the fallback (or the generic words) stands.
    for _ in 0..<64 {
        if let presentable = layer as? any Presentable { return (presentable.presentation, true) }
        if let presentation = presenter.presentation(of: layer) { return (presentation, true) }
        if layer is any Defect { return (StoicPresentation.ours, true) }
        guard let stoic = layer as? any PresentationLayer else { break }
        switch stoic.presentationStep {
        case .decisive(let presentation):
            return (presentation, true)
        case .inside(let inner, let left):
            if let left { fallback = left }
            layer = inner
        case .opaque:
            return fallback.map { ($0, true) } ?? (StoicPresentation.generic, false)
        }
    }
    return fallback.map { ($0, true) } ?? (StoicPresentation.generic, false)
}

// MARK: Stoic's own wordings

/// The keys and English text of Stoic's own presentations, in the `Stoic`
/// table: design/31's table, and the rules StoicFoundation and StoicHTTP add.
package enum StoicWording {
    package static let table = "Stoic"

    private static func stoic(_ key: String, _ text: String) -> Wording {
        Wording(key, default: text, table: table)
    }

    package static let failure = stoic("stoic.failure", "Something went wrong.")
    package static let ours = stoic("stoic.failure.ours", "Something went wrong on our side.")
    package static let unavailable = stoic("stoic.unavailable", "The service isn't answering right now.")
    package static let busy = stoic("stoic.busy", "Too many requests right now.")
    package static let slow = stoic("stoic.slow", "This is taking too long.")
    package static let closing = stoic("stoic.closing", "The app is closing.")
    package static let stuck = stoic("stoic.stuck", "Something is stuck. Try again later.")
    package static let unconfirmed = stoic(
        "stoic.outcome.unconfirmed", "We couldn't confirm this finished. Trying again is safe.")
    package static let outcomeUnknown = stoic(
        "stoic.outcome.unknown", "We couldn't confirm whether this went through. Check before trying again.")
    package static let unreachable = stoic("stoic.unreachable", "Couldn't reach the service.")
    package static let noEffect = stoic("stoic.lifecycle.no_effect", "That has no effect now.")
    package static let newer = stoic("stoic.lifecycle.newer", "This was changed by a newer version of the app.")
    package static let gone = stoic("stoic.lifecycle.gone", "This no longer exists.")
    package static let conflict = stoic("stoic.lifecycle.conflict", "Someone else changed this at the same moment.")
    package static let denied = stoic("stoic.permission.denied", "You don't have permission to do this.")
    package static let checking = stoic("stoic.permission.loading", "Still checking what you can do.")
    package static let uncheckable = stoic("stoic.permission.unknown", "We couldn't check what you can do.")
    package static let sync = stoic("stoic.sync", "Couldn't sync right now.")

    // StoicFoundation's and StoicHTTP's, kept beside the kernel's so the keys
    // are written once.
    package static let offline = stoic("stoic.offline", "You're offline.")
    package static let diskFull = stoic("stoic.disk_full", "There isn't enough space on this device.")
    package static let signIn = stoic("stoic.http.sign_in", "Sign in again to continue.")
    package static let invalid = stoic("stoic.http.invalid", "Check what you entered.")

    /// Every wording the kernel's table uses. A lifecycle's refusal reason is
    /// the definition's own sentence, in a table named for the lifecycle, and
    /// is not listed: the definition knows its reasons.
    package static let kernel: [Wording] = [
        failure, ours, unavailable, busy, slow, closing, stuck, unconfirmed, outcomeUnknown, unreachable,
        noEffect, newer, gone, conflict, denied, checking, uncheckable, sync,
    ]
}

/// Stoic's own presentations, by what failed.
package enum StoicPresentation {
    package static let generic = Presentation(StoicWording.failure, recovery: .contactSupport)
    package static let ours = Presentation(StoicWording.ours, recovery: .contactSupport)
    package static let slow = Presentation(StoicWording.slow, recovery: .tryAgain)
    package static let unreachable = Presentation(StoicWording.unreachable, recovery: .tryAgain)
    package static let gone = Presentation(StoicWording.gone, recovery: .nothing)
    package static let conflict = Presentation(StoicWording.conflict, recovery: .tryAgain)
    package static let denied = Presentation(StoicWording.denied, recovery: .nothing)
    package static let sync = Presentation(StoicWording.sync, recovery: .tryAgain)

    /// When a wait asked for ends: `retryAfter` from the ambient wall clock's
    /// now, or no stated time.
    package static func waitUntil(_ retryAfter: Duration?) -> Recovery {
        .wait(until: retryAfter.map { Moment.now + $0 })
    }

    /// A rejection's row of the table; `nil` for a reason Stoic does not
    /// know (an app's own), which presents as nothing classified it.
    package static func rejection(_ rejection: Rejection) -> Presentation? {
        switch rejection.reason {
        case .circuitOpen, .budgetExhausted:
            Presentation(StoicWording.unavailable, recovery: waitUntil(rejection.retryAfter))
        case .rateLimited:
            Presentation(StoicWording.busy, recovery: waitUntil(rejection.retryAfter))
        case .bulkheadFull:
            Presentation(StoicWording.busy, recovery: .tryAgain)
        case .deadlineExceeded:
            slow
        case .shuttingDown:
            Presentation(StoicWording.closing, recovery: .nothing)
        case .abandonmentLimit:
            Presentation(StoicWording.stuck, recovery: .wait(until: nil))
        default:
            nil
        }
    }

    /// A permission check's "not yet" or "could not tell".
    package static func unknown(_ unknown: PermissionUnknown) -> Presentation {
        switch unknown {
        case .loading: Presentation(StoicWording.checking, recovery: .wait(until: nil))
        case .unavailable: Presentation(StoicWording.uncheckable, recovery: .tryAgain)
        }
    }
}

// MARK: The kernel's errors

extension Report: PresentationLayer {
    /// The root decides; the frames are for the developer, not the person.
    var presentationStep: PresentationStep { .inside(root, fallback: nil) }
}

extension Rejection: PresentationLayer {
    var presentationStep: PresentationStep {
        StoicPresentation.rejection(self).map(PresentationStep.decisive) ?? .opaque
    }
}

extension PolicyError: PresentationLayer {
    var presentationStep: PresentationStep {
        switch self {
        case .rejected(let rejection): rejection.presentationStep
        case .failed(let failure): .inside(failure, fallback: nil)
        }
    }
}

extension ConcurrentFailure: PresentationLayer {
    var presentationStep: PresentationStep { .inside(primary, fallback: nil) }
}

extension OperationError: PresentationLayer {
    var presentationStep: PresentationStep {
        // It may have happened, on an operation that is not safe to repeat by
        // itself: whatever the failure says, the person must know that first.
        if outcome == .unknown, safety == .keyed {
            return .decisive(Presentation(StoicWording.unconfirmed, recovery: .tryAgain))
        }
        if outcome == .unknown, safety == .notRepeatable {
            return .decisive(Presentation(StoicWording.outcomeUnknown, recovery: .checkFirst))
        }
        switch stop {
        case .rejected(let rejection):
            return rejection.presentationStep
        case .cancelled:
            // Cancellation of a call that is safe to repeat presents nothing
            // and never gets here; what is left is "it did not finish".
            return .decisive(StoicPresentation.slow)
        case .failed(let failure):
            let fallback: Presentation? = switch outcome {
            case .notExecuted: StoicPresentation.unreachable
            case .unknown: StoicPresentation.slow
            case .executed: nil
            }
            return .inside(failure, fallback: fallback)
        }
    }
}

extension LifecycleRefusal: PresentationLayer {
    var presentationStep: PresentationStep {
        switch self {
        case .refused(_, _, let reason):
            // The definition's own sentence, written for a person (design/27),
            // keyed by its text in a table named for the lifecycle.
            .decisive(Presentation(Wording(reason, default: reason, table: L.name), recovery: .nothing))
        case .ignored:
            .decisive(Presentation(StoicWording.noEffect, recovery: .nothing))
        case .newerDefinition:
            .decisive(Presentation(StoicWording.newer, recovery: .updateApp))
        case .invalid, .chainTooLong:
            .decisive(StoicPresentation.ours)
        }
    }
}

extension LifecycleUpdateError: PresentationLayer {
    var presentationStep: PresentationStep {
        switch self {
        case .refused(let refusal): refusal.presentationStep
        case .notFound: .decisive(StoicPresentation.gone)
        case .conflict: .decisive(StoicPresentation.conflict)
        case .storage(let failure): .inside(failure, fallback: nil)
        // Cancellation presents nothing and never gets here.
        case .cancelled: .opaque
        }
    }
}

extension PermissionRefusal: PresentationLayer {
    /// A denial's reason is not shown: a policy's reason can name someone
    /// (design/28), so the words are the generic denial, and an app that wants
    /// the reason shown makes its own presentation.
    var presentationStep: PresentationStep {
        switch self {
        case .denied: .decisive(StoicPresentation.denied)
        case .unknown(let unknown): .decisive(StoicPresentation.unknown(unknown))
        }
    }
}

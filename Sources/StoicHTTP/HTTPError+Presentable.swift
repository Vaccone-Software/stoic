public import Stoic
internal import StoicFoundation

extension HTTPError: Presentable {
    /// What a person reads when a request fails (design/31).
    ///
    /// 401 asks them to sign in again; 403 is the permission denial; 404 and
    /// 410 say it no longer exists; 409 that someone else changed it; 400 and
    /// 422 to check what they entered; 429 and 5xx that the service is busy
    /// or not answering, with a wait until its `Retry-After` when it sent
    /// one. A transport failure reads as StoicFoundation presents its
    /// `URLError` code, and as "couldn't reach the service" when that has no
    /// words for it. Any other status, a response the client refused (too
    /// large, not matching its schema, a redirect it would not follow) is a
    /// disagreement between this app and its server: "Something went wrong on
    /// our side", for support.
    public var presentation: Presentation {
        switch self {
        case .status(let code, _, let retryAfter, _, _):
            switch code {
            case 401: Presentation(StoicWording.signIn, recovery: .signInAgain)
            case 403: StoicPresentation.denied
            case 404, 410: StoicPresentation.gone
            case 409: StoicPresentation.conflict
            case 400, 422: Presentation(StoicWording.invalid, recovery: .changeInput(fields: []))
            case 429: Presentation(StoicWording.busy, recovery: StoicPresentation.waitUntil(retryAfter))
            case 500...599: Presentation(StoicWording.unavailable, recovery: StoicPresentation.waitUntil(retryAfter))
            default: StoicPresentation.ours
            }
        case .transport(let code, _):
            FoundationPresentation.urlError(code) ?? StoicPresentation.unreachable
        case .timedOut:
            StoicPresentation.slow
        case .rejected(let rejection, _):
            StoicPresentation.rejection(rejection) ?? StoicPresentation.ours
        case .reauthenticationFailed:
            Presentation(StoicWording.signIn, recovery: .signInAgain)
        case .authenticationFailed(let error, _):
            error.retryDecision == .stop
                ? StoicPresentation.ours : Presentation(StoicWording.unavailable, recovery: .wait(until: nil))
        case .responseTooLarge, .decoding, .redirectRefused:
            StoicPresentation.ours
        }
    }

    /// Every wording ``presentation`` can produce, for a translation catalog.
    public static let wordings: [Wording] = [
        StoicWording.signIn, StoicWording.denied, StoicWording.gone, StoicWording.conflict, StoicWording.invalid,
        StoicWording.busy, StoicWording.unavailable, StoicWording.ours, StoicWording.offline, StoicWording.slow,
        StoicWording.unreachable, StoicWording.closing, StoicWording.stuck,
    ]
}

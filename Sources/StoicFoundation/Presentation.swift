public import Foundation
public import Stoic

extension String {
    /// The wording as a person reads it: its translation in `bundle`'s table
    /// for the wording's key, else its default text, with each `{name}`
    /// placeholder replaced by its argument formatted for `locale` (design/31).
    ///
    /// A number is formatted as `locale` writes numbers, a moment as a date
    /// and time, a duration in units. A placeholder with no argument is left
    /// as it is. Stoic's own keys are in the `Stoic` table: an app that
    /// translates them adds a `Stoic` table of its own, and
    /// `Presenter.wordings` lists every key a presenter can produce.
    ///
    /// - Parameters:
    ///   - wording: The key, table, default text and arguments.
    ///   - bundle: Where the tables are; the app's main bundle by default.
    ///   - locale: How the arguments are formatted.
    ///   - timeZone: The zone a moment is written in; the device's when `nil`,
    ///     which is where the person reading it is.
    public init(localized wording: Wording, bundle: Bundle = .main, locale: Locale = .current, timeZone: TimeZone? = nil) {
        let template = bundle.localizedString(forKey: wording.key, value: wording.defaultText, table: wording.table)
        self = wording.filling(template) { argument in
            switch argument {
            case .text(let text):
                return text
            case .integer(let integer):
                return integer.formatted(.number.locale(locale))
            case .moment(let moment):
                var style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
                if let timeZone { style.timeZone = timeZone }
                return Date(timeIntervalSince1970: moment.secondsSinceEpoch).formatted(style)
            case .duration(let duration):
                return duration.formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide).locale(locale))
            }
        }
    }
}

extension Moment {
    /// Seconds since 1970 as a `Double`, for `Date`: exact to well under a
    /// microsecond for any moment a person reads.
    fileprivate var secondsSinceEpoch: Double {
        let (seconds, attoseconds) = sinceEpoch.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

extension Presenter {
    /// ``Presenter/standard`` with rules for Foundation's errors (design/31):
    /// offline (no connection, a lost one, cellular not allowed) as "You're
    /// offline." with a wait; a timeout as "This is taking too long."; a host
    /// that cannot be found or connected to as "Couldn't reach the service.";
    /// a full disk as "There isn't enough space on this device.". Any other
    /// `URLError`, `POSIXError` or `CocoaError` is left to the generic words.
    ///
    /// An app installs it at its entry point:
    ///
    ///     withAmbient({ $0.presenter = .foundation }) { … }
    public static let foundation: Presenter = Presenter.standard
        .adding(URLError.self, wordings: [StoicWording.offline, StoicWording.slow, StoicWording.unreachable]) {
            FoundationPresentation.urlError($0.code)
        }
        .adding(POSIXError.self, wordings: [StoicWording.diskFull]) { FoundationPresentation.posixError($0.code) }
        .adding(CocoaError.self, wordings: [StoicWording.diskFull]) { FoundationPresentation.cocoaError($0.code) }
}

/// Foundation's errors as a person reads them: shared with StoicHTTP, whose
/// transport failures are `URLError` codes.
package enum FoundationPresentation {
    package static let offline = Presentation(StoicWording.offline, recovery: .wait(until: nil))
    package static let diskFull = Presentation(StoicWording.diskFull, recovery: .nothing)

    package static func urlError(_ code: URLError.Code) -> Presentation? {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            offline
        case .timedOut:
            StoicPresentation.slow
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            StoicPresentation.unreachable
        default:
            nil
        }
    }

    package static func posixError(_ code: POSIXError.Code) -> Presentation? {
        switch code {
        case .ENOSPC: diskFull
        case .ETIMEDOUT: StoicPresentation.slow
        case .ENETDOWN: offline
        case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: StoicPresentation.unreachable
        default: nil
        }
    }

    package static func cocoaError(_ code: CocoaError.Code) -> Presentation? {
        code == .fileWriteOutOfSpace ? diskFull : nil
    }
}

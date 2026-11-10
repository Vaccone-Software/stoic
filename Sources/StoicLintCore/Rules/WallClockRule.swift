#if STOIC_LINT
import SwiftSyntax

/// Reading the device's clock, calendar or zone directly: `Date()`,
/// `Date.now`, `Calendar.current`, `TimeZone.current` (and their
/// `autoupdatingCurrent` twins).
///
/// Each is a hidden input. A test cannot control it, so code that reads
/// "now" or "today" this way does something different on every run and on
/// every machine, and a test of it waits for real time or is not written.
/// And each answers a question the code did not say: `Date()` used as
/// "when did it happen" is a `Moment`, which the ambient wall clock gives
/// (`Moment.now`); "which day is it" needs a place, which `Calendar.current`
/// supplies silently from the device (design/26).
///
/// Exempt: `Sources/StoicTime/Foundation`, which is the one place Stoic reads
/// the system's zone (the seam the rest goes through). Test code is not
/// exempt: a test that reads today's date is the flaky test this rule is for.
final class WallClockReadRule: RuleVisitor {
    private static let seamDirectory = "/Sources/StoicTime/Foundation/"

    private var isExempt: Bool {
        ("/" + reporter.path).contains(Self.seamDirectory)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isExempt, node.arguments.isEmpty, !node.hasClosure else { return .visitChildren }
        // `Date()` and `NSDate()`, `Foundation.Date()`, and `Date.init()`.
        var name = Self.typeName(node.calledExpression)
        if name == nil, let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            member.declName.baseName.tokenKind == .keyword(.`init`), let base = member.base
        {
            name = Self.typeName(base)
        }
        guard let name, name == "Date" || name == "NSDate" else { return .visitChildren }
        reporter.report(
            .wallClockRead, at: node,
            message: "`\(name)()` reads the device's clock directly: a test cannot control it, and nothing says which \"now\" it is.",
            fixIt: "use `Moment.now`, the ambient wall clock (and `.date` where an API needs a `Date`)")
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isExempt, let base = node.base, let type = Self.typeName(base) else { return .visitChildren }
        let member = node.declName.baseName.text
        switch (type, member) {
        case ("Date", "now"):
            reporter.report(
                .wallClockRead, at: node.declName,
                message: "`Date.now` reads the device's clock directly: a test cannot control it, and nothing says which \"now\" it is.",
                fixIt: "use `Moment.now`, the ambient wall clock (and `.date` where an API needs a `Date`)")
        case ("Calendar", "current"), ("Calendar", "autoupdatingCurrent"):
            reporter.report(
                .wallClockRead, at: node.declName,
                message:
                    "`Calendar.\(member)` brings the device's zone in unsaid: \"today\" and \"this month\" differ by device, and a test cannot control them.",
                fixIt: "say the place: `PlainDate.today(in:)` and `PlainDate` arithmetic, or a `Calendar` given an explicit `timeZone`")
        case ("TimeZone", "current"), ("TimeZone", "autoupdatingCurrent"):
            reporter.report(
                .wallClockRead, at: node.declName,
                message: "`TimeZone.\(member)` reads the device's zone directly: a test cannot control it.",
                fixIt: "use `TimeZoneID.device`, which the zone rules supply and a test scripts")
        default:
            break
        }
        return .visitChildren
    }

    /// `Date` for `Date` or `Foundation.Date`; nil for anything else.
    private static func typeName(_ expression: ExprSyntax) -> String? {
        if let name = expression.referencedName { return name }
        if let member = expression.as(MemberAccessExprSyntax.self), member.base?.referencedName == "Foundation" {
            return member.declName.baseName.text
        }
        return nil
    }
}

#endif

import Foundation
@testable import Stoic
import StoicTesting
import Testing

private enum EditEvent: Permission {
    typealias Subject = String
    typealias Principal = String
    static let name = "test.edit-event"
}

private struct Opaque: Error, CustomStringConvertible {
    var description: String { "opaque failure" }
}

private struct OurBug: Defect {}

private struct SignUpFull: Error, Presentable {
    var presentation: Presentation {
        Presentation(Wording("signup.full", default: "This event is full."), recovery: .nothing)
    }
}

/// An app error that wraps a Stoic one, and decides how it reads.
private struct SyncFailed: Error, Presentable {
    let underlying: any Error
    var presentation: Presentation {
        Presentation(Wording("sync.failed", default: "Your changes are saved and will sync later."), recovery: .nothing)
    }
}

/// An error that carries a server's own reference.
private struct ServerSaid: Error, Presentable {
    let reference: SupportReference
    var presentation: Presentation {
        Presentation(Wording("server.said", default: "The server refused."), recovery: .contactSupport, reference: reference)
    }
}

private func operationError(
    _ stop: OperationError<any Error>.Stop, outcome: OperationError<any Error>.Outcome, safety: RepeatSafety = .idempotent
) -> OperationError<any Error> {
    var last: (any Error)?
    if case .failed(let failure) = stop { last = failure }
    return OperationError(stop: stop, outcome: outcome, last: last, attempts: 2, safety: safety, idempotencyKey: nil)
}

/// design/31's table as data: every Stoic error, the key and recovery it
/// presents as. A changed row is a reviewed diff.
@Suite("Presenting failures", .stoic())
struct PresentationTests {
    struct Row: Sendable, CustomStringConvertible {
        let name: String
        let error: any Error & Sendable
        let key: String
        let recovery: Recovery
        var description: String { name }
    }

    static let now = TestClock.wallClockStart

    static let rows: [Row] = [
        Row(name: "unclassified", error: Opaque(), key: "stoic.failure", recovery: .contactSupport),
        Row(name: "a defect", error: OurBug(), key: "stoic.failure.ours", recovery: .contactSupport),
        Row(
            name: "LifecycleRefusal.invalid", error: LifecycleRefusal<Reminder>.invalid(state: .waiting, event: .nudge, reason: "no"),
            key: "stoic.failure.ours", recovery: .contactSupport),
        Row(
            name: "LifecycleRefusal.chainTooLong", error: LifecycleRefusal<Reminder>.chainTooLong(state: .waiting, steps: 64),
            key: "stoic.failure.ours", recovery: .contactSupport),
        Row(
            name: "circuit open", error: Rejection(.circuitOpen, retryAfter: .seconds(30)), key: "stoic.unavailable",
            recovery: .wait(until: now + .seconds(30))),
        Row(name: "budget exhausted", error: Rejection(.budgetExhausted), key: "stoic.unavailable", recovery: .wait(until: nil)),
        Row(
            name: "rate limited", error: Rejection(.rateLimited, retryAfter: .seconds(5)), key: "stoic.busy",
            recovery: .wait(until: now + .seconds(5))),
        Row(name: "bulkhead full", error: Rejection(.bulkheadFull), key: "stoic.busy", recovery: .tryAgain),
        Row(name: "deadline exceeded", error: Rejection(.deadlineExceeded), key: "stoic.slow", recovery: .tryAgain),
        Row(
            name: "unknown outcome on a read-only operation",
            error: operationError(.failed(Opaque()), outcome: .unknown, safety: .readOnly), key: "stoic.slow", recovery: .tryAgain),
        Row(
            name: "unknown outcome on an idempotent operation",
            error: operationError(.failed(Opaque()), outcome: .unknown, safety: .idempotent), key: "stoic.slow", recovery: .tryAgain),
        Row(name: "shutting down", error: Rejection(.shuttingDown), key: "stoic.closing", recovery: .nothing),
        Row(name: "abandonment limit", error: Rejection(.abandonmentLimit), key: "stoic.stuck", recovery: .wait(until: nil)),
        Row(
            name: "unknown outcome, keyed", error: operationError(.failed(SignUpFull()), outcome: .unknown, safety: .keyed),
            key: "stoic.outcome.unconfirmed", recovery: .tryAgain),
        Row(
            name: "unknown outcome, keyed, cancelled", error: operationError(.cancelled, outcome: .unknown, safety: .keyed),
            key: "stoic.outcome.unconfirmed", recovery: .tryAgain),
        Row(
            name: "unknown outcome, not repeatable",
            error: operationError(.failed(SignUpFull()), outcome: .unknown, safety: .notRepeatable),
            key: "stoic.outcome.unknown", recovery: .checkFirst),
        Row(
            name: "not executed, failure unclassified", error: operationError(.failed(Opaque()), outcome: .notExecuted),
            key: "stoic.unreachable", recovery: .tryAgain),
        Row(
            name: "refused by a policy", error: operationError(.rejected(Rejection(.bulkheadFull)), outcome: .notExecuted),
            key: "stoic.busy", recovery: .tryAgain),
        Row(
            name: "LifecycleRefusal.refused",
            error: LifecycleRefusal<Reminder>.refused(state: .done, event: .nudge, reason: "this reminder is already done"),
            key: "this reminder is already done", recovery: .nothing),
        Row(
            name: "LifecycleRefusal.ignored", error: LifecycleRefusal<Reminder>.ignored(state: .done, event: .nudge),
            key: "stoic.lifecycle.no_effect", recovery: .nothing),
        Row(
            name: "LifecycleRefusal.newerDefinition", error: LifecycleRefusal<Reminder>.newerDefinition(written: 3, current: 2),
            key: "stoic.lifecycle.newer", recovery: .updateApp),
        Row(
            name: "LifecycleUpdateError.notFound", error: LifecycleUpdateError<Reminder, Opaque>.notFound,
            key: "stoic.lifecycle.gone", recovery: .nothing),
        Row(
            name: "LifecycleUpdateError.conflict", error: LifecycleUpdateError<Reminder, Opaque>.conflict(attempts: 3),
            key: "stoic.lifecycle.conflict", recovery: .tryAgain),
        Row(
            name: "LifecycleUpdateError.refused",
            error: LifecycleUpdateError<Reminder, Opaque>.refused(.ignored(state: .done, event: .nudge)),
            key: "stoic.lifecycle.no_effect", recovery: .nothing),
        Row(
            name: "LifecycleUpdateError.storage", error: LifecycleUpdateError<Reminder, Rejection>.storage(Rejection(.bulkheadFull)),
            key: "stoic.busy", recovery: .tryAgain),
        Row(
            name: "PermissionRefusal.denied",
            error: PermissionRefusal<EditEvent>.denied(
                PermissionDenial(subject: "beach-clean", principal: "ana@example.com", policy: "organisers", reason: "only Ana's friend may")),
            key: "stoic.permission.denied", recovery: .nothing),
        Row(
            name: "PermissionRefusal.unknown(.loading)", error: PermissionRefusal<EditEvent>.unknown(.loading),
            key: "stoic.permission.loading", recovery: .wait(until: nil)),
        Row(
            name: "PermissionRefusal.unknown(.unavailable)", error: PermissionRefusal<EditEvent>.unknown(.unavailable("down")),
            key: "stoic.permission.unknown", recovery: .tryAgain),
    ]

    /// Every way a Stoic layer can carry an error to the screen.
    static let wrappers: [(name: String, wrap: @Sendable (any Error) -> any Error)] = [
        ("bare", { $0 }),
        ("Report", { Report($0).adding(Report.Frame("saving the commitment")) }),
        ("PolicyError", { PolicyError<any Error>.failed($0) }),
        ("OperationError, executed", { operationError(.failed($0), outcome: .executed) }),
        ("ConcurrentFailure", { ConcurrentFailure<any Error>([$0, Opaque()]) }),
        ("Report in an OperationError", { operationError(.failed(Report($0)), outcome: .executed) }),
    ]

    @Test func everyRowInEveryWrapper() throws {
        for row in Self.rows {
            for wrapper in Self.wrappers {
                let presented = try #require(wrapper.wrap(row.error).presented(), "\(row) in \(wrapper.name)")
                #expect(presented.message.key == row.key, "\(row) in \(wrapper.name)")
                #expect(presented.recovery == row.recovery, "\(row) in \(wrapper.name)")
                #expect(presented.isClassified == (row.key != "stoic.failure"), "\(row) in \(wrapper.name)")
            }
        }
    }

    @Test func stoicsOwnKeysAreInTheStoicTableWithEnglishText() throws {
        let presented = try #require(Rejection(.bulkheadFull).presented())
        #expect(presented.message.table == "Stoic")
        #expect(presented.message.defaultText == "Too many requests right now.")
        let refused = try #require(LifecycleRefusal<Reminder>.refused(state: .done, event: .nudge, reason: "this reminder is already done").presented())
        #expect(refused.message.table == Reminder.name, "a refusal's reason lives in a table named for its lifecycle")
        #expect(refused.message.defaultText == "this reminder is already done")
    }

    @Test // design/31: "an error is a cancellation"
    func cancellationPresentsNothingAndRecordsNothing() {
        let cancellations: [any Error] = [
            CancellationError(),
            Rejection(.cancelled),
            PolicyError<Opaque>.rejected(Rejection(.cancelled)),
            operationError(.cancelled, outcome: .notExecuted, safety: .keyed),
            operationError(.cancelled, outcome: .unknown, safety: .idempotent),
            Report(CancellationError()).adding(Report.Frame("loading")),
            LifecycleUpdateError<Reminder, Opaque>.cancelled,
            ConcurrentFailure<any Error>([CancellationError()]),
        ]
        for error in cancellations {
            #expect(error.presented() == nil, "\(error)")
        }
        #expect(StoicTest.events.events(named: "failure.presented").isEmpty)
    }

    @Test // design/31: "a keyed operation is cancelled after reaching the backend"
    func aKeyedCallCancelledAfterReachingTheBackendIsNotCancellation() throws {
        let error = operationError(.cancelled, outcome: .unknown, safety: .keyed)
        let presented = try #require(error.presented())
        #expect(presented.message.key == "stoic.outcome.unconfirmed")
        #expect(presented.message.defaultText == "We couldn't confirm this finished. Trying again is safe.")
    }

    @Test // design/31: "an error conforms to Presentable"
    func aPresentableErrorDecidesWithANewReference() throws {
        let first = try #require(SignUpFull().presented())
        let second = try #require(SignUpFull().presented())
        #expect(first.message.key == "signup.full")
        #expect(first.recovery == .nothing)
        #expect(first.isClassified)
        #expect(first.reference != second.reference, "each presentation is its own failure")
    }

    @Test // design/31: "an app error wraps a Stoic error"
    func theOuterPresentableDecides() throws {
        let error = SyncFailed(underlying: Rejection(.circuitOpen))
        #expect(try #require(error.presented()).message.key == "sync.failed")
        let wrapped = Report(error).adding(Report.Frame("syncing"))
        #expect(try #require(wrapped.presented()).message.key == "sync.failed")
    }

    @Test // design/31: "a Report wraps a Presentable error"
    func aReportShowsItsRootNotItsFrames() throws {
        let report = Report(SignUpFull()).adding(Report.Frame("signing up for the beach clean"))
        let presented = try #require(report.presented())
        #expect(presented.message.key == "signup.full")
        #expect(!presented.message.description.contains("beach clean"))
    }

    @Test // design/31: "an OperationError was refused by a policy"
    func aPolicysRefusalReadsAsItsRow() throws {
        let error = operationError(.rejected(Rejection(.rateLimited, retryAfter: .seconds(60))), outcome: .notExecuted)
        let presented = try #require(error.presented())
        #expect(presented.message.key == "stoic.busy")
        #expect(presented.recovery == .wait(until: Self.now + .seconds(60)))
    }

    @Test // design/31: "an OperationError's failure is Presentable"
    func anOperationsPresentableFailureDecidesUnlessTheOutcomeIsUnknown() throws {
        for outcome: OperationError<any Error>.Outcome in [.executed, .notExecuted] {
            let error = operationError(.failed(SignUpFull()), outcome: outcome, safety: .keyed)
            #expect(try #require(error.presented()).message.key == "signup.full", "\(outcome)")
        }
        for safety: RepeatSafety in [.readOnly, .idempotent] {
            let error = operationError(.failed(SignUpFull()), outcome: .unknown, safety: safety)
            #expect(try #require(error.presented()).message.key == "signup.full", "\(safety)")
        }
        let keyed = operationError(.failed(SignUpFull()), outcome: .unknown, safety: .keyed)
        #expect(try #require(keyed.presented()).message.key == "stoic.outcome.unconfirmed")
        let once = operationError(.failed(SignUpFull()), outcome: .unknown, safety: .notRepeatable)
        #expect(try #require(once.presented()).message.key == "stoic.outcome.unknown")
    }

    @Test // design/31: "nobody classified an error"
    func anUnclassifiedErrorGetsTheGenericWordsAndAWarning() throws {
        let presented = try #require(Opaque().presented())
        #expect(presented.message.key == "stoic.failure")
        #expect(presented.message.defaultText == "Something went wrong.")
        #expect(presented.recovery == .contactSupport)
        #expect(!presented.isClassified)
        let event = try #require(StoicTest.events.events(named: "failure.presented").last)
        #expect(event.level == .warning)
        #expect(event["reference"]?.description == presented.reference.description)
        #expect(event["classified"]?.description == "false")
    }

    @Test // design/31: "an error is a Defect"
    func aDefectIsOursAndReportedAtErrorLevel() throws {
        let presented = try #require(Report(OurBug()).presented())
        #expect(presented.message.defaultText == "Something went wrong on our side.")
        let event = try #require(StoicTest.events.events(named: "failure.presented").last)
        #expect(event.level == .error)
    }

    @Test func aClassifiedFailureIsReportedAtInfo() throws {
        _ = try #require(Rejection(.bulkheadFull).presented())
        let event = try #require(StoicTest.events.events(named: "failure.presented").last)
        #expect(event.level == .info)
        #expect(event["key"]?.description == "stoic.busy")
        #expect(event["table"]?.description == "Stoic")
        #expect(event["recovery"]?.description == "tryAgain")
    }

    @Test // design/31: "an error's description holds private data"
    func theDescriptionReachesOnlyThePrivateFieldOfTheEvent() throws {
        struct Leaky: Error, CustomStringConvertible {
            var description: String { "SENTINEL-ana@example.com" }
        }
        let errors: [any Error] = [
            Leaky(), Report(Leaky()), operationError(.failed(Leaky()), outcome: .notExecuted),
            operationError(.failed(Leaky()), outcome: .unknown, safety: .keyed),
            LifecycleUpdateError<Reminder, Leaky>.storage(Leaky()),
        ]
        for error in errors {
            let presented = try #require(error.presented())
            #expect(!presented.message.description.contains("SENTINEL"))
            #expect(!presented.message.defaultText.contains("SENTINEL"))
            #expect(presented.message.arguments.isEmpty)
            #expect(!"\(presented)".contains("SENTINEL"))
        }
        for event in StoicTest.events.events(named: "failure.presented") {
            for field in event.fields where field.privacy == .public {
                #expect(!field.value.description.contains("SENTINEL"), "public field \(field.key)")
            }
            let error = try #require(event.fields.first { $0.key == "error" })
            #expect(error.privacy == .private)
            #expect(error.value.description.contains("SENTINEL"), "the event keeps it, privately, for whoever debugs it")
        }
    }

    @Test // design/31: "a presentation carries a server's reference"
    func aServersReferenceIsShownAsItIs() throws {
        let theirs = try #require(SupportReference("K7Q2M-9XD4F"))
        let presented = try #require(Report(ServerSaid(reference: theirs)).presented())
        #expect(presented.reference == theirs)
        let event = try #require(StoicTest.events.events(named: "failure.presented").last)
        #expect(event["reference"]?.description == "K7Q2M-9XD4F")
    }

    @Test func theAmbientPresentersRuleComesAfterPresentableAndBeforeStoics() throws {
        let rule = Wording("app.opaque", default: "The sync engine is busy.")
        let presenter = Presenter.standard
            .adding(Opaque.self, wordings: [rule]) { _ in Presentation(rule, recovery: .tryAgain) }
            .adding(Rejection.self) { $0.reason == .bulkheadFull ? Presentation(rule, recovery: .wait(until: nil)) : nil }
        try withAmbient({ $0.presenter = presenter }) { () throws in
            #expect(try #require(Opaque().presented()).message.key == "app.opaque")
            #expect(try #require(Report(Opaque()).presented()).message.key == "app.opaque", "a rule applies at any layer")
            #expect(try #require(Rejection(.bulkheadFull).presented()).recovery == .wait(until: nil), "a rule overrides Stoic's row")
            #expect(try #require(Rejection(.circuitOpen).presented()).message.key == "stoic.unavailable", "nil passes on")
            #expect(try #require(SyncFailed(underlying: Opaque()).presented()).message.key == "sync.failed")
        }
        #expect(presenter.wordings.contains(rule))
        #expect(presenter.wordings.starts(with: Presenter.standard.wordings))
    }

    @Test func theRuleAddedLastIsAskedFirst() throws {
        let first = Wording("first", default: "First.")
        let second = Wording("second", default: "Second.")
        let presenter = Presenter.standard
            .adding(Opaque.self) { _ in Presentation(first, recovery: .nothing) }
            .adding(Opaque.self) { _ in Presentation(second, recovery: .nothing) }
        try withAmbient({ $0.presenter = presenter }) { () throws in
            #expect(try #require(Opaque().presented()).message.key == "second")
        }
    }

    @Test func theStandardPresentersWordingsAreTheTable() {
        let keys = Set(Presenter.standard.wordings.map(\.key))
        for row in Self.rows where row.key.hasPrefix("stoic.") {
            #expect(keys.contains(row.key), "\(row.key)")
        }
        #expect(keys.contains("stoic.sync"))
        #expect(Presenter.standard.wordings.allSatisfy { $0.table == "Stoic" })
    }

    @Test func aSelfWrappingChainEndsAtTheGenericWords() throws {
        var error: any Error = Opaque()
        for _ in 0..<100 { error = Report(PolicyError<any Error>.failed(error)) }
        // Kept out of the macros, which would describe the whole chain.
        let key = error.presented()?.message.key
        #expect(key == "stoic.failure")
    }

    @Test func presentedRoundTripsThroughJSONShapes() throws {
        let presentation = Presentation(
            Wording("invite.expired", default: "This link expired on {date}.", table: "Invites", arguments: [
                "date": .moment(Self.now), "count": .integer(3), "name": .text("Ana"), "left": .duration(.seconds(90)),
            ]),
            recovery: .changeInput(fields: ["email"]),
            reference: SupportReference("K7Q2M-9XD4F"))
        let recoveries: [Recovery] = [
            .tryAgain, .wait(until: nil), .wait(until: Self.now), .signInAgain, .changeInput(fields: []), .checkFirst,
            .updateApp, .contactSupport, .nothing,
        ]
        #expect(try JSONDecoder().decode(Presentation.self, from: JSONEncoder().encode(presentation)) == presentation)
        for recovery in recoveries {
            #expect(try JSONDecoder().decode(Recovery.self, from: JSONEncoder().encode(recovery)) == recovery)
        }
    }
}

@Suite("Support references", .stoic())
struct SupportReferenceTests {
    @Test func aReferenceIsTenCrockfordSymbolsInTwoGroups() throws {
        let reference = SupportReference.make()
        let text = reference.description
        #expect(text.count == 11)
        #expect(text.split(separator: "-").map(\.count) == [5, 5])
        #expect(text.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ-".contains($0) })
        #expect(SupportReference(text) == reference)
    }

    @Test // design/31: "a person reads a reference back with the wrong case or an O for a 0"
    func readingBackIsForgiving() throws {
        let reference = try #require(SupportReference("K7Q2M-9XD10"))
        #expect(SupportReference("k7q2m9xd10") == reference)
        #expect(SupportReference("K7Q2M 9XD1O") == reference, "O reads as 0")
        #expect(SupportReference("K7Q2M-9XDLO") == reference, "L reads as 1")
        #expect(SupportReference("K7Q2M-9XDI0") == reference, "I reads as 1")
        #expect(SupportReference("K7Q2M-9XD1") == nil, "nine symbols")
        #expect(SupportReference("K7Q2M-9XD100") == nil, "eleven symbols")
        #expect(SupportReference("K7Q2M-9XDU0") == nil, "U is not a symbol")
        #expect(SupportReference("") == nil)
    }

    @Test func aSeededRunDrawsTheSameReferences() async {
        func draw() async -> [String] {
            await withAmbient({ $0.random = .seeded(42) }) {
                (0..<5).map { _ in SupportReference.make().description }
            }
        }
        let first = await draw()
        #expect(first == (await draw()))
        #expect(Set(first).count == 5)
    }

    @Test func everyValueOfFiftyBitsRoundTrips() {
        for value: UInt64 in [0, 1, 31, 32, (1 << 50) - 1, 0x2_A5A5_A5A5_A5A5] {
            let reference = SupportReference(value: value)
            #expect(SupportReference(reference.description) == reference)
        }
    }
}

@Suite("Wordings")
struct WordingTests {
    @Test func theDescriptionFillsPlaceholdersPlainly() {
        let wording = Wording("w", default: "{name} has {count} places left until {when}, {left} from now.", arguments: [
            "name": .text("Beach clean"), "count": .integer(3), "when": .moment(TestClock.wallClockStart),
            "left": .duration(.seconds(90)),
        ])
        #expect(wording.description == "Beach clean has 3 places left until 2026-01-01T00:00:00Z, 90.0 seconds from now.")
    }

    @Test // design/31: "a wording's text names an argument it was not given"
    func aPlaceholderWithNoArgumentIsLeftAsItIs() {
        let wording = Wording("w", default: "Hello {name}, {missing} and {open", arguments: ["name": .text("Ana")])
        #expect(wording.description == "Hello Ana, {missing} and {open")
        #expect(Wording("w", default: "{a}{b}", arguments: ["b": .integer(1)]).description == "{a}1")
        #expect(Wording("w", default: "{{name}}", arguments: ["name": .text("x")]).description == "{x}")
        #expect(Wording("w", default: "no arguments {here}").description == "no arguments {here}")
    }
}

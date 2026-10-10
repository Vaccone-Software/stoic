import StoicJSON
import Synchronization
import Testing

@testable import StoicSchema

struct Point: Sendable, Equatable {
    let x: Double
    let y: Double

    static let schema = Schema.object(Point.self) { f in
        let x = f.field("x", \.x, .double(), doc: "Horizontal.")
        let y = f.field("y", \.y, .double(), doc: "Vertical.")
        return f.build { v in Point(x: v[x], y: v[y]) }
    }
}

struct Segment: Sendable, Equatable {
    let from: Point
    let to: Point
    let label: String?
    let width: Int

    static let schema = Schema.object(Segment.self) { f in
        let from = f.field("from", \.from, Point.schema)
        let to = f.field("to", \.to, Point.schema)
        let label = f.field("label", \.label, .optional(.string(.length(1...20))))
        let width = f.field("width", \.width, .int(.range(1...10)), default: 1, unit: "px")
        return f.build { v in Segment(from: v[from], to: v[to], label: v[label], width: v[width]) }
    }
}

/// An account with a rule that spans two fields.
struct Span: Sendable, Equatable {
    let low: Int
    let high: Int

    static let schema = Schema.object(Span.self) { f in
        let low = f.field("low", \.low, .int())
        let high = f.field("high", \.high, .int())
        return f.build { v throws(ValidationFailure) in
            guard v[low] <= v[high] else {
                throw ValidationFailure(
                    SchemaIssue(
                        path: at("high"), code: .outOfRange, expected: "at least low (\(v[low]))",
                        actual: "\(v[high])"))
            }
            return Span(low: v[low], high: v[high])
        }
    }
}

struct Account: Sendable, Equatable {
    let id: UInt64
    let name: String
    let token: String
    let tags: [String]

    static let schema = Schema.object(Account.self, doc: "A user account.") { f in
        let id = f.field("id", \.id, .uint64(), aliases: ["account_id"])
        let name = f.field("name", \.name, .string(.length(1...40)))
        let token = f.field("token", \.token, .string(.length(8...)), secret: true)
        let tags = f.field("tags", \.tags, .array(of: .string()), default: [])
        return f.build { v in Account(id: v[id], name: v[name], token: v[token], tags: v[tags]) }
    }
}

/// Counts how many times initialisers run, to prove they do not run early.
private let builds = Mutex(0)

struct Counted: Sendable, Equatable {
    let a: Int
    let b: Int

    static let schema = Schema.object(Counted.self) { f in
        let a = f.field("a", \.a, .int())
        let b = f.field("b", \.b, .int())
        return f.build { v in
            builds.withLock { $0 += 1 }
            return Counted(a: v[a], b: v[b])
        }
    }
}

@Suite("Objects without defaults")
struct ObjectReaderTests {
    @Test func decodesWhenEveryFieldIsPresent() {
        let result = Point.schema.decodeReporting(#"{"x": 1.5, "y": -2}"#)
        #expect(result.value == Point(x: 1.5, y: -2))
        #expect(result.issues.isEmpty)
    }

    @Test func missingFieldsAreMissingKeyErrorsAtTheirPaths() {
        let result = Point.schema.decodeReporting("{}")
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.x missing_key", "$.y missing_key"])
        #expect(result.issues[0].message == "missing required key `x`")
    }

    @Test func twoBadCoordinatesAreTwoIssuesNotOne() {
        let result = Point.schema.decodeReporting(#"{"x": "left", "y": [1]}"#)
        #expect(result.issues.locations == ["$.x type_mismatch", "$.y type_mismatch"])
    }

    @Test func aFailureEarlyDoesNotHideALaterFailure() {
        let result = Segment.schema.decodeReporting(#"{"from": 5, "to": {"x": 1}, "width": 99}"#)
        #expect(
            result.issues.locations == [
                "$.from type_mismatch", "$.to.y missing_key", "$.width out_of_range",
            ])
    }

    @Test func theInitialiserRunsOnlyWhenEveryFieldDecoded() {
        let before = builds.withLock { $0 }
        _ = Counted.schema.decodeReporting(#"{"a": 1, "b": "x"}"#)
        _ = Counted.schema.decodeReporting(#"{"a": "x", "b": 1}"#)
        _ = Counted.schema.decodeReporting("{}")
        _ = Counted.schema.decodeReporting(#"{"a": 1, "b": 2, "c": 3}"#)  // unknown key rejected
        #expect(builds.withLock { $0 } == before)
        let ok = Counted.schema.decodeReporting(#"{"a": 1, "b": 2}"#)
        #expect(ok.value == Counted(a: 1, b: 2))
        #expect(builds.withLock { $0 } == before + 1)
    }

    @Test func declaringTheSchemaDoesNotRunTheInitialiser() {
        // The describing pass must never call `build`'s closure.
        let before = builds.withLock { $0 }
        _ = Counted.schema.node
        #expect(builds.withLock { $0 } == before)
    }

    @Test func nestedObjectsAccumulateAcrossLevels() {
        let text = """
            {
              "from": {"x": "a", "y": 2},
              "to": {"x": 1, "y": null},
              "label": "",
              "width": 0
            }
            """
        let result = Segment.schema.decodeReporting(text)
        #expect(
            result.issues.locations == [
                "$.from.x type_mismatch", "$.to.y type_mismatch", "$.label too_short", "$.width out_of_range",
            ])
        #expect(result.issues[0].source?.start.line == 2)
        #expect(result.issues[3].source?.start.line == 5)
    }

    @Test func optionalFieldsAndDefaultsMakeKeysOptional() {
        let result = Segment.schema.decodeReporting(#"{"from": {"x": 0, "y": 0}, "to": {"x": 1, "y": 1}}"#)
        #expect(result.value == Segment(from: Point(x: 0, y: 0), to: Point(x: 1, y: 1), label: nil, width: 1))
    }

    @Test func unknownKeysAreRejectedWithSuggestions() {
        let result = Point.schema.decodeReporting(#"{"x": 1, "y": 2, "z": 3, "xx": 4}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.z unknown_key", "$.xx unknown_key"])
        // Two-letter keys are too short for a guess to mean anything.
        #expect(result.issues.allSatisfy { $0.suggestions.isEmpty })
    }

    @Test func aTypoedRequiredKeyIsBothMissingAndUnknownWithTheHint() {
        let result = Account.schema.decodeReporting(#"{"id": 1, "nmae": "A", "token": "12345678"}"#)
        #expect(result.issues.locations == ["$.name missing_key", "$.nmae unknown_key"])
        #expect(result.issues[1].suggestions == ["name"])
    }

    @Test func aliasesAndRespellingsWork() {
        let result = Account.schema.decodeReporting(#"{"account_id": 7, "Name": "A", "token": "12345678"}"#)
        #expect(result.value == Account(id: 7, name: "A", token: "12345678", tags: []))
        #expect(result.issues.map(\.code) == [.deprecatedKey, .deprecatedKey])
        #expect(result.issues.allSatisfy { $0.severity == .warning })
    }

    @Test func lenientRepairsFieldsWithDefaultsAndLeavesTheRestErrors() {
        let result = Segment.schema.decodeReporting(
            #"{"from": {"x": 0, "y": 0}, "to": {"x": 1}, "width": 99}"#, options: .lenient)
        // `width` has a default and is repaired; `to.y` has none and is not.
        #expect(result.value == nil)
        #expect(result.issues.map(\.severity) == [.error, .repaired])
        let repaired = Segment.schema.decodeReporting(
            #"{"from": {"x": 0, "y": 0}, "to": {"x": 1, "y": 1}, "width": 99}"#, options: .lenient)
        #expect(repaired.value?.width == 1)
        #expect(repaired.issues.map(\.severity) == [.repaired])
        #expect(repaired.issues[0].message.hasSuffix("; used the default 1"))
    }

    @Test func aRuleSpanningFieldsRunsAfterAllFieldsDecoded() {
        #expect(Span.schema.decodeReporting(#"{"low": 1, "high": 2}"#).value == Span(low: 1, high: 2))
        let result = Span.schema.decodeReporting(#"{"low": 5, "high": 2}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.high out_of_range"])
        #expect(result.issues[0].expected == "at least low (5)")
        // Field errors take precedence: the rule never sees a half-built value.
        #expect(Span.schema.decodeReporting(#"{"low": "x", "high": 2}"#).issues.locations == ["$.low type_mismatch"])
    }

    @Test func aThrownRuleIsPlacedUnderTheObjectsOwnPath() {
        struct Holder: Sendable, Equatable { let span: Span }
        let schema = Schema.object(Holder.self) { f in
            let span = f.field("span", \.span, Span.schema)
            return f.build { v in Holder(span: v[span]) }
        }
        let result = schema.decodeReporting("{\n  \"span\": {\"low\": 5, \"high\": 2}\n}")
        #expect(result.issues.locations == ["$.span.high out_of_range"])
        #expect(result.issues[0].source?.start.line == 2)
    }

    @Test func aRuleThatThrowsOnlyWarningsStillFails() {
        struct Never: Sendable, Equatable { let a: Int }
        let schema = Schema.object(Never.self) { f in
            let a = f.field("a", \.a, .int())
            return f.build { v throws(ValidationFailure) in
                _ = v[a]
                throw ValidationFailure(SchemaIssue(severity: .warning, code: .custom))
            }
        }
        let result = schema.decodeReporting(#"{"a": 1}"#)
        #expect(result.value == nil)
        #expect(result.errors.count == 1)
    }

    @Test func secretsAreRedacted() {
        let result = Account.schema.decodeReporting(#"{"id": 1, "name": "A", "token": "short"}"#)
        #expect(result.issues.map(\.code) == [.tooShort])
        #expect(result.issues[0].actual == nil)
        #expect(!result.issues[0].description.contains("short\""))
    }

    @Test func notAnObjectIsAMismatch() {
        #expect(Point.schema.decodeReporting("[1,2]").issues.locations == ["$ type_mismatch"])
    }

    @Test func decodingIsSafeFromManyTasksAtOnce() async {
        let results = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let ok = Point.schema.decodeReporting("{\"x\": \(i), \"y\": 2}").value == Point(x: Double(i), y: 2)
                    let bad = Point.schema.decodeReporting(#"{"x": "a"}"#).issues.count == 2
                    return ok && bad
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 })
    }
}

@Suite("Objects without defaults: declaration and encoding")
struct ObjectReaderDeclarationTests {
    @Test func nodeRecordsRequirednessDocumentationAndPolicy() {
        guard case .object(let node) = Segment.schema.node else { return fail("node") }
        #expect(node.name == "Segment")
        #expect(node.unknownKeys == .reject)
        #expect(node.fields.map(\.key) == ["from", "to", "label", "width"])
        #expect(node.fields.map(\.isRequired) == [true, true, false, false])
        #expect(node.fields[3].unit == "px")
        #expect(node.fields[3].defaultValue == 1)
        guard case .object(let point) = node.fields[0].node else { return fail("point") }
        #expect(point.fields.map(\.doc) == ["Horizontal.", "Vertical."])
        guard case .object(let account) = Account.schema.node else { return fail("account") }
        #expect(account.doc == "A user account.")
        #expect(account.fields[0].aliases == ["account_id"])
        #expect(account.fields[2].isSecret)
    }

    @Test func encodesFromKeyPaths() {
        let segment = Segment(from: Point(x: 0, y: 1), to: Point(x: 2.5, y: 3), label: "edge", width: 4)
        #expect(
            Segment.schema.encode(segment).encodedString(style: .compact)
                == #"{"from":{"x":0,"y":1},"to":{"x":2.5,"y":3},"label":"edge","width":4}"#)
    }

    @Test func roundTrips() {
        let segment = Segment(from: Point(x: -1, y: 1e-3), to: Point(x: 2.5, y: 3), label: nil, width: 7)
        let text = Segment.schema.encode(segment).encodedString()
        #expect(Segment.schema.decodeReporting(text).value == segment)
        let account = Account(id: UInt64.max, name: "Ada", token: "abcdefgh", tags: ["a", "b"])
        #expect(Account.schema.decodeReporting(Account.schema.encode(account).encodedString()).value == account)
    }

    @Test func sparseOmitsDefaultedFieldsButNeverRequiredOnes() {
        let segment = Segment(from: Point(x: 0, y: 0), to: Point(x: 1, y: 1), label: nil, width: 1)
        // `width` is at its default and `label` is nil: both omitted. Points
        // have no defaults, so every coordinate is written.
        #expect(
            Segment.schema.encode(segment, style: .sparse).encodedString(style: .compact)
                == #"{"from":{"x":0,"y":0},"to":{"x":1,"y":1}}"#)
        let wide = Segment(from: Point(x: 0, y: 0), to: Point(x: 1, y: 1), label: "e", width: 2)
        #expect(Segment.schema.encode(wide, style: .sparse).object?.keys == ["from", "to", "label", "width"])
    }

    @Test func sparseIsAFixedPoint() {
        for width in [1, 2] {
            let segment = Segment(from: Point(x: 0, y: 0), to: Point(x: 1, y: 1), label: nil, width: width)
            let once = Segment.schema.encode(segment, style: .sparse)
            let decoded = Segment.schema.decodeReporting(once.encodedString()).value
            #expect(decoded == segment)
            #expect(decoded.map { Segment.schema.encode($0, style: .sparse) } == once)
        }
    }

    @Test func secretsFollowTheStyle() {
        let account = Account(id: 1, name: "A", token: "abcdefgh", tags: [])
        #expect(Account.schema.encode(account).object?["token"] == "abcdefgh")
        #expect(Account.schema.encode(account, style: .fullWithoutSecrets).object?["token"] == nil)
        // A required secret has no default, so sparse keeps it only on request.
        #expect(Account.schema.encode(account, style: .sparse).object?["token"] == nil)
        #expect(Account.schema.encode(account, style: .sparse(includeSecrets: true)).object?["token"] == "abcdefgh")
    }
}

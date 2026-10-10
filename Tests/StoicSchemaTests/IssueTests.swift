import StoicJSON
import Testing

@testable import StoicSchema

@Suite("Issue")
struct IssueTests {
    @Test func descriptionHasPositionPathAndMessage() {
        let source = SourceRange(
            start: SourceLocation(offset: 10, line: 3, column: 7),
            end: SourceLocation(offset: 15, line: 3, column: 12)
        )
        let issue = SchemaIssue(
            path: JSONPath([.key("network"), .key("hosts"), .index(3)]),
            code: .outOfRange,
            expected: "a number between 1 and 5",
            actual: "99",
            source: source
        )
        #expect(issue.description == "3:7 $.network.hosts[3]: 99 is out of range, expected a number between 1 and 5")
    }

    @Test func descriptionWithoutSourceOmitsThePosition() {
        let issue = SchemaIssue(path: at("a"), code: .missingKey, parameters: ["key": "a"])
        #expect(issue.description == "$.a: missing required key `a`")
    }

    @Test func suggestionsAreListedInEnglish() {
        func line(_ suggestions: [String]) -> String {
            SchemaIssue(path: at("k"), code: .unknownKey, suggestions: suggestions).description
        }
        #expect(line(["a"]).hasSuffix("(did you mean `a`?)"))
        #expect(line(["a", "b"]).hasSuffix("(did you mean `a` or `b`?)"))
        #expect(line(["a", "b", "c"]).hasSuffix("(did you mean `a`, `b`, or `c`?)"))
        #expect(!line([]).contains("did you mean"))
    }

    @Test func suggestionIsTheFirstSuggestion() {
        #expect(SchemaIssue(code: .unknownKey, suggestions: ["x", "y"]).suggestion == "x")
        #expect(SchemaIssue(code: .unknownKey).suggestion == nil)
    }

    @Test func warningsAndRepairsSayWhatTheyAre() {
        let warning = SchemaIssue(severity: .warning, path: at("a"), code: .unknownKey, parameters: ["key": "a"])
        #expect(warning.description == "$.a: warning: unknown key `a`")
        let repaired = SchemaIssue(
            severity: .repaired, path: at("a"), code: .outOfRange, parameters: ["repair": "used the default 3"],
            expected: "at most 5", actual: "9")
        #expect(repaired.description == "$.a: repaired: 9 is out of range, expected at most 5; used the default 3")
    }

    @Test func messageIsDerivedNotStored() {
        var issue = SchemaIssue(code: .outOfRange, expected: "at most 5", actual: "9")
        #expect(issue.message == "9 is out of range, expected at most 5")
        issue.actual = nil
        #expect(issue.message == "value is out of range, expected at most 5")
    }

    @Test func everyBuiltInCodeHasAMessageThatIsNotTheFallback() {
        let codes: [IssueCode] = [
            .typeMismatch, .missingKey, .unknownKey, .deprecatedKey, .duplicateKey, .outOfRange, .tooShort,
            .tooLong, .tooFew, .tooMany, .patternMismatch, .notOneOf, .notMultiple, .notUnique,
            .precisionLoss, .notFinite, .custom, .parseError,
        ]
        for code in codes {
            let issue = SchemaIssue(path: at("k"), code: code, expected: "something", actual: "1")
            #expect(!issue.message.isEmpty)
            #expect(issue.message != code.rawValue.replacing("_", with: " "), "\(code) has no message of its own")
        }
    }

    @Test func unknownCodesFallBackToTheirMessageParameter() {
        let code = IssueCode(rawValue: "my_rule")
        let issue = SchemaIssue(code: code, parameters: ["message": "my rule failed"])
        #expect(issue.message == "my rule failed")
        #expect(SchemaIssue(code: code).message == "my rule")
    }

    @Test func codesAreStableStrings() {
        #expect(IssueCode.typeMismatch.rawValue == "type_mismatch")
        #expect(IssueCode.missingKey.rawValue == "missing_key")
        #expect(IssueCode.unknownKey.rawValue == "unknown_key")
        #expect(IssueCode.deprecatedKey.rawValue == "deprecated_key")
        #expect(IssueCode.outOfRange.rawValue == "out_of_range")
        #expect(IssueCode.tooShort.rawValue == "too_short")
        #expect(IssueCode.tooLong.rawValue == "too_long")
        #expect(IssueCode.tooFew.rawValue == "too_few")
        #expect(IssueCode.tooMany.rawValue == "too_many")
        #expect(IssueCode.patternMismatch.rawValue == "pattern_mismatch")
        #expect(IssueCode.notOneOf.rawValue == "not_one_of")
        #expect(IssueCode.notMultiple.rawValue == "not_multiple")
        #expect(IssueCode.notUnique.rawValue == "not_unique")
        #expect(IssueCode.precisionLoss.rawValue == "precision_loss")
        #expect(IssueCode.notFinite.rawValue == "not_finite")
        #expect(IssueCode.custom.rawValue == "custom")
        #expect(IssueCode.parseError.rawValue == "parse_error")
    }
}

@Suite("ValidationFailure")
struct ValidationFailureTests {
    @Test func descriptionIsOneIssuePerLine() {
        let failure = ValidationFailure(issues: [
            SchemaIssue(path: at("a"), code: .missingKey, parameters: ["key": "a"]),
            SchemaIssue(severity: .warning, path: at("b"), code: .unknownKey, parameters: ["key": "b"], suggestions: ["bb"]),
        ])
        #expect(
            failure.description
                == "$.a: missing required key `a`\n$.b: warning: unknown key `b` (did you mean `bb`?)")
    }

    @Test func errorsFiltersOutWarningsAndRepairs() {
        let failure = ValidationFailure(issues: [
            SchemaIssue(severity: .warning, code: .unknownKey),
            SchemaIssue(severity: .error, code: .missingKey),
            SchemaIssue(severity: .repaired, code: .outOfRange),
        ])
        #expect(failure.errors.map(\.code) == [.missingKey])
    }

    @Test func isAnError() {
        let error: any Error = ValidationFailure(SchemaIssue(code: .custom))
        #expect(error is ValidationFailure)
    }
}

@Suite("Did you mean")
struct SuggestionTests {
    @Test func distanceCountsTheFourEdits() {
        func d(_ a: String, _ b: String) -> Int {
            Suggestions.damerauLevenshtein(Array(a.unicodeScalars), Array(b.unicodeScalars))
        }
        #expect(d("", "") == 0)
        #expect(d("abc", "") == 3)
        #expect(d("", "abc") == 3)
        #expect(d("same", "same") == 0)
        #expect(d("kitten", "sitting") == 3)  // two substitutions, one insertion
        #expect(d("teh", "the") == 1)  // a swap is one edit
        #expect(d("ab", "ba") == 1)
        #expect(d("ca", "abc") == 2)  // the unrestricted form; OSA says 3
        #expect(d("flaw", "lawn") == 2)
    }

    @Test func thresholdIsAThirdOfTheLengthCappedAtTwo() {
        #expect(Suggestions.threshold(forLength: 0) == 0)
        #expect(Suggestions.threshold(forLength: 2) == 0)
        #expect(Suggestions.threshold(forLength: 3) == 1)
        #expect(Suggestions.threshold(forLength: 5) == 1)
        #expect(Suggestions.threshold(forLength: 6) == 2)
        #expect(Suggestions.threshold(forLength: 100) == 2)
    }

    @Test func aTypoFindsItsKey() {
        let keys = ["scrollSpeed", "theme", "hosts"]
        #expect(Suggestions.nearest(to: "scrolSpeed", among: keys) == ["scrollSpeed"])
        #expect(Suggestions.nearest(to: "thme", among: keys) == ["theme"])
    }

    @Test func aTranspositionIsOneEdit() {
        #expect(Suggestions.nearest(to: "scrollSpede", among: ["scrollSpeed"]) == ["scrollSpeed"])
        #expect(Suggestions.nearest(to: "tehme", among: ["theme"]) == ["theme"])
    }

    @Test func caseAndSeparatorsDoNotCount() {
        #expect(Suggestions.nearest(to: "Scroll_Speed", among: ["scrollSpeed"]) == ["scrollSpeed"])
        #expect(Suggestions.nearest(to: "scroll-speed", among: ["scrollSpeed"]) == ["scrollSpeed"])
        #expect(Suggestions.nearest(to: "scrol_speed", among: ["scrollSpeed"]) == ["scrollSpeed"])
    }

    @Test func nothingIsSuggestedWhenTooFar() {
        #expect(Suggestions.nearest(to: "zzzzzz", among: ["scrollSpeed", "theme"]) == [])
        #expect(Suggestions.nearest(to: "scrollSpeedAndMore", among: ["scrollSpeed"]) == [])
    }

    @Test func shortInputsOnlyMatchExactlyUpToNormalisation() {
        #expect(Suggestions.nearest(to: "ab", among: ["ac", "abc"]) == [])
        #expect(Suggestions.nearest(to: "A_B", among: ["ab"]) == ["ab"])
    }

    @Test func nearestComesFirstThenDeclarationOrder() {
        let candidates = ["colour", "color", "cooler", "colors"]
        #expect(Suggestions.nearest(to: "color", among: candidates) == ["color", "colour", "colors"])
    }

    @Test func atMostThreeAndNoDuplicates() {
        let many = ["abcd", "abce", "abcf", "abcg", "abch"]
        #expect(Suggestions.nearest(to: "abcx", among: many).count == 3)
        #expect(Suggestions.nearest(to: "abcx", among: many) == ["abcd", "abce", "abcf"])
        #expect(Suggestions.nearest(to: "abcdd", among: ["abcd", "abcd"]) == ["abcd"])
    }

    @Test func isDeterministicAcrossRuns() {
        let candidates = ["delta", "dalta", "delto", "dolta"]
        let first = Suggestions.nearest(to: "delte", among: candidates)
        for _ in 0..<20 {
            #expect(Suggestions.nearest(to: "delte", among: candidates) == first)
        }
    }

    @Test func aHostileLongKeyIsNotMeasured() {
        let key = String(repeating: "a", count: 10_000)
        #expect(Suggestions.nearest(to: key, among: [key]) == [])
    }

    @Test func worksOnUnicodeScalars() {
        #expect(Suggestions.nearest(to: "caf\u{E9}s", among: ["cafes"]) == ["cafes"])
    }
}

@Suite("Reading order")
struct ReadingOrderTests {
    /// Declared in the reverse of the order the file lists them in, which is
    /// how a type is often declared.
    struct Backwards: Sendable, Equatable {
        var third = 3
        var second = 2
        var first = 1

        static let schema = Schema.object(Backwards.self, default: Backwards()) {
            Field("third", \.third, .int(.range(0...10)))
            Field("second", \.second, .int(.range(0...10)))
            Field("first", \.first, .int(.range(0...10)))
        }
    }

    @Test func issuesFromTextFollowThePositionInTheFile() {
        let text = "{\n  \"first\": 99,\n  \"second\": 98,\n  \"third\": 97\n}"
        let result = Backwards.schema.decodeReporting(text)
        #expect(result.issues.locations == ["$.first out_of_range", "$.second out_of_range", "$.third out_of_range"])
        #expect(result.issues.map { $0.source?.start.line } == [2, 3, 4])
    }

    @Test func thePrintedReportReadsTopToBottom() {
        let text = "{\"third\": 97, \"first\": 99,\n \"second\": 98}"
        do throws(ValidationFailure) {
            _ = try Backwards.schema.decode(text)
            Issue.record("expected a failure")
        } catch {
            let lines = error.description.split(separator: "\n").map { $0.prefix(4) }
            #expect(lines == ["1:11", "1:24", "2:12"])
        }
    }

    @Test func positionsOnTheSameLineAreOrderedByColumn() {
        let result = Backwards.schema.decodeReporting(#"{"second": 98, "third": 97, "first": 99}"#)
        #expect(result.issues.map { $0.source?.start.column } == [12, 25, 38])
    }

    @Test func issuesWithTheSamePositionKeepTheOrderTheyWereFound() {
        var issues = [
            SchemaIssue(path: at("a"), code: .tooShort, source: nil), SchemaIssue(path: at("b"), code: .tooLong),
        ]
        #expect(issues.inReadingOrder().locations == ["$.a too_short", "$.b too_long"])
        let start = SourceLocation(offset: 5, line: 1, column: 6)
        let place = SourceRange(start: start, end: start)
        issues[0].source = place
        issues[1].source = place
        #expect(issues.inReadingOrder().locations == ["$.a too_short", "$.b too_long"])
    }

    @Test func withoutTextTheOrderIsAsFound() {
        let result = Backwards.schema.decode(json(#"{"first": 99, "second": 98, "third": 97}"#))
        // Declaration order: the schema's, since there is no file to read.
        #expect(result.issues.locations == ["$.third out_of_range", "$.second out_of_range", "$.first out_of_range"])
    }
}

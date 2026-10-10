#if STOIC_MACROS
import SwiftDiagnostics
import Testing

@Suite("@Schema: constraint attributes")
struct ConstraintExpansionTests {
    @Test func everyConstraintBecomesTheConstraintOfTheSameName() {
        expand(
            """
            @Schema
            struct Limits {
                @Range(200...4000) var speed: Double = 1000
                @GreaterThan(0) @LessThan(1.5) var ratio: Double = 1
                @MultipleOf(5) var step: Int = 5
                @Length(1...64) @Pattern("^[a-z]+$") var name: String = "a"
                @Length(...20, unit: .utf8Bytes) var code = ""
                @Count(0...8) @Unique var tags: [String] = []
                @Count(...50) var map: [String: Int] = [:]
            }
            """,
            to: """
                struct Limits {
                    @Range(200...4000) var speed: Double = 1000
                    @GreaterThan(0) @LessThan(1.5) var ratio: Double = 1
                    @MultipleOf(5) var step: Int = 5
                    @Length(1...64) @Pattern("^[a-z]+$") var name: String = "a"
                    @Length(...20, unit: .utf8Bytes) var code = ""
                    @Count(0...8) @Unique var tags: [String] = []
                    @Count(...50) var map: [String: Int] = [:]

                    static let schema: StoicSchema::Schema<Limits> = StoicSchema::Schema.object(Limits.self, default: Limits()) {
                        StoicSchema::Field("speed", \\.speed, .double(.range(200 ... 4000)))
                        StoicSchema::Field("ratio", \\.ratio, .double(.greaterThan(0), .lessThan(1.5)))
                        StoicSchema::Field("step", \\.step, .int(.multipleOf(5)))
                        StoicSchema::Field("name", \\.name, .string(.length(1 ... 64), .pattern("^[a-z]+$")))
                        StoicSchema::Field("code", \\.code, .string(.length(...20, unit: .utf8Bytes)))
                        StoicSchema::Field("tags", \\.tags, .array(of: .string(), .count(0 ... 8), .unique))
                        StoicSchema::Field("map", \\.map, .dictionary(of: .int(), .count(...50)))
                    }
                }

                extension Limits: StoicSchema::Schematic {
                }
                """)
    }

    @Test func scalarConstraintsReachTheInnermostValue() {
        expand(
            """
            @Schema
            struct Deep {
                @Range(0...9) @Count(1...3) var grid: [[Int]]? = nil
                @Length(1...8) var names: [String: String?] = [:]
                @Range(1...5) var maybe: UInt8? = nil
                @Length(4...) var secret: Secret<String> = Secret("abcd")
            }
            """,
            to: """
                struct Deep {
                    @Range(0...9) @Count(1...3) var grid: [[Int]]? = nil
                    @Length(1...8) var names: [String: String?] = [:]
                    @Range(1...5) var maybe: UInt8? = nil
                    @Length(4...) var secret: Secret<String> = Secret("abcd")

                    static let schema: StoicSchema::Schema<Deep> = StoicSchema::Schema.object(Deep.self, default: Deep()) {
                        StoicSchema::Field("grid", \\.grid, .optional(.array(of: .array(of: .int(.range(0 ... 9))), .count(1 ... 3))))
                        StoicSchema::Field("names", \\.names, .dictionary(of: .optional(.string(.length(1 ... 8)))))
                        StoicSchema::Field("maybe", \\.maybe, .optional(.integer(UInt8.self, [.range(1 ... 5)])))
                        StoicSchema::Field("secret", \\.secret, .transform(base: .string(.length(4...)), decode: {
                                    Secret($0)
                                }, encode: {
                                    $0.reveal()
                                }, describe: "a secret value"), secret: true)
                    }
                }

                extension Deep: StoicSchema::Schematic {
                }
                """)
    }
}

@Suite("@Schema: constraint diagnostics")
struct ConstraintDiagnosticTests {
    @Test func constraintsThatDoNotFitTheType() {
        expand(
            """
            @Schema
            struct Bad {
                @Length(1...5) var count: Int = 0
                @Range(1...5) var name: String = ""
                @Range(1...5) var flag: Bool = false
                @Range(1...5) var port: Port = Port(clamping: 80)
                @Count(1...5) var number: Int = 0
                @Unique var map: [String: Int] = [:]
                @Pattern("a") var list: [Int] = []
            }
            """,
            diagnostics: [
                problem("@Length needs a string, and `count` is `Int`", 3, 5, fixIts: ["remove @Length"]),
                problem("@Range needs a number, and `name` is `String`", 4, 5, fixIts: ["remove @Range"]),
                problem("@Range needs a number, and `flag` is `Bool`", 5, 5, fixIts: ["remove @Range"]),
                problem("@Range cannot be applied to `port`: the macro cannot look inside `Port`, so it cannot tell that it is a number. Put the constraint in that type's own schema (a refined type, or its `@Schema`)", 6, 5, fixIts: ["remove @Range"]),
                problem("@Count applies to an array or a dictionary, and `number` is `Int`", 7, 5, fixIts: ["remove @Count"]),
                problem("@Unique applies to an array; `map` is a dictionary, whose keys are already unique", 8, 5, fixIts: ["remove @Unique"]),
                problem("@Pattern needs a string, and `list` is `[Int]`", 9, 5, fixIts: ["remove @Pattern"]),
            ],
            to: """
                struct Bad {
                    @Length(1...5) var count: Int = 0
                    @Range(1...5) var name: String = ""
                    @Range(1...5) var flag: Bool = false
                    @Range(1...5) var port: Port = Port(clamping: 80)
                    @Count(1...5) var number: Int = 0
                    @Unique var map: [String: Int] = [:]
                    @Pattern("a") var list: [Int] = []
                }
                """)
    }

    @Test func constraintsThatCannotHold() {
        expand(
            """
            @Schema
            struct Bad {
                @Range(10...1) var a: Int = 5
                @Range(1..<1) var b: Int = 1
                @Length(5...1) var c: String = ""
                @Length(-1...3) var d: String = ""
                @Count(3...2) var e: [Int] = []
                @MultipleOf(0) var f: Int = 0
                @Range(1...5) @GreaterThan(10) var g: Int = 3
                @Pattern("(") var h: String = ""
            }
            """,
            diagnostics: [
                problem("`10...1` contains no number: the lower bound is above the upper", 3, 12),
                problem("`1..<1` contains no number: the lower bound is above the upper", 4, 12),
                problem("`5...1` contains no count: the lower bound is above the upper", 5, 13),
                problem("a length cannot be negative", 6, 13),
                problem("`3...2` contains no count: the lower bound is above the upper", 7, 12),
                problem("@MultipleOf needs a step above zero, not 0", 8, 17),
                problem("the constraints on `g` allow no number: @Range(1...5), @GreaterThan(10)", 9, 19),
                problem("\"(\" is not a regular expression Swift can compile: expected ')'", 10, 14),
            ],
            to: """
                struct Bad {
                    @Range(10...1) var a: Int = 5
                    @Range(1..<1) var b: Int = 1
                    @Length(5...1) var c: String = ""
                    @Length(-1...3) var d: String = ""
                    @Count(3...2) var e: [Int] = []
                    @MultipleOf(0) var f: Int = 0
                    @Range(1...5) @GreaterThan(10) var g: Int = 3
                    @Pattern("(") var h: String = ""
                }
                """)
    }

    @Test func defaultsThatBreakTheirOwnConstraints() {
        expand(
            """
            @Schema
            struct Bad {
                @Range(200...4000) var speed: Double = 5000
                @Range(0...9) var neg: Int = -1
                @Length(1...3) var name = "toolong"
                @Length(1...) var empty = ""
                @Count(1...2) var list: [Int] = []
                @Count(...1) var map: [String: Int] = ["a": 1, "b": 2]
                @Length(2...) var each: [String] = ["ok", "x"]
                @Unique var twice: [Int] = [1, 1]
                @MultipleOf(5) var step: Int = 7
                @Range(1...5) var maybe: Int? = 9
                @Range(1...5) var fine: Int? = nil
            }
            """,
            diagnostics: [
                problem("the default of `speed`, 5000, does not satisfy @Range(200...4000); a schema whose default is invalid fails its own checks", 3, 44),
                problem("the default of `neg`, -1, does not satisfy @Range(0...9); a schema whose default is invalid fails its own checks", 4, 34),
                problem("the default of `name`, \"toolong\" (7), does not satisfy @Length(1...3); a schema whose default is invalid fails its own checks", 5, 31),
                problem("the default of `empty`, \"\" (0), does not satisfy @Length(1...); a schema whose default is invalid fails its own checks", 6, 31),
                problem("the default of `list`, [] (0 elements), does not satisfy @Count(1...2); a schema whose default is invalid fails its own checks", 7, 37),
                problem("the default of `map`, [\"a\": 1, \"b\": 2] (2 entries), does not satisfy @Count(...1); a schema whose default is invalid fails its own checks", 8, 43),
                problem("the default of `each`, \"x\" (1), does not satisfy @Length(2...); a schema whose default is invalid fails its own checks", 9, 47),
                problem("the default of `twice`, which repeats 1, does not satisfy @Unique; a schema whose default is invalid fails its own checks", 10, 36),
                problem("the default of `step`, 7, does not satisfy @MultipleOf(5); a schema whose default is invalid fails its own checks", 11, 36),
                problem("the default of `maybe`, 9, does not satisfy @Range(1...5); a schema whose default is invalid fails its own checks", 12, 37),
            ],
            to: """
                struct Bad {
                    @Range(200...4000) var speed: Double = 5000
                    @Range(0...9) var neg: Int = -1
                    @Length(1...3) var name = "toolong"
                    @Length(1...) var empty = ""
                    @Count(1...2) var list: [Int] = []
                    @Count(...1) var map: [String: Int] = ["a": 1, "b": 2]
                    @Length(2...) var each: [String] = ["ok", "x"]
                    @Unique var twice: [Int] = [1, 1]
                    @MultipleOf(5) var step: Int = 7
                    @Range(1...5) var maybe: Int? = 9
                    @Range(1...5) var fine: Int? = nil
                }
                """)
    }

    @Test func nullableAndSecretNeedTheRightType() {
        expand(
            """
            @Schema
            struct Bad {
                @Nullable var plain: Int = 0
                @Secret var already: Secret<String> = Secret("")
            }
            """,
            diagnostics: [
                problem("@Nullable says that `nil` is written as `null`, and `plain` is not optional", 3, 5, fixIts: ["remove @Nullable"]),
                problem("`already` is a `Secret` already, so it is a secret field without @Secret", 4, 5, .warning, fixIts: ["remove @Secret"]),
            ],
            to: """
                struct Bad {
                    var plain: Int = 0
                    var already: Secret<String> = Secret("")
                }
                """)
    }

    @Test func theFixItRemovesTheConstraint() {
        expand(
            """
            @Schema
            struct Bad {
                @Length(1...5) var count: Int = 0
            }
            """,
            diagnostics: [
                problem("@Length needs a string, and `count` is `Int`", 3, 5, fixIts: ["remove @Length"])
            ],
            to: """
                struct Bad {
                    @Length(1...5) var count: Int = 0
                }
                """,
            fixIts: ["remove @Length"],
            fixed: """
                @Schema
                struct Bad {
                    var count: Int = 0
                }
                """)
    }
}
#endif

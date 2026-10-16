#if STOIC_MACROS
import Testing

@Suite("@Refined")
struct RefinedExpansionTests {
    @Test func aRefinementIsItsBaseAndItsConstraints() {
        expand(
            """
            @Refined(Double.self, .range(0.1...10), .finite)
            enum ScrollSpeedRule {}

            @Refined(String.self, .length(1...32), .pattern("^[a-z]+$"))
            public struct SlugRule {}

            @Refined([Int].self, .count(1...3), .unique)
            enum TriadRule {}
            """,
            to: """
                enum ScrollSpeedRule {

                    typealias Base = Double

                    static var constraints: [StoicSchema::Constraint] {
                        [.range(0.1 ... 10), .finite]
                    }
                }
                public struct SlugRule {

                    public typealias Base = String

                    public static var constraints: [StoicSchema::Constraint] {
                        [.length(1 ... 32), .pattern("^[a-z]+$")]
                    }
                }
                enum TriadRule {

                    typealias Base = [Int]

                    static var constraints: [StoicSchema::Constraint] {
                        [.count(1 ... 3), .unique]
                    }
                }

                extension ScrollSpeedRule: StoicSchema::Refinement, StoicSchema::ClampableRefinement {
                }

                extension SlugRule: StoicSchema::Refinement {
                }

                extension TriadRule: StoicSchema::Refinement {
                }
                """)
    }

    @Test func onlyANumberWithRangesAndOneStepCanBeClamped() {
        // Clamping is arithmetic: a pattern, a list of values or a second step
        // has no nearest value, so `init(clamping:)` is not offered.
        expand(
            """
            @Refined(Int.self, .range(0...100), .multipleOf(5))
            enum StepRule {}

            @Refined(Int.self, .oneOf([1, 3]))
            enum OddRule {}

            @Refined(Int.self, .multipleOf(2), .multipleOf(3))
            enum SixRule {}
            """,
            to: """
                enum StepRule {

                    typealias Base = Int

                    static var constraints: [StoicSchema::Constraint] {
                        [.range(0 ... 100), .multipleOf(5)]
                    }
                }
                enum OddRule {

                    typealias Base = Int

                    static var constraints: [StoicSchema::Constraint] {
                        [.oneOf([1, 3])]
                    }
                }
                enum SixRule {

                    typealias Base = Int

                    static var constraints: [StoicSchema::Constraint] {
                        [.multipleOf(2), .multipleOf(3)]
                    }
                }

                extension StepRule: StoicSchema::Refinement, StoicSchema::ClampableRefinement {
                }

                extension OddRule: StoicSchema::Refinement {
                }

                extension SixRule: StoicSchema::Refinement {
                }
                """)
    }

    @Test func constraintsMustFitTheBaseAndHoldTogether() {
        expand(
            """
            @Refined(Int.self, .length(1...3))
            enum A {}

            @Refined(String.self, .range(1...3))
            enum B {}

            @Refined(Int.self, .range(5...1))
            enum C {}

            @Refined([Int].self, .range(1...3))
            enum D {}

            @Refined(Int.self, .range(1...5), .greaterThan(9))
            enum E {}

            @Refined(Int.self, .count(1...3))
            enum F {}
            """,
            diagnostics: [
                problem(".length needs a string, and the base type is `Int`", 1, 20),
                problem(".range needs a number, and the base type is `String`", 4, 23),
                problem("`5...1` contains no number: the lower bound is above the upper", 7, 27),
                problem(".range needs a number, and the base type is `[Int]`", 10, 22),
                problem("the constraints on the base type allow no number: .range(1...5), .greaterThan(9)", 13, 35),
                problem(".count applies to an array or a dictionary, and the base type is `Int`", 16, 20),
            ],
            to: """
                enum A {}
                enum B {}
                enum C {}
                enum D {}
                enum E {}
                enum F {}
                """)
    }

    @Test func theDeclarationAndTheArgumentsAreChecked() {
        expand(
            """
            @Refined(Int.self)
            enum NoConstraints {}

            @Refined(Int, .range(1...3))
            enum NotAMetatype {}

            @Refined
            enum NoArguments {}

            @Refined(Int.self, .range(1...3))
            class NotAValue {}

            @Refined(Set<Int>.self, .count(1...3))
            enum Unsupported {}
            """,
            diagnostics: [
                problem("a refinement with no constraints refines nothing: add `.range(…)`, `.length(…)` or another", 1, 1),
                problem("the first argument of @Refined is the base type, written `Double.self`, not Int", 4, 10),
                problem("@Refined needs the base type first, written `Double.self`, then the constraints", 7, 1),
                problem("@Refined applies to an enum or a struct, which names the refinement", 10, 1),
                problem("the base type: `Set` has no schema: use an array with `@Unique`", 13, 10),
            ],
            to: """
                enum NoConstraints {}
                enum NotAMetatype {}
                enum NoArguments {}
                class NotAValue {}
                enum Unsupported {}
                """)
    }
}
#endif

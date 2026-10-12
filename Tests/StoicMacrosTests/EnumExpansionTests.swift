#if STOIC_MACROS
import Testing

@Suite("@Schema on an enum: the expansion")
struct EnumExpansionTests {
    @Test func rawValuesBecomeAnEnumeration() {
        expand(
            """
            @Schema
            enum Speed: String {
                case slow, fast = "FAST"
            }
            """,
            to: """
                enum Speed: String {
                    case slow, fast = "FAST"

                    static let schema: StoicSchema::Schema<Speed> = StoicSchema::Schema.enumeration(Speed.self)
                }

                extension Speed: StoicSchema::Schematic, CaseIterable {
                }
                """)
    }

    @Test func integerRawValuesBecomeAnIntegerEnumeration() {
        expand(
            """
            @Schema
            public enum Priority: Int, Sendable {
                case low = 1
                case high = 5
            }
            """,
            to: """
                public enum Priority: Int, Sendable {
                    case low = 1
                    case high = 5

                    public static let schema: StoicSchema::Schema<Priority> = StoicSchema::Schema.enumeration(Priority.self)
                }

                extension Priority: StoicSchema::Schematic, CaseIterable {
                }
                """)
    }

    @Test func casesWithValuesBecomeATaggedUnion() {
        expand(
            """
            /// A drawable shape.
            @Schema(discriminator: "kind", valueKey: "payload")
            enum Shape {
                /// A circle.
                case circle(Circle)
                case rect(width: Double, height: Double)
                case label(String)
                case sized(size: Int)
                @Key("pt") case point
                case `default`
                case group([Shape])
                case maybe(Int?)
            }
            """,
            to: """
                /// A drawable shape.
                enum Shape {
                    /// A circle.
                    case circle(Circle)
                    case rect(width: Double, height: Double)
                    case label(String)
                    case sized(size: Int)
                    case point
                    case `default`
                    case group([Shape])
                    case maybe(Int?)

                    static let schema: StoicSchema::Schema<Shape> = StoicSchema::Schema.union(Shape.self, discriminator: "kind", doc: "A drawable shape.", valueKey: "payload") {
                        StoicSchema::Case("circle", Circle.schema, Shape.circle, doc: "A circle.") {
                            if case .circle(let payload) = $0 {
                                payload
                            } else {
                                nil
                            }
                        }
                        StoicSchema::Case("rect", StoicSchema::Schema.object((width: Double, height: Double).self, name: "Shape.rect") { reader in
                            let _width = reader.field("width", \\.width, .double())
                            let _height = reader.field("height", \\.height, .double())
                            return reader.build { values in
                                        (width: values[_width], height: values[_height])
                                    }
                        }, {
                                Shape.rect(width: $0.width, height: $0.height)
                            }) {
                            if case .rect(let width, let height) = $0 {
                                (width: width, height: height)
                            } else {
                                nil
                            }
                        }
                        StoicSchema::Case("label", StoicSchema::Schema<String>.string(), Shape.label) {
                            if case .label(let payload) = $0 {
                                payload
                            } else {
                                nil
                            }
                        }
                        StoicSchema::Case("sized", StoicSchema::Schema<Int>.int(), Shape.sized) {
                            if case .sized(let payload) = $0 {
                                payload
                            } else {
                                nil
                            }
                        }
                        StoicSchema::Case("pt", Shape.point) {
                            if case .point = $0 {
                                true
                            } else {
                                false
                            }
                        }
                        StoicSchema::Case("default", Shape.`default`) {
                            if case .`default` = $0 {
                                true
                            } else {
                                false
                            }
                        }
                        StoicSchema::Case("group", StoicSchema::Schema<[Shape]>.array(of: .lazy {
                                    Shape.schema
                                }), Shape.group) {
                            if case .group(let payload) = $0 {
                                payload
                            } else {
                                nil
                            }
                        }
                        StoicSchema::Case("maybe", StoicSchema::Schema<Int?>.optional(.int()), Shape.maybe) {
                            if case .maybe(let payload) = $0 {
                                payload
                            } else {
                                nil
                            }
                        }
                    }
                }

                extension Shape: StoicSchema::Schematic {
                }
                """)
    }

    @Test func anUnionIsNotCaseIterable() {
        expand(
            """
            @Schema(name: "Wire")
            public enum Message {
                case ping
                case data(Payload)
            }
            """,
            to: """
                public enum Message {
                    case ping
                    case data(Payload)

                    public static let schema: StoicSchema::Schema<Message> = StoicSchema::Schema.union(Message.self, name: "Wire") {
                        StoicSchema::Case("ping", Message.ping) {
                            if case .ping = $0 {
                                true
                            } else {
                                false
                            }
                        }
                        StoicSchema::Case("data", Payload.schema, Message.data) {
                            if case .data(let payload) = $0 {
                                payload
                            } else {
                                nil
                            }
                        }
                    }
                }

                extension Message: StoicSchema::Schematic {
                }
                """)
    }

    @Test func aStructTakesItsVersionsAndKeepsUnknownKeys() {
        expand(
            """
            @Schema(name: "Prefs", unknownKeys: .reject, version: 2, versionKey: "v", missingVersion: .current, migrations: [.from(1, to: 2, .rename("a", to: "b"))])
            struct Prefs {
                var b = 1
            }

            @Schema(version: 3)
            struct Loose {
                var name = ""
                @PreserveUnknownKeys var extra = JSONObject()
            }
            """,
            to: """
                struct Prefs {
                    var b = 1

                    static let schema: StoicSchema::Schema<Prefs> = StoicSchema::Schema.object(Prefs.self, name: "Prefs", default: Prefs(), unknownKeys: .reject, version: 2, versionKey: "v", missingVersion: .current, migrations: [.from(1, to: 2, .rename("a", to: "b"))]) {
                        StoicSchema::Field("b", \\.b, .int())
                    }
                }
                struct Loose {
                    var name = ""
                    var extra = JSONObject()

                    static let schema: StoicSchema::Schema<Loose> = StoicSchema::Schema.object(Loose.self, default: Loose(), version: 3, preservingUnknownKeysIn: \\Loose.extra) {
                        StoicSchema::Field("name", \\.name, .string())
                    }
                }

                extension Prefs: StoicSchema::Schematic {
                }

                extension Loose: StoicSchema::Schematic {
                }
                """)
    }

    @Test func anUnknownCaseOnRawValues() {
        expand(
            """
            @Schema
            enum Standing: String {
                case good, late
                @UnknownCase case unknown
            }
            """,
            to: """
                enum Standing: String {
                    case good, late
                    case unknown

                    static let schema: StoicSchema::Schema<Standing> = StoicSchema::Schema.enumeration(Standing.self, unknownCase: .unknown)
                }

                extension Standing: StoicSchema::Schematic, CaseIterable {
                }
                """)
    }

    @Test func anUnknownCaseThatCarriesTheValue() {
        expand(
            """
            @Schema
            enum Plan {
                case free
                @Key("pro_plan") case pro
                @UnknownCase case other(String)
            }
            """,
            to: """
                enum Plan {
                    case free
                    case pro
                    case other(String)

                    static let schema: StoicSchema::Schema<Plan> = StoicSchema::Schema.openEnumeration(Plan.self, cases: ["free", "pro_plan"], fallback: "other", read: {
                            switch $0 {
                            case "free":
                                Plan.free;
                            case "pro_plan":
                                Plan.pro;
                            default:
                                Plan.other($0)
                            }
                        }, write: {
                            switch $0 {
                            case .free:
                                "free";
                            case .pro:
                                "pro_plan";
                            case .other(let raw):
                                raw
                            }
                        })
                }

                extension Plan: StoicSchema::Schematic {
                }
                """)
    }

    @Test func aPlainUnknownCaseWithoutARawType() {
        expand(
            """
            @Schema
            enum Mood {
                case calm
                @UnknownCase case unclear
            }
            """,
            to: """
                enum Mood {
                    case calm
                    case unclear

                    static let schema: StoicSchema::Schema<Mood> = StoicSchema::Schema.openEnumeration(Mood.self, cases: ["calm", "unclear"], fallback: "unclear", read: {
                            switch $0 {
                            case "calm":
                                Mood.calm;
                            case "unclear":
                                Mood.unclear;
                            default:
                                Mood.unclear
                            }
                        }, write: {
                            switch $0 {
                            case .calm:
                                "calm";
                            case .unclear:
                                "unclear"
                            }
                        })
                }

                extension Mood: StoicSchema::Schematic {
                }
                """)
    }
}
#endif

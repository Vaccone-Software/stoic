#if STOIC_MACROS
import StoicJSON
import StoicMacros
import StoicSchema
import StoicSchemaTesting
import Testing

/// How fast to go.
@Schema
enum Speed: String, Equatable {
    case slow
    case fast = "FAST"
    case ludicrous
}

extension Speed {
    static let byHand: Schema<Speed> = .enumeration(Speed.self)
}

@Schema
enum Priority: Int, Equatable {
    case low = 1
    case high = 5
    case urgent = 10
}

@Schema
struct Circle: Equatable {
    /// The radius.
    @GreaterThan(0) var radius: Double = 1
}

/// A drawable shape.
@Schema(discriminator: "kind")
enum Shape: Equatable {
    /// A circle.
    case circle(Circle)
    /// A rectangle.
    case rect(width: Double, height: Double)
    case label(String)
    @Key("pt") case point
    case group([Shape])
    case sized(size: Int)
    case maybe(Int?)
}

extension Shape {
    static let byHand: Schema<Shape> = .union(Shape.self, discriminator: "kind", doc: "A drawable shape.") {
        Case("circle", Circle.schema, Shape.circle, doc: "A circle.") { if case .circle(let payload) = $0 { payload } else { nil } }
        Case(
            "rect",
            Schema.object((width: Double, height: Double).self, name: "Shape.rect") { reader in
                let _width = reader.field("width", \.width, .double())
                let _height = reader.field("height", \.height, .double())
                return reader.build { values in (width: values[_width], height: values[_height]) }
            }, { Shape.rect(width: $0.width, height: $0.height) }, doc: "A rectangle."
        ) { if case .rect(let width, let height) = $0 { (width: width, height: height) } else { nil } }
        Case("label", Schema<String>.string(), Shape.label) { if case .label(let payload) = $0 { payload } else { nil } }
        Case("pt", Shape.point) { if case .point = $0 { true } else { false } }
        Case("group", Schema<[Shape]>.array(of: .lazy { Shape.schema }), Shape.group) {
            if case .group(let payload) = $0 { payload } else { nil }
        }
        Case("sized", Schema<Int>.int(), Shape.sized) { if case .sized(let payload) = $0 { payload } else { nil } }
        Case("maybe", Schema<Int?>.optional(.int()), Shape.maybe) { if case .maybe(let payload) = $0 { payload } else { nil } }
    }
}

@Suite("@Schema on an enum")
struct EnumTests {
    @Test func aStringEnumerationIsTheLibrarysEnumeration() {
        expectEquivalent(Speed.schema, Speed.byHand, seeds: 0..<6)
        #expect(Speed.schema.decode("FAST").value == .fast)
        #expect(Speed.schema.decode("fast").errors.first?.suggestions == ["FAST"])
        #expect(Speed.allCases.count == 3)
        #expect(expectSchemaSuite(Speed.schema, seed: 1, cases: 40).isClean)
    }

    @Test func anIntegerEnumerationIsTheLibrarysIntegerEnumeration() {
        #expect(Priority.schema.decode(5).value == .high)
        #expect(Priority.schema.decode(2).errors.count == 1)
        #expect(Priority.schema.encode(.urgent) == 10)
        #expect(expectSchemaSuite(Priority.schema, seed: 1, cases: 40).isClean)
    }

    @Test func aUnionIsWrittenTheWayTheLibraryDocuments() {
        expectEquivalent(Shape.schema, Shape.byHand, seeds: 0..<10)
        let decoded = Shape.schema.decode(["kind": "rect", "width": 3, "height": 4])
        #expect(decoded.value == .rect(width: 3, height: 4))
        #expect(Shape.schema.decode(["kind": "pt"]).value == .point)
        #expect(Shape.schema.decode(["kind": "point"]).errors.first?.code == .notOneOf)
        #expect(Shape.schema.decode(["kind": "circle", "radius": 2]).value == .circle(Circle(radius: 2)))
        #expect(Shape.schema.decode(["kind": "label", "value": "hi"]).value == .label("hi"))
    }

    @Test func eachCaseEncodesToItsOwnObject() {
        let schema = Shape.schema
        #expect(schema.encode(.circle(Circle(radius: 2))) == ["kind": "circle", "radius": 2])
        #expect(schema.encode(.rect(width: 1, height: 2)) == ["kind": "rect", "width": 1, "height": 2])
        #expect(schema.encode(.label("x")) == ["kind": "label", "value": "x"])
        #expect(schema.encode(.point) == ["kind": "pt"])
        #expect(schema.encode(.group([.point])) == ["kind": "group", "value": [["kind": "pt"]]])
    }

    @Test func theUnionPassesItsSuite() {
        #expect(expectSchemaSuite(Shape.schema, seed: 4, cases: 80).isClean)
    }
}
#endif

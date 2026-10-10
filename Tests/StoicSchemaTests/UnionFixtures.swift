import StoicJSON
import StoicSchema

struct Circle: Sendable, Equatable {
    var radius: Double = 1
    var filled = false

    static let schema = Schema.object(Circle.self, default: Circle(), unknownKeys: .reject, doc: "A round shape.") {
        Field("radius", \.radius, .double(.greaterThan(0), .range(...1000)), doc: "Distance from the centre.", unit: "pt")
        Field("filled", \.filled, .bool, doc: "Whether the inside is painted.")
    }
}

/// A payload with no defaults: both fields are required.
struct Rect: Sendable, Equatable {
    var width: Int
    var height: Int

    static let schema = Schema.object(Rect.self, doc: "A box.") { f in
        let width = f.field("width", \.width, .int(.range(1...10_000)), doc: "Horizontal extent.")
        let height = f.field("height", \.height, .int(.range(1...10_000)), doc: "Vertical extent.")
        return f.build { v in Rect(width: v[width], height: v[height]) }
    }
}

enum Shape: Sendable, Equatable {
    case circle(Circle)
    case rect(Rect)
    case label(String)
    case point

    static let schema: Schema<Shape> = .union(discriminator: "type", doc: "Something drawable.") {
        Case("circle", Circle.schema, Shape.circle, doc: "A circle.") { if case .circle(let c) = $0 { c } else { nil } }
        Case("rect", Rect.schema, Shape.rect) { if case .rect(let r) = $0 { r } else { nil } }
        Case("label", .string(.length(1...40)), Shape.label) { if case .label(let t) = $0 { t } else { nil } }
        Case("point", Shape.point) { if case .point = $0 { true } else { false } }
    }
}

/// A recursive union: arithmetic over numbers.
indirect enum Expression: Sendable, Equatable {
    case number(Double)
    case sum([Expression])
    case negate(Expression)

    static let schema: Schema<Expression> = .union(Expression.self, discriminator: "op") {
        Case("number", .double(), Expression.number) { if case .number(let n) = $0 { n } else { nil } }
        Case("sum", .array(of: .lazy { Expression.schema }, .count(1...8)), Expression.sum) {
            if case .sum(let terms) = $0 { terms } else { nil }
        }
        Case("negate", .lazy { Expression.schema }, Expression.negate) {
            if case .negate(let inner) = $0 { inner } else { nil }
        }
    }
}

/// A union as a field, beside other things.
struct Canvas: Sendable, Equatable {
    var title = "Untitled"
    var shapes: [Shape] = []
    var background: Shape = .point

    static let schema = Schema.object(Canvas.self, default: Canvas(), unknownKeys: .reject) {
        Field("title", \.title, .string(.length(1...20)), doc: "Name.")
        Field("shapes", \.shapes, .array(of: Shape.schema, count: 0...10), doc: "Drawn in order.")
        Field("background", \.background, Shape.schema, doc: "Drawn first.")
    }
}

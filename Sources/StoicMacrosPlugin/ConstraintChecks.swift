#if STOIC_MACROS
import SwiftSyntax

/// What `@Range`, `@Length` and the others have to be true of a property,
/// found out at compile time where the macro can see enough to say.
///
/// Three kinds of question. Does the constraint fit the type (a `@Length` on
/// an `Int`)? Is it coherent (an empty range, constraints that exclude each
/// other)? Does the default satisfy it, when the default is a literal? All
/// three would otherwise surface as a trap when the schema is first used or
/// a failure in `SchemaSuite`; the point of doing it here is to put the
/// error on the line that is wrong.
func checkConstraints(of field: inout FieldModel, type: ValueType, reporter: Reporter) {
    let startErrors = reporter.errorCount
    let subject = Subject(name: "`\(field.property)`", typeText: field.typeText)
    checkFit(scalar: field.scalar, collection: field.collection, type: type, subject: subject, reporter: reporter)
    if reporter.errorCount > startErrors { return }
    let allowed = checkCoherence(
        scalar: field.scalar, collection: field.collection, subject: subject, anchor: field.node, reporter: reporter)
    if reporter.errorCount > startErrors { return }

    // The default, when it is a literal.
    if let value = field.defaultValue {
        checkDefault(value, type: type, field: field, allowed: allowed, reporter: reporter)
    }
}

/// What a constraint is about, in the words of a message.
struct Subject {
    /// `` `speed` `` for a property, "the base type" for a refinement.
    var name: String
    var typeText: String
}

/// Does each constraint fit the type it is about?
func checkFit(scalar: [Marker], collection: [Marker], type: ValueType, subject: Subject, reporter: Reporter) {
    for marker in scalar {
        let leaf = type.leaf
        let fits =
            (marker.kind.constrainsNumbers && (leaf == .number || leaf == .decimal)) || (marker.kind.constrainsStrings && leaf == .string)
        if !fits {
            let wanted = marker.kind.constrainsNumbers ? "a number" : "a string"
            let message: String
            if leaf == .named {
                message =
                    "\(marker.name) cannot be applied to \(subject.name): the macro cannot look inside `\(subject.typeText)`, so it cannot tell that it is \(wanted). Put the constraint in that type's own schema (a refined type, or its `@Schema`)"
            } else {
                message = "\(marker.name) needs \(wanted), and \(subject.name) is `\(subject.typeText)`"
            }
            reporter.error(
                marker.node, Problem(id: "constraint-type-mismatch", message: message),
                fixIts: marker.removalFixIts)
        }
    }
    for marker in collection {
        let outer = type.collection
        let fits = outer != nil && (marker.kind == .count || outer?.isArray == true)
        if !fits {
            let message: String
            if marker.kind == .unique, outer != nil {
                message = "\(marker.name) applies to an array; \(subject.name) is a dictionary, whose keys are already unique"
            } else {
                message = "\(marker.name) applies to an array or a dictionary, and \(subject.name) is `\(subject.typeText)`"
            }
            reporter.error(
                marker.node, Problem(id: "constraint-type-mismatch", message: message),
                fixIts: marker.removalFixIts)
        }
    }
}

/// Is each constraint possible, and are the numeric ones together? Returns
/// the numbers they allow, as far as they are literal.
func checkCoherence(
    scalar: [Marker], collection: [Marker], subject: Subject, anchor: Syntax, reporter: Reporter
) -> Interval {
    let startErrors = reporter.errorCount
    for marker in scalar + collection { checkCoherent(marker, reporter: reporter) }
    if reporter.errorCount > startErrors { return Interval() }
    var allowed = Interval()
    for marker in scalar where marker.kind.constrainsNumbers {
        if let interval = interval(of: marker) { allowed.intersect(interval) }
    }
    if allowed.isEmpty {
        let numeric = scalar.filter { $0.kind.constrainsNumbers }
        reporter.error(
            numeric.last?.node ?? anchor,
            Problem(
                id: "contradictory-constraints",
                message: "the constraints on \(subject.name) allow no number: \(numeric.map { $0.node.trimmedDescription }.joined(separator: ", "))"
            ))
    }
    return allowed
}

private func checkCoherent(_ marker: Marker, reporter: Reporter) {
    switch marker.kind {
    case .range:
        if let argument = marker.arguments.first, let range = rangeLiteral(argument.expression),
            let low = range.lowerBound, let high = range.upperBound,
            Interval(lower: low, upper: high).isEmpty
        {
            reporter.error(
                argument.expression,
                Problem(id: "empty-range", message: "`\(argument.expression.trimmedDescription)` contains no number: the lower bound is above the upper"))
        }
    case .length, .count:
        guard let argument = marker.arguments.first, let (low, high) = counts(of: marker) else { return }
        if let low, low < 0 {
            reporter.error(
                argument.expression,
                Problem(id: "negative-count", message: "\(marker.kind == .length ? "a length" : "a count") cannot be negative"))
        } else if let low, let high, low > high {
            reporter.error(
                argument.expression,
                Problem(id: "empty-range", message: "`\(argument.expression.trimmedDescription)` contains no count: the lower bound is above the upper"))
        }
    case .multipleOf:
        if let argument = marker.arguments.first, let step = number(of: argument.expression), step <= 0 {
            reporter.error(
                argument.expression, Problem(id: "bad-step", message: "@MultipleOf needs a step above zero, not \(argument.expression.trimmedDescription)"))
        }
    case .pattern:
        guard let argument = marker.arguments.first else { return }
        if let (value, _) = plainStringLiteral(argument.expression) {
            do {
                _ = try Regex(value)
            } catch {
                reporter.error(
                    argument.expression,
                    Problem(id: "bad-pattern", message: "\(argument.expression.trimmedDescription) is not a regular expression Swift can compile: \(error)"))
            }
        }
    default:
        break
    }
}

/// Checks a literal default against the constraints of its property.
private func checkDefault(
    _ value: ExprSyntax, type: ValueType, field: FieldModel, allowed: Interval, reporter: Reporter
) {
    switch type {
    case .optional(let wrapped), .secret(let wrapped):
        // `Secret("…")` and `nil` are not literals of the wrapped type.
        if case .secret = type { return }
        checkDefault(value, type: wrapped, field: field, allowed: allowed, reporter: reporter)
    case .integer, .double, .decimal:
        guard let literal = number(of: value) else { return }
        for marker in field.scalar where marker.kind.constrainsNumbers {
            if let interval = interval(of: marker), !interval.contains(literal) {
                report(value, "\(value.trimmedDescription)", marker, field, reporter)
            } else if marker.kind == .multipleOf, let step = marker.arguments.first.flatMap({ number(of: $0.expression) }),
                step > 0, let whole = Int(exactly: literal), let wholeStep = Int(exactly: step), whole % wholeStep != 0
            {
                report(value, "\(value.trimmedDescription)", marker, field, reporter)
            }
        }
    case .string:
        guard let (text, _) = plainStringLiteral(value) else { return }
        for marker in field.scalar where marker.kind == .length {
            guard let (low, high) = counts(of: marker) else { continue }
            let measured = length(of: text, unit: lengthUnit(of: marker))
            let tooShort = low.map { measured < $0 } ?? false
            let tooLong = high.map { measured > $0 } ?? false
            if tooShort || tooLong {
                report(value, "\(value.trimmedDescription) (\(measured))", marker, field, reporter)
            }
        }
    case .array(let element):
        guard let array = value.as(ArrayExprSyntax.self) else { return }
        for marker in field.collection where marker.kind == .count {
            guard let (low, high) = counts(of: marker) else { continue }
            let measured = array.elements.count
            if low.map({ measured < $0 }) == true || high.map({ measured > $0 }) == true {
                report(value, "\(value.trimmedDescription) (\(measured) elements)", marker, field, reporter)
            }
        }
        var seen: Set<String> = []
        for item in array.elements {
            checkDefault(item.expression, type: element, field: stripped(field), allowed: allowed, reporter: reporter)
            if field.collection.contains(where: { $0.kind == .unique }), !seen.insert(item.expression.trimmedDescription).inserted {
                if let marker = field.collection.first(where: { $0.kind == .unique }) {
                    report(item.expression, "which repeats \(item.expression.trimmedDescription)", marker, field, reporter)
                }
            }
        }
    case .dictionary(let element):
        guard let dictionary = value.as(DictionaryExprSyntax.self) else { return }
        var entries = 0
        if case .elements(let list) = dictionary.content {
            entries = list.count
            for entry in list { checkDefault(entry.value, type: element, field: stripped(field), allowed: allowed, reporter: reporter) }
        }
        for marker in field.collection where marker.kind == .count {
            guard let (low, high) = counts(of: marker) else { continue }
            if low.map({ entries < $0 }) == true || high.map({ entries > $0 }) == true {
                report(value, "\(value.trimmedDescription) (\(entries) entries)", marker, field, reporter)
            }
        }
    default:
        break
    }
}

/// The field as its elements see it: the collection's own constraints are
/// about the collection.
private func stripped(_ field: FieldModel) -> FieldModel {
    var copy = field
    copy.collection = []
    return copy
}

private func report(_ node: some SyntaxProtocol, _ what: String, _ marker: Marker, _ field: FieldModel, _ reporter: Reporter) {
    reporter.error(
        node,
        Problem(
            id: "default-violates-constraint",
            message: "the default of `\(field.property)`, \(what), does not satisfy \(marker.node.trimmedDescription); a schema whose default is invalid fails its own checks"))
}
#endif

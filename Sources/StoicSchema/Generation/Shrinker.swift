internal import StoicJSON

/// Proposes simpler versions of a valid document, simplest first.
///
/// Shrinking is structural, toward the minima the schema itself states:
/// numbers toward zero or the nearest bound, strings toward the shortest
/// length, collections toward their minimum count, fields toward their
/// defaults or toward absence. Candidates are only proposals; the caller
/// decodes each and keeps those the schema accepts, so a proposal that
/// breaks a rule the shrinker does not understand costs nothing.
enum Shrinker {
    static func candidates(_ node: SchemaNode, _ value: JSONValue) -> [JSONValue] {
        var found: [JSONValue] = []
        switch node {
        case .boolean:
            if value == .bool(true) { found.append(.bool(false)) }

        case .integer(let type, let constraints):
            found = integers(type, constraints, value)

        case .number(let constraints):
            found = doubles(constraints, value)

        case .string(let constraints):
            found = strings(constraints, value)

        case .enumeration(_, let cases):
            if let first = cases.first, value != .string(first) { found.append(.string(first)) }

        case .integerEnumeration(_, let cases):
            if let first = cases.first, value != .number(JSONNumber(first.value)) {
                found.append(.number(JSONNumber(first.value)))
            }

        case .array(let element, let constraints):
            guard case .array(let items) = value else { break }
            let low = minimumCount(constraints)
            if items.count > low {
                found.append(.array(Array(items.prefix(low))))
                for index in items.indices.prefix(8) {
                    var fewer = items
                    fewer.remove(at: index)
                    if fewer.count >= low { found.append(.array(fewer)) }
                }
            }
            for index in items.indices.prefix(4) {
                for smaller in candidates(element, items[index]) {
                    var copy = items
                    copy[index] = smaller
                    found.append(.array(copy))
                }
            }

        case .dictionary(let element, let constraints):
            guard case .object(let entries) = value else { break }
            let low = minimumCount(constraints)
            if entries.count > low {
                found.append(.object(JSONObject(entries.prefix(low))))
                for member in entries.prefix(8) {
                    var fewer = entries
                    fewer[member.key] = nil
                    if fewer.count >= low { found.append(.object(fewer)) }
                }
            }
            for member in entries.prefix(4) {
                for smaller in candidates(element, member.value) {
                    var copy = entries
                    copy[member.key] = smaller
                    found.append(.object(copy))
                }
            }

        case .optional(let wrapped, _):
            if !value.isNull { found = candidates(wrapped, value) }

        case .json:
            if value != .null { found.append(.null) }

        case .object(let object):
            guard case .object(let members) = value else { break }
            for field in object.fields {
                guard let present = members[field.key] else { continue }
                if !field.isRequired {
                    var without = members
                    without[field.key] = nil
                    found.append(.object(without))
                }
                if let fallback = field.defaultValue, fallback != present {
                    var reset = members
                    reset[field.key] = fallback
                    found.append(.object(reset))
                }
            }
            for field in object.fields {
                guard let present = members[field.key] else { continue }
                for smaller in candidates(field.node, present) {
                    var copy = members
                    copy[field.key] = smaller
                    found.append(.object(copy))
                }
            }

        case .transformed(let transform):
            if let first = transform.examples.first, first != value { found.append(first) }
            if transform.examples.isEmpty { found.append(contentsOf: candidates(transform.base, value)) }

        case .union(let union):
            guard case .object(let members) = value, case .string(let tag)? = members[union.discriminator],
                let entry = union.cases.first(where: { ExactKey($0.tag) == ExactKey(tag) })
            else { break }
            if entry.isFlat {
                found = candidates(entry.node, value)
            } else if let payload = members[union.valueKey] {
                for smaller in candidates(entry.node, payload) {
                    var copy = members
                    copy[union.valueKey] = smaller
                    found.append(.object(copy))
                }
            }

        case .lazy(_, let resolve):
            found = candidates(resolve(), value)
        }
        return found.filter { $0 != value }
    }

    private static func minimumCount(_ constraints: [Constraint]) -> Int {
        var low = 0
        for constraint in constraints {
            if case .count(let range) = constraint.kind { low = max(low, range.lower ?? 0) }
        }
        return low
    }

    private static func integers(_ type: IntegerType, _ constraints: [Constraint], _ value: JSONValue) -> [JSONValue] {
        guard case .number(let number) = value, let current = number.integralInt64.map({ Int128($0) })
            ?? number.integralUInt64.map({ Int128($0) })
        else { return [] }
        let (low, high) = ValueMaker.integerBounds(type, constraints)
        let target = min(max(0, low), high)
        guard current != target else { return [] }
        let toward: Int128 = current > target ? -1 : 1
        let candidates: [Int128] = [target, current + (target - current) / 2, current + toward]
        return candidates.map { .number(JSONNumber($0)) }
    }

    private static func doubles(_ constraints: [Constraint], _ value: JSONValue) -> [JSONValue] {
        guard case .number(let number) = value, let current = number.double else { return [] }
        var low = -Double.infinity
        var high = Double.infinity
        for constraint in constraints {
            guard case .range(let range) = constraint.kind else { continue }
            if let bound = range.lower?.value.double { low = max(low, bound) }
            if let bound = range.upper?.value.double { high = min(high, bound) }
        }
        let target = min(max(0, low), high)
        var candidates = [target, current + (target - current) / 2, current.rounded(.towardZero), (current * 10).rounded() / 10]
        candidates.append(contentsOf: [low.isFinite ? low : target, high.isFinite ? high : target])
        return candidates.compactMap { JSONNumber($0).map { .number($0) } }
    }

    private static func strings(_ constraints: [Constraint], _ value: JSONValue) -> [JSONValue] {
        guard case .string(let text) = value else { return [] }
        var floor = 0
        for constraint in constraints {
            if case .length(let range, let unit) = constraint.kind, unit == .characters { floor = max(floor, range.lower ?? 0) }
        }
        let scalars = Array(text.unicodeScalars)
        func string(_ slice: some Sequence<Unicode.Scalar>) -> JSONValue {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: slice)
            return .string(String(view))
        }
        var found: [JSONValue] = []
        if floor == 0 { found.append(.string("")) }
        found.append(string(scalars.prefix(floor)))
        found.append(.string(String(repeating: "a", count: floor)))
        if scalars.count > floor {
            found.append(string(scalars.prefix(max(floor, scalars.count / 2))))
            found.append(string(scalars.dropLast()))
        }
        found.append(.string(String(repeating: "a", count: scalars.count)))
        return found
    }
}

internal import StoicJSON

extension Versioning {
    /// What reading the version of an object decided.
    struct Gate {
        /// The object to decode: migrated, and with the version key removed
        /// unless the document is newer than the schema and preserved.
        var object: JSONObject
        /// Whether any step was applied, so positions in the original text
        /// no longer describe the object.
        var migrated: Bool
    }

    /// Reads an object's version and, if it is older than the schema's,
    /// migrates it step by step. Records the issues; returns `nil` exactly
    /// when it recorded an error.
    ///
    /// The version key is reserved: it is removed from the object here (the
    /// object's fields never see it, so a schema that rejects unknown keys
    /// does not reject it) and written back by the encoder.
    ///
    /// - Parameter preservesUnknown: Whether the object keeps keys it does
    ///   not declare. A document newer than the schema is then read as if
    ///   it were current, its extra keys (the newer version number among
    ///   them) kept for the next write, because refusing it would make an
    ///   old release the end of a file's life, and rewriting it would
    ///   destroy what the new release put there.
    func gate(_ object: JSONObject, preservesUnknown: Bool, state: inout DecodeState) -> Gate? {
        var version = oldest
        if let value = object[key] {
            state.push(key: key)
            defer { state.pop() }
            guard case .number(let number) = value else {
                state.typeMismatch(expected: "a positive integer", found: value)
                return nil
            }
            guard number.isInteger || number.hasIntegralValue, let found = number.integralInt64 else {
                state.typeMismatch(expected: "a positive integer", found: value)
                return nil
            }
            guard found >= 1, found <= Int64(Int32.max) else {
                state.report(.outOfRange, expected: "a positive integer", actual: number.lexeme)
                return nil
            }
            version = Int(found)
        } else {
            switch missing {
            case .oldest: version = oldest
            case .current: version = current
            case .error:
                state.report(
                    .missingKey, path: state.path.appending(key: key), sourcePath: state.inputPath,
                    parameters: ["key": .string(key)], expected: "a positive integer")
                return nil
            }
        }

        if version > current {
            state.push(key: key)
            defer { state.pop() }
            let parameters: JSONObject = [
                "version": .number(JSONNumber(version)), "supported": .number(JSONNumber(current)),
            ]
            if preservesUnknown {
                state.report(.versionTooNew, severity: .warning, parameters: parameters)
                return Gate(object: object, migrated: false)
            }
            state.report(.versionTooNew, parameters: parameters, expected: "version \(current) or older")
            return nil
        }

        var rest = object
        rest[key] = nil
        guard version < current else { return Gate(object: rest, migrated: false) }

        var document = JSONValue.object(rest)
        var migrated = false
        while version < current {
            guard let step = step(from: version) else {
                state.push(key: key)
                state.report(
                    .versionUnsupported,
                    parameters: [
                        "version": .number(JSONNumber(version)), "oldest": .number(JSONNumber(oldest)),
                        "current": .number(JSONNumber(current)),
                    ])
                state.pop()
                return nil
            }
            let parameters: JSONObject = [
                "from": .number(JSONNumber(step.from)), "to": .number(JSONNumber(step.to)),
                "operations": .array(step.operations.map { .string($0.description) }),
            ]
            do throws(MigrationFailure) {
                try step.apply(to: &document)
            } catch {
                var failed = parameters
                failed["message"] = .string(error.message)
                state.report(.migrationFailed, parameters: failed)
                return nil
            }
            state.report(.migrated, severity: .warning, parameters: parameters)
            migrated = true
            version = step.to
        }
        guard case .object(let result) = document else {
            state.report(
                .migrationFailed,
                parameters: ["message": .string("a custom operation replaced the document by something that is not an object")])
            return nil
        }
        return Gate(object: result, migrated: migrated)
    }

    /// The object as written: the version first, unless the object already
    /// carries a newer one (a document from a newer release, preserved).
    func stamp(_ members: JSONObject) -> JSONObject {
        if case .number(let kept)? = members[key], let newer = kept.integralInt64, newer > Int64(current) {
            return members
        }
        var stamped = JSONObject()
        stamped[key] = .number(JSONNumber(current))
        for member in members where !ExactKey(member.key).isEqual(to: key) { stamped[member.key] = member.value }
        return stamped
    }
}

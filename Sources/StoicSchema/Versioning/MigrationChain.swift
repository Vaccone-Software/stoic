public import StoicJSON

/// What ``Schema/migrationChainCheck(cases:seed:)`` found.
public struct MigrationChainReport: Sendable, CustomStringConvertible {
    /// A document that did not migrate to a valid current one.
    public struct Failure: Sendable {
        /// The document as the older version would have written it.
        public var oldDocument: JSONValue
        /// What the schema made of it.
        public var issues: [Issue]
        public var summary: String
    }

    /// The result for one migration step.
    public struct Step: Sendable {
        public var from: Int
        public var to: Int
        /// How many generated documents were migrated.
        public var documentsChecked: Int
        /// Why the step could not be tested, if it could not: an operation
        /// with no inverse, so no old document can be made.
        public var unchecked: String?
        /// Facts about the step the check could not pin down (a deleted
        /// field with no example of its old value): not failures, but
        /// coverage the author could add.
        public var gaps: [String]
        public var failures: [Failure]
    }

    public var steps: [Step]
    /// Problems with the history as a whole: a schema that is not
    /// versioned, a chain that does not reach the current version.
    public var problems: [String]

    /// Whether every step that could be tested passed and the history is
    /// sound. Steps that could not be tested do not count as passing; see
    /// ``untested``.
    public var isClean: Bool {
        problems.isEmpty && steps.allSatisfy { $0.failures.isEmpty }
    }

    /// The steps that could not be tested.
    public var untested: [Step] { steps.filter { $0.unchecked != nil } }

    public var description: String {
        var lines = problems.map { "problem: \($0)" }
        for step in steps {
            var line = "version \(step.from) to \(step.to): "
            if let why = step.unchecked {
                line += "not tested (\(why))"
            } else {
                line += "\(step.documentsChecked) documents, \(step.failures.count) failed"
            }
            lines.append(line)
            for gap in step.gaps { lines.append("  gap: \(gap)") }
            for failure in step.failures.prefix(3) {
                lines.append("  \(failure.summary)")
                lines.append("    old document: \(failure.oldDocument.encodedString(style: .compact))")
                for issue in failure.issues.filter({ $0.severity == .error }) { lines.append("    \(issue)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension Schema {
    /// Proves the history of a versioned schema leads somewhere valid.
    ///
    /// A migration is code that runs on a user's file once, unobserved, so
    /// it is worth testing against more than the three files a person
    /// remembered to keep. But the old schemas are gone: the point of
    /// migrating JSON is that old Swift types need not be kept. So the check
    /// works backwards. It generates documents valid at the *current*
    /// version, runs each step of the history in reverse to build a document
    /// the older release could have written (a renamed field gets its old
    /// name, a pinned field is removed, a moved one goes back), and then
    /// decodes that document with the full schema. It must come out the
    /// other end valid, having been migrated through every step after it.
    ///
    /// A step is tested only if all the steps from it on can be run
    /// backwards: the declarative operations can (a `delete` needs an
    /// `example` to restore, or its deleted field is simply absent from the
    /// old documents, reported as a gap; a `mapEnum` that merges two values
    /// cannot), and a `custom` one can if it gave an `inverse`. A step that
    /// cannot is reported as untested rather than passed.
    ///
    /// This complements the time capsule (golden documents from real
    /// releases, kept in the test target): the capsule proves the files that
    /// exist, the chain check proves the ones that could.
    ///
    /// - Parameters:
    ///   - cases: How many documents to migrate per step.
    ///   - seed: Reproduces the documents.
    public func migrationChainCheck(cases: Int = 30, seed: UInt64 = 0) -> MigrationChainReport {
        guard case .object(let node) = self.node, let versioning = node.versioning else {
            return MigrationChainReport(
                steps: [], problems: ["the schema is not a versioned object, so it has no migrations to check"])
        }
        var problems: [String] = []
        var chains: [Int: [Migration]] = [:]
        for first in versioning.migrations {
            var chain: [Migration] = []
            var step: Migration? = first
            while let next = step {
                chain.append(next)
                step = versioning.step(from: next.to)
            }
            if chain.last?.to != versioning.current {
                problems.append("the migrations from version \(first.from) end at version \(chain.last?.to ?? first.from), not \(versioning.current)")
            }
            chains[first.from] = chain
        }

        let generator = self.generator
        var random = SplitMix64(seed: seed)
        var documents: [JSONValue] = []
        for _ in 0..<cases {
            guard let sample = try? generator.sample(using: &random) else { continue }
            documents.append(sample.document)
        }
        if documents.isEmpty {
            problems.append("no valid current document could be generated to run the migrations backwards from")
        }

        // A rename or move writes to a path the next version reads; if no
        // generated document of that version ever has the path, the step
        // names a field the schema does not have, which no old document
        // would reveal because the inverse would have nothing to undo.
        var targetsSeen: [Int: Set<Int>] = [:]
        let allSteps = versioning.migrations.sorted { $0.from > $1.from }  // newest first
        for current in documents {
            var document = current
            for step in allSteps {
                for (index, operation) in step.operations.enumerated() {
                    if let target = operation.target, case .object(let root) = document,
                        PathEdit.value(at: PathEdit.split(target)[...], in: root) != nil
                    {
                        targetsSeen[step.from, default: []].insert(index)
                    }
                }
                guard let inverse = step.inverted() else { break }
                var broke = false
                do throws(MigrationFailure) {
                    for operation in inverse.operations { try operation.apply(to: &document) }
                } catch {
                    broke = true
                }
                if broke { break }
            }
        }

        var steps: [MigrationChainReport.Step] = []
        for first in versioning.migrations.sorted(by: { $0.from < $1.from }) {
            var report = MigrationChainReport.Step(
                from: first.from, to: first.to, documentsChecked: 0, unchecked: nil, gaps: [], failures: [])
            guard let chain = chains[first.from] else { continue }
            var inverses: [(Migration, [Migration.Operation])] = []
            for step in chain.reversed() {
                guard let inverse = step.inverted() else {
                    report.unchecked = "version \(step.from) to \(step.to) has an operation with no inverse"
                    break
                }
                report.gaps.append(contentsOf: inverse.gaps.map { "\(step.from) to \(step.to): \($0)" })
                inverses.append((step, inverse.operations))
            }
            if report.unchecked == nil, !documents.isEmpty {
                for (index, operation) in first.operations.enumerated() where operation.target != nil {
                    if !(targetsSeen[first.from]?.contains(index) ?? false) {
                        report.failures.append(
                            .init(
                                oldDocument: .null, issues: [],
                                summary: "\"\(operation)\" writes to `\(operation.target ?? "")`, which no generated document of version \(first.to) has: is it a field of the schema?"
                            ))
                    }
                }
            }
            if report.unchecked != nil {
                steps.append(report)
                continue
            }
            for current in documents {
                var old = current
                var broken: String?
                for (step, operations) in inverses {
                    do throws(MigrationFailure) {
                        for operation in operations { try operation.apply(to: &old) }
                    } catch {
                        broken = "the inverse of version \(step.from) to \(step.to) failed: \(error.message)"
                        break
                    }
                    if case .object(var object) = old {
                        object[versioning.key] = .number(JSONNumber(step.from))
                        old = .object(object)
                    }
                }
                report.documentsChecked += 1
                if let broken {
                    report.failures.append(.init(oldDocument: old, issues: [], summary: broken))
                    continue
                }
                let result = decode(old, options: .strict)
                let applied = result.issues.filter { $0.code == .migrated }.count
                if !result.errors.isEmpty {
                    report.failures.append(
                        .init(oldDocument: old, issues: result.issues, summary: "an old document does not migrate to a valid one"))
                } else if applied != chain.count {
                    report.failures.append(
                        .init(
                            oldDocument: old, issues: result.issues,
                            summary: "expected \(chain.count) migrations to be applied, saw \(applied)"))
                }
            }
            steps.append(report)
        }
        return MigrationChainReport(steps: steps, problems: problems)
    }
}

extension Migration.Operation {
    /// The path the operation writes a value the schema is expected to read,
    /// for those that do: the new name of a rename, the destination of a
    /// move, the field of a mapped enumeration.
    var target: String? {
        switch kind {
        case .rename(let path, let name):
            var keys = PathEdit.split(path)
            keys.removeLast()
            return (keys + [name]).joined(separator: ".")
        case .move(_, let to): return to
        case .mapEnum(let path, _): return path
        case .delete, .setIfAbsent, .pinDefault, .custom: return nil
        }
    }
}

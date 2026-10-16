#if STOIC_MACROS
import SwiftSyntax

/// What was written inside `@Schema(…)`, by label.
///
/// The arguments are passed to the library as they were written (the macro
/// does not interpret `unknownKeys: .reject`, it copies it), and the macro
/// checks only what it can: that a label belongs to the kind of type it is
/// on, and that the ones that need each other come together.
struct SchemaArguments {
    var node: AttributeSyntax
    var byLabel: [String: LabeledExprSyntax] = [:]

    init(_ attribute: AttributeSyntax) {
        node = attribute
        if case .argumentList(let list)? = attribute.arguments {
            for argument in list {
                if let label = argument.label?.text { byLabel[label] = argument }
            }
        }
    }

    func text(_ label: String) -> String? {
        byLabel[label]?.expression.trimmedDescription
    }

    func has(_ label: String) -> Bool { byLabel[label] != nil }

    /// `label: value` for the labels present, in the order given, ready for
    /// a call.
    func passed(_ labels: [String]) -> [String] {
        labels.compactMap { label in text(label).map { "\(label): \($0)" } }
    }

    static let structLabels = [
        "name", "unknownKeys", "spellings", "version", "versionKey", "missingVersion", "migrations",
    ]
    static let unionLabels = ["name", "discriminator", "valueKey"]

    /// Reports every argument that does not belong to the kind of type.
    func check(allowed: [String], kind: String, reporter: Reporter) {
        guard case .argumentList(let list)? = node.arguments else { return }
        for argument in list {
            guard let label = argument.label?.text, !allowed.contains(label) else { continue }
            let belongsTo: String
            switch label {
            case "discriminator", "valueKey": belongsTo = "an enum with associated values"
            case "name": belongsTo = "a struct or an enum with associated values"
            default: belongsTo = "a struct"
            }
            reporter.error(
                argument,
                Problem(
                    id: "argument-not-applicable",
                    message: "`\(label):` applies to \(belongsTo), and this is \(kind)"),
                fixIts: [.removing(argument, "remove `\(label):`")])
        }
    }
}
#endif

#if STOIC_LINT
import SwiftSyntax

/// `claim.unverified()`: a claim's value taken as a fact with no verifier
/// (design/28). The escape is legitimate when the reason is written (a
/// display of what a person typed, a value the app decides to take on
/// trust), and the escape budget then records it.
///
/// Test code is exempt: a test reads what it claimed. Syntactic: a method
/// reference (`let f = claim.unverified`) is not seen.
final class UnverifiedClaimRule: RuleVisitor {
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard !reporter.isTestFile, node.arguments.isEmpty, !node.hasClosure,
            let member = node.calledExpression.as(MemberAccessExprSyntax.self), member.base != nil,
            member.declName.baseName.text == "unverified", member.declName.argumentNames == nil
        else { return .visitChildren }
        reporter.report(
            .unverifiedClaim, at: member.declName,
            message: "`unverified()` takes a claim's value as a fact without a verifier: nothing has vouched for it.",
            fixIt:
                "verify it (a verifier reads the claim through its `Minter`), or justify it with `// stoic:allow(unverified-claim): <why this claim may be taken as it is>`"
        )
        return .visitChildren
    }
}

/// A `Mint` anyone can make, in a type that declares itself evidence
/// (design/28). Whoever can construct a kind's `Mint` can mint proofs of it,
/// so the only initialiser must be `private` or `fileprivate` to the
/// verifier's file.
///
/// Flags, in a type or extension whose inheritance clause names `Evidence`,
/// `PrincipalEvidence` or `ContentEvidence`: a nested `struct`, `class` or
/// `actor` `Mint` with no initialiser (its implicit one is internal) or
/// with one that is not `private` or `fileprivate`; an `enum Mint` with a
/// case; and `typealias Mint = …`. Syntactic: a conformance added in an
/// extension elsewhere, or a `Mint` declared outside the type, is not seen.
final class EvidenceMintAccessRule: RuleVisitor {
    private static let evidenceProtocols: Set<String> = ["Evidence", "PrincipalEvidence", "ContentEvidence"]

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node.inheritanceClause, node.memberBlock)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node.inheritanceClause, node.memberBlock)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node.inheritanceClause, node.memberBlock)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node.inheritanceClause, node.memberBlock)
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node.inheritanceClause, node.memberBlock)
        return .visitChildren
    }

    private func check(_ inheritance: InheritanceClauseSyntax?, _ members: MemberBlockSyntax) {
        guard let inheritance, inheritance.inheritedTypes.contains(where: { Self.namesEvidence($0.type) }) else { return }
        for item in members.members {
            let decl = item.decl
            if let alias = decl.as(TypeAliasDeclSyntax.self), alias.name.text == "Mint" {
                report(at: alias.name, "`typealias Mint` makes the token anything already is, so anyone can mint this evidence.")
            } else if let mint = decl.as(StructDeclSyntax.self), mint.name.text == "Mint" {
                checkInitialisers(of: mint.name, in: mint.memberBlock)
            } else if let mint = decl.as(ClassDeclSyntax.self), mint.name.text == "Mint" {
                checkInitialisers(of: mint.name, in: mint.memberBlock)
            } else if let mint = decl.as(ActorDeclSyntax.self), mint.name.text == "Mint" {
                checkInitialisers(of: mint.name, in: mint.memberBlock)
            } else if let mint = decl.as(EnumDeclSyntax.self), mint.name.text == "Mint" {
                let hasCase = mint.memberBlock.members.contains { $0.decl.is(EnumCaseDeclSyntax.self) }
                if hasCase {
                    report(at: mint.name, "an `enum Mint` with a case can be made by anyone who names the case, so anyone can mint this evidence.")
                }
            }
        }
    }

    private func checkInitialisers(of name: TokenSyntax, in members: MemberBlockSyntax) {
        let initialisers = members.members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }
        guard !initialisers.isEmpty else {
            report(at: name, "`Mint` declares no initialiser, so its implicit one is internal: any code in the module can mint this evidence.")
            return
        }
        for initialiser in initialisers
        where !initialiser.modifiers.contains(.private) && !initialiser.modifiers.contains(.fileprivate) {
            let access = initialiser.modifiers.first { modifier in
                [.keyword(.public), .keyword(.open), .keyword(.package), .keyword(.internal)].contains(modifier.name.tokenKind)
            }?.name.text ?? "internal"
            report(at: initialiser.initKeyword, "this `Mint` initialiser is \(access): code outside the verifier's file can mint this evidence.")
        }
    }

    private func report(at node: some SyntaxProtocol, _ message: String) {
        reporter.report(
            .evidenceMintAccess, at: node, message: message,
            fixIt: "declare `struct Mint { fileprivate init() {} }` in the verifier's file, or justify it with `// stoic:allow(evidence-mint-access): <why>`")
    }

    /// `Evidence`, `PrincipalEvidence`, `ContentEvidence`, or one of them
    /// qualified (`Stoic.Evidence`).
    private static func namesEvidence(_ type: TypeSyntax) -> Bool {
        if let identifier = type.as(IdentifierTypeSyntax.self) { return evidenceProtocols.contains(identifier.name.text) }
        if let member = type.as(MemberTypeSyntax.self) { return evidenceProtocols.contains(member.name.text) }
        if let composition = type.as(CompositionTypeSyntax.self) {
            return composition.elements.contains { namesEvidence($0.type) }
        }
        return false
    }
}

/// `.deriving { _ in … }`: a value with real evidence and invented content
/// (design/28). Derivation keeps content evidence because the new value is
/// computed from the verified one; a closure that ignores its input is a
/// forgery with the verifier's name on it.
///
/// Flags a closure passed to `deriving` whose parameters are all `_`, or that
/// names no parameter and uses no `$0`. Syntactic: a closure that reads its
/// parameter and returns something else is not seen, nor is a `$0` that
/// belongs to a closure nested inside.
final class DerivationIgnoresInputRule: RuleVisitor {
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let call = node.memberCall, call.name == "deriving" else { return .visitChildren }
        for closure in node.closures {
            if let ignored = Self.ignoredParameter(closure) {
                report(at: ignored)
            } else if closure.signature?.parameterClause == nil, !Self.usesShorthand(closure) {
                report(at: closure.leftBrace)
            }
        }
        return .visitChildren
    }

    private func report(at node: some SyntaxProtocol) {
        reporter.report(
            .derivationIgnoresInput, at: node,
            message: "this derivation ignores its input: the result would carry the evidence of a value it was not computed from.",
            fixIt: "compute the new value from the verified one (`$0`, or a named parameter); for a value that is new, verify it")
    }

    /// The `_` of a closure whose every parameter is `_`, or nil.
    private static func ignoredParameter(_ closure: ClosureExprSyntax) -> TokenSyntax? {
        guard let clause = closure.signature?.parameterClause else { return nil }
        switch clause {
        case .simpleInput(let shorthand):
            let names = shorthand.map(\.name)
            guard let first = names.first, names.allSatisfy({ $0.tokenKind == .wildcard }) else { return nil }
            return first
        case .parameterClause(let parameters):
            let list = Array(parameters.parameters)
            let ignored = list.filter { ($0.secondName ?? $0.firstName).tokenKind == .wildcard }
            guard let first = ignored.first, ignored.count == list.count else { return nil }
            return first.secondName ?? first.firstName
        }
    }

    /// Whether `$0` (or any `$n`) appears in the closure's body.
    private static func usesShorthand(_ closure: ClosureExprSyntax) -> Bool {
        closure.statements.tokens(viewMode: .sourceAccurate).contains {
            if case .dollarIdentifier = $0.tokenKind { return true }
            return false
        }
    }
}

#endif

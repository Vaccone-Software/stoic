#if STOIC_LINT
import StoicLintCore

/// Lints an inline snippet and returns the rule short names it triggered,
/// in source order, so a test reads as "this snippet earns exactly these".
func rules(
    in source: String,
    path: String = "/work/Sources/App/File.swift"
) -> [String] {
    Linter().lint(source: source, path: path).map(\.rule.shortName)
}

func findings(in source: String, path: String = "/work/Sources/App/File.swift") -> [Finding] {
    Linter().lint(source: source, path: path)
}
#endif

import Foundation
import PackagePlugin

/// Runs `stoic-lint` over a target's Swift sources as part of every build,
/// so a violation of a Stoic rule is a build error rather than a review
/// comment (design/13).
///
/// Attach it to a target:
///
///     .target(name: "App", plugins: [.plugin(name: "StoicLint", package: "stoic")])
///
/// How it fits the build:
///
/// - The command's inputs are the target's Swift files (and the baseline, if
///   there is one), and its output is a stamp file the tool writes only when
///   the run passes. The build system reruns the command when an input
///   changes, and, because a failing run leaves no stamp, on every build
///   until the violations are fixed. A failure can never go quiet by being
///   cached.
/// - The tool prints `path:line:col: error: [rule] message`; SwiftPM and
///   Xcode turn that into build errors that point at the line.
/// - A `.stoic-lint-baseline.json` at the package root (or the Xcode
///   project's folder) is passed as `--baseline`; see design/13 for the
///   ratchet.
@main
struct StoicLint: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target as? SourceModuleTarget else { return [] }
        let sources = module.sourceFiles(withSuffix: ".swift").map(\.url)
        return [
            try command(
                tool: context.tool(named: "stoic-lint").url,
                targetName: target.name,
                sources: sources,
                projectDirectory: context.package.directoryURL,
                workDirectory: context.pluginWorkDirectoryURL
            )
        ].compactMap { $0 }
    }
}

extension StoicLint {
    /// The build command, or nil when the target has no Swift sources (a
    /// command with no inputs would run on every build for nothing).
    fileprivate func command(
        tool: URL,
        targetName: String,
        sources: [URL],
        projectDirectory: URL,
        workDirectory: URL
    ) throws -> Command? {
        guard !sources.isEmpty else { return nil }

        let stamp = workDirectory.appending(path: "\(targetName).stoic-lint-stamp")
        var arguments: [String] = ["--output", stamp.path(percentEncoded: false)]
        var inputs = sources

        let baseline = projectDirectory.appending(path: ".stoic-lint-baseline.json")
        if FileManager.default.fileExists(atPath: baseline.path(percentEncoded: false)) {
            arguments += ["--baseline", baseline.path(percentEncoded: false)]
            inputs.append(baseline)
        }
        arguments += sources.map { $0.path(percentEncoded: false) }

        return .buildCommand(
            displayName: "StoicLint \(targetName)",
            executable: tool,
            arguments: arguments,
            inputFiles: inputs,
            outputFiles: [stamp]
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

/// The same command for an Xcode project: attach the plugin to a target in
/// its "Run Build Tool Plug-ins" build phase.
extension StoicLint: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let sources = target.inputFiles
            .filter { $0.type == .source && $0.url.pathExtension == "swift" }
            .map(\.url)
        return [
            try command(
                tool: context.tool(named: "stoic-lint").url,
                targetName: target.displayName,
                sources: sources,
                projectDirectory: context.xcodeProject.directoryURL,
                workDirectory: context.pluginWorkDirectoryURL
            )
        ].compactMap { $0 }
    }
}
#endif

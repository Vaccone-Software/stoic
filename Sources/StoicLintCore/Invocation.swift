#if STOIC_LINT

/// The command line of `stoic-lint`, parsed. Kept out of `main` so it can be
/// tested without a process.
///
///     stoic-lint [--baseline <file>] [--output <stamp>] <path>…
///     stoic-lint --write-baseline <file> <path>…
///
/// Each `<path>` is a Swift file, or a directory searched for `*.swift`.
public struct Invocation: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case lint
        case writeBaseline(String)
        case help
    }

    public var mode: Mode = .lint
    public var baselinePath: String?
    /// A file written on success, so a build system can tell the tool ran
    /// and may skip it until its inputs change.
    public var outputPath: String?
    public var inputs: [String] = []

    public static let usage = """
        usage: stoic-lint [--baseline <file>] [--output <stamp>] <path>…
               stoic-lint --write-baseline <file> <path>…

        Checks Swift sources against Stoic's lint rules. Exits 1 if a finding is
        not accepted by the baseline, 2 on a usage or I/O error.

          --baseline <file>        accept the findings listed in <file> as warnings
          --output <stamp>         write <stamp> when the run passes
          --write-baseline <file>  record every current finding in <file>, exit 0
        """

    public struct UsageError: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    public static func parse(_ arguments: [String]) throws -> Invocation {
        var result = Invocation()
        var index = 0

        func value(for flag: String, inline: String?) throws -> String {
            if let inline { return inline }
            index += 1
            guard index < arguments.count else { throw UsageError(description: "\(flag) needs a value") }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            let flag: String
            let inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                flag = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            } else {
                flag = argument
                inline = nil
            }
            switch flag {
            case "--baseline": result.baselinePath = try value(for: flag, inline: inline)
            case "--output": result.outputPath = try value(for: flag, inline: inline)
            case "--write-baseline": result.mode = .writeBaseline(try value(for: flag, inline: inline))
            case "--help", "-h": result.mode = .help
            case "--":
                result.inputs += arguments[(index + 1)...]
                index = arguments.count
            default:
                if argument.hasPrefix("-"), argument != "-" {
                    throw UsageError(description: "unknown option \(argument)")
                }
                result.inputs.append(argument)
            }
            index += 1
        }

        if result.mode != .help, result.inputs.isEmpty {
            throw UsageError(description: "no paths to lint")
        }
        if case .writeBaseline = result.mode, result.baselinePath != nil {
            throw UsageError(description: "--write-baseline records everything; it cannot be combined with --baseline")
        }
        return result
    }
}

#endif

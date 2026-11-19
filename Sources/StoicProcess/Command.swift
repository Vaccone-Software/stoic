#if os(macOS)
internal import Darwin

/// A program to run: what, with which arguments, where, and in exactly
/// which environment.
///
/// The environment is always given whole. A child that inherits its
/// parent's environment by default inherits whatever reached the parent:
/// a key meant for one tool, a variable a parent shell set for itself. Say
/// ``ProcessEnvironment/current`` to pass this process's on, and filter it
/// first when something in it must not reach the child.
public struct Command: Sendable, Hashable, CustomStringConvertible {
    /// An absolute path. No search of `PATH`: which program runs is decided
    /// by the caller, never by the environment it hands over.
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// The child's working directory; this process's when nil.
    public var directory: String?
    /// Where the child's standard input comes from.
    public var input: Input
    /// Where its standard output goes.
    public var output: Output
    /// Where its standard error goes.
    public var errors: ErrorOutput
    /// Whether it is stopped with its owner, or left to run on its own.
    public var lifetime: Lifetime

    public init(
        _ executable: String,
        _ arguments: [String] = [],
        in directory: String? = nil,
        environment: [String: String],
        input: Input = .none,
        output: Output = .pipe,
        errors: ErrorOutput = .pipe,
        lifetime: Lifetime = .owned
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.input = input
        self.output = output
        self.errors = errors
        self.lifetime = lifetime
    }

    /// The program's name and how many arguments it has: never the
    /// arguments themselves, which may hold anything.
    public var description: String {
        let name = executable.split(separator: "/").last.map(String.init) ?? executable
        return "\(name) (\(arguments.count) arguments)"
    }

    /// Where standard input comes from.
    public enum Input: Sendable, Hashable {
        /// `/dev/null`: a read gets end of file at once, so a program that
        /// asks a question is answered "nothing" rather than waiting forever.
        case none
        /// A pipe the parent writes to through ``ChildProcess/input``.
        /// Held open until ``ProcessInput/finish()`` or the stop, so a child
        /// that exits at end of input (as many helpers do) also exits when
        /// its parent does.
        case pipe
        /// This process's own standard input.
        case inherit
        /// A file, read from its start.
        case file(String)
    }

    /// Where standard output goes.
    public enum Output: Sendable, Hashable {
        /// A pipe, read through ``ChildProcess/output``. The child can write
        /// only as far ahead of the reader as the pipe holds (64 KB on
        /// macOS): read it, or the child waits.
        case pipe
        /// `/dev/null`.
        case discard
        /// This process's own standard output.
        case inherit
        /// A file, created if missing (mode `0o644`) and truncated, or
        /// appended to.
        case file(String, append: Bool = false)
    }

    /// Where standard error goes.
    public enum ErrorOutput: Sendable, Hashable {
        /// A pipe of its own, read through ``ChildProcess/errors``.
        case pipe
        /// Into the standard output, interleaved as the child wrote them
        /// (`2>&1`).
        case mergeWithOutput
        /// `/dev/null`.
        case discard
        /// This process's own standard error.
        case inherit
        /// A file, as for ``Output/file(_:append:)``.
        case file(String, append: Bool = false)
    }

    /// How long the child may live.
    public enum Lifetime: Sendable, Hashable {
        /// In a process group of its own, stopped with everything it
        /// started when its ``ChildProcess`` is stopped or released, and
        /// recorded in a ``ProcessLedger`` if one is given, so a crash of
        /// this process does not leave it running.
        case owned
        /// In a session of its own, never signalled, never recorded: a
        /// program that must outlive this one (an updater that relaunches
        /// it). Its input and output cannot be pipes, which would end with
        /// this process.
        case detached
    }
}

/// The environment variables of this process, read from `environ`.
public enum ProcessEnvironment {
    /// This process's environment, now.
    public static var current: [String: String] {
        var found: [String: String] = [:]
        var entry = unsafe environ
        while let pointer = unsafe entry.pointee {
            let text = unsafe String(cString: pointer)
            if let equals = text.firstIndex(of: "=") {
                found[String(text[..<equals])] = String(text[text.index(after: equals)...])
            }
            unsafe entry += 1
        }
        return found
    }
}
#endif

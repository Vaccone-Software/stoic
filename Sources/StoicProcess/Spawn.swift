#if os(macOS)
internal import Darwin

/// The descriptors a spawn leaves this process holding: the parent's ends
/// of whichever streams were pipes.
struct SpawnedPipes {
    var input: Int32?
    var output: Int32?
    var errors: Int32?
}

/// `posix_spawn`, with everything a child must not inherit taken away.
///
/// - **Descriptors.** `POSIX_SPAWN_CLOEXEC_DEFAULT`: the child gets its
///   three standard streams and nothing else, never the pipes this process
///   holds to its other children. An inherited write end of another child's
///   output would hold that output open until this child ended.
/// - **Signals.** Every signal back to its default action and none blocked:
///   a parent that ignores `SIGPIPE` (as most apps must) would otherwise
///   hand a child that ignores it too, and a pipeline it runs would never
///   end when its reader does.
/// - **Start.** Suspended, so its exit can be watched before it can exit.
/// - **Group.** A process group of its own (`.owned`), so it and everything
///   it starts can be signalled as one; or a session of its own
///   (`.detached`), so nothing this process's group or terminal receives
///   reaches it.
enum Spawn {
    static func start(_ command: Command) throws(ProcessError) -> (pid: Int32, pipes: SpawnedPipes) {
        if command.lifetime == .detached {
            let pipes = command.input == .pipe || command.output == .pipe || command.errors == .pipe
            if pipes { throw .pipeForDetached }
        }

        var actions = unsafe posix_spawn_file_actions_t(bitPattern: 0)
        unsafe posix_spawn_file_actions_init(&actions)
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }

        var opened: [Int32] = []           // every pipe end made, closed on failure
        var childEnds: [Int32] = []        // closed in this process once the child has them
        var pipes = SpawnedPipes()
        func fail(_ error: ProcessError) -> ProcessError {
            for fd in opened { _ = close(fd) }
            return error
        }
        func makePipe(_ what: String) throws(ProcessError) -> (read: Int32, write: Int32) {
            var ends: [Int32] = [0, 0]
            guard unsafe pipe(&ends) == 0 else { throw fail(.couldNotPrepare(what: what, errno: errno)) }
            for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            opened += ends
            return (ends[0], ends[1])
        }

        switch command.input {
        case .none: unsafe posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        case .inherit: unsafe posix_spawn_file_actions_addinherit_np(&actions, 0)
        case .file(let path): unsafe posix_spawn_file_actions_addopen(&actions, 0, path, O_RDONLY, 0)
        case .pipe:
            let ends = try makePipe("standard input")
            unsafe posix_spawn_file_actions_adddup2(&actions, ends.read, 0)
            childEnds.append(ends.read)
            pipes.input = ends.write
        }
        switch command.output {
        case .discard: unsafe posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        case .inherit: unsafe posix_spawn_file_actions_addinherit_np(&actions, 1)
        case .file(let path, let append):
            unsafe posix_spawn_file_actions_addopen(&actions, 1, path, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0o644)
        case .pipe:
            let ends = try makePipe("standard output")
            unsafe posix_spawn_file_actions_adddup2(&actions, ends.write, 1)
            childEnds.append(ends.write)
            pipes.output = ends.read
        }
        switch command.errors {
        case .mergeWithOutput: unsafe posix_spawn_file_actions_adddup2(&actions, 1, 2)
        case .discard: unsafe posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        case .inherit: unsafe posix_spawn_file_actions_addinherit_np(&actions, 2)
        case .file(let path, let append):
            unsafe posix_spawn_file_actions_addopen(&actions, 2, path, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0o644)
        case .pipe:
            let ends = try makePipe("standard error")
            unsafe posix_spawn_file_actions_adddup2(&actions, ends.write, 2)
            childEnds.append(ends.write)
            pipes.errors = ends.read
        }
        if let directory = command.directory {
            unsafe posix_spawn_file_actions_addchdir(&actions, directory)
        }

        var attributes = unsafe posix_spawnattr_t(bitPattern: 0)
        unsafe posix_spawnattr_init(&attributes)
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        // Started suspended: it runs once its exit is watched (see
        // `Core.watchExit`), so it cannot end before anyone is listening.
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_START_SUSPENDED
        switch command.lifetime {
        case .owned:
            flags |= POSIX_SPAWN_SETPGROUP
            unsafe posix_spawnattr_setpgroup(&attributes, 0)
        case .detached:
            flags |= POSIX_SPAWN_SETSID
        }
        unsafe posix_spawnattr_setflags(&attributes, Int16(flags))
        var everySignal = sigset_t()
        unsafe sigfillset(&everySignal)
        unsafe posix_spawnattr_setsigdefault(&attributes, &everySignal)
        var noSignals = sigset_t()
        unsafe sigemptyset(&noSignals)
        unsafe posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = unsafe ([command.executable] + command.arguments).map { unsafe strdup($0) } + [nil]
        let envp = unsafe command.environment.map { unsafe strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for unsafe pointer in unsafe argv + envp { unsafe free(pointer) } }

        var pid: pid_t = 0
        let status = unsafe posix_spawn(&pid, command.executable, &actions, &attributes, argv, envp)
        guard status == 0 else { throw fail(.couldNotStart(executable: command.executable, errno: status)) }
        for fd in childEnds { _ = close(fd) }
        return (pid, pipes)
    }
}

extension ProcessExit {
    /// Decodes a `waitpid` status.
    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
    }
}
#endif

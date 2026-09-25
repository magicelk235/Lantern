import Darwin
import Foundation
import IDEProtocol

/// Starts processes on a new pseudo-terminal.
///
/// `forkpty` gives the child a new session with the PTY slave as controlling terminal on fds 0-2. The forked
/// child then only makes async-signal-safe calls with memory prepared before the fork: `chdir` and
/// `posix_spawn(POSIX_SPAWN_SETEXEC)`, which execs in place with `POSIX_SPAWN_CLOEXEC_DEFAULT` (no daemon fd
/// other than 0-2 leaks into the shell), default signal dispositions and an empty signal mask. A CLOEXEC pipe
/// reports a failed `chdir`/exec back to the parent so `pty.open` fails synchronously.
enum PTYSpawner {
    struct Child {
        let pid: pid_t
        /// PTY master, non-blocking and close-on-exec.
        let master: Int32
    }

    /// The user's login shell (`getpwuid`), falling back to `$SHELL`, then `/bin/zsh`.
    static func loginShell() -> String {
        passwdField { $0.pw_shell } ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func homeDirectory() -> String {
        passwdField { $0.pw_dir } ?? NSHomeDirectory()
    }

    /// `base` (normally the daemon's environment) adjusted for an interactive terminal, overlaid with `overlay`.
    static func environment(base: [String: String], overlay: [String: String]?, cwd: String) -> [String: String] {
        var env = base
        // Sizes and identities of whatever terminal the daemon was started from must not leak.
        for key in ["COLUMNS", "LINES", "TERMCAP", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "OLDPWD"] {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["PWD"] = cwd
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        if let overlay {
            env.merge(overlay) { _, new in new }
        }
        return env
    }

    /// Resolves `name` like `execvp` would, but against the child's `PATH` and working directory.
    static func resolveExecutable(_ name: String, cwd: String, searchPath: String?) throws -> String {
        if name.contains("/") {
            let path = name.hasPrefix("/") ? name : cwd + "/" + name
            guard isExecutableFile(path) else {
                throw DaemonError(.badParams, "not an executable file: \(name)")
            }
            return path
        }
        for component in (searchPath ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":", omittingEmptySubsequences: false) {
            let dir = component.isEmpty ? cwd : component.hasPrefix("/") ? String(component) : cwd + "/" + component
            let candidate = dir + "/" + name
            if isExecutableFile(candidate) { return candidate }
        }
        throw DaemonError(.badParams, "command not found: \(name)")
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Forks `argv` (with `executable` already resolved) on a new PTY of `cols`×`rows` in `cwd`.
    static func spawn(executable: String, argv: [String], environment: [String: String], cwd: String, cols: Int, rows: Int) throws -> Child {
        // Everything the child touches is allocated here, before the fork.
        let cArgv = CStringArray(argv)
        let cEnv = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let cPath = strdup(executable)!
        let cCwd = strdup(cwd)!
        defer {
            free(cPath)
            free(cCwd)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd in Int32(0)...2 { posix_spawn_file_actions_addinherit_np(&fileActions, fd) }

        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&errorPipe) == 0 else { throw posixError("pipe") }
        _ = fcntl(errorPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(errorPipe[1], F_SETFD, FD_CLOEXEC)
        let reportRead = errorPipe[0]
        let reportWrite = errorPipe[1]

        var term = defaultTermios()
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, &term, &size)
        if pid == 0 {
            // Child: async-signal-safe calls only.
            Darwin.close(reportRead)
            var failure: Int32 = 0
            if chdir(cCwd) != 0 {
                failure = errno
            } else {
                failure = posix_spawn(nil, cPath, &fileActions, &attributes, cArgv.pointers, cEnv.pointers)
            }
            _ = Darwin.write(reportWrite, &failure, MemoryLayout<Int32>.size)
            _exit(127)
        }
        Darwin.close(reportWrite)
        guard pid > 0 else {
            let error = posixError("forkpty")
            Darwin.close(reportRead)
            throw error
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        // EOF: exec succeeded (CLOEXEC closed the pipe). Four bytes: errno of the failed chdir/exec.
        var failure: Int32 = 0
        var received = 0
        while received < MemoryLayout<Int32>.size {
            let n = withUnsafeMutableBytes(of: &failure) { Darwin.read(reportRead, $0.baseAddress! + received, $0.count - received) }
            if n > 0 { received += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
        Darwin.close(reportRead)
        if received == MemoryLayout<Int32>.size {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            Darwin.close(master)
            throw DaemonError(.badParams, "cannot start \(executable) in \(cwd): \(String(cString: strerror(failure)))")
        }
        return Child(pid: pid, master: master)
    }

    /// Current working directory of `pid` (follows `cd` in the shell), nil if unavailable.
    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Internals

    /// `<sys/ttydefaults.h>` settings plus IUTF8 (correct erase of multi-byte characters in canonical mode).
    private static func defaultTermios() -> termios {
        var t = termios()
        t.c_iflag = tcflag_t(BRKINT | ICRNL | IMAXBEL | IXON | IXANY | IUTF8)
        t.c_oflag = tcflag_t(OPOST | ONLCR)
        t.c_cflag = tcflag_t(CREAD | CS8 | HUPCL)
        t.c_lflag = tcflag_t(ECHO | ICANON | ISIG | IEXTEN | ECHOE | ECHOKE | ECHOCTL)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            for i in cc.indices { cc[i] = 0xff } // _POSIX_VDISABLE
            cc[Int(VEOF)] = 0x04
            cc[Int(VERASE)] = 0x7f
            cc[Int(VWERASE)] = 0x17
            cc[Int(VKILL)] = 0x15
            cc[Int(VREPRINT)] = 0x12
            cc[Int(VINTR)] = 0x03
            cc[Int(VQUIT)] = 0x1c
            cc[Int(VSUSP)] = 0x1a
            cc[Int(VDSUSP)] = 0x19
            cc[Int(VSTART)] = 0x11
            cc[Int(VSTOP)] = 0x13
            cc[Int(VLNEXT)] = 0x16
            cc[Int(VDISCARD)] = 0x0f
            cc[Int(VSTATUS)] = 0x14
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        cfsetispeed(&t, speed_t(B38400))
        cfsetospeed(&t, speed_t(B38400))
        return t
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
    }

    private static func passwdField(_ field: (passwd) -> UnsafeMutablePointer<CChar>?) -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        return buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result) == 0, result != nil,
                  let value = field(entry), value.pointee != 0 else { return nil }
            return String(cString: value)
        }
    }

    private static func posixError(_ call: String) -> DaemonError {
        DaemonError(.internal, "\(call) failed: \(String(cString: strerror(errno)))")
    }
}

/// NULL-terminated `char *[]` owned by Swift, built before a fork so the child never allocates.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointers[index] = strdup(string) }
        pointers[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}

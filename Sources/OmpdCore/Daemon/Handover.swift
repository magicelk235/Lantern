import Darwin
import Foundation
import IDEProtocol

/// What an in-place ompd upgrade hands to the next image (Regime A). ompd replaces its own process image with
/// the installed executable (`execve` with `run <its arguments> --handover <file>`), so the pid stays, every omp stays
/// its child (`waitpid` keeps working), and the descriptors named here stay open: no PTY master closes, so no omp sees a
/// SIGHUP, and no ownership lock is let go. The file lives in `run/` (0600), is written durably and read back before the
/// exec, and the next image deletes it as soon as it has read it.
public struct DaemonHandover: Codable, Sendable {
    /// Bumped on any incompatible change. `ompd handover-info` lists the formats an executable reads; ompd only hands
    /// over to one that reads its own.
    static let format = 1
    static let readableFormats = [1]

    var format = Self.format
    /// The image that wrote it (`ompdVersion`).
    var fromVersion = ompdVersion
    /// When this ompd process started; kept across handovers (`daemon.status`'s `startedAt`).
    var startedAt: Date
    /// The descriptor holding `ompd.lock` (`DaemonInstanceLock`), filled in by the process that execs.
    var instanceLock: Int32 = -1
    /// ompd wanted every session paused (no window was open).
    var pauseDemand: Bool
    var ptys: PTYPoolHandover
    var sessions: [SupervisorHandover]
    var bridge: BridgeHandover

    /// Every descriptor the next image inherits; FD_CLOEXEC is cleared on exactly these.
    var descriptors: [Int32] {
        [instanceLock] + ptys.ptys.compactMap(\.masterFD) + sessions.compactMap(\.lock?.descriptor)
    }

    /// Writes the handover to `url` (0600, flushed to disk) and reads it back: the exec only happens on a file the next
    /// image can decode.
    func write(to url: URL) throws {
        try StorageIO.writeAtomically(try IDECoding.encoder().encode(self), to: url, mode: 0o600, durable: true)
        _ = try Self.read(from: url)
    }

    /// Reads the handover the previous image wrote to `url` and removes the file (it carries the bridges' tokens).
    static func take(from url: URL) throws -> DaemonHandover {
        defer { unlink(url.path(percentEncoded: false)) }
        return try read(from: url)
    }

    private static func read(from url: URL) throws -> DaemonHandover {
        guard let data = try StorageIO.readFileIfPresent(url) else {
            throw StorageError.system(operation: "open", path: url.path(percentEncoded: false), code: ENOENT)
        }
        let handover = try IDECoding.decoder().decode(DaemonHandover.self, from: data)
        guard readableFormats.contains(handover.format) else {
            throw HandoverError("handover format \(handover.format) is not one this ompd reads (\(readableFormats))")
        }
        return handover
    }
}

/// The PTY pool (`PTYPool.freezeForHandover`).
struct PTYPoolHandover: Codable, Sendable {
    var ptys: [PTYHandover]
    /// Children of PTYs closed within their kill grace, not reaped yet: the next image reaps them.
    var closing: [Int32]
    /// The snapshot (by PTY id) each session's next PTY continues from (sessions whose omp does not run).
    var sessionScreens: [SessionKey: PTYID]
}

/// One PTY: everything the next image's pool needs to read on where this one stopped.
struct PTYHandover: Codable, Sendable {
    var info: PTYInfo
    /// A plain terminal's `pty.open` environment overrides (written to its snapshots).
    var persistedEnv: [String: String]?
    /// Creation order (`PTYPool.list()`).
    var sequence: UInt64
    /// The master's descriptor; nil once the tty hung up.
    var masterFD: Int32?
    /// The mirror's screen (`TerminalMirror.serialize(includePending: true)`): replayed into the next image's mirror,
    /// it continues with the next byte the master yields.
    var screen: Data
    /// A session PTY whose program's first scrollback erase has not gone by yet: what that filter holds back (nil: none).
    var scrollbackEraseHeld: [UInt8]?
    /// Input the tty has not taken yet.
    var pendingInput: Data
}

/// One `SessionSupervisor`.
struct SupervisorHandover: Codable, Sendable {
    var sessionKey: SessionKey
    /// The omp serving the session; nil while none runs.
    var omp: RunningOmp?
    /// The session file's ownership lock, when the supervisor holds it.
    var lock: LockHandover?
}

/// An omp that runs on: the next image follows it.
struct RunningOmp: Codable, Sendable {
    var pid: Int32
    /// Its PTY: a session PTY ompd spawned it on, or the terminal it was started in (`adopted`).
    var ptyId: PTYID
    var adopted: Bool
    var spawnedAt: Date
    /// The main agent's `busy`/`idle` underneath a pause.
    var activity: SessionStatus
    var pausedBy: PauseOwner?
    /// Its ide-bridge was connected: it redials the next image (false: omp runs without one).
    var bridge: Bool
}

struct LockHandover: Codable, Sendable {
    var descriptor: Int32
    /// Canonical (`OwnershipLock.canonicalPath`) session file the lock is named after.
    var sessionFile: String
}

/// The ide-bridge server's credentials (`BridgeServer.handoverState`): what lets the next image accept each bridge's
/// redial, and the hellos of omps started later in the terminals.
public struct BridgeHandover: Codable, Sendable {
    struct Session: Codable, Sendable {
        var sessionKey: SessionKey
        var token: String
        /// The omp that may say hello with it.
        var pid: Int32
        /// An omp started in a terminal and adopted: the terminal whose credentials its redials carry.
        var terminal: PTYID?
    }

    var sessions: [Session]
    /// Each terminal PTY's token.
    var terminals: [PTYID: String]
}

extension PauseOwner: Codable {}

struct HandoverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The process side of an in-place upgrade.
enum ProcessImage {
    /// Clears FD_CLOEXEC on each of `descriptors`, so they stay open across the exec. Throws, with every flag set again,
    /// when one of them is not an open descriptor.
    static func inherit(_ descriptors: [Int32]) throws {
        var cleared: [Int32] = []
        for fd in descriptors {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0, fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC) == 0 else {
                let code = errno
                closeOnExec(cleared)
                throw HandoverError("descriptor \(fd) cannot be handed over: \(String(cString: strerror(code)))")
            }
            cleared.append(fd)
        }
    }

    /// Sets FD_CLOEXEC on each of `descriptors` again (the exec did not happen, or the next image adopted them).
    static func closeOnExec(_ descriptors: [Int32]) {
        for fd in descriptors {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

    /// Closes every descriptor above stderr that is not close-on-exec: at the start of an image, those the previous image
    /// handed over (everything ompd opens itself is close-on-exec).
    static func closeInherited() {
        for fd in 3..<getdtablesize() {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0, flags & FD_CLOEXEC == 0 { close(fd) }
        }
    }

    /// Replaces this process's image with `path` (`execve`, same pid, ompd's environment) after clearing the calling
    /// thread's signal mask, which the new image would inherit. Returns only when the exec failed, with its errno.
    static func replace(with path: String, arguments: [String]) -> Int32 {
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        pthread_sigmask(SIG_SETMASK, &noSignals, nil)
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        execve(path, argv, envp)
        return errno
    }
}

import Darwin
import Foundation
import IDEProtocol
import os

/// Owns one IDE session (`SessionKey`): the omp TUI currently serving it, running on a session PTY of the daemon's
/// pool. It spawns omp from the manifest's `LaunchSpec`, follows the ide-bridge inside it (identity,
/// busy/idle, title, session switches) into the manifest, holds the session file's ownership lock, respawns omp with
/// `--resume` when it dies, and stops it the graceful way (bridge `session.shutdown`), never with a signal
/// first.
public actor SessionSupervisor {
    public nonisolated let sessionKey: SessionKey

    public enum StartMode: Sendable, Equatable {
        /// A new omp session.
        case fresh
        /// `--resume <sessionFile>` of the manifest entry; the ownership lock is taken before spawning.
        case resume
    }

    public enum StopIntent: Sendable, Equatable {
        /// The user closed the session: `closedByUser`, status `closed`, PTY removed, ownership released.
        case user
        /// The daemon is going away; the session resumes at its next start.
        case daemonShutdown
    }

    private let context: SupervisorContext
    private var status: SessionStatus

    // The omp TUI
    /// The session's PTY: running, or exited and kept so its last screen stays attachable. Mirrors `entry.ptyId`.
    private var ptyId: PTYID?
    /// The running omp; nil once it exited.
    private var pid: Int32?
    /// Bumped per spawn; work tied to an older spawn is dropped.
    private var generation = 0
    /// Opens when the current spawn's omp exits.
    private var exited = ExitGate()
    private var spawnedAt = Date.distantPast
    private var startTask: Task<Void, any Error>?
    private var bridgeTask: Task<Void, Never>?
    private var bridgeHello: BridgeHello?
    /// ompd is stopping omp: its exit is expected and finished by `stop`.
    private var stopping: StopIntent?
    /// `stop` was called: nothing starts omp again until `reopen`.
    private var stopRequested = false
    /// When automatic respawns happened (crash-loop guard).
    private var respawns: [ContinuousClock.Instant] = []

    // Ownership
    private var lock: (any SessionLockHandle)?
    /// Canonical path (`OwnershipLock.canonicalPath`) of the locked session file.
    private var lockedFile: String?

    /// `entry` is the session's current manifest entry.
    public init(entry: SessionManifestEntry, context: SupervisorContext) {
        sessionKey = entry.sessionKey
        self.context = context
        status = entry.status
        ptyId = entry.ptyId
    }

    // MARK: - Queries

    /// omp runs (it may be being stopped).
    public var isRunning: Bool { pid != nil }

    public var currentStatus: SessionStatus { status }

    // MARK: - Start

    /// Spawns omp's TUI on a new session PTY and returns once the PTY runs and the manifest entry points to it (the
    /// bridge `hello`, ownership of a new session's file and the switch to `idle` follow in the background). `cols` and
    /// `rows` default to the previous screen's size. Joins a start already in progress; a no-op while omp runs. On
    /// failure the session is `needs_attention` and a notice says why.
    public func start(_ mode: StartMode, cols: Int? = nil, rows: Int? = nil, notice: String? = nil) async throws {
        if let startTask { return try await startTask.value }
        guard pid == nil else { return }
        guard !stopRequested else { throw DaemonError(.internal, "session \(sessionKey) is being stopped") }
        let task = Task { try await self.runLaunch(mode, cols: cols, rows: rows, notice: notice) }
        startTask = task
        try await task.value
    }

    /// Hands over an ownership lock the daemon already took for `sessionFile` (adopting a session with
    /// `session.open` checks ownership before creating anything).
    public func adoptLock(_ handle: any SessionLockHandle, sessionFile: String) {
        releaseLock()
        lock = handle
        lockedFile = OwnershipLock.canonicalPath(sessionFile)
    }

    /// `session.open` of this session's own file while its omp is not running (closed, gave up, …): resumed under
    /// the same `SessionKey`, in a new PTY that continues the old screen.
    public func reopen(workspace: String, cols: Int, rows: Int) async throws {
        if let startTask { _ = try? await startTask.value }
        guard pid == nil else { throw DaemonError(.sessionBusy, "session \(sessionKey) is already open") }
        stopRequested = false
        stopping = nil
        respawns = []
        await updateEntry { entry in
            entry.closedByUser = false
            entry.workspace = workspace
        }
        try await start(.resume, cols: cols, rows: rows)
    }

    /// Regime B2: the daemon restarted and this session's omp is gone. Resumed from its file, started
    /// afresh if omp never wrote one, or left `needs_attention` when the file was never known.
    public func restoreAfterDaemonStart() async {
        guard let entry = await context.manifest.entry(sessionKey), entry.status != .closed else { return }
        guard let file = entry.sessionFile else {
            notify("error", "The omp session file of this session is unknown (the ide-bridge never connected), so it cannot be resumed.")
            await setStatus(.needsAttention)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: file) {
                // An omp of the dead daemon may still be finishing its teardown into the file; resuming before it is
                // done would fork the session.
                await SessionFileTail.waitForQuiescence(path: file, quietPeriod: context.timings.resumeQuietPeriod)
                guard !Task.isCancelled else { return }
                try await start(.resume, notice: "ompd restarted; resuming the omp session from \(file).")
            } else {
                try await start(.fresh, notice: "ompd restarted; the session had no saved history, so a new omp session was started.")
            }
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func runLaunch(_ mode: StartMode, cols: Int?, rows: Int?, notice: String?) async throws {
        // Cleared before anyone awaiting this task resumes, so an exit handled right after can start again.
        defer { startTask = nil }
        try await launch(mode, cols: cols, rows: rows, notice: notice)
    }

    private func launch(_ mode: StartMode, cols: Int?, rows: Int?, notice: String?) async throws {
        guard let entry = await context.manifest.entry(sessionKey) else {
            throw DaemonError(.noSuchSession, "no such session: \(sessionKey)")
        }
        guard Self.isDirectory(entry.workspace) else {
            notify("error", "The workspace folder \(entry.workspace) does not exist; locate it to resume the session.")
            await setStatus(.needsAttention)
            throw DaemonError(.badParams, "workspace does not exist: \(entry.workspace)")
        }
        var resumeFile: String?
        if mode == .resume {
            guard let file = entry.sessionFile, FileManager.default.fileExists(atPath: file) else {
                notify("error", "The omp session file \(entry.sessionFile ?? "(unknown)") is missing; the session cannot be resumed.")
                await setStatus(.needsAttention)
                throw DaemonError(.badParams, "session file does not exist: \(entry.sessionFile ?? "(unknown)")")
            }
            do {
                try takeOwnership(of: file, sessionId: entry.sessionId)
            } catch {
                notify("error", "Cannot resume: \(error)")
                await setStatus(.needsAttention)
                throw error
            }
            resumeFile = file
        }

        await setStatus(mode == .resume ? .resuming : .starting)
        if let notice { notify("info", notice) }

        let credentials = await context.bridge.expect(sessionKey: sessionKey)
        generation += 1
        let generation = generation
        let gate = ExitGate()
        let previous = ptyId
        let info: PTYInfo
        do {
            info = try await context.ptys.openSession(
                sessionKey: sessionKey, cwd: entry.workspace,
                command: [entry.launch.ompPath]
                    + Self.arguments(for: entry.launch, bridgeExtension: context.bridgeExtension, resume: resumeFile),
                environment: context.baseEnvironment, overlay: entry.launch.env.merging(credentials.environment) { $1 },
                cols: cols, rows: rows, continuing: previous,
                onExit: { [weak self] exit in
                    gate.open()
                    Task { await self?.ptyExited(exit, generation: generation) }
                })
        } catch {
            await context.bridge.forget(sessionKey)
            notify("error", "omp could not be started: \(error)")
            await setStatus(.needsAttention)
            throw DaemonError(.ompError, "omp did not start: \(error)")
        }
        exited = gate
        pid = gate.isOpen ? nil : info.pid
        ptyId = info.ptyId
        spawnedAt = Date()
        stopping = nil
        if let pid = info.pid { await context.bridge.setExpectedPID(pid, for: sessionKey) }
        await updateEntry { $0.ptyId = info.ptyId }
        // Only now that the entry points to the new PTY does the old one go away (clients follow `ptyId`).
        if let previous, previous != info.ptyId { try? await context.ptys.close(previous) }
        guard generation == self.generation, !gate.isOpen else { return } // exited already: ptyExited takes over
        bridgeTask = Task { await self.followBridge(generation: generation) }
    }

    static func arguments(for launch: LaunchSpec, bridgeExtension: String?, resume sessionFile: String?) -> [String] {
        var arguments: [String] = []
        if let model = launch.model { arguments += ["--model", model] }
        if let mode = launch.approvalMode { arguments += ["--approval-mode", mode] }
        if let directory = launch.sessionDir { arguments += ["--session-dir", directory] }
        if let bridgeExtension { arguments += ["-e", bridgeExtension] }
        if let sessionFile { arguments += ["--resume", sessionFile] }
        return arguments + launch.extraArgs
    }

    // MARK: - omp exits

    /// omp is gone. An exit ompd asked for is finished by `stop`. Otherwise exit status 0 means the user quit omp in
    /// its TUI (`/exit`, Ctrl+D): the session is `closed`, its PTY kept so the last screen stays visible, and it can be
    /// opened again. Anything else (a signal, a crash, SIGHUP's 129) is an unexpected death: `interrupted`, then a
    /// respawn with `--resume` unless the crash-loop guard gives up.
    private func ptyExited(_ exit: PTYExit, generation: Int) async {
        if let startTask { _ = try? await startTask.value }
        guard generation == self.generation else { return }
        await forgetSpawn()
        if stopping != nil || stopRequested { return }
        if exit.code == 0 {
            releaseLock()
            await setStatus(.closed)
            notify("info", "omp exited; the session is closed. Open it again to resume it.")
            return
        }
        let sessionFile = await context.manifest.entry(sessionKey)?.sessionFile
        let recorded = sessionFile.flatMap { SessionFileTail.sessionExitKind(path: $0, recordedSince: spawnedAt) }
        notify("warning", "omp exited unexpectedly (\(exit); \(recorded.map { "session_exit \($0)" } ?? "no session_exit recorded")).")
        await setStatus(.interrupted)
        await respawnAfterCrash()
    }

    private func respawnAfterCrash() async {
        let now = ContinuousClock.now
        let window = context.timings.respawnWindow
        respawns.removeAll { now - $0 > window }
        guard respawns.count < context.timings.maxRespawns else {
            notify("error", "omp keeps exiting (\(respawns.count) respawns within \(window)); it is not restarted again. Open the session to retry.")
            await setStatus(.needsAttention)
            return
        }
        guard let file = await context.manifest.entry(sessionKey)?.sessionFile else {
            notify("error", "The omp session file of this session is unknown (the ide-bridge never connected), so it cannot be resumed.")
            await setStatus(.needsAttention)
            return
        }
        respawns.append(now)
        do {
            if FileManager.default.fileExists(atPath: file) {
                try await start(.resume, notice: "Resuming the omp session from \(file).")
            } else {
                try await start(.fresh, notice: "omp exited before it saved the session; a new omp session was started.")
            }
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): respawn failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drops what belonged to the omp that exited. Idempotent.
    private func forgetSpawn() async {
        pid = nil
        bridgeTask?.cancel()
        bridgeTask = nil
        bridgeHello = nil
        await context.bridge.forget(sessionKey)
    }

    // MARK: - Stop

    /// Graceful stop: bridge `session.shutdown` (omp disposes: `session_exit {kind:"normal"}`, tool
    /// processes torn down) and up to `timings.stop` for the exit; then SIGHUP (the only step without a bridge), then
    /// SIGKILL of the process group. Returns once omp is gone. `.user` then closes the session and its PTY.
    public func stop(_ intent: StopIntent) async {
        stopRequested = true
        if let startTask { _ = try? await startTask.value }
        if intent == .user {
            // Before stopping: a daemon crash mid-close must not resume a session the user closed.
            await updateEntry { $0.closedByUser = true }
        }
        if pid != nil {
            if stopping == nil || intent == .user { stopping = intent }
            await terminate()
            await forgetSpawn()
        }
        guard intent == .user else { return }
        releaseLock()
        let closing = ptyId
        ptyId = nil
        status = .closed
        await updateEntry { entry in
            entry.status = .closed
            entry.ptyId = nil
            entry.closedByUser = true
        }
        if let closing { try? await context.ptys.close(closing) }
    }

    private func terminate() async {
        guard let ptyId else { return }
        let gate = exited
        let timings = context.timings
        var asked = false
        if bridgeHello?.capabilities["session.shutdown"] == true {
            let deadline = ContinuousClock.now + timings.stop
            do {
                _ = try await context.bridge.call(sessionKey, method: "session.shutdown", params: [:], timeout: timings.stop)
                asked = true
            } catch BridgeError.disconnected {
                asked = true // the bridge went away while omp disposed
            } catch {
                notify("warning", "The graceful shutdown through the ide-bridge failed (\(error)); hanging up omp's terminal.")
            }
            if asked {
                if await gate.wait(timeout: max(.zero, deadline - ContinuousClock.now)) { return }
                notify("warning", "omp did not exit within \(timings.stop) of the graceful shutdown; hanging up its terminal.")
            }
        }
        try? await context.ptys.signal(ptyId, SIGHUP)
        if await gate.wait(timeout: asked ? timings.hangup : timings.stop) { return }
        notify("warning", "omp did not exit after SIGHUP; killing its process group.")
        try? await context.ptys.signal(ptyId, SIGKILL)
        _ = await gate.wait(timeout: timings.hangup)
    }

    // MARK: - Health

    /// After a wake from sleep: omp must answer the bridge's `session.info`.
    public func healthCheck() async {
        guard pid != nil, stopping == nil, bridgeHello != nil else { return }
        let started = ContinuousClock.now
        do {
            _ = try await context.bridge.call(sessionKey, method: "session.info", params: [:], timeout: context.timings.healthCheck)
            let elapsed = ContinuousClock.now - started
            supervisorLog.info("session \(self.sessionKey, privacy: .public): wake health check answered in \(elapsed, privacy: .public)")
        } catch {
            notify("warning", "Wake health check: omp did not answer session.info through the ide-bridge (\(error)).")
        }
    }

    // MARK: - Bridge

    private func followBridge(generation: Int) async {
        let hello: BridgeHello
        do {
            hello = try await context.bridge.waitForHello(sessionKey, timeout: context.timings.hello)
        } catch {
            guard generation == self.generation, pid != nil, stopping == nil else { return }
            notify(
                "warning",
                "The ide-bridge extension did not connect (\(error)); status, title, graceful stop and resume after a crash are unavailable for this omp process.")
            await becomeIdleIfStarting()
            return
        }
        guard generation == self.generation, pid != nil else { return }
        bridgeHello = hello
        if hello.capabilities["events.activity"] != true {
            notify("warning", "An older copy of the ide-bridge serves this omp (no activity or title events); the session's status and title will not update until it is restarted with the current omp IDE.")
        }
        await adopt(sessionFile: hello.sessionFile, sessionId: hello.sessionId, title: hello.title, replacingTitle: false)
        await becomeIdleIfStarting()
        for await event in await context.bridge.events(sessionKey) {
            guard generation == self.generation else { return }
            await handle(bridgeEvent: event)
        }
    }

    private func handle(bridgeEvent event: JSONValue) async {
        guard event["t"]?.stringValue == "evt", let kind = event["kind"]?.stringValue else { return }
        let data = event["data"]
        switch kind {
        case "activity":
            guard let state = data?["state"]?.stringValue, [.busy, .idle, .starting, .resuming].contains(status) else { return }
            let new: SessionStatus = state == "busy" ? .busy : .idle
            let now = Date()
            status = new
            await updateEntry { entry in
                entry.status = new
                entry.lastActiveAt = now
            }
        case "title":
            guard let title = data?["title"]?.stringValue, !title.isEmpty else { return }
            await updateEntry { $0.title = title }
        case "session_switch":
            // `/new`, `/resume`, `/fork` inside the TUI: the session now lives in another file.
            guard data?["isMain"]?.boolValue == true, let session = data?["session"], let file = session["file"]?.stringValue else {
                return
            }
            await adopt(sessionFile: file, sessionId: session["id"]?.stringValue, title: session["title"]?.stringValue, replacingTitle: true)
        default:
            break
        }
    }

    /// omp serves `sessionFile` now: the manifest follows it, and so does ownership (by path, even before omp created
    /// the file).
    private func adopt(sessionFile file: String, sessionId: String?, title: String?, replacingTitle: Bool) async {
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        await updateEntry { entry in
            entry.sessionFile = file
            if let sessionId { entry.sessionId = sessionId }
            if replacingTitle || title != nil { entry.title = title }
        }
        do {
            try takeOwnership(of: file, sessionId: sessionId)
        } catch {
            notify("error", "Could not take ownership of \(file): \(error)")
        }
    }

    private func becomeIdleIfStarting() async {
        if status == .starting || status == .resuming { await setStatus(.idle) }
    }

    // MARK: - Ownership

    private func takeOwnership(of file: String, sessionId: String?) throws {
        let canonical = OwnershipLock.canonicalPath(file)
        guard lockedFile != canonical else { return }
        let handle = try context.locks.acquire(sessionFile: file, sessionId: sessionId, sessionKey: sessionKey)
        releaseLock()
        lock = handle
        lockedFile = canonical
    }

    private func releaseLock() {
        lock?.release()
        lock = nil
        lockedFile = nil
    }

    // MARK: - Manifest

    private func setStatus(_ new: SessionStatus) async {
        status = new
        await updateEntry { $0.status = new }
    }

    private func updateEntry(_ body: @escaping @Sendable (inout SessionManifestEntry) -> Void) async {
        do {
            try await context.manifest.updateEntry(sessionKey, body)
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): manifest update failed: \(String(describing: error), privacy: .public)")
            context.persistenceFailed(error)
        }
    }

    private func notify(_ level: String, _ message: String) {
        supervisorLog.log(
            level: level == "error" ? .error : .default,
            "session \(self.sessionKey, privacy: .public): \(message, privacy: .public)")
        context.notify(DaemonNotice(level: level, message: message, sessionKey: sessionKey, at: Date()))
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// A one-shot event (a spawn's omp exited) that any number of tasks can await with a timeout. Opened from the PTY
/// pool's exit callback, so waiters wake even while the supervisor is busy.
final class ExitGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    var isOpen: Bool { state.withLock { $0.isOpen } }

    func open() {
        let waiters = state.withLock { s in
            s.isOpen = true
            defer { s.waiters = [:] }
            return s.waiters
        }
        for waiter in waiters.values { waiter.resume() }
    }

    /// True once open; false after `timeout` (or when the calling task is cancelled) while still closed.
    func wait(timeout: Duration) async -> Bool {
        if isOpen { return true }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
        }
        return isOpen
    }

    private func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.isOpen || Task.isCancelled { return true }
                    s.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

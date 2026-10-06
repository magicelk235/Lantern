import Darwin
import Foundation
import IDEProtocol
import os

/// Owns one IDE session (`SessionKey`): the omp TUI currently serving it, running on a session PTY of the daemon's
/// pool. It spawns omp from the manifest's `LaunchSpec`, follows the ide-bridge inside it (identity,
/// busy/idle, title, session switches, pause) into the manifest, holds the session file's ownership lock, respawns omp
/// with `--resume` when it dies, pauses omp's agents while the daemon wants them paused, and stops it the
/// graceful way (bridge `session.shutdown`), never with a signal first. A bridge whose connection ends while
/// omp runs redials (an in-place ompd upgrade, or a blip); it is followed again from its new hello.
///
/// An adopted session (`adoptTerminalSession`) is an omp the user started in one of the IDE's terminals: the same
/// bridge, the same manifest, the same pause policy, but the PTY is the terminal's, which ompd neither spawned nor
/// signals. The bridge is the only handle on that omp: a graceful stop goes through it or not at all. Its exit (watched
/// as a process, ompd is not its parent) closes the session — never respawned, it resumes in a session PTY like any
/// other.
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
        /// `restart`: omp is resumed right after it exits.
        case restart
    }

    private let context: SupervisorContext
    private var status: SessionStatus {
        didSet {
            publishRuntime() // the main agent's row follows it
            noteChange()
        }
    }

    // The omp TUI
    /// The session's PTY: running, or exited and kept so its last screen stays attachable. Mirrors `entry.ptyId`. For an
    /// adopted session, the terminal PTY omp runs in.
    private var ptyId: PTYID?
    /// The running omp; nil once it exited.
    private var pid: Int32?
    /// omp runs in a terminal the user started it in (`entry.adopted`): no PTY of its own, no signals, no respawn.
    private var adopted = false
    /// Bumped per spawn; work tied to an older spawn is dropped.
    private var generation = 0
    /// Opens when the current spawn's omp exits.
    private var exited = ExitGate()
    private var spawnedAt = Date.distantPast
    private var startTask: Task<Void, any Error>? {
        didSet { noteChange() }
    }
    private var bridgeTask: Task<Void, Never>?
    private var bridgeHello: BridgeHello?
    /// Where the current spawn's ide-bridge stands.
    private var link = BridgeLink.none {
        didSet { if link != oldValue { noteChange() } }
    }
    /// An adopted omp's exit (it is not ompd's child, so no PTY reaps it).
    private var exitWatch: ProcessExitWatch?
    /// ompd is stopping omp: its exit is expected and finished by `stop` (or by `restart`, which resumes it).
    private var stopping: StopIntent? {
        didSet { noteChange() }
    }
    /// `stop` was called: nothing starts omp again until `reopen` or an adoption.
    private var stopRequested = false
    /// When automatic respawns happened (crash-loop guard).
    private var respawns: [ContinuousClock.Instant] = []
    /// Tasks waiting for any of the above to change (`waitForChange`).
    private var changeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// The ide-bridge of the current spawn, as the supervisor follows it.
    enum BridgeLink: Sendable, Equatable {
        /// No omp runs.
        case none
        /// omp was spawned; its bridge has not said hello yet.
        case awaitingHello
        /// omp runs without a bridge: none said hello in time.
        case absent
        case connected
        /// The connection ended while omp runs: the bridge redials (an ompd upgrade, a dropped connection).
        case redialing
    }

    // Regime B recovery
    /// What the omp that died (or that `restart` stopped) left unfinished, found before the respawn with `--resume` and
    /// applied once the resumed omp's bridge said hello (continuation policy, service relaunch). Only a resume carries it.
    private var recovery: Recovery?
    /// The pass after a spawn's hello that applies the pause demand, then `recovery`; with the spawn's generation.
    private var recoveryTask: (generation: Int, task: Task<Void, Never>)? {
        didSet { noteChange() }
    }

    private struct Recovery {
        /// What a death left: handled per the restore policy, merged with an interruption waiting for a decision.
        var interruption: Interruption?
        /// `restart` stopped omp: what its stop interrupted (`restarted`) is continued whatever the restore policy,
        /// and an interruption waiting for a decision keeps waiting.
        var restart = false
        var restarted: Interruption?
    }

    // omp's pause gate
    /// Who holds the gate closed, as the bridge last reported it; nil while it is open.
    private var pausedBy: PauseOwner?
    /// The main agent's activity (`busy`/`idle`) underneath a pause: the status once the pause ends.
    private var activity: SessionStatus = .idle
    /// A `syncPause` pass runs; `pauseRecheck` makes it look at the demand once more when its bridge call returns.
    private var pauseSyncing = false
    private var pauseRecheck = false

    // Ownership
    private var lock: (any SessionLockHandle)?
    /// Canonical path (`OwnershipLock.canonicalPath`) of the locked session file.
    private var lockedFile: String?

    // Agent supervision
    /// What omp runs, folded from its bridge since the hello; empty while there is none.
    private var tracker = RuntimeTracker()
    /// Subagents of the interruption waiting for the user's decision (`pendingContinuation.agents`): parked, they read
    /// `interrupted`.
    private var heldAgents: Set<String> {
        didSet { publishRuntime() }
    }
    /// The runtime clients last got (`context.runtimeChanged`).
    private var publishedRuntime: SessionRuntime

    /// `entry` is the session's current manifest entry.
    public init(entry: SessionManifestEntry, context: SupervisorContext) {
        sessionKey = entry.sessionKey
        self.context = context
        status = entry.status
        ptyId = entry.ptyId
        heldAgents = Set(entry.pendingContinuation?.agents.map(\.id) ?? [])
        publishedRuntime = SessionRuntime(sessionKey: entry.sessionKey)
    }

    // MARK: - Queries

    /// omp runs (it may be being stopped).
    public var isRunning: Bool { pid != nil }

    /// omp runs or is being started: nothing else may serve the session now.
    public var isOpen: Bool { pid != nil || startTask != nil }

    public var currentStatus: SessionStatus { status }

    /// What omp runs, as clients last got it: empty while omp does not run or before its bridge said hello.
    public var runtime: SessionRuntime { publishedRuntime }

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

    /// An omp the user started in terminal PTY `terminal` said hello with the terminal's credentials and ompd accepted
    /// it (`hello`, as the bridge registered it under this session's key): from now on this session is that omp. Only
    /// while omp does not run for the session (a new entry, or one that is closed or given up); `lock` is the file's
    /// ownership lock the daemon already took for a new entry, nil for a session of this supervisor's own, which takes
    /// it itself. `workspace` is omp's cwd. Follows the bridge from here as after a spawn's hello, applies the pause
    /// demand, and watches the omp process for its exit.
    public func adoptTerminalSession(
        hello: BridgeHello, terminal: PTYID, workspace: String, lock handle: (any SessionLockHandle)?
    ) async throws {
        if let startTask { _ = try? await startTask.value }
        guard pid == nil else { throw DaemonError(.sessionBusy, "session \(sessionKey) is already open") }
        if let handle {
            adoptLock(handle, sessionFile: hello.sessionFile)
        } else {
            try takeOwnership(of: hello.sessionFile, sessionId: hello.sessionId)
        }
        stopRequested = false
        stopping = nil
        respawns = []
        generation += 1
        let generation = generation
        bridgeTask?.cancel()
        let gate = ExitGate()
        exited = gate
        let previous = ptyId
        pid = hello.pid
        ptyId = terminal
        adopted = true
        spawnedAt = Date()
        bridgeHello = hello
        pausedBy = hello.pausedBy
        activity = .idle
        let new: SessionStatus = pausedBy == nil ? .idle : .paused
        status = new
        let title = hello.title
        let now = Date()
        await updateEntry { entry in
            entry.workspace = workspace
            entry.sessionFile = hello.sessionFile
            entry.sessionId = hello.sessionId
            if let title { entry.title = title }
            entry.status = new
            entry.ptyId = terminal
            entry.adopted = true
            entry.spawnedAt = now
            entry.closedByUser = false
            entry.lastActiveAt = now
        }
        // The last screen of the session's own previous omp, if a PTY was kept for it: the terminal shows omp now.
        if let previous, previous != terminal { try? await context.ptys.close(previous) }
        warnAboutCapabilities(of: hello)
        link = .connected
        watchAdoptedExit(of: hello.pid, generation: generation, gate: gate)
        Task { await self.syncPause() }
        bridgeTask = Task { await self.followAdoptedBridge(hello: hello, generation: generation) }
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
                recovery = Recovery(interruption: InterruptionAnalyzer.analyze(
                    sessionFile: file, since: entry.spawnedAt, cause: "ompd restarted"))
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

        // The omp this spawn runs: the pinned one or, when that is gone (an upgrade removed its Cellar folder),
        // the one a new session would get; and the version it reports, recorded as what the session runs.
        let pinned = entry.launch.ompPath
        let omp: String
        if OmpBinary.isUsable(pinned) {
            omp = pinned
        } else {
            do {
                omp = try OmpBinary.locate(explicit: context.ompExecutable, environment: context.baseEnvironment)
            } catch {
                notify("error", "omp is no longer at \(pinned), and no other omp was found: \(error)")
                await setStatus(.needsAttention)
                throw DaemonError(.ompError, "omp is gone from \(pinned): \(error)")
            }
        }
        let version: String?
        do {
            version = try await OmpBinary.version(at: omp, timeout: .seconds(10))
        } catch {
            version = nil
            supervisorLog.error("session \(self.sessionKey, privacy: .public): the version of \(omp, privacy: .public) is unknown: \(String(describing: error), privacy: .public)")
        }

        await setStatus(mode == .resume ? .resuming : .starting)
        if mode == .fresh { recovery = nil }
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
                command: [omp] + Self.arguments(for: entry.launch, bridgeExtension: context.bridgeExtension, resume: resumeFile),
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
        adopted = false
        spawnedAt = Date()
        stopping = nil
        link = pid == nil ? .none : .awaitingHello
        // A new omp starts with its pause gate open and its main agent waiting for input.
        pausedBy = nil
        activity = .idle
        if let pid = info.pid { await context.bridge.setExpectedPID(pid, for: sessionKey) }
        let now = spawnedAt
        await updateEntry { entry in
            entry.ptyId = info.ptyId
            entry.adopted = false
            entry.spawnedAt = now
            entry.launch.ompPath = omp
            if let version {
                entry.launch.ompVersion = version
                entry.installedOmpVersion = version
            }
        }
        if omp != pinned {
            notify("info", "omp is no longer at \(pinned) (an upgrade may have removed it); this session now runs \(omp)\(version.map { ", omp \($0)" } ?? "").")
        }
        if let version { context.ompSpawned(version, omp) }
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
        if let sessionFile {
            // Merged with what a previous death left, if the resume that was to apply it never got to its hello.
            let found = InterruptionAnalyzer.analyze(sessionFile: sessionFile, since: spawnedAt, cause: "omp exited unexpectedly: \(exit)")
            // A restart's continuation the resume never got to stays too.
            var next = recovery ?? Recovery()
            next.interruption = InterruptionAnalyzer.merge(recovery?.interruption, found)
            recovery = next
        }
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

    /// An adopted omp exited (`/exit`, a crash, its terminal closed) or was stopped through the bridge. An exit ompd
    /// asked for is finished by `stop`. Any other makes the session `closed` — how omp ended is its terminal's business,
    /// and nothing is respawned into it — with no PTY of its own: the terminal stays a terminal, and the session resumes
    /// in a session PTY like any other.
    private func adoptedOmpGone(generation: Int) async {
        guard generation == self.generation, stopping == nil, !stopRequested else { return }
        await forgetSpawn()
        adopted = false
        releaseLock()
        ptyId = nil
        status = .closed
        await updateEntry { entry in
            entry.status = .closed
            entry.ptyId = nil
            entry.adopted = false
        }
        notify("info", "omp exited in its terminal; the session is closed. Open it again to resume it.")
    }

    /// Watches the adopted omp `pid` (the shell of its terminal reaps it, not ompd): its exit opens `gate` and closes the
    /// session.
    private func watchAdoptedExit(of pid: Int32, generation: Int, gate: ExitGate) {
        exitWatch = ProcessExitWatch(pid: pid) { [weak self] in
            gate.open()
            Task { await self?.adoptedOmpGone(generation: generation) }
        }
    }

    /// Drops what belonged to the omp that exited; clients get its runtime emptied. Idempotent.
    private func forgetSpawn() async {
        pid = nil
        link = .none
        exitWatch = nil
        bridgeTask?.cancel()
        bridgeTask = nil
        bridgeHello = nil
        pausedBy = nil
        tracker = RuntimeTracker()
        publishRuntime()
        await context.bridge.forget(sessionKey)
    }

    // MARK: - Stop

    /// Graceful stop: bridge `session.shutdown` (omp disposes: `session_exit {kind:"normal"}`, tool
    /// processes torn down) and up to `timings.stop` for the exit; then SIGHUP (the only step without a bridge), then
    /// SIGKILL of the process group. Returns once omp is gone. `.user` then closes the session and its PTY.
    ///
    /// An adopted omp gets the bridge step only: its terminal is never signalled or closed. If it does not exit, a
    /// `.user` stop leaves the session as it was (omp keeps running in its terminal); a `.daemonShutdown` stop leaves
    /// the rest to the PTY pool's shutdown, which hangs the terminals up.
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
            if adopted, !exited.isOpen {
                if intent == .user {
                    stopping = nil
                    stopRequested = false
                    await updateEntry { $0.closedByUser = false }
                }
                return
            }
            await forgetSpawn()
        }
        guard intent == .user else { return }
        releaseLock()
        let closing = adopted ? nil : ptyId
        adopted = false
        ptyId = nil
        status = .closed
        await updateEntry { entry in
            entry.status = .closed
            entry.ptyId = nil
            entry.closedByUser = true
            entry.adopted = false
        }
        if let closing { try? await context.ptys.close(closing) }
    }

    /// `session.forget`: the session is about to leave the manifest. Only while omp is not running and nothing will
    /// start it again (`closed`, or `needs_attention`); a running, starting or respawning session is refused with
    /// `sessionBusy`. Releases the ownership lock and closes the PTY kept for the last screen. Nothing starts omp again.
    public func forget() async throws {
        if let startTask { _ = try? await startTask.value }
        guard pid == nil, status == .closed || status == .needsAttention else {
            throw DaemonError(.sessionBusy, "session \(sessionKey) is \(status.rawValue); close it before forgetting it")
        }
        stopRequested = true
        releaseLock()
        let closing = ptyId
        ptyId = nil
        if let closing { try? await context.ptys.close(closing) }
    }

    /// `session.restart`: omp stops the graceful way, then is resumed at once with
    /// `--resume` in a new PTY that continues its screen, running whatever omp is installed at `launch.ompPath` now (a
    /// session that never wrote its file starts afresh, as after a death). What the stop interrupts is continued whatever
    /// the restore policy; an interruption already waiting for the user's decision keeps waiting. Refused with
    /// `sessionBusy` while omp is not running (or is being started or stopped) and while the main agent is busy, unless
    /// `force`; with `badParams` for an omp the user started in a terminal. Returns once the new omp runs; a stop that
    /// comes in meanwhile wins (nothing is resumed).
    public func restart(force: Bool) async throws {
        if let startTask { _ = try? await startTask.value }
        guard pid != nil, !stopRequested else {
            throw DaemonError(.sessionBusy, "omp is not running in session \(sessionKey)")
        }
        guard !adopted else {
            throw DaemonError(.badParams, "omp runs in the terminal the user started it in (session \(sessionKey)); restart it there")
        }
        guard stopping == nil, [.idle, .busy, .paused].contains(status) else {
            throw DaemonError(.sessionBusy, "omp of session \(sessionKey) is starting or stopping; try again in a moment")
        }
        guard force || activity != .busy else {
            throw DaemonError(.sessionBusy, "the main agent of session \(sessionKey) is busy; restart the session once it is idle")
        }
        let runStart = spawnedAt
        stopping = .restart
        await terminate()
        await forgetSpawn()
        guard !stopRequested else { return }
        guard let file = await context.manifest.entry(sessionKey)?.sessionFile, FileManager.default.fileExists(atPath: file) else {
            return try await start(.fresh)
        }
        let restarted = InterruptionAnalyzer.analyze(sessionFile: file, since: runStart, cause: "the session was restarted from Lantern")
        // What an earlier death left and a resume never got to apply (its bridge did not say hello) is kept for its policy.
        recovery = Recovery(interruption: recovery?.interruption, restart: true, restarted: restarted)
        try await start(.resume)
    }

    private func terminate() async {
        guard let ptyId else { return }
        let gate = exited
        let timings = context.timings
        var asked = false
        if link == .redialing {
            // The graceful stop goes through the bridge, which is reconnecting (an ompd upgrade, a blip).
            await waitWhile({ link == .redialing }, timeout: timings.redial)
        }
        if bridgeHello?.capabilities["session.shutdown"] == true {
            let deadline = ContinuousClock.now + timings.stop
            do {
                _ = try await context.bridge.call(sessionKey, method: "session.shutdown", params: [:], timeout: timings.stop)
                asked = true
            } catch BridgeError.disconnected {
                asked = true // the bridge went away while omp disposed
            } catch {
                notify(
                    "warning",
                    adopted
                        ? "The graceful shutdown through the ide-bridge failed (\(error)); omp keeps running in its terminal."
                        : "The graceful shutdown through the ide-bridge failed (\(error)); hanging up omp's terminal.")
            }
            if asked {
                if await gate.wait(timeout: max(.zero, deadline - ContinuousClock.now)) { return }
                notify(
                    "warning",
                    adopted
                        ? "omp did not exit within \(timings.stop) of the graceful shutdown; it keeps running in its terminal."
                        : "omp did not exit within \(timings.stop) of the graceful shutdown; hanging up its terminal.")
            }
        } else if adopted {
            notify("warning", "This omp cannot be stopped through the ide-bridge; it keeps running in its terminal.")
        }
        // An adopted omp's terminal is the user's: never signalled.
        guard !adopted else { return }
        try? await context.ptys.signal(ptyId, SIGHUP)
        if await gate.wait(timeout: asked ? timings.hangup : timings.stop) { return }
        notify("warning", "omp did not exit after SIGHUP; killing its process group.")
        try? await context.ptys.signal(ptyId, SIGKILL)
        _ = await gate.wait(timeout: timings.hangup)
    }

    // MARK: - Health

    /// After a wake from sleep: omp must answer the bridge's `session.info`. A main agent busy in a turn
    /// (not paused) then gets `timings.wakeStallTimeout` to show progress; a turn whose model stream stalled is aborted
    /// by the bridge and the agent is told to continue (a transport failure, not a death: no policy applies).
    public func healthCheck() async {
        guard pid != nil, stopping == nil, let hello = bridgeHello else { return }
        let generation = generation
        let started = ContinuousClock.now
        do {
            _ = try await context.bridge.call(sessionKey, method: "session.info", params: [:], timeout: context.timings.healthCheck)
            let elapsed = ContinuousClock.now - started
            supervisorLog.info("session \(self.sessionKey, privacy: .public): wake health check answered in \(elapsed, privacy: .public)")
        } catch {
            notify("warning", "Wake health check: omp did not answer session.info through the ide-bridge (\(error)).")
            return
        }
        guard activity == .busy, pausedBy == nil, hello.capabilities["session.watchStall"] == true else { return }
        let timeout = context.timings.wakeStallTimeout
        do {
            let result = try await context.bridge.call(
                sessionKey, method: "session.watchStall",
                params: ["timeoutMs": .number(Double(timeout.components.seconds * 1000))],
                timeout: timeout + context.timings.bridgeCall)
            guard result["stalled"]?.boolValue == true, generation == self.generation, pid != nil else { return }
            notify("warning", "omp's model stream made no progress for \(timeout) after the wake; the turn was aborted and the agent asked to continue.")
            try await prompt(ContinuationMessages.wake)
        } catch {
            guard generation == self.generation, pid != nil else { return }
            notify("warning", "Wake stall check failed: \(error)")
        }
    }

    // MARK: - Recovery

    /// After the resumed omp's hello: its persisted subagents registered, named services relaunched, and what the dead
    /// omp left unfinished (with any interruption still waiting for a decision) handled per the restore policy. After a
    /// `restart`, what its stop interrupted is continued, and an interruption waiting for a decision keeps waiting (unless
    /// an earlier death's comes along, which goes through the policy as it would have).
    private func recover(_ recovery: Recovery, generation: Int) async {
        guard generation == self.generation, pid != nil, let hello = bridgeHello else { return }
        if hello.capabilities["agents.loadPersisted"] == true {
            do {
                _ = try await context.bridge.call(sessionKey, method: "agents.loadPersisted", params: [:], timeout: context.timings.bridgeCall)
            } catch {
                supervisorLog.error("session \(self.sessionKey, privacy: .public): agents.loadPersisted failed: \(String(describing: error), privacy: .public)")
            }
        }
        await relaunchServices()
        guard generation == self.generation, pid != nil else { return }
        if !recovery.restart || recovery.interruption != nil { await applyPolicy(to: recovery.interruption) }
        guard let restarted = recovery.restarted, generation == self.generation, pid != nil else { return }
        if restarted.evalKernelsLost {
            notify("info", "The eval kernels of the omp that ended are gone; variables and imports defined in them must be loaded again.")
        }
        await deliver(restarted, main: restarted.mainInterrupted, agents: restarted.agents, notContinued: [])
    }

    /// `found` (what a death left) merged with the interruption waiting for a decision, handled per the restore policy.
    private func applyPolicy(to found: Interruption?) async {
        let waiting = await context.manifest.entry(sessionKey)?.pendingContinuation
        guard let interruption = InterruptionAnalyzer.merge(waiting, found) else { return }
        if interruption.evalKernelsLost, found?.evalKernelsLost == true {
            notify("info", "The eval kernels of the omp that ended are gone; variables and imports defined in them must be loaded again.")
        }
        let policy = await context.manifest.store.current.restorePolicy
        let main = interruption.mainInterrupted
        let agents = interruption.agents
        let leftMain = main && policy.main == .never
        let leftAgents = policy.subagents == .never ? agents : []
        let askMain = main && policy.main == .ask
        let askAgents = policy.subagents == .ask ? agents : []
        let autoMain = main && policy.main == .auto
        let autoAgents = policy.subagents == .auto ? agents : []

        let asked = Interruption(
            detectedAt: interruption.detectedAt, cause: interruption.cause, mainInterrupted: askMain,
            pendingToolCalls: askMain ? interruption.pendingToolCalls : [], agents: askAgents,
            evalKernelsLost: interruption.evalKernelsLost)
        heldAgents = Set(askAgents.map(\.id))
        await updateEntry { $0.pendingContinuation = asked.isEmpty ? nil : asked }
        if leftMain || !leftAgents.isEmpty {
            await mark(interruption, decision: "left", main: leftMain, agents: leftAgents.map(\.id))
        }
        if autoMain || !autoAgents.isEmpty {
            await deliver(interruption, main: autoMain, agents: autoAgents, notContinued: (leftAgents + askAgents).map(\.id))
        }
    }

    /// `session.continue`: the user's answer to the interruption waiting for a decision. The main agent (if `main` and
    /// it was interrupted) and the subagents in `ids` continue; the rest is left.
    public func continueInterrupted(main: Bool, agents ids: [String]) async throws {
        if let startTask { _ = try? await startTask.value }
        guard let pending = await context.manifest.entry(sessionKey)?.pendingContinuation else {
            throw DaemonError(.badParams, "no interruption is waiting for a decision in session \(sessionKey)")
        }
        let continueMain = main && pending.mainInterrupted
        let chosen = pending.agents.filter { ids.contains($0.id) }
        let left = pending.agents.filter { !ids.contains($0.id) }
        let running = pid != nil && bridgeHello != nil && stopping == nil
        guard running || (!continueMain && chosen.isEmpty) else {
            throw DaemonError(.sessionBusy, "omp is not running in session \(sessionKey); open the session first")
        }
        heldAgents = []
        await updateEntry { $0.pendingContinuation = nil }
        guard running else { return } // left while omp is not running: nothing to tell it
        let leftMain = pending.mainInterrupted && !continueMain
        if leftMain || !left.isEmpty {
            await mark(pending, decision: "left", main: leftMain, agents: left.map(\.id))
        }
        if continueMain || !chosen.isEmpty {
            await deliver(pending, main: continueMain, agents: chosen, notContinued: left.map(\.id))
        }
    }

    /// Tells the interrupted agents to continue: subagents first (like `write agent://<id>`, which revives them; their
    /// results reach the main agent the usual way), then the main agent, so its waiting on them holds.
    /// The marker goes first, so a death during the continuation is an interruption of its own.
    private func deliver(_ interruption: Interruption, main: Bool, agents: [InterruptedAgent], notContinued: [String]) async {
        let capabilities = bridgeHello?.capabilities ?? [:]
        let canMessage = capabilities["agent.message"] == true
        let canPrompt = capabilities["session.prompt"] == true
        let messaged = canMessage ? agents : []
        await mark(interruption, decision: "continued", main: main && canPrompt, agents: messaged.map(\.id))
        if !agents.isEmpty, !canMessage {
            notify("warning", "The interrupted subagents (\(agents.map(\.id).joined(separator: ", "))) cannot be asked to continue: this omp's ide-bridge cannot message agents.")
        }
        var continued: [String] = []
        for agent in messaged {
            do {
                _ = try await context.bridge.call(
                    sessionKey, method: "agent.message",
                    params: ["id": .string(agent.id), "body": .string(ContinuationMessages.agent(agent, cause: interruption.cause))],
                    timeout: context.timings.bridgeCall)
                continued.append(agent.id)
            } catch {
                notify("warning", "Subagent \(agent.id) could not be asked to continue: \(error)")
            }
        }
        guard main else { return }
        guard canPrompt else {
            notify("warning", "The main agent cannot be asked to continue: this omp's ide-bridge cannot submit prompts. Tell it in the session.")
            return
        }
        let leftAgents = notContinued + messaged.map(\.id).filter { !continued.contains($0) }
        do {
            try await prompt(ContinuationMessages.main(interruption, continuedAgents: continued, leftAgents: leftAgents))
        } catch {
            notify("warning", "The main agent could not be asked to continue: \(error)")
        }
    }

    private func prompt(_ text: String) async throws {
        _ = try await context.bridge.call(sessionKey, method: "session.prompt", params: ["text": .string(text)], timeout: context.timings.bridgeCall)
    }

    /// Appends the `com.magicelklabs.lantern.interrupted` entry (IDE bookkeeping, not model context): the interruption is handled,
    /// and is not reported again at a later death.
    private func mark(_ interruption: Interruption, decision: String, main: Bool, agents: [String]) async {
        guard bridgeHello?.capabilities["entry.append"] == true else { return }
        do {
            let data: JSONValue = [
                "recordedAt": .string(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
                "detectedAt": .string(interruption.detectedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
                "cause": .string(interruption.cause),
                "decision": .string(decision),
                "main": .bool(main),
                "pendingToolCalls": try JSONValue(encoding: main ? interruption.pendingToolCalls : []),
                "agents": .array(agents.map { .string($0) }),
            ]
            _ = try await context.bridge.call(
                sessionKey, method: "entry.append",
                params: ["customType": .string(InterruptionAnalyzer.markerType), "data": data], timeout: context.timings.bridgeCall)
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): interruption marker not written: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Named services

    /// A `service` event: the manifest keeps the spec and whether it should run (omp's broker can neither tell an
    /// idle-out from a stop nor keep its records).
    private func noteService(_ data: JSONValue?) async {
        guard let data, let op = data["op"]?.stringValue else { return }
        switch op {
        case "started":
            guard let name = data["name"]?.stringValue else { return }
            var env: [String: String] = [:]
            for (key, value) in data["env"]?.objectValue ?? [:] { if let value = value.stringValue { env[key] = value } }
            // A new spec under a live name replaces it, and omp resets its mode to `session`.
            let service = NamedService(
                id: name, mode: "session", command: data["command"]?.stringValue, cwd: data["cwd"]?.stringValue, env: env,
                pty: data["pty"]?.boolValue ?? true, ready: data["ready"].flatMap { $0 == .null ? nil : $0 }, desiredRunning: true)
            await updateEntry { entry in
                entry.services.removeAll { $0.id == name }
                entry.services.append(service)
            }
        case "stopped", "exited":
            let names = Set(data["names"]?.arrayValue?.compactMap(\.stringValue) ?? [data["name"]?.stringValue].compactMap { $0 })
            await updateEntry { entry in
                for index in entry.services.indices where names.contains(entry.services[index].id) {
                    entry.services[index].desiredRunning = false
                }
            }
        case "mode":
            guard let name = data["name"]?.stringValue, let mode = data["mode"]?.stringValue else { return }
            await updateEntry { entry in
                for index in entry.services.indices where entry.services[index].id == name {
                    entry.services[index].mode = mode
                    if mode == "detached" { entry.services[index].pty = false }
                }
            }
        default:
            break
        }
    }

    /// Services that should run and do not (the broker reaped them with the omp, or the machine restarted) are
    /// relaunched from the broker's record with `omp ps restart`, which keeps their spec and mode. A service the broker
    /// no longer knows cannot be relaunched by ompd: a notice says so, and it is not tried again.
    private func relaunchServices() async {
        guard let entry = await context.manifest.entry(sessionKey) else { return }
        let desired = entry.services.filter(\.desiredRunning)
        guard !desired.isEmpty else { return }
        let environment = context.baseEnvironment.merging(entry.launch.env) { $1 }
        let control = context.services
        let states: [String: String]
        do {
            states = try await control.states(workspace: entry.workspace, omp: entry.launch.ompPath, environment: environment)
        } catch {
            notify("warning", "Named services could not be checked after the restart: \(error)")
            return
        }
        var restarted: [String] = []
        var lost: [NamedService] = []
        for service in desired {
            guard let state = states[service.id] else {
                lost.append(service)
                continue
            }
            guard !liveServiceStates.contains(state) else { continue }
            do {
                switch try await control.run(.restart, service.id, workspace: entry.workspace, omp: entry.launch.ompPath, environment: environment) {
                case .done: restarted.append(service.id)
                case .unknown: lost.append(service)
                case .failed(let message): notify("warning", "The service \(service.id) could not be restarted: \(message)")
                }
            } catch {
                notify("warning", "The service \(service.id) could not be restarted: \(error)")
            }
        }
        if !restarted.isEmpty {
            notify("info", "Restarted the named service\(restarted.count == 1 ? "" : "s") \(restarted.joined(separator: ", ")).")
        }
        guard !lost.isEmpty else { return }
        for service in lost {
            notify("warning", "The service \(service.id) was not restored: omp no longer has its record. Ask the agent to start it again\(service.command.map { " (\($0))" } ?? "").")
        }
        let names = Set(lost.map(\.id))
        await updateEntry { entry in
            for index in entry.services.indices where names.contains(entry.services[index].id) {
                entry.services[index].desiredRunning = false
            }
        }
    }

    // MARK: - Bridge

    private func followBridge(generation: Int) async {
        let hello: BridgeHello
        do {
            hello = try await context.bridge.waitForHello(sessionKey, timeout: context.timings.hello)
        } catch {
            guard generation == self.generation, pid != nil, stopping == nil else { return }
            link = .absent
            notify(
                "warning",
                "The ide-bridge extension did not connect (\(error)); status, title, graceful stop and resume after a crash are unavailable for this omp process.")
            await becomeIdleIfStarting()
            return
        }
        guard generation == self.generation, pid != nil else { return }
        bridgeHello = hello
        pausedBy = hello.pausedBy
        link = .connected
        warnAboutCapabilities(of: hello)
        await adopt(sessionFile: hello.sessionFile, sessionId: hello.sessionId, title: hello.title, replacingTitle: false)
        await becomeIdleIfStarting()
        // An omp spawned while no Lantern window is connected is paused right away, before a recovery gives its
        // agents anything to do.
        let recovery = recovery
        self.recovery = nil
        recoveryTask = (generation, Task {
            await self.syncPause()
            if let recovery { await self.recover(recovery, generation: generation) }
            self.recoveryEnded(generation: generation)
        })
        await seedRuntime(from: hello, generation: generation)
        await followConnections(generation: generation)
    }

    private func recoveryEnded(generation: Int) {
        if recoveryTask?.generation == generation { recoveryTask = nil }
    }

    /// The bridge of an adopted omp, from its hello on.
    private func followAdoptedBridge(hello: BridgeHello, generation: Int) async {
        await seedRuntime(from: hello, generation: generation)
        await followConnections(generation: generation)
    }

    /// The bridge's events, connection after connection. When one ends while omp runs, nothing it reported holds any
    /// more and the bridge redials (after an ompd upgrade, or a dropped connection): followed again from its new hello
    /// (`reconnected`). Ends when omp exits (its spawn is forgotten) or another spawn takes over.
    private func followConnections(generation: Int) async {
        while true {
            for await event in await context.bridge.events(sessionKey) {
                guard generation == self.generation else { return }
                await handle(bridgeEvent: event)
            }
            guard generation == self.generation else { return }
            tracker = RuntimeTracker()
            publishRuntime()
            guard pid != nil else { return }
            link = .redialing
            await followRedial(generation: generation)
            guard generation == self.generation, link == .connected else { return }
        }
    }

    /// Waits for the bridge to redial; nothing comes of it once omp exited.
    private func followRedial(generation: Int) async {
        let hello: BridgeHello
        do {
            hello = try await context.bridge.waitForRedial(sessionKey)
        } catch {
            return
        }
        guard generation == self.generation, pid != nil else { return }
        await reconnected(hello, generation: generation)
    }

    /// A redial's hello: what it says replaces what the gap may have hidden — the pause gate, the main agent's activity,
    /// the session file and title — ompd's pause demand applies again, and the agent tree, what waits for the user and the
    /// jobs are read again.
    private func reconnected(_ hello: BridgeHello, generation: Int) async {
        bridgeHello = hello
        link = .connected
        if let busy = hello.activity { activity = busy }
        await notePause(hello.pausedBy)
        await adopt(sessionFile: hello.sessionFile, sessionId: hello.sessionId, title: hello.title, replacingTitle: false)
        Task { await self.syncPause() }
        await seedRuntime(from: hello, generation: generation)
    }

    private func warnAboutCapabilities(of hello: BridgeHello) {
        if hello.capabilities["events.activity"] != true {
            notify("warning", "An older copy of the ide-bridge serves this omp (no activity or title events); the session's status and title will not update until it is restarted with the current Lantern.")
        } else if hello.capabilities["session.pause"] != true {
            notify("warning", "This omp cannot be paused through the ide-bridge; its agents keep working while Lantern is closed.")
        }
    }

    private func handle(bridgeEvent event: JSONValue) async {
        if event["t"]?.stringValue == "gap" { return await resyncRuntime() }
        guard event["t"]?.stringValue == "evt", let kind = event["kind"]?.stringValue else { return }
        let data = event["data"]
        switch kind {
        case "activity":
            guard let state = data?["state"]?.stringValue, [.busy, .idle, .paused, .starting, .resuming].contains(status) else {
                return
            }
            activity = state == "busy" ? .busy : .idle
            let new: SessionStatus = pausedBy == nil ? activity : .paused
            let now = Date()
            status = new
            await updateEntry { entry in
                entry.status = new
                entry.lastActiveAt = now
            }
        case "pause":
            guard let paused = data?["paused"]?.boolValue else { return }
            await notePause(PauseOwner(paused: paused, by: data?["by"]?.stringValue))
        case "title":
            guard let title = data?["title"]?.stringValue, !title.isEmpty else { return }
            await updateEntry { $0.title = title }
        case "session_switch":
            // `/new`, `/resume`, `/fork` inside the TUI: the session now lives in another file.
            guard data?["isMain"]?.boolValue == true, let session = data?["session"], let file = session["file"]?.stringValue else {
                return
            }
            await adopt(sessionFile: file, sessionId: session["id"]?.stringValue, title: session["title"]?.stringValue, replacingTitle: true)
        case "service":
            await noteService(data)
        case "jobs":
            tracker.replaceJobs(data)
            publishRuntime()
        case "attention":
            tracker.attention = RuntimeTracker.attention(data?["items"])
            publishRuntime()
        default:
            guard kind.hasPrefix("registry:") else { return }
            tracker.apply(registry: String(kind.dropFirst("registry:".count)), row: data)
            publishRuntime()
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
        if status == .starting || status == .resuming { await setStatus(pausedBy == nil ? .idle : .paused) }
    }

    // MARK: - Agent supervision

    /// `agent.control`: revives, parks or kills agent `id` of the running omp; reviving the main agent is a no-op.
    /// Returns its row afterwards, nil once omp no longer lists it. `bridgeUnavailable` while omp does not run or its
    /// bridge cannot do it, `ompError` when omp refuses.
    public func control(agent id: String, _ action: AgentControl.Action) async throws -> AgentInfo? {
        let method = "agent.\(action.rawValue)"
        if let unavailable = bridgeUnavailable(for: method) { throw unavailable }
        if action == .revive, id == RuntimeTracker.mainAgentID { return publishedRuntime.agents.first { $0.id == id } }
        let result = try await callBridge(method, params: ["id": .string(id)])
        return tracker.agent(fromRow: result["agent"], mainStatus: RuntimeTracker.mainStatus(status), held: heldAgents)
    }

    /// `agent.message`: `write agent://<id>` from the main agent, which revives a parked agent; its answer reaches the
    /// main agent like any reply. Errors as `control`.
    public func message(agent id: String, body: String) async throws {
        _ = try await callBridge("agent.message", params: ["id": .string(id), "body": .string(body)])
    }

    /// What `write proc://<name>/mode` does, through this omp's bridge: named service `name` of the session's workspace
    /// gets `mode`. Errors as `control`.
    public func setServiceMode(_ name: String, mode: String) async throws {
        _ = try await callBridge("service.mode", params: ["name": .string(name), "mode": .string(mode)])
    }

    /// Why `method` cannot go to the bridge now; nil when it can.
    private func bridgeUnavailable(for method: String) -> DaemonError? {
        guard pid != nil, stopping == nil, let hello = bridgeHello else {
            return DaemonError(.bridgeUnavailable, "omp is not running in session \(sessionKey)")
        }
        guard hello.capabilities[method] == true else {
            return DaemonError(.bridgeUnavailable, "the ide-bridge of session \(sessionKey) cannot do \(method)")
        }
        return nil
    }

    /// `method` through the bridge, failing as clients are told: omp's refusal is `ompError`, a bridge that is gone or
    /// does not answer `bridgeUnavailable`.
    private func callBridge(_ method: String, params: JSONValue) async throws -> JSONValue {
        if let unavailable = bridgeUnavailable(for: method) { throw unavailable }
        do {
            return try await context.bridge.call(sessionKey, method: method, params: params, timeout: context.timings.bridgeCall)
        } catch BridgeError.callFailed(_, let message) {
            throw DaemonError(.ompError, message)
        } catch let error as BridgeError {
            throw DaemonError(.bridgeUnavailable, "\(method) in session \(sessionKey): \(error)")
        }
    }

    /// After a hello (a spawn's, an adoption's or a redial's): the agent tree as omp has it now (`agents.snapshot`), its
    /// jobs (`jobs.snapshot`) and what waited for the user then. The pushes buffered meanwhile are handled next and bring
    /// it forward.
    private func seedRuntime(from hello: BridgeHello, generation: Int) async {
        var seeded = RuntimeTracker()
        seeded.attention = hello.attention
        if hello.capabilities["agents.snapshot"] == true {
            do {
                seeded.seed(agents: try await read("agents.snapshot")["agents"]?.arrayValue ?? [])
            } catch {
                supervisorLog.error("session \(self.sessionKey, privacy: .public): agents.snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
        if hello.capabilities["events.jobs"] == true {
            do {
                seeded.replaceJobs(try await read("jobs.snapshot")["snapshot"])
            } catch {
                supervisorLog.error("session \(self.sessionKey, privacy: .public): jobs.snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard generation == self.generation, pid != nil else { return }
        tracker = seeded
        publishRuntime()
    }

    /// The bridge dropped pushes (`gap`): the agent tree, what waits for the user and the jobs are read again.
    private func resyncRuntime() async {
        guard let capabilities = bridgeHello?.capabilities else { return }
        let generation = generation
        var resynced = tracker
        do {
            if capabilities["agents.snapshot"] == true {
                resynced.seed(agents: try await read("agents.snapshot")["agents"]?.arrayValue ?? [])
            }
            if capabilities["events.attention"] == true {
                resynced.attention = RuntimeTracker.attention(try await read("session.info")["attention"])
            }
            if capabilities["events.jobs"] == true {
                resynced.replaceJobs(try await read("jobs.snapshot")["snapshot"])
            }
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): runtime not read again after a gap: \(String(describing: error), privacy: .public)")
            return
        }
        guard generation == self.generation, pid != nil else { return }
        tracker = resynced
        publishRuntime()
    }

    /// A bridge method that only reads (`agents.snapshot`, `session.info`, `jobs.snapshot`).
    private func read(_ method: String) async throws -> JSONValue {
        try await context.bridge.call(sessionKey, method: method, params: [:], timeout: context.timings.bridgeCall)
    }

    /// Hands the runtime to clients when it changed (`ServerFrame.runtime`).
    private func publishRuntime() {
        let runtime = tracker.runtime(sessionKey: sessionKey, mainStatus: RuntimeTracker.mainStatus(status), held: heldAgents)
        guard runtime != publishedRuntime else { return }
        publishedRuntime = runtime
        context.runtimeChanged(runtime)
    }

    // MARK: - Pause

    /// Brings omp's pause gate in line with the daemon's demand: closed while no Lantern window is connected, and a pause
    /// ompd engaged released once one is. A pause the user engaged is left alone either way. Concurrent calls coalesce
    /// into one more pass. A no-op until the bridge's hello (which applies the demand) or when the bridge cannot pause.
    public func syncPause() async {
        if pauseSyncing {
            pauseRecheck = true
            return
        }
        pauseSyncing = true
        defer { pauseSyncing = false }
        repeat {
            pauseRecheck = false
            await syncPauseOnce()
        } while pauseRecheck
    }

    private func syncPauseOnce() async {
        guard pid != nil, stopping == nil, !stopRequested, bridgeHello?.capabilities["session.pause"] == true else { return }
        let pause = context.pauseDemand.isOn
        // Pausing: not while anyone's pause holds. Resuming: only ompd's own pause.
        guard pause ? pausedBy == nil : pausedBy == .daemon else { return }
        let generation = generation
        do {
            let result = try await context.bridge.call(
                sessionKey, method: pause ? "session.pause" : "session.resume",
                params: pause ? [:] : ["ifPausedBy": .string(PauseOwner.daemon.rawValue)], timeout: context.timings.bridgeCall)
            guard generation == self.generation else { return }
            await notePause(PauseOwner(paused: result["paused"]?.boolValue == true, by: result["pausedBy"]?.stringValue))
        } catch {
            guard generation == self.generation, pid != nil, stopping == nil else { return }
            notify(
                "warning",
                pause
                    ? "omp's agents could not be paused while Lantern is closed (\(error)); they keep working."
                    : "omp's agents could not be resumed (\(error)); dismiss omp's pause screen in the session to resume them.")
        }
    }

    /// The gate is closed by `owner`, or open (nil): the status is `paused`, else the main agent's activity.
    private func notePause(_ owner: PauseOwner?) async {
        pausedBy = owner
        guard [.busy, .idle, .paused].contains(status) else { return }
        let new: SessionStatus = owner == nil ? activity : .paused
        if new != status { await setStatus(new) }
    }

    // MARK: - In-place upgrade

    /// What keeps this session from being handed to another image of ompd now; nil when nothing does. `lasting` tells a
    /// reason that does not pass by itself (an ide-bridge too old to redial) from one that does (omp starting, stopping,
    /// resuming or being told what an earlier run left unfinished).
    func handoverBlocker() -> (reason: String, lasting: Bool)? {
        if startTask != nil || [.starting, .resuming, .interrupted].contains(status) {
            return ("omp is being started", false)
        }
        if pid != nil, stopping != nil { return ("omp is being stopped", false) }
        if recoveryTask != nil { return ("omp is being told what its previous run left unfinished", false) }
        guard pid != nil else { return nil }
        switch link {
        case .awaitingHello:
            return ("omp's ide-bridge has not said hello yet", false)
        case .connected, .redialing:
            guard bridgeHello?.capabilities["bridge.redial"] == true else {
                return ("omp's ide-bridge cannot reconnect (it is older than this ompd); restart the session to load the current one", true)
            }
            return nil
        case .none, .absent:
            return nil
        }
    }

    /// Waits until nothing passing keeps the session from being handed over, at most `timeout`; returns what blocks then.
    func waitForHandover(timeout: Duration) async -> (reason: String, lasting: Bool)? {
        await waitWhile({ handoverBlocker().map { !$0.lasting } ?? false }, timeout: timeout)
        return handoverBlocker()
    }

    /// The session as the next image takes it over (`takeOver`). Called once the bridge server ended every connection
    /// (`BridgeServer.quiesce`): first handles every event the bridge sent before its connection ended, at most
    /// `timeout`. Throws when the session cannot be handed over.
    func handoverState(timeout: Duration) async throws -> SupervisorHandover {
        await waitWhile({ link == .connected || handoverBlocker().map { !$0.lasting } ?? false }, timeout: timeout)
        if let blocker = handoverBlocker() { throw HandoverError("session \(sessionKey): \(blocker.reason)") }
        guard link != .connected else { throw HandoverError("session \(sessionKey): its ide-bridge did not hang up in time") }
        var omp: RunningOmp?
        if let pid, let ptyId {
            omp = RunningOmp(
                pid: pid, ptyId: ptyId, adopted: adopted, spawnedAt: spawnedAt, activity: activity, pausedBy: pausedBy,
                bridge: link == .redialing)
        }
        let held = lock?.descriptor.flatMap { fd in lockedFile.map { LockHandover(descriptor: fd, sessionFile: $0) } }
        return SupervisorHandover(sessionKey: sessionKey, omp: omp, lock: held)
    }

    /// The next image of an in-place upgrade: this session as the previous image handed it over. Takes over the
    /// ownership lock and the omp that runs on: an adopted omp's exit is watched, and a bridge that was connected is
    /// waited for to redial. Returns what the exit of omp's session PTY goes to (`PTYPool.adopt`); nil when no omp runs
    /// on a session PTY.
    func takeOver(_ state: SupervisorHandover) -> (@Sendable (PTYExit) -> Void)? {
        if let held = state.lock {
            do {
                lock = try context.locks.adopt(descriptor: held.descriptor, sessionFile: held.sessionFile)
                lockedFile = held.sessionFile
            } catch {
                // The descriptor stays open, so the lock stays held while this process lives.
                notify("error", "The ownership lock of \(held.sessionFile) could not be taken over: \(error)")
            }
        }
        guard let omp = state.omp else { return nil }
        generation += 1
        let generation = generation
        let gate = ExitGate()
        exited = gate
        pid = omp.pid
        ptyId = omp.ptyId
        adopted = omp.adopted
        spawnedAt = omp.spawnedAt
        activity = omp.activity
        pausedBy = omp.pausedBy
        link = omp.bridge ? .redialing : .absent
        if omp.bridge {
            bridgeTask = Task {
                await self.followRedial(generation: generation)
                guard self.isConnected(generation: generation) else { return }
                await self.followConnections(generation: generation)
            }
        }
        if omp.adopted {
            watchAdoptedExit(of: omp.pid, generation: generation, gate: gate)
            return nil
        }
        return { [weak self] exit in
            gate.open()
            Task { await self?.ptyExited(exit, generation: generation) }
        }
    }

    private func isConnected(generation: Int) -> Bool {
        generation == self.generation && link == .connected
    }

    // MARK: - Waiting for changes

    /// Waits while `condition` holds, at most `timeout`; it is checked again whenever the session's status, its start,
    /// stop or recovery task, or its bridge link changes.
    private func waitWhile(_ condition: () -> Bool, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while condition(), ContinuousClock.now < deadline {
            let id = UUID()
            let timer = Task { [weak self] in
                try? await Task.sleep(until: deadline)
                await self?.wake(id)
            }
            await withCheckedContinuation { changeWaiters[id] = $0 }
            timer.cancel()
        }
    }

    private func wake(_ id: UUID) {
        changeWaiters.removeValue(forKey: id)?.resume()
    }

    private func noteChange() {
        guard !changeWaiters.isEmpty else { return }
        let waiters = changeWaiters
        changeWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
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

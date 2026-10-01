import Darwin
import Foundation
import IDEProtocol
import IDETransport
import os

/// ompd: owns every omp session (one `SessionSupervisor` per manifest entry, each running omp's TUI on a
/// session PTY, or — adopted — in a terminal the user typed `omp` into) and every terminal (the PTY pool), and serves
/// the IDE protocol on `$APP_SUPPORT/run/ompd.sock`. While no omp IDE window is open, every session is paused.
///
/// Lifecycle: `start()` (manifest, supervisors, socket) → `restore()` (Regime B2: terminals from their snapshots,
/// every session the user did not close respawned with `--resume`) → … → `shutdown()` (the graceful path).
public actor Daemon {
    public struct Configuration: Sendable {
        public var paths: AppSupportPaths
        /// omp executable for new sessions; nil = `OmpBinary.locate` (`$OMP_BIN`, `PATH`, Homebrew).
        public var ompExecutable: String?
        /// Appended to the omp command line of every new session (pinned in its `LaunchSpec.extraArgs`).
        public var ompArguments: [String]
        /// `--session-dir` of every new session; nil = omp's default for the workspace.
        public var sessionDirectory: String?
        /// Staged `ide-bridge.ts` loaded into every omp with `-e`.
        public var bridgeExtension: String?
        /// Environment every omp starts from.
        public var baseEnvironment: [String: String]
        public var timings: SupervisorTimings
        /// Wake to the per-session `session.info` health check.
        public var wakeHealthCheckDelay: Duration
        /// How long no omp IDE window must be connected (after the last one disconnected, or after `start()`) before
        /// every session is paused: an app relaunch or a reconnect blip within it pauses nothing.
        public var detachedPauseGrace: Duration
        /// omp's launch broker: named services listed and controlled (`services.list`, `service.control`), and
        /// relaunched after a Regime-B resume.
        public var services: any ServiceControl
        /// Free space on `$APP_SUPPORT`'s volume under which ompd warns (`LowSpaceAlarm`); nil: the larger of 1 GiB and
        /// 1% of the volume.
        public var lowSpaceThreshold: Int64?
        /// The process ompd runs in and the ompd installed at its path: how it upgrades itself (`daemon.upgrade`).
        /// Nil: it does not.
        public var process: (any DaemonProcess)?
        /// How long an upgrade waits for sessions that are starting, stopping or being continued before it gives up on
        /// handing over in place.
        public var handoverSettle: Duration

        public init(
            paths: AppSupportPaths, ompExecutable: String? = nil, ompArguments: [String] = [], sessionDirectory: String? = nil,
            bridgeExtension: String? = nil, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
            timings: SupervisorTimings = SupervisorTimings(), wakeHealthCheckDelay: Duration = .seconds(10),
            detachedPauseGrace: Duration = .seconds(3), services: any ServiceControl = OmpServiceControl(),
            lowSpaceThreshold: Int64? = nil, process: (any DaemonProcess)? = nil, handoverSettle: Duration = .seconds(10)
        ) {
            self.paths = paths
            self.ompExecutable = ompExecutable
            self.ompArguments = ompArguments
            self.sessionDirectory = sessionDirectory
            self.bridgeExtension = bridgeExtension
            self.baseEnvironment = baseEnvironment
            self.timings = timings
            self.wakeHealthCheckDelay = wakeHealthCheckDelay
            self.detachedPauseGrace = detachedPauseGrace
            self.services = services
            self.lowSpaceThreshold = lowSpaceThreshold
            self.process = process
            self.handoverSettle = handoverSettle
        }
    }

    /// Environment variables pinned into a new session's `LaunchSpec.env` (omp storage root and profile).
    static let pinnedEnvironmentKeys = ["PI_CODING_AGENT_DIR", "OMP_PROFILE"]

    public nonisolated let configuration: Configuration
    /// When this ompd process started (kept across in-place upgrades).
    public nonisolated let startedAt: Date
    nonisolated let router = IDERouter()

    private let token: String
    private let manifest: ManifestPublisher
    private let ptys: PTYPool
    private let bridge: any SessionBridgeLink
    private let locks: any SessionLockProvider
    private let readOnly = ReadOnlyMode()
    private let broadcaster = Broadcaster()
    private let pauseDemand = PauseDemand()
    private var server: IDEServer?
    private var supervisors: [SessionKey: SessionSupervisor] = [:]
    private var shutdownTask: Task<Void, Never>?
    /// Serves the bridge's terminal-mode hellos (`adoptTerminal`).
    private var adoptionTask: Task<Void, Never>?
    /// Connected omp IDE apps (`ClientKind.app`) and whether each has a window open; `ompd status` and other cli
    /// clients do not count.
    private var appConnections: [UUID: Bool] = [:]
    /// Sleeps out `detachedPauseGrace` once no window is open, then pauses every session; a grace that was cancelled
    /// or superseded (its `id` no longer here) does nothing.
    private var detachedPause: (id: UUID, task: Task<Void, Never>)?
    /// Upgrade decisions, one after the other (an omp IDE of another version saying hello and its `daemon.upgrade` race).
    private var upgradeDecision: Task<DaemonUpgrade.Result, any Error>?
    /// The in-place handover runs: no new work, the pause demand stays as it is; undone if it fails.
    private var handover: Task<Void, Never>?
    /// `shutdown` was called: a handover in flight gives up before the exec.
    private var shutdownRequested = false
    /// `daemon.upgrade whenSettled`: ompd restarts into the installed executable once every session is settled.
    private let restartWhenSettled = Flag()
    /// Free space and PTY snapshot writes, checked whenever ompd writes anyway.
    private lazy var storageWatch = StorageWatch(
        volume: configuration.paths.root, alarm: LowSpaceAlarm(fixedThreshold: configuration.lowSpaceThreshold),
        notify: { [broadcaster] in broadcaster.send(.notice($0)) })
    /// The version of the omp each running session is pinned to, as installed now.
    private lazy var installations = OmpInstallations(
        manifest: manifest,
        locate: { [configuration] in try OmpBinary.locate(explicit: configuration.ompExecutable, environment: configuration.baseEnvironment) },
        persistenceFailed: { [readOnly, broadcaster] in Self.enterReadOnly(readOnly, broadcaster, failedWith: $0) })
    /// `storage.report` and `storage.clean`.
    private lazy var storage = StorageMaintenance(
        paths: configuration.paths, manifest: manifest, ptys: ptys, baseEnvironment: configuration.baseEnvironment,
        ompExecutable: configuration.ompExecutable)

    /// Nothing touches the disk or the socket before `start()`. `paths` must already be `prepare()`d. `startedAt`: when
    /// the process started (an in-place upgrade's next image keeps the first image's).
    public init(
        configuration: Configuration, token: String, bridge: any SessionBridgeLink, locks: any SessionLockProvider, ptys: PTYPool,
        startedAt: Date = Date()
    ) {
        self.configuration = configuration
        self.token = token
        self.bridge = bridge
        self.locks = locks
        self.ptys = ptys
        self.startedAt = startedAt
        manifest = ManifestPublisher(store: ManifestStore(url: configuration.paths.manifest))
    }

    public var isReadOnly: Bool { readOnly.isOn }

    // MARK: - Lifecycle

    /// Loads the manifest, creates a supervisor per session, and starts serving clients. Started afresh, it drops the
    /// previous daemon's runtime state (no PTY and no omp survived it). As the next image of an in-place upgrade
    /// (`handover`), it takes over what the previous image ran instead — PTYs, omps, ownership locks, the pause demand —
    /// and the manifest stays as it is; the bridges redial. No window is open yet: unless one opens within
    /// `detachedPauseGrace`, the sessions are paused.
    public func start(handover: DaemonHandover? = nil) async throws {
        precondition(server == nil && shutdownTask == nil, "Daemon.start() called twice")
        try await manifest.store.load()
        if handover == nil {
            try await manifest.update { manifest in
                for index in manifest.sessions.indices {
                    manifest.sessions[index].ptyId = nil
                    manifest.sessions[index].adopted = false
                    if manifest.sessions[index].status != .closed { manifest.sessions[index].status = .interrupted }
                }
            }
        }
        for entry in await manifest.sessions where supervisors[entry.sessionKey] == nil {
            supervisors[entry.sessionKey] = SessionSupervisor(entry: entry, context: supervisorContext)
        }
        let broadcaster = broadcaster
        let storageWatch = storageWatch
        let restartWhenSettled = restartWhenSettled
        manifest.setSink { [weak self] list in
            broadcaster.send(.sessions(list))
            storageWatch.checkFreeSpace()
            if restartWhenSettled.isOn { Task { await self?.restartIfSettled(list.sessions) } }
        }
        await ptys.setChangeHandler { broadcaster.send(.ptys(PTYList.Result(ptys: $0))) }
        await ptys.setSnapshotObserver { storageWatch.snapshotsWritten(failure: $0) }
        let bridge = bridge
        await ptys.setTerminalEnvironment { ptyId in await bridge.expectTerminal(ptyId: ptyId).environment }
        if let handover { await takeOver(handover) }
        adoptionTask = Task { [weak self] in
            for await hello in await bridge.terminalHellos() {
                guard let self else { return }
                await self.adoptTerminal(hello)
            }
        }
        registerRoutes()
        try await serve()
        windowsChanged(pauseAtOnce: false)
    }

    /// Serves the IDE protocol on `$APP_SUPPORT/run/ompd.sock`.
    private func serve() async throws {
        let server = IDEServer(
            socketPath: configuration.paths.socket.path(percentEncoded: false), token: token, daemonVersion: ompdVersion,
            startedAt: startedAt, handler: self)
        try await server.start()
        self.server = server
        broadcaster.attach(server)
    }

    /// Regime B2: terminals come back from their snapshots, and every session the user did not close is
    /// respawned (in parallel) with `--resume` in a new PTY that continues its last saved screen.
    public func restore() async {
        do {
            _ = try await ptys.restoreFromSnapshots()
        } catch {
            daemonLog.error("restoring terminals failed: \(String(describing: error), privacy: .public)")
        }
        await ptys.discardSessionScreens(keeping: Set(supervisors.keys))
        let supervisors = Array(supervisors.values)
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors {
                group.addTask { await supervisor.restoreAfterDaemonStart() }
            }
        }
    }

    /// The graceful path: terminal snapshots, then every omp stopped in parallel through its bridge
    /// (SIGHUP/SIGKILL for stragglers), then the PTYs snapshotted again and hung up, socket closed. An in-place upgrade
    /// under way gives up first (unless it is past its point of no return). Idempotent; later callers wait for the first.
    public func shutdown() async {
        if let shutdownTask { return await shutdownTask.value }
        shutdownRequested = true
        restartWhenSettled.set(false)
        await handover?.value
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { await self.performShutdown() }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        daemonLog.notice("shutting down")
        detachedPause?.task.cancel()
        detachedPause = nil
        adoptionTask?.cancel()
        adoptionTask = nil
        do {
            try await ptys.snapshotAll()
        } catch {
            daemonLog.error("terminal snapshots failed: \(String(describing: error), privacy: .public)")
        }
        let supervisors = Array(supervisors.values)
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors {
                group.addTask { await supervisor.stop(.daemonShutdown) }
            }
        }
        do {
            try await ptys.shutdown()
        } catch {
            daemonLog.error("final terminal snapshots failed: \(String(describing: error), privacy: .public)")
        }
        await server?.stop()
        broadcaster.attach(nil)
        server = nil
        daemonLog.notice("shut down")
    }

    /// System is about to sleep: make the terminals durable (the manifest always is).
    public func prepareForSleep() async {
        do {
            try await ptys.snapshotAll()
        } catch {
            daemonLog.error("terminal snapshots before sleep failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// System woke: after `wakeHealthCheckDelay`, every live omp is health-checked through its bridge.
    public func didWake() async {
        try? await Task.sleep(for: configuration.wakeHealthCheckDelay)
        guard shutdownTask == nil else { return }
        let supervisors = Array(supervisors.values)
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors {
                group.addTask { await supervisor.healthCheck() }
            }
        }
    }

    // MARK: - Supervisors

    private var supervisorContext: SupervisorContext {
        let readOnly = readOnly
        let broadcaster = broadcaster
        let installations = installations
        return SupervisorContext(
            manifest: manifest, ptys: ptys, bridge: bridge, locks: locks, bridgeExtension: configuration.bridgeExtension,
            baseEnvironment: configuration.baseEnvironment, ompExecutable: configuration.ompExecutable,
            timings: configuration.timings, pauseDemand: pauseDemand, services: configuration.services,
            persistenceFailed: { error in Self.enterReadOnly(readOnly, broadcaster, failedWith: error) },
            notify: { broadcaster.send(.notice($0)) }, runtimeChanged: { broadcaster.send(.runtime($0)) },
            ompSpawned: { version, path in Task { await installations.spawned(version, at: path) } })
    }

    /// The manifest could not be written (disk full, I/O error): read-only for the rest of this daemon's life.
    nonisolated func persistenceFailed(_ error: any Error) {
        Self.enterReadOnly(readOnly, broadcaster, failedWith: error)
    }

    private static func enterReadOnly(_ readOnly: ReadOnlyMode, _ broadcaster: Broadcaster, failedWith error: any Error) {
        guard readOnly.trip() else { return }
        daemonLog.fault("the session manifest could not be written (\(String(describing: error), privacy: .public)); read-only mode")
        broadcaster.send(.notice(DaemonNotice(
            level: "error",
            message: "The session manifest could not be written (\(error)). ompd is read-only: running sessions and terminals keep going, but new sessions are refused because they could not be restored. Free disk space and restart ompd.",
            at: Date(), topic: StorageWatch.isOutOfSpace(error) ? DaemonNotice.diskSpaceTopic : nil)))
    }

    private func supervisor(_ key: SessionKey) throws -> SessionSupervisor {
        guard let supervisor = supervisors[key] else { throw DaemonError(.noSuchSession, "no such session: \(key)") }
        return supervisor
    }

    /// Refuses new sessions while shutting down, handing over to another image of ompd, or read-only.
    private func ensureAcceptingWork() throws {
        if shutdownTask != nil { throw DaemonError(.internal, "ompd is shutting down") }
        if handover != nil { throw DaemonError(.internal, "ompd is upgrading itself; try again in a moment") }
        if readOnly.isOn { throw DaemonError(.readOnly, "ompd is read-only: the session manifest could not be written (disk full?)") }
    }

    /// Adds `entry` to the manifest with a new supervisor; undone if the manifest cannot be written.
    private func register(_ entry: SessionManifestEntry) async throws -> SessionSupervisor {
        let supervisor = SessionSupervisor(entry: entry, context: supervisorContext)
        supervisors[entry.sessionKey] = supervisor
        do {
            try await manifest.update { $0.sessions.append(entry) }
        } catch {
            supervisors[entry.sessionKey] = nil
            persistenceFailed(error)
            throw DaemonError(.internal, "cannot write the session manifest: \(error)")
        }
        return supervisor
    }

    private func launchSpec(approvalMode: String?, model: String?) async throws -> LaunchSpec {
        let ompPath: String
        let ompVersion: String
        do {
            ompPath = try OmpBinary.locate(explicit: configuration.ompExecutable, environment: configuration.baseEnvironment)
            ompVersion = try await OmpBinary.version(at: ompPath)
        } catch {
            throw DaemonError(.ompError, "\(error)")
        }
        var env: [String: String] = [:]
        for key in Self.pinnedEnvironmentKeys {
            if let value = configuration.baseEnvironment[key] { env[key] = value }
        }
        return LaunchSpec(
            ompPath: ompPath, ompVersion: ompVersion, approvalMode: approvalMode, model: model,
            extraArgs: configuration.ompArguments, env: env, sessionDir: configuration.sessionDirectory)
    }

    /// `realpath` of an existing directory: every session of a workspace runs omp from the same cwd (it scopes omp's
    /// named-service broker).
    static func canonicalDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw DaemonError(.badParams, "workspace must be an absolute path: \(path)") }
        guard let resolved = realpath(path, nil) else { throw DaemonError(.badParams, "workspace does not exist: \(path)") }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DaemonError(.badParams, "workspace is not a directory: \(path)")
        }
        return canonical
    }

    static func canonicalFile(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Methods

    private func status() async -> DaemonStatus.Result {
        DaemonStatus.Result(
            daemonVersion: ompdVersion, pid: getpid(), startedAt: startedAt, readOnly: readOnly.isOn,
            sessions: await manifest.sessions, ptys: await ptys.list())
    }

    private func createSession(_ params: SessionCreate.Params) async throws -> SessionManifestEntry {
        try ensureAcceptingWork()
        let workspace = try Self.canonicalDirectory(params.workspace)
        let launch = try await launchSpec(approvalMode: params.approvalMode, model: params.model)
        try ensureAcceptingWork()
        let entry = SessionManifestEntry(
            sessionKey: UUID().uuidString.lowercased(), workspace: workspace, launch: launch, createdAt: Date())
        let supervisor = try await register(entry)
        try await supervisor.start(.fresh, cols: params.cols, rows: params.rows)
        return await manifest.entry(entry.sessionKey) ?? entry
    }

    /// Adopts an omp session file: resumed in a new session, or — when it is the file of a session whose omp is not
    /// running (closed, given up) — in that same session.
    private func openSession(_ params: SessionOpen.Params) async throws -> SessionManifestEntry {
        try ensureAcceptingWork()
        let workspace = try Self.canonicalDirectory(params.workspace)
        guard params.sessionFile.hasPrefix("/"), let file = Self.canonicalFile(params.sessionFile) else {
            throw DaemonError(.badParams, "no such session file: \(params.sessionFile)")
        }
        let existing = await manifest.sessions.first { entry in
            entry.sessionFile.map { Self.canonicalFile($0) ?? $0 } == file
        }
        if let existing {
            try await supervisor(existing.sessionKey).reopen(workspace: workspace, cols: params.cols, rows: params.rows)
            guard let entry = await manifest.entry(existing.sessionKey) else {
                throw DaemonError(.noSuchSession, "session \(existing.sessionKey) vanished")
            }
            return entry
        }
        let key = UUID().uuidString.lowercased()
        // Ownership first: nothing is created for a file another omp IDE daemon owns.
        let lock = try locks.acquire(sessionFile: file, sessionId: nil, sessionKey: key)
        let supervisor: SessionSupervisor
        do {
            let launch = try await launchSpec(approvalMode: nil, model: nil)
            try ensureAcceptingWork()
            let entry = SessionManifestEntry(
                sessionKey: key, workspace: workspace, sessionFile: file, launch: launch, createdAt: Date())
            supervisor = try await register(entry)
        } catch {
            lock.release()
            throw error
        }
        await supervisor.adoptLock(lock, sessionFile: file)
        try await supervisor.start(.resume, cols: params.cols, rows: params.rows)
        guard let entry = await manifest.entry(key) else { throw DaemonError(.noSuchSession, "session \(key) vanished") }
        return entry
    }

    /// An omp the user started in one of the IDE's terminals said hello (the bridge's terminal mode; token and pid
    /// already checked): it becomes a session — a new entry, or the entry of a session whose omp is not running when
    /// omp resumed that session's file — served by the terminal's PTY, `workspace` = omp's cwd. Refused when the
    /// terminal is not a running plain terminal, already runs an adopted omp (an omp started by that omp inherits the
    /// terminal's credentials), or omp resumed a file another running session owns (`sessionBusy`); the
    /// bridge then behaves as in lock mode.
    private func adoptTerminal(_ request: TerminalHello) async {
        let hello = request.hello
        let key: SessionKey
        var lock: (any SessionLockHandle)?
        var launch: LaunchSpec?
        let workspace: String
        do {
            try ensureAcceptingWork()
            guard let terminal = await ptys.info(request.ptyId), terminal.running, terminal.sessionKey == nil else {
                throw DaemonError(.noSuchPTY, "PTY \(request.ptyId) is not a running terminal")
            }
            if let hosting = await manifest.sessions.first(where: { $0.adopted && $0.ptyId == request.ptyId }) {
                throw DaemonError(.sessionBusy, "terminal \(request.ptyId) already runs omp session \(hosting.sessionKey)")
            }
            workspace = try Self.canonicalDirectory(hello.cwd)
            let file = OwnershipLock.canonicalPath(hello.sessionFile)
            let existing = await manifest.sessions.first { $0.sessionFile.map(OwnershipLock.canonicalPath) == file }
            if let existing {
                guard try await !supervisor(existing.sessionKey).isOpen else {
                    throw DaemonError(.sessionBusy, "session \(existing.sessionKey) is already open")
                }
                key = existing.sessionKey
            } else {
                key = UUID().uuidString.lowercased()
                // Ownership first: nothing is created for a file another omp IDE daemon owns.
                lock = try locks.acquire(sessionFile: hello.sessionFile, sessionId: hello.sessionId, sessionKey: key)
                do {
                    launch = try await launchSpec(approvalMode: nil, model: nil)
                    try ensureAcceptingWork()
                } catch {
                    lock?.release()
                    throw error
                }
            }
        } catch {
            daemonLog.notice("omp in terminal \(request.ptyId, privacy: .public) not adopted: \(Self.message(of: error), privacy: .public)")
            await bridge.refuseTerminalHello(request, reason: Self.message(of: error))
            return
        }
        guard let accepted = await bridge.adoptTerminalHello(request, as: key) else {
            lock?.release() // omp went away before the verdict
            return
        }
        do {
            let supervisor: SessionSupervisor
            if let launch {
                // Listed in its running state from the first push: omp is already there, waiting for input.
                let entry = SessionManifestEntry(
                    sessionKey: key, workspace: workspace, sessionFile: hello.sessionFile, sessionId: hello.sessionId,
                    title: hello.title, launch: launch, status: accepted.pausedBy == nil ? .idle : .paused, ptyId: request.ptyId,
                    createdAt: Date(), adopted: true)
                supervisor = try await register(entry)
            } else {
                supervisor = try self.supervisor(key)
            }
            try await supervisor.adoptTerminalSession(hello: accepted, terminal: request.ptyId, workspace: workspace, lock: lock)
        } catch {
            // Welcomed but without a session: the omp runs on without a bridge.
            lock?.release()
            await bridge.forget(key)
            broadcaster.send(.notice(DaemonNotice(
                level: "error", message: "omp in a terminal could not be adopted as a session: \(Self.message(of: error))", at: Date())))
        }
    }

    private static func message(of error: any Error) -> String {
        (error as? DaemonError)?.message ?? "\(error)"
    }

    private func closeSession(_ params: SessionClose.Params) async throws -> Empty {
        try await supervisor(params.sessionKey).stop(.user)
        return Empty()
    }

    /// Drops a session whose omp is not running from the manifest (the session file on disk stays), with its supervisor,
    /// ownership lock and last-screen PTY. Undone if the manifest cannot be written.
    private func forgetSession(_ params: SessionForget.Params) async throws -> Empty {
        try ensureAcceptingWork()
        let key = params.sessionKey
        let supervisor = try supervisor(key)
        try await supervisor.forget()
        supervisors[key] = nil
        do {
            try await manifest.update { $0.sessions.removeAll { $0.sessionKey == key } }
        } catch {
            supervisors[key] = supervisor
            persistenceFailed(error)
            throw DaemonError(.internal, "cannot write the session manifest: \(error)")
        }
        await ptys.discardSessionScreens(keeping: Set(supervisors.keys))
        return Empty()
    }

    private func continueSession(_ params: SessionContinue.Params) async throws -> Empty {
        try await supervisor(params.sessionKey).continueInterrupted(main: params.main, agents: params.agents)
        return Empty()
    }

    /// `session.restart`: refused while read-only (the new omp's PTY could not be recorded) like new sessions.
    private func restartSession(_ params: SessionRestart.Params) async throws -> SessionManifestEntry {
        try ensureAcceptingWork()
        try await supervisor(params.sessionKey).restart(force: params.force)
        guard let entry = await manifest.entry(params.sessionKey) else {
            throw DaemonError(.noSuchSession, "session \(params.sessionKey) vanished")
        }
        return entry
    }

    private func storageReport() async -> StorageReport {
        await storage.report()
    }

    private func cleanStorage() async -> StorageClean.Result {
        await storage.clean()
    }

    private func setRestorePolicy(_ policy: RestorePolicy) async throws -> RestorePolicy {
        if readOnly.isOn { throw DaemonError(.readOnly, "ompd is read-only: the session manifest could not be written (disk full?)") }
        do {
            return try await manifest.update { $0.restorePolicy = policy }.restorePolicy
        } catch {
            persistenceFailed(error)
            throw DaemonError(.internal, "cannot write the session manifest: \(error)")
        }
    }

    // MARK: - Agent supervision

    /// Every session's runtime, in manifest order (empty lists for a session whose omp does not run).
    private func runtimes() async -> SessionRuntimeList.Result {
        var sessions: [SessionRuntime] = []
        for entry in await manifest.sessions {
            guard let supervisor = supervisors[entry.sessionKey] else { continue }
            sessions.append(await supervisor.runtime)
        }
        return SessionRuntimeList.Result(sessions: sessions)
    }

    private func controlAgent(_ params: AgentControl.Params) async throws -> AgentControl.Result {
        AgentControl.Result(agent: try await supervisor(params.sessionKey).control(agent: params.agentId, params.action))
    }

    private func messageAgent(_ params: AgentMessage.Params) async throws -> Empty {
        try await supervisor(params.sessionKey).message(agent: params.agentId, body: params.body)
        return Empty()
    }

    /// `services.list`: omp's broker records of `workspace` merged with what its sessions recorded.
    private func services(in workspace: String) async throws -> [ServiceInfo] {
        let workspace = try Self.canonicalDirectory(workspace)
        let entries = await manifest.sessions.filter { $0.workspace == workspace }
        let omp = try await brokerOmp(for: entries)
        let records = try await configuration.services.records(workspace: workspace, omp: omp.path, environment: omp.environment)
        return mergeServices(records: records, entries: entries)
    }

    /// `service.control`: `omp ps stop|kill|restart`, then `desiredRunning` cleared (stop, kill) or set (restart) in every
    /// session of the workspace that recorded the service; or its mode changed through the bridge of a running session of
    /// the workspace and recorded the same way. Returns the service as `services.list` shows it afterwards.
    private func controlService(_ params: ServiceControlRequest.Params) async throws -> ServiceControlRequest.Result {
        let workspace = try Self.canonicalDirectory(params.workspace)
        let name = params.name
        let entries = await manifest.sessions.filter { $0.workspace == workspace }
        switch params.action {
        case .stop: try await runService(.stop, name, workspace: workspace, entries: entries)
        case .kill: try await runService(.kill, name, workspace: workspace, entries: entries)
        case .restart: try await runService(.restart, name, workspace: workspace, entries: entries)
        case .setMode:
            guard let mode = params.mode, Self.serviceModes.contains(mode) else {
                throw DaemonError(.badParams, "service.control setMode needs mode persist, session or detached")
            }
            try await setServiceMode(name, mode: mode, workspace: workspace, entries: entries)
            try await updateServices(named: name, in: workspace) { service in
                service.mode = mode
                if mode == "detached" { service.pty = false } // omp gives a detached service no PTY
            }
        }
        let service = try await services(in: workspace).first { $0.name == name } ?? ServiceInfo(name: name, state: "unknown")
        return ServiceControlRequest.Result(service: service)
    }

    /// `proc://<name>/mode` values.
    private static let serviceModes: Set<String> = ["persist", "session", "detached"]

    /// A stop or kill of a service the broker no longer knows leaves nothing running under that name; a restart of one
    /// fails (ompd has nothing to relaunch it from).
    private func runService(_ command: ServiceCommand, _ name: String, workspace: String, entries: [SessionManifestEntry]) async throws {
        let omp = try await brokerOmp(for: entries)
        switch try await configuration.services.run(command, name, workspace: workspace, omp: omp.path, environment: omp.environment) {
        case .done:
            break
        case .unknown:
            guard command != .restart else {
                throw DaemonError(.ompError, "omp has no record of the service \(name) any more; ask the agent to start it again")
            }
        case .failed(let message):
            throw DaemonError(.ompError, message)
        }
        try await updateServices(named: name, in: workspace) { $0.desiredRunning = command == .restart }
    }

    /// Through the first session of the workspace whose bridge can: those that recorded the service first.
    private func setServiceMode(_ name: String, mode: String, workspace: String, entries: [SessionManifestEntry]) async throws {
        let recorded = { (entry: SessionManifestEntry) in entry.services.contains { $0.id == name } }
        for entry in entries.filter(recorded) + entries.filter({ !recorded($0) }) {
            guard let supervisor = supervisors[entry.sessionKey] else { continue }
            do {
                return try await supervisor.setServiceMode(name, mode: mode)
            } catch let error as DaemonError where error.code == .bridgeUnavailable {
                continue
            }
        }
        throw DaemonError(.bridgeUnavailable, "no omp running in \(workspace) has an ide-bridge that can change a service's mode")
    }

    /// `change` applied to service `name` in every session of `workspace` that recorded it.
    private func updateServices(
        named name: String, in workspace: String, _ change: @escaping @Sendable (inout NamedService) -> Void
    ) async throws {
        do {
            try await manifest.update { manifest in
                for session in manifest.sessions.indices where manifest.sessions[session].workspace == workspace {
                    for service in manifest.sessions[session].services.indices
                    where manifest.sessions[session].services[service].id == name {
                        change(&manifest.sessions[session].services[service])
                    }
                }
            }
        } catch {
            persistenceFailed(error)
            throw DaemonError(.internal, "cannot write the session manifest: \(error)")
        }
    }

    /// The omp that runs `omp ps` for a workspace's broker: the pinned binary and environment of a running session of the
    /// workspace, else of another of its sessions whose binary is still there, else what a new session would get.
    private func brokerOmp(for entries: [SessionManifestEntry]) async throws -> (path: String, environment: [String: String]) {
        let usable = entries.filter { FileManager.default.isExecutableFile(atPath: $0.launch.ompPath) }
        var chosen = usable.first
        for entry in usable {
            guard await supervisors[entry.sessionKey]?.isRunning == true else { continue }
            chosen = entry
            break
        }
        if let chosen { return (chosen.launch.ompPath, configuration.baseEnvironment.merging(chosen.launch.env) { $1 }) }
        do {
            return (try OmpBinary.locate(explicit: configuration.ompExecutable, environment: configuration.baseEnvironment), configuration.baseEnvironment)
        } catch {
            throw DaemonError(.ompError, "\(error)")
        }
    }

    // MARK: - Routes

    private nonisolated func registerRoutes() {
        router.on(DaemonStatus.self) { [weak self] _, _ in
            try await Self.alive(self).status()
        }
        router.on(SessionCreate.self) { [weak self] params, _ in
            try await Self.alive(self).createSession(params)
        }
        router.on(SessionOpen.self) { [weak self] params, _ in
            try await Self.alive(self).openSession(params)
        }
        router.on(ListSessions.self) { [weak self] _, _ in
            SessionList(sessions: try await Self.alive(self).manifest.sessions)
        }
        router.on(SessionClose.self) { [weak self] params, _ in
            try await Self.alive(self).closeSession(params)
        }
        router.on(SessionForget.self) { [weak self] params, _ in
            try await Self.alive(self).forgetSession(params)
        }
        router.on(SessionContinue.self) { [weak self] params, _ in
            try await Self.alive(self).continueSession(params)
        }
        router.on(RestorePolicyGet.self) { [weak self] _, _ in
            try await Self.alive(self).manifest.store.current.restorePolicy
        }
        router.on(RestorePolicySet.self) { [weak self] params, _ in
            try await Self.alive(self).setRestorePolicy(params)
        }
        router.on(PTYOpen.self) { [weak self] params, _ in
            try await Self.alive(self).ptys.open(params)
        }
        router.on(PTYAttach.self) { [weak self] params, connection in
            let ptyId = params.ptyId
            return try await Self.alive(self).ptys.attach(ptyId, subscriber: connection.id) { data in
                connection.send(.ptyOutput(PTYOutput(ptyId: ptyId, data: data)))
            }
        }
        router.on(PTYDetach.self) { [weak self] params, connection in
            try await Self.alive(self).ptys.detach(params.ptyId, subscriber: connection.id)
            return Empty()
        }
        router.on(PTYWrite.self) { [weak self] params, _ in
            try await Self.alive(self).ptys.write(params.ptyId, params.data)
            return Empty()
        }
        router.on(PTYResize.self) { [weak self] params, _ in
            try await Self.alive(self).ptys.resize(params.ptyId, cols: params.cols, rows: params.rows)
            return Empty()
        }
        router.on(PTYClose.self) { [weak self] params, _ in
            let daemon = try Self.alive(self)
            try await daemon.ptys.close(params.ptyId, refusingSessions: true)
            await daemon.bridge.forgetTerminal(ptyId: params.ptyId)
            return Empty()
        }
        router.on(PTYList.self) { [weak self] _, _ in
            PTYList.Result(ptys: try await Self.alive(self).ptys.list())
        }
        router.on(ClientPresence.self) { [weak self] params, connection in
            try await Self.alive(self).presence(connection.id, hasWindow: params.hasWindow)
            return Empty()
        }
        router.on(SessionRuntimeList.self) { [weak self] _, _ in
            try await Self.alive(self).runtimes()
        }
        router.on(AgentControl.self) { [weak self] params, _ in
            try await Self.alive(self).controlAgent(params)
        }
        router.on(AgentMessage.self) { [weak self] params, _ in
            try await Self.alive(self).messageAgent(params)
        }
        router.on(ServiceList.self) { [weak self] params, _ in
            ServiceList.Result(services: try await Self.alive(self).services(in: params.workspace))
        }
        router.on(ServiceControlRequest.self) { [weak self] params, _ in
            try await Self.alive(self).controlService(params)
        }
        router.on(SessionRestart.self) { [weak self] params, _ in
            try await Self.alive(self).restartSession(params)
        }
        router.on(StorageReportRequest.self) { [weak self] _, _ in
            try await Self.alive(self).storageReport()
        }
        router.on(StorageClean.self) { [weak self] _, _ in
            try await Self.alive(self).cleanStorage()
        }
        router.on(DaemonUpgrade.self) { [weak self] params, _ in
            try await Self.alive(self).upgrade(params.mode)
        }
    }

    private static func alive(_ daemon: Daemon?) throws -> Daemon {
        guard let daemon else { throw DaemonError(.internal, "ompd is shutting down") }
        return daemon
    }

    // MARK: - Upgrades

    /// How long the answer to the `daemon.upgrade` that started a handover gets to go out before its connection ends.
    static let responseGrace: Duration = .milliseconds(100)

    /// `daemon.upgrade`, and an omp IDE of another version saying hello (`auto`): decided one after the other.
    private func upgrade(_ mode: DaemonUpgrade.Mode) async throws -> DaemonUpgrade.Result {
        let previous = upgradeDecision
        let decision = Task {
            _ = try? await previous?.value
            return try await self.decideUpgrade(mode)
        }
        upgradeDecision = decision
        return try await decision.value
    }

    /// Moves to the ompd installed at this ompd's path when it is another one (`UpgradePlan`): handing over in place
    /// when nothing blocks it, else restarting the graceful way as `mode` says. Answers before anything happens.
    private func decideUpgrade(_ mode: DaemonUpgrade.Mode) async throws -> DaemonUpgrade.Result {
        guard let process = configuration.process else { throw DaemonError(.internal, "this ompd cannot upgrade itself") }
        if shutdownTask != nil || shutdownRequested { throw DaemonError(.internal, "ompd is shutting down") }
        if handover != nil { return DaemonUpgrade.Result(outcome: .handingOver, runningVersion: ompdVersion) }
        guard let installed = await process.installedReplacement() else {
            return DaemonUpgrade.Result(outcome: .upToDate, runningVersion: ompdVersion)
        }
        let blocker = await handoverBlocker(for: installed)
        let unsettled = await manifest.sessions.filter { !$0.status.isSettled }.map(\.sessionKey)
        let plan = UpgradePlan.decide(mode, handoverBlocker: blocker, installedStarts: installed.failure == nil, unsettled: unsettled)
        daemonLog.notice("upgrade \(mode.rawValue, privacy: .public) to ompd \(installed.version ?? "?", privacy: .public): \(String(describing: plan), privacy: .public)\(blocker.map { " (no handover: \($0))" } ?? "", privacy: .public)")
        switch plan {
        case .handOver:
            restartWhenSettled.set(false)
            handover = Task {
                let failure = await self.handOverInPlace()
                await self.handoverFailed(failure, fallback: mode)
            }
        case .restartNow:
            restartWhenSettled.set(false)
            Task { await self.restartIntoInstalled() }
        case .restartWhenSettled:
            restartWhenSettled.set(true)
        case .wait:
            break
        }
        return DaemonUpgrade.Result(
            outcome: plan.outcome, runningVersion: ompdVersion, installedVersion: installed.version,
            handoverUnavailable: blocker, unsettledSessions: unsettled)
    }

    /// Why ompd cannot hand over to `installed` in place; nil when it can. What passes by itself (omp starting,
    /// stopping or being continued) is waited out first, at most `handoverSettle`.
    private func handoverBlocker(for installed: InstalledExecutable) async -> String? {
        if let failure = installed.failure { return "the installed ompd could not be started: \(failure)" }
        guard installed.handoverFormats.contains(DaemonHandover.format) else {
            return "the installed ompd \(installed.version ?? "") cannot take over from a running one"
        }
        if readOnly.isOn { return "ompd is read-only (the session manifest could not be written)" }
        let supervisors = Array(supervisors.values)
        let settle = configuration.handoverSettle
        let blockers = await withTaskGroup(of: String?.self) { group in
            for supervisor in supervisors {
                group.addTask {
                    await supervisor.waitForHandover(timeout: settle).map { "session \(supervisor.sessionKey): \($0.reason)" }
                }
            }
            var found: [String] = []
            for await blocker in group { if let blocker { found.append(blocker) } }
            return found.sorted()
        }
        return blockers.isEmpty ? nil : blockers.joined(separator: "; ")
    }

    /// The in-place upgrade (Regime A), in order: app connections end and the socket goes; every PTY stops being read,
    /// written and reaped with its master kept open; every bridge connection ends without losing an event (the bridges
    /// redial the next image); the sessions' state, the bridges' credentials and the ownership locks are collected; the
    /// process becomes the installed executable (`DaemonProcess.handOver`). Returns only when that failed, with why.
    private func handOverInPlace() async -> String {
        guard let process = configuration.process else { return "this ompd cannot upgrade itself" }
        try? await Task.sleep(for: Self.responseGrace)
        cancelDetachedPause()
        await server?.stop()
        broadcaster.attach(nil)
        server = nil
        appConnections = [:]
        let frozen = await ptys.freezeForHandover()
        let redial = configuration.timings.redial
        guard await bridge.quiesce(timeout: redial) else { return "an ide-bridge did not hang up within \(redial)" }
        var sessions: [SupervisorHandover] = []
        for supervisor in supervisors.values {
            do {
                sessions.append(try await supervisor.handoverState(timeout: redial))
            } catch {
                return "\(error)"
            }
        }
        let handover = DaemonHandover(
            startedAt: startedAt, pauseDemand: pauseDemand.isOn, ptys: frozen, sessions: sessions,
            bridge: await bridge.handoverState())
        guard !shutdownRequested else { return "ompd was told to stop" }
        daemonLog.notice("handing over \(frozen.ptys.count) PTYs and \(sessions.count) sessions to the installed ompd")
        return "\(process.handOver(handover))"
    }

    /// The handover did not happen (`failure`): everything runs on as before — PTYs read again, bridges redial, the app
    /// reconnects — and `mode`'s fallback applies, unless ompd is shutting down.
    private func handoverFailed(_ failure: String, fallback mode: DaemonUpgrade.Mode) async {
        daemonLog.error("in-place upgrade failed: \(failure, privacy: .public)")
        await ptys.thaw()
        do {
            try await bridge.resumeListening()
        } catch {
            daemonLog.fault("the ide-bridge socket could not be bound again: \(String(describing: error), privacy: .public)")
        }
        do {
            try await serve()
        } catch {
            daemonLog.fault("the client socket could not be bound again: \(String(describing: error), privacy: .public)")
        }
        handover = nil
        windowsChanged(pauseAtOnce: false)
        guard !shutdownRequested else { return }
        broadcaster.send(.notice(DaemonNotice(
            level: "warning", message: "ompd could not upgrade itself in place (\(failure)).", at: Date())))
        let unsettled = await manifest.sessions.contains { !$0.status.isSettled }
        switch mode {
        case .now:
            await restartIntoInstalled()
        case .whenSettled, .auto:
            if !unsettled {
                await restartIntoInstalled()
            } else if mode == .whenSettled {
                restartWhenSettled.set(true)
            }
        }
    }

    /// `whenSettled`: the manifest changed; once every session is settled, the restart happens.
    private func restartIfSettled(_ sessions: [SessionManifestEntry]) async {
        guard restartWhenSettled.isOn, handover == nil, !shutdownRequested, sessions.allSatisfy(\.status.isSettled) else { return }
        restartWhenSettled.set(false)
        await restartIntoInstalled()
    }

    /// The graceful fallback (Regime B2): every omp stopped through its bridge and terminals snapshotted, then
    /// the installed executable starts afresh in this process; sessions resume with `--resume` and the restore policy
    /// decides what their interrupted agents do.
    private func restartIntoInstalled() async {
        guard let process = configuration.process, !shutdownRequested else { return }
        daemonLog.notice("restarting into the installed ompd")
        await shutdown()
        await process.restart()
    }

    /// The next image of an in-place upgrade: the pause demand, every session's omp and lock, and every PTY, as the
    /// previous image handed them over (`start(handover:)`).
    private func takeOver(_ handover: DaemonHandover) async {
        pauseDemand.set(handover.pauseDemand)
        var exits: [PTYID: @Sendable (PTYExit) -> Void] = [:]
        for state in handover.sessions {
            guard let supervisor = supervisors[state.sessionKey] else {
                daemonLog.fault("handed-over session \(state.sessionKey, privacy: .public) is not in the manifest")
                continue
            }
            if let onExit = await supervisor.takeOver(state), let ptyId = state.omp?.ptyId { exits[ptyId] = onExit }
        }
        await ptys.adopt(handover.ptys, onExit: exits)
        daemonLog.notice("took over \(handover.ptys.ptys.count) PTYs and \(handover.sessions.count) sessions from ompd \(handover.fromVersion, privacy: .public)")
    }

    // MARK: - Paused while no window is open

    private var windowOpen: Bool { appConnections.values.contains(true) }

    private func appConnected(_ id: UUID, hasWindow: Bool) {
        appConnections[id] = hasWindow
        windowsChanged(pauseAtOnce: false)
    }

    /// `client.presence`: the app's last window closed or the app is quitting (it says so: the pause is immediate), or
    /// a window opened.
    private func presence(_ id: UUID, hasWindow: Bool) {
        guard appConnections[id] != nil else { return }
        appConnections[id] = hasWindow
        windowsChanged(pauseAtOnce: true)
    }

    private func appDisconnected(_ id: UUID) {
        guard appConnections.removeValue(forKey: id) != nil else { return }
        windowsChanged(pauseAtOnce: false)
    }

    /// A window open in any app resumes what ompd paused. With none, every session pauses: right away when an app said
    /// its last window closed, otherwise (a connection dropped, an app connected without a window, ompd started)
    /// after `detachedPauseGrace`, so an app crash-relaunch or a reconnect blip pauses nothing.
    private func windowsChanged(pauseAtOnce: Bool) {
        // Handing over, the next image applies the demand; app connections end without saying anything about windows.
        guard shutdownTask == nil, handover == nil else { return }
        if windowOpen {
            cancelDetachedPause()
            guard pauseDemand.set(false) else { return }
            daemonLog.notice("an omp IDE window is open; resuming the sessions ompd paused")
            syncPauses()
        } else if pauseAtOnce {
            cancelDetachedPause()
            pauseEverySession(because: "the last omp IDE window closed")
        } else if detachedPause == nil, !pauseDemand.isOn {
            scheduleDetachedPause()
        }
    }

    private func cancelDetachedPause() {
        detachedPause?.task.cancel()
        detachedPause = nil
    }

    private func scheduleDetachedPause() {
        let id = UUID()
        let grace = configuration.detachedPauseGrace
        detachedPause = (id, Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.pauseDetached(id)
        })
    }

    private func pauseDetached(_ id: UUID) {
        guard detachedPause?.id == id else { return } // cancelled or superseded meanwhile
        detachedPause = nil
        guard !windowOpen, shutdownTask == nil else { return }
        pauseEverySession(because: "no omp IDE window for \(configuration.detachedPauseGrace)")
    }

    private func pauseEverySession(because reason: String) {
        guard pauseDemand.set(true) else { return }
        daemonLog.notice("\(reason, privacy: .public); pausing every session")
        syncPauses()
    }

    /// Every supervisor applies the demand on its own; a slow bridge holds up only its own session.
    private func syncPauses() {
        for supervisor in supervisors.values {
            Task { await supervisor.syncPause() }
        }
    }
}

extension Daemon: IDERequestHandler {
    public func sessionsForWelcome() async -> [SessionManifestEntry] {
        await manifest.sessions
    }

    public nonisolated func handle(_ request: Request, from connection: IDEConnection) async -> Response {
        await router.route(request, from: connection)
    }

    /// An omp IDE said hello (refused when its protocol differs; it retries): ompd moves to the ompd installed at its path
    /// if that is another executable (`daemon.upgrade auto`), so the app's retry, or its next connection, lands on it.
    /// Every app hello checks, not only one of another version: a rebuild or an update can keep the version string, and
    /// the check is one hash of ompd's own executable.
    public nonisolated func helloReceived(_ hello: Hello) {
        guard hello.clientKind == .app, configuration.process != nil else { return }
        Task { [weak self] in
            do {
                _ = try await self?.upgrade(.auto)
            } catch {
                daemonLog.error("upgrade on a hello of omp IDE \(hello.clientVersion, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func connectionOpened(_ connection: IDEConnection, hello: Hello) async {
        guard hello.clientKind == .app else { return }
        appConnected(connection.id, hasWindow: hello.hasWindow)
        // An upgrade while no app was connected shows on the sessions' tabs.
        let installations = installations
        Task { await installations.refresh() }
    }

    public func connectionClosed(_ connection: IDEConnection) async {
        appDisconnected(connection.id)
        await ptys.detachAll(subscriber: connection.id)
    }
}

/// Where daemon-wide pushes go: the IDE server once it runs.
final class Broadcaster: Sendable {
    private let server = OSAllocatedUnfairLock<IDEServer?>(initialState: nil)

    func attach(_ server: IDEServer?) {
        self.server.withLock { $0 = server }
    }

    func send(_ frame: ServerFrame) {
        server.withLock { $0 }?.broadcast(frame)
    }
}

let daemonLog = Logger(subsystem: "com.omp-ide.ompd", category: "daemon")

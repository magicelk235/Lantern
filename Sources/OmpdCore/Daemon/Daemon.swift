import Darwin
import Foundation
import IDEProtocol
import IDETransport
import os

/// ompd: owns every omp session (one `SessionSupervisor` per manifest entry), the PTY pool and the
/// journals, and serves the IDE protocol on `$APP_SUPPORT/run/ompd.sock`.
///
/// Lifecycle: `start()` (manifest, supervisors, socket) → `restore()` (Regime B2: resume every session the user did
/// not close, restore terminals) → … → `shutdown()` (the graceful path).
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
        /// Wake to the per-session `get_state` health check.
        public var wakeHealthCheckDelay: Duration

        public init(
            paths: AppSupportPaths, ompExecutable: String? = nil, ompArguments: [String] = [], sessionDirectory: String? = nil,
            bridgeExtension: String? = nil, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
            timings: SupervisorTimings = SupervisorTimings(), wakeHealthCheckDelay: Duration = .seconds(10)
        ) {
            self.paths = paths
            self.ompExecutable = ompExecutable
            self.ompArguments = ompArguments
            self.sessionDirectory = sessionDirectory
            self.bridgeExtension = bridgeExtension
            self.baseEnvironment = baseEnvironment
            self.timings = timings
            self.wakeHealthCheckDelay = wakeHealthCheckDelay
        }
    }

    /// Environment variables pinned into a new session's `LaunchSpec.env` (omp storage root and profile).
    static let pinnedEnvironmentKeys = ["PI_CODING_AGENT_DIR", "OMP_PROFILE"]
    /// omp commands that start agent work; refused in read-only mode because their output could not be journaled.
    static let workCommands: Set<String> = ["prompt", "abort_and_prompt", "steer", "follow_up"]
    /// Queued-but-unwritten bytes a journal replay lets build up for one client before pausing.
    static let replayBacklogLimit = 8 << 20

    public nonisolated let configuration: Configuration
    public nonisolated let startedAt = Date()
    nonisolated let router = IDERouter()

    private let token: String
    private let manifest: ManifestPublisher
    private let ptys: PTYPool
    private let bridge: any SessionBridgeLink
    private let locks: any SessionLockProvider
    private let readOnly = ReadOnlyMode()
    private let broadcaster = Broadcaster()
    private var server: IDEServer?
    private var supervisors: [SessionKey: SessionSupervisor] = [:]
    private var subscriptions: [UUID: [SessionKey: Task<Void, Never>]] = [:]
    private var shutdownTask: Task<Void, Never>?

    /// Nothing touches the disk or the socket before `start()`. `paths` must already be `prepare()`d.
    public init(
        configuration: Configuration, token: String, bridge: any SessionBridgeLink, locks: any SessionLockProvider, ptys: PTYPool
    ) {
        self.configuration = configuration
        self.token = token
        self.bridge = bridge
        self.locks = locks
        self.ptys = ptys
        manifest = ManifestPublisher(store: ManifestStore(url: configuration.paths.manifest))
    }

    public var isReadOnly: Bool { readOnly.isOn }

    // MARK: - Lifecycle

    /// Loads the manifest, opens a supervisor (and journal) per session, and starts serving clients.
    public func start() async throws {
        precondition(server == nil && shutdownTask == nil, "Daemon.start() called twice")
        let loaded = try await manifest.store.load()
        for entry in loaded.sessions where supervisors[entry.sessionKey] == nil {
            supervisors[entry.sessionKey] = try SessionSupervisor(entry: entry, context: supervisorContext)
        }
        let broadcaster = broadcaster
        manifest.setSink { broadcaster.send(.sessions($0)) }
        registerRoutes()
        let server = IDEServer(
            socketPath: configuration.paths.socket.path(percentEncoded: false), token: token, daemonVersion: ompdVersion,
            startedAt: startedAt, handler: self)
        try await server.start()
        self.server = server
        broadcaster.attach(server)
    }

    /// Regime B2: terminals come back from their snapshots, and every session the user did not close is
    /// resumed (in parallel) — its omp cannot still be running, since omp dies with the daemon's pipes.
    public func restore() async {
        do {
            _ = try await ptys.restoreFromSnapshots()
        } catch {
            daemonLog.error("restoring terminals failed: \(String(describing: error), privacy: .public)")
        }
        let supervisors = Array(supervisors.values)
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors {
                group.addTask { await supervisor.restoreAfterDaemonStart() }
            }
        }
    }

    /// The graceful path: terminal snapshots, manifest, then every omp stopped in parallel by stdin EOF
    /// (stragglers killed after `timings.stop`), journals flushed and closed, socket closed. Idempotent; later
    /// callers wait for the first.
    public func shutdown() async {
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { await self.performShutdown() }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        daemonLog.notice("shutting down")
        do {
            try await ptys.shutdown()
        } catch {
            daemonLog.error("terminal snapshots failed: \(String(describing: error), privacy: .public)")
        }
        let supervisors = Array(supervisors.values)
        for supervisor in supervisors { await supervisor.persistLastSeq() }
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors {
                group.addTask { await supervisor.stop(.daemonShutdown) }
            }
        }
        for supervisor in supervisors { await supervisor.closeJournal() }
        await server?.stop()
        broadcaster.attach(nil)
        server = nil
        daemonLog.notice("shut down")
    }

    /// System is about to sleep: make terminals, manifest and journals durable.
    public func prepareForSleep() async {
        do {
            try await ptys.snapshotAll()
        } catch {
            daemonLog.error("terminal snapshots before sleep failed: \(String(describing: error), privacy: .public)")
        }
        for supervisor in supervisors.values {
            await supervisor.persistLastSeq()
            await supervisor.syncJournal()
        }
    }

    /// System woke: after `wakeHealthCheckDelay`, every live omp is health-checked with `get_state`.
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
        return SupervisorContext(
            manifest: manifest, journalDirectory: configuration.paths.journalDir, bridge: bridge, locks: locks,
            bridgeExtension: configuration.bridgeExtension, baseEnvironment: configuration.baseEnvironment,
            timings: configuration.timings, readOnly: readOnly,
            journalFailed: { key, error in Self.enterReadOnly(readOnly, broadcaster, journalOf: key, failedWith: error) })
    }

    /// A journal append failed (disk full, I/O error): read-only for the rest of this daemon's life.
    nonisolated func journalFailed(_ key: SessionKey, _ error: any Error) {
        Self.enterReadOnly(readOnly, broadcaster, journalOf: key, failedWith: error)
    }

    private static func enterReadOnly(
        _ readOnly: ReadOnlyMode, _ broadcaster: Broadcaster, journalOf key: SessionKey, failedWith error: any Error
    ) {
        guard readOnly.trip() else { return }
        daemonLog.fault("journal of \(key, privacy: .public) failed (\(String(describing: error), privacy: .public)); read-only mode")
        // Out of band (seq 0): the journal cannot take it. Clients apply only seqs above what they hold, so this is a
        // banner hint for every connected client, never a journal record.
        let notice = DaemonEvent.notice(
            level: "error",
            message: "The journal could not be written (\(error)). ompd is read-only: omp keeps running but its output is no longer recorded and new work is refused. Free disk space and restart ompd.")
        if let payload = try? JSONValue(encoding: notice) {
            broadcaster.send(.event(JournalRecord(sessionKey: key, seq: 0, ts: Date(), kind: .daemon, payload: payload)))
        }
    }

    private func supervisor(_ key: SessionKey) throws -> SessionSupervisor {
        guard let supervisor = supervisors[key] else { throw DaemonError(.noSuchSession, "no such session: \(key)") }
        return supervisor
    }

    /// Refuses work that needs the journal or a live daemon.
    private func ensureAcceptingWork() throws {
        if shutdownTask != nil { throw DaemonError(.internal, "ompd is shutting down") }
        if readOnly.isOn { throw DaemonError(.readOnly, "ompd is read-only: the journal could not be written (disk full?)") }
    }

    /// Adds `entry` to the manifest with a new supervisor; undone if the manifest cannot be written.
    private func register(_ entry: SessionManifestEntry) async throws -> SessionSupervisor {
        let supervisor: SessionSupervisor
        do {
            supervisor = try SessionSupervisor(entry: entry, context: supervisorContext)
        } catch {
            throw DaemonError(.internal, "cannot open the journal of \(entry.sessionKey): \(error)")
        }
        supervisors[entry.sessionKey] = supervisor
        do {
            try await manifest.update { $0.sessions.append(entry) }
        } catch {
            supervisors[entry.sessionKey] = nil
            await supervisor.closeJournal()
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
        try await supervisor.start(.fresh)
        return await manifest.entry(entry.sessionKey) ?? entry
    }

    private func openSession(_ params: SessionOpen.Params) async throws -> SessionManifestEntry {
        try ensureAcceptingWork()
        let workspace = try Self.canonicalDirectory(params.workspace)
        guard params.sessionFile.hasPrefix("/"), let file = Self.canonicalFile(params.sessionFile) else {
            throw DaemonError(.badParams, "no such session file: \(params.sessionFile)")
        }
        let owner = await manifest.sessions.first { entry in
            !entry.closedByUser && entry.sessionFile.map { Self.canonicalFile($0) ?? $0 } == file
        }
        if let owner {
            throw DaemonError(.sessionBusy, "\(file) is already open as session \(owner.sessionKey)")
        }
        let key = UUID().uuidString.lowercased()
        // Ownership first: nothing is created for a file another omp owns.
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
        try await supervisor.start(.resume)
        guard let entry = await manifest.entry(key) else { throw DaemonError(.noSuchSession, "session \(key) vanished") }
        return entry
    }

    private func closeSession(_ params: SessionClose.Params) async throws -> Empty {
        try await supervisor(params.sessionKey).stop(.user)
        return Empty()
    }

    private func snapshot(_ params: SessionSnapshot.Params) async throws -> SessionSnapshot.Result {
        let snapshot = try await supervisor(params.sessionKey).snapshot()
        guard let entry = await manifest.entry(params.sessionKey) else {
            throw DaemonError(.noSuchSession, "no such session: \(params.sessionKey)")
        }
        return SessionSnapshot.Result(entry: entry, state: snapshot.state, entries: snapshot.entries, lastSeq: snapshot.lastSeq)
    }

    private func ompCommand(_ params: OmpCommand.Params) async throws -> JSONValue {
        let supervisor = try supervisor(params.sessionKey)
        if let type = params.command["type"]?.stringValue, Self.workCommands.contains(type) { try ensureAcceptingWork() }
        return try await supervisor.command(params.command)
    }

    private func respond(_ params: UIRespond.Params) async throws -> Empty {
        try await supervisor(params.sessionKey).respond(requestId: params.requestId, response: params.response)
        return Empty()
    }

    // MARK: - Subscriptions

    /// Replays the journal after `since` and then streams it live, in one gap- and duplicate-free sequence (the
    /// journal takes replay and live registration in one step). An unknown `since` (beyond the journal) gets a
    /// `resync` first and continues from the journal's end. One subscription per (connection, session): a new one
    /// replaces the old, which stops sending before the new one starts.
    private func subscribe(_ params: Subscribe.Params, _ connection: IDEConnection) async throws -> Subscribe.Result {
        let key = params.sessionKey
        let journal = try supervisor(key).journal
        var resync: Resync?
        var subscription: (replay: [JournalRecord], live: AsyncStream<JournalRecord>)?
        do {
            subscription = try await journal.subscribe(after: params.since)
            if subscription == nil {
                let lastSeq = await journal.lastSeq
                resync = Resync(sessionKey: key, lastSeq: lastSeq)
                subscription = try await journal.subscribe(after: lastSeq)
            }
        } catch StorageError.journalClosed {
            throw DaemonError(.internal, "ompd is shutting down")
        } catch {
            throw DaemonError(.internal, "journal of \(key) unreadable: \(error)")
        }
        guard let subscription else {
            throw DaemonError(.internal, "journal of \(key) moved backwards")
        }
        let (replay, live) = subscription
        let resyncFrame = resync
        let previous = subscriptions[connection.id]?[key]
        previous?.cancel()
        subscriptions[connection.id, default: [:]][key] = Task.detached {
            await previous?.value
            await Self.stream(resync: resyncFrame, replay: replay, live: live, to: connection)
        }
        return Subscribe.Result(replayedThrough: replay.last?.seq ?? resyncFrame?.lastSeq ?? params.since)
    }

    private static func stream(
        resync: Resync?, replay: [JournalRecord], live: AsyncStream<JournalRecord>, to connection: IDEConnection
    ) async {
        guard !Task.isCancelled else { return }
        if let resync { connection.send(.resync(resync)) }
        for record in replay {
            // Paced so a long replay never trips the slow-consumer cutoff meant for clients that stopped reading.
            await connection.waitForBacklog(atMost: replayBacklogLimit)
            guard !Task.isCancelled else { return }
            connection.send(.event(record))
        }
        for await record in live {
            connection.send(.event(record))
        }
    }

    private func unsubscribe(_ params: Unsubscribe.Params, _ connection: IDEConnection) async -> Empty {
        let task = subscriptions[connection.id]?.removeValue(forKey: params.sessionKey)
        task?.cancel()
        await task?.value
        return Empty()
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
        router.on(Subscribe.self) { [weak self] params, connection in
            try await Self.alive(self).subscribe(params, connection)
        }
        router.on(Unsubscribe.self) { [weak self] params, connection in
            try await Self.alive(self).unsubscribe(params, connection)
        }
        router.on(SessionSnapshot.self) { [weak self] params, _ in
            try await Self.alive(self).snapshot(params)
        }
        router.on(OmpCommand.self) { [weak self] params, _ in
            try await Self.alive(self).ompCommand(params)
        }
        router.on(UIRespond.self) { [weak self] params, _ in
            try await Self.alive(self).respond(params)
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
            try await Self.alive(self).ptys.close(params.ptyId)
            return Empty()
        }
        router.on(PTYList.self) { [weak self] _, _ in
            PTYList.Result(ptys: try await Self.alive(self).ptys.list())
        }
    }

    private static func alive(_ daemon: Daemon?) throws -> Daemon {
        guard let daemon else { throw DaemonError(.internal, "ompd is shutting down") }
        return daemon
    }
}

extension Daemon: IDERequestHandler {
    public func sessionsForWelcome() async -> [SessionManifestEntry] {
        await manifest.sessions
    }

    public nonisolated func handle(_ request: Request, from connection: IDEConnection) async -> Response {
        await router.route(request, from: connection)
    }

    public func connectionClosed(_ connection: IDEConnection) async {
        for task in (subscriptions.removeValue(forKey: connection.id) ?? [:]).values { task.cancel() }
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

import Foundation
// The models speak the wire types (`SessionManifestEntry`, `PTYInfo`, …): importing IDEModel brings them along.
@_exported import IDEProtocol
import IDETransport
import Observation

/// The app's link to ompd, also the menu-bar extra's (`ClientKind.cli`): connects over
/// `run/ompd.sock` with the token in `run/token`, retrying with exponential backoff while the daemon is starting or
/// restarting, keeps the session manifest and the PTY list current from ompd's pushes, and routes PTY output to the
/// terminals and session TUIs on screen. After each (re)connect every shown terminal and session attaches again;
/// restoring sends nothing to omp.
@MainActor @Observable
public final class DaemonConnection: TerminalBackend {
    public enum Status: Equatable, Sendable {
        case connecting
        case connected(Welcome)
        /// The last attempt failed; retrying with backoff.
        case daemonUnavailable(reason: String)
        /// ompd refused this app's protocol version (`version_mismatch`; `message` is ompd's): another build than the app's.
        /// A current ompd moves to the one installed at its path by itself (`daemon.upgrade auto`); an older one runs
        /// until it is restarted. Retrying with backoff, so the app connects to the ompd that starts next.
        case versionMismatch(message: String)
    }

    /// Delay before retry `n` (1-based): `initial * 2^(n-1)`, at most `maximum`.
    public struct Backoff: Equatable, Sendable {
        public var initial: Duration
        public var maximum: Duration

        public init(initial: Duration = .milliseconds(250), maximum: Duration = .seconds(5)) {
            self.initial = initial
            self.maximum = maximum
        }

        public func delay(afterFailures failures: Int) -> Duration {
            let doublings = min(max(failures - 1, 0), 30)
            return min(initial * (1 << doublings), maximum)
        }
    }

    public nonisolated let paths: AppSupportPaths
    public nonisolated let clientVersion: String
    /// What says hello: Lantern (`app`), whose windows keep the sessions running, or a client that is no window
    /// (`cli`, the menu-bar extra), which neither keeps them running nor resumes them.
    public nonisolated let clientKind: ClientKind
    public nonisolated let backoff: Backoff

    public private(set) var status: Status = .connecting
    /// Every session in the daemon's manifest (welcome, then `sessions` pushes).
    public private(set) var sessions: [SessionManifestEntry] = []
    /// Sessions shown in a tab, each following its omp TUI from PTY to PTY.
    public private(set) var openSessions: [SessionKey: SessionTerminal] = [:]
    /// Out-of-band notices from the running ompd (`ServerFrame.notice`, e.g. read-only mode), oldest first. At most
    /// `noticeLimit`; cleared when the app connects to a different ompd process or by `dismissNotices()`.
    public private(set) var notices: [DaemonNotice] = []
    public nonisolated static let noticeLimit = 50
    /// ompd's PTYs: the terminals, and the PTYs the session TUIs run on.
    public let terminals = TerminalRegistry()
    /// This app has a Lantern window open. ompd pauses every session while no connected app has one:
    /// every (re)connect's hello carries it, and changes go to ompd as `client.presence`.
    public private(set) var hasWindow = false
    /// What each running session's omp runs: agents, jobs, what waits for the user (`session.runtime` after each
    /// connect, then `runtime` pushes). A session without an entry runs nothing ompd knows of.
    public private(set) var runtimes: [SessionKey: SessionRuntime] = [:]

    @ObservationIgnored private var client: IDEClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// `Welcome.daemonStartedAt` of the ompd the notices came from.
    @ObservationIgnored private var noticesDaemonStartedAt: Date?
    /// What the current connection's ompd was told last (hello or `client.presence`).
    @ObservationIgnored private var reportedHasWindow: Bool?
    /// The latest `client.presence` report; each waits for the one before, so ompd gets them in order.
    @ObservationIgnored private var presenceReport: Task<Void, Never>?

    public init(
        paths: AppSupportPaths = .standard, clientVersion: String, clientKind: ClientKind = .app, backoff: Backoff = Backoff()
    ) {
        self.paths = paths
        self.clientVersion = clientVersion
        self.clientKind = clientKind
        self.backoff = backoff
        terminals.backend = self
    }

    public var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// Sessions grouped by workspace folder.
    public var workspaces: [WorkspaceGroup] { WorkspaceGroup.group(sessions) }

    /// The newest notice, for the connection banner.
    public var latestNotice: DaemonNotice? { notices.last }

    public func dismissNotices() {
        notices = []
    }

    /// Starts connecting (idempotent). Keeps reconnecting until `stop()`.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    /// Disconnects and stops reconnecting.
    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await client?.close()
    }

    /// A window of this app opened (`true`) or its last one closed. ompd hears of it now if connected, otherwise in
    /// the next hello. Only an `app` has windows: a `cli` connection never says it has one.
    public func setHasWindow(_ hasWindow: Bool) {
        guard clientKind == .app, hasWindow != self.hasWindow else { return }
        self.hasWindow = hasWindow
        queuePresenceReport()
    }

    /// Waits until ompd was told the latest `hasWindow` (or could not be: not connected, or an ompd from before
    /// `client.presence`), at most `timeout`.
    public func presenceReported(within timeout: Duration) async {
        guard let report = presenceReport else { return }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            report.cancel()
        }
        await report.value
        deadline.cancel()
    }

    /// Tells ompd `hasWindow` after the reports before it; cancelling it cancels those too.
    private func queuePresenceReport() {
        let previous = presenceReport
        presenceReport = Task {
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            await reportPresence()
        }
    }

    private func reportPresence() async {
        guard let client, reportedHasWindow != hasWindow else { return }
        let hasWindow = hasWindow
        reportedHasWindow = hasWindow
        _ = try? await client.call(ClientPresence.self, .init(hasWindow: hasWindow))
    }

    // MARK: - Sessions

    /// The TUI of `sessionKey` for its tab, made the first time. It attaches once a display asks, and follows omp to
    /// every PTY it runs on.
    @discardableResult
    public func open(_ sessionKey: SessionKey) -> SessionTerminal {
        if let session = openSessions[sessionKey] { return session }
        let session = SessionTerminal(sessionKey: sessionKey, registry: terminals)
        session.update(entry: sessions.first { $0.sessionKey == sessionKey })
        openSessions[sessionKey] = session
        return session
    }

    /// The session's tab closed: ompd stops streaming its TUI to the app. omp keeps running.
    public func release(_ sessionKey: SessionKey) {
        openSessions.removeValue(forKey: sessionKey)?.release()
    }

    /// Asks ompd to start omp's TUI in `workspace`, `size` big. The new session also arrives through the next `sessions`
    /// push.
    public func createSession(workspace: URL, approvalMode: ApprovalMode?, size: TerminalSize) async throws -> SessionManifestEntry {
        let path = Self.folderPath(workspace)
        let size = size.clamped
        let entry = try await connectedClient().call(
            SessionCreate.self,
            .init(workspace: path, approvalMode: approvalMode?.rawValue, cols: size.cols, rows: size.rows))
        adopt(entry)
        return entry
    }

    /// Starts omp again for a closed session, resuming its session file (`session.open`) with the TUI `size` big. ompd
    /// keeps the session (same key) and moves it to a new PTY, which its tab follows. `workspace`: a folder to run it
    /// in instead of the recorded one (the session's folder moved or is gone).
    public func resumeSession(_ sessionKey: SessionKey, in workspace: URL? = nil, size: TerminalSize) async throws -> SessionManifestEntry {
        guard let entry = sessions.first(where: { $0.sessionKey == sessionKey }), let sessionFile = entry.sessionFile else {
            throw DaemonError(.noSuchSession, "ompd knows no session file to resume this session from.")
        }
        let path = workspace.map { Self.folderPath($0) } ?? entry.workspace
        let size = size.clamped
        let resumed = try await connectedClient().call(
            SessionOpen.self, .init(sessionFile: sessionFile, workspace: path, cols: size.cols, rows: size.rows))
        adopt(resumed)
        return resumed
    }

    /// Starts omp's TUI `size` big in `workspace`, resuming the omp session file `file` (`session.open`): a new session,
    /// or the session ompd keeps for that file when its omp is not running. It also arrives through the next `sessions`
    /// push.
    public func openSession(file: URL, workspace: URL, size: TerminalSize) async throws -> SessionManifestEntry {
        let size = size.clamped
        let entry = try await connectedClient().call(
            SessionOpen.self,
            .init(sessionFile: file.path(percentEncoded: false), workspace: Self.folderPath(workspace), cols: size.cols, rows: size.rows))
        adopt(entry)
        return entry
    }

    /// The session ompd keeps for the omp session file at `path`, the paths compared canonically (`realpath`).
    public func session(forFile path: String) -> SessionManifestEntry? {
        let file = SessionFileListing.canonicalPath(path)
        return sessions.first { $0.sessionFile.map(SessionFileListing.canonicalPath) == file }
    }

    /// Answers the session's `pendingContinuation`: the main agent (`main`) and the subagents `agents` are asked to
    /// continue, the rest is left as it is. `main: false, agents: []` leaves it all.
    public func continueSession(_ sessionKey: SessionKey, main: Bool, agents: [String]) async throws {
        _ = try await connectedClient().call(SessionContinue.self, .init(sessionKey: sessionKey, main: main, agents: agents))
    }

    /// What ompd does with agents an omp death interrupted.
    public func restorePolicy() async throws -> RestorePolicy {
        try await connectedClient().call(RestorePolicyGet.self, Empty())
    }

    /// Replaces the restore policy; returns what ompd keeps.
    @discardableResult
    public func setRestorePolicy(_ policy: RestorePolicy) async throws -> RestorePolicy {
        try await connectedClient().call(RestorePolicySet.self, policy)
    }

    /// Ends the session's omp gracefully; the session stays listed as closed and can be resumed.
    public func closeSession(_ sessionKey: SessionKey) async throws {
        _ = try await connectedClient().call(SessionClose.self, .init(sessionKey: sessionKey))
    }

    /// Drops a stopped session from ompd's list (`session.forget`); its session file on disk stays. The `sessions`
    /// push confirms, but the list here drops it right away.
    public func forgetSession(_ sessionKey: SessionKey) async throws {
        _ = try await connectedClient().call(SessionForget.self, .init(sessionKey: sessionKey))
        release(sessionKey)
        sessions.removeAll { $0.sessionKey == sessionKey }
    }

    /// A session a call returned. A `sessions` push may already have brought it, or a newer state of it: that stays.
    private func adopt(_ entry: SessionManifestEntry) {
        guard !sessions.contains(where: { $0.sessionKey == entry.sessionKey }) else { return }
        sessions.append(entry)
        openSessions[entry.sessionKey]?.update(entry: entry)
    }

    /// A folder's path as ompd gets it: standardized, without a trailing slash.
    private static func folderPath(_ folder: URL) -> String {
        var path = folder.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - Agent supervision

    /// Every tool approval and `ask` waiting in a session TUI, over all sessions.
    public var attentionCount: Int { runtimes.values.reduce(0) { $0 + $1.attention.count } }

    /// Revives, parks or kills an agent of a running session; returns its row afterwards (nil once omp dropped it).
    @discardableResult
    public func control(agent agentId: String, of sessionKey: SessionKey, _ action: AgentControl.Action) async throws -> AgentInfo? {
        try await connectedClient().call(AgentControl.self, .init(sessionKey: sessionKey, agentId: agentId, action: action)).agent
    }

    /// `write agent://<agentId>` from the session's main agent.
    public func message(agent agentId: String, of sessionKey: SessionKey, body: String) async throws {
        _ = try await connectedClient().call(AgentMessage.self, .init(sessionKey: sessionKey, agentId: agentId, body: body))
    }

    /// The named services of `workspace` (omp's broker merged with what ompd recorded).
    public func services(in workspace: URL) async throws -> [ServiceInfo] {
        try await connectedClient().call(ServiceList.self, .init(workspace: Self.folderPath(workspace))).services
    }

    /// Stops, kills, restarts or re-modes a named service of `workspace`; returns it afterwards.
    @discardableResult
    public func control(
        service name: String, in workspace: URL, _ action: ServiceControlRequest.Action, mode: String? = nil
    ) async throws -> ServiceInfo {
        try await connectedClient().call(
            ServiceControlRequest.self, .init(workspace: Self.folderPath(workspace), name: name, action: action, mode: mode)
        ).service
    }

    private func apply(runtime: SessionRuntime) {
        let empty = runtime.agents.isEmpty && runtime.jobs.isEmpty && runtime.attention.isEmpty
        if empty {
            if runtimes[runtime.sessionKey] != nil { runtimes.removeValue(forKey: runtime.sessionKey) }
        } else if runtimes[runtime.sessionKey] != runtime {
            runtimes[runtime.sessionKey] = runtime
        }
    }

    /// The whole set after a (re)connect; an ompd from before `session.runtime` leaves it empty.
    private func fetchRuntimes(_ client: IDEClient) async {
        guard let list = try? await client.call(SessionRuntimeList.self, Empty()) else { return }
        guard self.client === client else { return }
        var fresh: [SessionKey: SessionRuntime] = [:]
        for runtime in list.sessions where !(runtime.agents.isEmpty && runtime.jobs.isEmpty && runtime.attention.isEmpty) {
            fresh[runtime.sessionKey] = runtime
        }
        if fresh != runtimes { runtimes = fresh }
    }

    // MARK: - Connection loop

    func connectedClient() throws -> IDEClient {
        guard let client else { throw IDETransportError.notConnected }
        return client
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            let client: IDEClient
            let welcome: Welcome
            let hasWindow = hasWindow
            do {
                let token = try readToken()
                client = IDEClient(
                    socketPath: paths.socket.path(percentEncoded: false), token: token, clientVersion: clientVersion,
                    clientKind: clientKind, hasWindow: hasWindow)
                welcome = try await client.connect()
            } catch {
                if Task.isCancelled { return }
                failures += 1
                status = if let refusal = error as? DaemonError, refusal.code == .versionMismatch {
                    .versionMismatch(message: refusal.message)
                } else {
                    .daemonUnavailable(reason: Self.reason(error))
                }
                do { try await Task.sleep(for: backoff.delay(afterFailures: failures)) } catch { return }
                continue
            }
            failures = 0
            await serve(client, welcome: welcome, hasWindow: hasWindow)
            if Task.isCancelled { return }
            status = .connecting
        }
    }

    /// Serves one connection until it ends. `hasWindow`: what its hello said.
    private func serve(_ client: IDEClient, welcome: Welcome, hasWindow: Bool) async {
        self.client = client
        reportedHasWindow = hasWindow
        // A window opened or closed while the hello was on its way.
        if hasWindow != self.hasWindow { queuePresenceReport() }
        status = .connected(welcome)
        if welcome.daemonStartedAt != noticesDaemonStartedAt {
            // A restarted ompd starts over (e.g. no longer read-only).
            if !notices.isEmpty { notices = [] }
            noticesDaemonStartedAt = welcome.daemonStartedAt
        }
        apply(sessions: welcome.sessions)
        terminals.connectionOpened()
        Task { await fetchRuntimes(client) }
        for await frame in client.pushes {
            route(frame)
        }
        self.client = nil
        await client.close()
        terminals.connectionClosed()
        if !runtimes.isEmpty { runtimes = [:] }
    }

    private func route(_ frame: ServerFrame) {
        switch frame {
        case .sessions(let list): apply(sessions: list.sessions)
        case .ptys(let list): terminals.receive(list)
        case .ptyOutput(let output): terminals.receive(output)
        case .runtime(let runtime): apply(runtime: runtime)
        case .notice(let notice):
            notices.append(notice)
            if notices.count > Self.noticeLimit { notices.removeFirst(notices.count - Self.noticeLimit) }
        case .welcome, .response: break // the client consumes these
        }
    }

    private func apply(sessions: [SessionManifestEntry]) {
        if sessions != self.sessions { self.sessions = sessions }
        for (sessionKey, session) in openSessions {
            session.update(entry: sessions.first { $0.sessionKey == sessionKey })
        }
    }

    private func readToken() throws -> String {
        let token: String
        do {
            token = try String(contentsOf: paths.token, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Unavailable.noToken(paths.token.path(percentEncoded: false))
        }
        guard !token.isEmpty else { throw Unavailable.noToken(paths.token.path(percentEncoded: false)) }
        return token
    }

    private enum Unavailable: Error {
        case noToken(String)
    }

    private static func reason(_ error: any Error) -> String {
        switch error {
        case Unavailable.noToken(let path):
            "ompd is not running (no token at \(path))."
        case IDETransportError.connectFailed:
            "ompd is not running (nothing listens on its socket)."
        case let error as DaemonError where error.code == .unauthorized:
            "ompd refused the connection token: \(error.message)"
        default:
            error.userMessage
        }
    }
}

/// Sessions of one workspace folder, newest first.
public struct WorkspaceGroup: Identifiable, Equatable, Sendable {
    public var path: String
    public var sessions: [SessionManifestEntry]

    public var id: String { path }
    public var name: String {
        let name = URL(filePath: path, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Groups by `workspace`, ordered by folder name then path; sessions newest first.
    public static func group(_ sessions: [SessionManifestEntry]) -> [WorkspaceGroup] {
        Dictionary(grouping: sessions, by: \.workspace)
            .map { path, sessions in
                WorkspaceGroup(path: path, sessions: sessions.sorted { ($0.createdAt, $0.sessionKey) > ($1.createdAt, $1.sessionKey) })
            }
            .sorted { ($0.name.localizedLowercase, $0.path) < ($1.name.localizedLowercase, $1.path) }
    }
}

extension SessionManifestEntry {
    /// omp's title for the session, else a short form of its key.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "Session \(sessionKey.prefix(8))"
    }

    /// omp does not run for the session: closed, or given up on after crashing again and again.
    public var isStopped: Bool { status == .closed || status == .needsAttention }

    /// omp does not run for the session and ompd knows a session file to start it again from (`session.open`).
    public var canResume: Bool { isStopped && sessionFile != nil }

    /// ompd knows the session's file, but it is no longer on disk: omp cannot resume it.
    public var sessionFileIsGone: Bool {
        guard let sessionFile else { return false }
        return !FileManager.default.fileExists(atPath: sessionFile)
    }

    /// The session's workspace folder is no longer on disk: omp cannot start there.
    public var workspaceIsGone: Bool {
        var isDirectory: ObjCBool = false
        return !FileManager.default.fileExists(atPath: workspace, isDirectory: &isDirectory) || !isDirectory.boolValue
    }
}

import Foundation
// The models speak the wire types (`SessionManifestEntry`, `PTYInfo`, …): importing IDEModel brings them along.
@_exported import IDEProtocol
import IDETransport
import Observation

/// The app's link to ompd: connects over `run/ompd.sock` with the token in `run/token`, retrying
/// with exponential backoff while the daemon is starting or restarting, keeps the session manifest and the PTY list
/// current from ompd's pushes, and routes PTY output to the terminals and session TUIs on screen. After each
/// (re)connect every shown terminal and session attaches again; restoring sends nothing to omp.
@MainActor @Observable
public final class DaemonConnection: TerminalBackend {
    public enum Status: Equatable, Sendable {
        case connecting
        case connected(Welcome)
        /// The last attempt failed; retrying with backoff.
        case daemonUnavailable(reason: String)
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

    @ObservationIgnored private var client: IDEClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// `Welcome.daemonStartedAt` of the ompd the notices came from.
    @ObservationIgnored private var noticesDaemonStartedAt: Date?

    public init(paths: AppSupportPaths = .standard, clientVersion: String, backoff: Backoff = Backoff()) {
        self.paths = paths
        self.clientVersion = clientVersion
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
        var path = workspace.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let size = size.clamped
        let entry = try await connectedClient().call(
            SessionCreate.self,
            .init(workspace: path, approvalMode: approvalMode?.rawValue, cols: size.cols, rows: size.rows))
        adopt(entry)
        return entry
    }

    /// Starts omp again for a closed session, resuming its session file (`session.open`) with the TUI `size` big. ompd
    /// keeps the session (same key) and moves it to a new PTY, which its tab follows.
    public func resumeSession(_ sessionKey: SessionKey, size: TerminalSize) async throws -> SessionManifestEntry {
        guard let entry = sessions.first(where: { $0.sessionKey == sessionKey }), let sessionFile = entry.sessionFile else {
            throw DaemonError(.noSuchSession, "ompd knows no session file to resume this session from.")
        }
        let size = size.clamped
        let resumed = try await connectedClient().call(
            SessionOpen.self, .init(sessionFile: sessionFile, workspace: entry.workspace, cols: size.cols, rows: size.rows))
        adopt(resumed)
        return resumed
    }

    /// Ends the session's omp gracefully; the session stays listed as closed and can be resumed.
    public func closeSession(_ sessionKey: SessionKey) async throws {
        _ = try await connectedClient().call(SessionClose.self, .init(sessionKey: sessionKey))
    }

    /// A session a call returned. A `sessions` push may already have brought it, or a newer state of it: that stays.
    private func adopt(_ entry: SessionManifestEntry) {
        guard !sessions.contains(where: { $0.sessionKey == entry.sessionKey }) else { return }
        sessions.append(entry)
        openSessions[entry.sessionKey]?.update(entry: entry)
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
            do {
                let token = try readToken()
                client = IDEClient(socketPath: paths.socket.path(percentEncoded: false), token: token, clientVersion: clientVersion)
                welcome = try await client.connect()
            } catch {
                if Task.isCancelled { return }
                failures += 1
                status = .daemonUnavailable(reason: Self.reason(error))
                do { try await Task.sleep(for: backoff.delay(afterFailures: failures)) } catch { return }
                continue
            }
            failures = 0
            await serve(client, welcome: welcome)
            if Task.isCancelled { return }
            status = .connecting
        }
    }

    /// Serves one connection until it ends.
    private func serve(_ client: IDEClient, welcome: Welcome) async {
        self.client = client
        status = .connected(welcome)
        if welcome.daemonStartedAt != noticesDaemonStartedAt {
            // A restarted ompd starts over (e.g. no longer read-only).
            if !notices.isEmpty { notices = [] }
            noticesDaemonStartedAt = welcome.daemonStartedAt
        }
        apply(sessions: welcome.sessions)
        terminals.connectionOpened()
        for await frame in client.pushes {
            route(frame)
        }
        self.client = nil
        await client.close()
        terminals.connectionClosed()
    }

    private func route(_ frame: ServerFrame) {
        switch frame {
        case .sessions(let list): apply(sessions: list.sessions)
        case .ptys(let list): terminals.receive(list)
        case .ptyOutput(let output): terminals.receive(output)
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
        case let error as DaemonError where error.code == .versionMismatch:
            "ompd speaks a different protocol version: \(error.message)"
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

    /// omp does not run for the session (closed, or given up on after crashing again and again) and ompd can start it
    /// again from its session file (`session.open`).
    public var canResume: Bool { (status == .closed || status == .needsAttention) && sessionFile != nil }
}

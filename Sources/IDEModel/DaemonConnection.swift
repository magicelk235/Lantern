import Foundation
import IDEProtocol
import IDETransport
import Observation

/// The app's link to ompd: connects over `run/ompd.sock` with the token in `run/token`, retrying
/// with exponential backoff while the daemon is starting or restarting, keeps the session list current, routes pushed
/// journal records to the open sessions and PTY output to the terminals, and re-subscribes every open session from its
/// `lastSeq` (and re-attaches every shown terminal) after each (re)connect. Restoring sends no omp command.
@MainActor @Observable
public final class DaemonConnection: SessionBackend {
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
    /// Sessions the user opened; each stays subscribed while connected.
    public private(set) var openSessions: [SessionKey: SessionViewModel] = [:]
    /// Out-of-band notices from the running ompd (`ServerFrame.notice`, e.g. read-only mode), oldest first. At most
    /// `noticeLimit`; cleared when the app connects to a different ompd process or by `dismissNotices()`.
    public private(set) var notices: [DaemonNotice] = []
    public nonisolated static let noticeLimit = 50
    /// ompd's PTYs and the terminals the app shows.
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

    /// Disconnects and stops reconnecting. Open sessions keep their transcripts.
    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await client?.close()
    }

    /// The model for `sessionKey`, subscribing it (now if connected, else on connect) the first time.
    @discardableResult
    public func open(_ sessionKey: SessionKey) -> SessionViewModel {
        if let model = openSessions[sessionKey] { return model }
        let model = SessionViewModel(sessionKey: sessionKey, entry: sessions.first { $0.sessionKey == sessionKey }, backend: self)
        openSessions[sessionKey] = model
        if client != nil { model.connectionOpened() }
        return model
    }

    /// Asks ompd to spawn omp in `workspace`. The new session also arrives through the next `sessions` push.
    public func createSession(workspace: URL, approvalMode: ApprovalMode?) async throws -> SessionManifestEntry {
        var path = workspace.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let entry = try await connectedClient().call(SessionCreate.self, .init(workspace: path, approvalMode: approvalMode?.rawValue))
        if !sessions.contains(where: { $0.sessionKey == entry.sessionKey }) { sessions.append(entry) }
        return entry
    }

    /// Gracefully ends the session's omp (the daemon closes its stdin and drains it); the transcript stays readable.
    public func closeSession(_ sessionKey: SessionKey) async throws {
        _ = try await connectedClient().call(SessionClose.self, .init(sessionKey: sessionKey))
    }

    // MARK: - SessionBackend

    public func subscribe(_ sessionKey: SessionKey, since: Seq) async throws -> Subscribe.Result {
        try await connectedClient().call(Subscribe.self, .init(sessionKey: sessionKey, since: since))
    }

    public func snapshot(_ sessionKey: SessionKey) async throws -> SessionSnapshot.Result {
        try await connectedClient().call(SessionSnapshot.self, .init(sessionKey: sessionKey))
    }

    public func send(_ command: JSONValue, to sessionKey: SessionKey) async throws -> JSONValue {
        try await connectedClient().call(OmpCommand.self, .init(sessionKey: sessionKey, command: command))
    }

    public func respond(to requestId: String, in sessionKey: SessionKey, with response: JSONValue) async throws {
        _ = try await connectedClient().call(UIRespond.self, .init(sessionKey: sessionKey, requestId: requestId, response: response))
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
        for model in openSessions.values { model.connectionOpened() }
        terminals.connectionOpened()
        for await frame in client.pushes {
            route(frame)
        }
        self.client = nil
        await client.close()
        for model in openSessions.values { model.connectionClosed() }
        terminals.connectionClosed()
    }

    private func route(_ frame: ServerFrame) {
        switch frame {
        case .event(let record): openSessions[record.sessionKey]?.receive(record)
        case .resync(let resync): openSessions[resync.sessionKey]?.receive(resync)
        case .sessions(let list): apply(sessions: list.sessions)
        case .notice(let notice):
            notices.append(notice)
            if notices.count > Self.noticeLimit { notices.removeFirst(notices.count - Self.noticeLimit) }
        case .ptyOutput(let output): terminals.receive(output)
        case .welcome, .response: break // the client consumes these
        }
    }

    private func apply(sessions: [SessionManifestEntry]) {
        if sessions != self.sessions { self.sessions = sessions }
        for entry in sessions {
            openSessions[entry.sessionKey]?.update(entry: entry)
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
}

import Foundation
import IDEProtocol

/// The menu-bar extra: `omp IDE Menu Bar.app`, a helper inside omp IDE (`Contents/Library/LoginItems`)
/// that omp IDE registers as a login item, so what the agents do shows in the menu bar also while omp IDE is closed. It
/// is a `cli` client of ompd: no window, so it neither keeps the sessions running nor resumes them.
public enum MenuBarHelper {
    /// The helper's bundle identifier, which `SMAppService.loginItem(identifier:)` registers.
    public static let bundleIdentifier = "com.omp-ide.menubar"
    /// omp IDE's: the defaults domain `shownKey` lives in, and the app Open omp IDE opens when the helper is not inside
    /// one.
    public static let appBundleIdentifier = "com.omp-ide.app"
    /// omp IDE's setting (Settings › General), also turned off by Hide from Menu Bar in the extra's menu: a Bool, on
    /// when absent.
    public static let shownKey = "showsMenuBarExtra"
}

/// What the menu-bar extra shows, from ompd's session manifest and the sessions' runtimes
/// (`DaemonConnection.sessions` and `.runtimes`): how many agents work right now, how much waits for the user, and
/// every session that is not closed, by project.
public struct MenuBarStatus: Equatable, Sendable {
    /// A session as the menu lists it.
    public struct Session: Equatable, Sendable, Identifiable {
        public var id: SessionKey { sessionKey }
        public var sessionKey: SessionKey
        /// omp's title for the session, else "New session".
        public var title: String
        public var status: SessionStatus
        /// The oldest tool approval or `ask` waiting in its TUI.
        public var waiting: AttentionItem?
        /// Its agents that work right now (`runningAgents(of:runtime:)`).
        public var runningAgents: Int

        public init(
            sessionKey: SessionKey, title: String, status: SessionStatus, waiting: AttentionItem? = nil, runningAgents: Int = 0
        ) {
            self.sessionKey = sessionKey
            self.title = title
            self.status = status
            self.waiting = waiting
            self.runningAgents = runningAgents
        }
    }

    /// A project folder and its sessions, oldest first (the order of its tabs).
    public struct Project: Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        /// The folder's name.
        public var name: String
        public var sessions: [Session]

        public init(path: String, name: String, sessions: [Session]) {
            self.path = path
            self.name = name
            self.sessions = sessions
        }
    }

    /// The agents that work right now, over every session: the number the menu bar shows.
    public var runningAgents: Int
    /// Tool approvals and `ask`s waiting in the sessions' TUIs (what the Dock badge counts).
    public var waitingCount: Int
    /// The projects of the listed sessions, by name.
    public var projects: [Project]

    public init(sessions: [SessionManifestEntry], runtimes: [SessionKey: SessionRuntime]) {
        var running = 0
        var waiting = 0
        var byProject: [String: [Session]] = [:]
        let listed = sessions.filter { $0.status != .closed }
            .sorted { ($0.createdAt, $0.sessionKey) < ($1.createdAt, $1.sessionKey) }
        for entry in listed {
            let runtime = runtimes[entry.sessionKey]
            let agents = Self.runningAgents(of: entry, runtime: runtime)
            let attention = runtime?.attention ?? []
            running += agents
            waiting += attention.count
            let title = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? "New session"
            byProject[entry.workspace, default: []].append(Session(
                sessionKey: entry.sessionKey, title: title, status: entry.status, waiting: attention.first, runningAgents: agents))
        }
        runningAgents = running
        waitingCount = waiting
        projects = byProject
            .map { path, sessions in
                let name = URL(filePath: path, directoryHint: .isDirectory).lastPathComponent
                return Project(path: path, name: name.isEmpty ? path : name, sessions: sessions)
            }
            .sorted { ($0.name.localizedLowercase, $0.path) < ($1.name.localizedLowercase, $1.path) }
    }

    /// The agents of a session that work right now: its main agent while the session is `busy`, and every other agent
    /// omp reports `running`. None while the session is paused, since omp's pause gate holds each agent at its next step
    /// (it is how every session waits while no omp IDE window is open), nor while its omp does not run.
    public static func runningAgents(of entry: SessionManifestEntry, runtime: SessionRuntime?) -> Int {
        switch entry.status {
        case .busy, .idle:
            let main = entry.status == .busy ? 1 : 0
            return main + (runtime?.agents.count(where: { $0.status == .running && !isMain($0) }) ?? 0)
        case .paused, .starting, .resuming, .interrupted, .closed, .needsAttention:
            return 0
        }
    }

    /// omp's main agent (`Main`), whose row follows the session.
    private static func isMain(_ agent: AgentInfo) -> Bool {
        agent.id == "Main" || agent.kind == "main"
    }
}

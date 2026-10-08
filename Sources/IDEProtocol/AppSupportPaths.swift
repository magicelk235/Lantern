import Foundation

/// Layout of `$APP_SUPPORT` = `~/Library/Application Support/com.magicelklabs.lantern/`: everything the IDE owns
/// on disk. Nothing under `run/` outlives a daemon run; everything else is user data.
public struct AppSupportPaths: Sendable, Equatable {
    public let root: URL
    /// Per-daemon-run state; wiped by `prepare()` because sockets, tokens and locks from a previous run
    /// (or another machine, after a migration) are never trusted.
    public let run: URL
    /// `run/ompd.sock`: the daemon's unix-domain socket.
    public let socket: URL
    /// `run/bridge.sock`: control socket the ide-bridge extension inside each omp dials.
    public let bridgeSocket: URL
    /// `run/token`: bearer token (0600) a client presents in `Hello`.
    public let token: URL
    /// `run/owned-sessions`: session-ownership locks consulted by ide-bridge.
    public let ownedSessions: URL
    /// `sessions.json`: the session manifest.
    public let manifest: URL
    /// `pty/`: serialized terminal screens.
    public let ptySnapshots: URL
    /// `hot-exit/`: plain-file mirrors of dirty editor buffers.
    public let hotExit: URL
    /// `state.sqlite`: the app's window/editor state.
    public let stateDB: URL
    /// `project-rename.json`: ompd's journal of a project folder rename under way (`ProjectRename`), which the next ompd
    /// finishes after a crash.
    public let projectRename: URL
    /// `project-rename-app.json`: the app's journal of the same rename, until its window layouts, editor state and
    /// unsaved buffers follow the folder.
    public let projectRenameApp: URL

    public init(root: URL) {
        self.root = root
        run = root.appending(path: "run", directoryHint: .isDirectory)
        socket = run.appending(path: "ompd.sock", directoryHint: .notDirectory)
        bridgeSocket = run.appending(path: "bridge.sock", directoryHint: .notDirectory)
        token = run.appending(path: "token", directoryHint: .notDirectory)
        ownedSessions = run.appending(path: "owned-sessions")
        manifest = root.appending(path: "sessions.json", directoryHint: .notDirectory)
        ptySnapshots = root.appending(path: "pty", directoryHint: .isDirectory)
        hotExit = root.appending(path: "hot-exit", directoryHint: .isDirectory)
        stateDB = root.appending(path: "state.sqlite", directoryHint: .notDirectory)
        projectRename = root.appending(path: "project-rename.json", directoryHint: .notDirectory)
        projectRenameApp = root.appending(path: "project-rename-app.json", directoryHint: .notDirectory)
    }

    /// Environment variable that relocates `standard` (tests, side-by-side daemons).
    public static let homeEnvironmentKey = "OMPD_HOME"

    /// `~/Library/Application Support/com.magicelklabs.lantern`, or `$OMPD_HOME` when set and non-empty.
    public static var standard: AppSupportPaths {
        if let home = ProcessInfo.processInfo.environment[homeEnvironmentKey], !home.isEmpty {
            return AppSupportPaths(root: URL(filePath: NSString(string: home).expandingTildeInPath, directoryHint: .isDirectory))
        }
        return AppSupportPaths(root: URL.applicationSupportDirectory.appending(path: "com.magicelklabs.lantern", directoryHint: .isDirectory))
    }
}

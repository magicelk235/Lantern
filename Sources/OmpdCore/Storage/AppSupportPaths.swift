import Foundation

/// Layout of `$APP_SUPPORT` = `~/Library/Application Support/omp-ide/`: everything the IDE owns
/// on disk. Nothing under `run/` outlives a daemon run; everything else is user data.
public struct AppSupportPaths: Sendable, Equatable {
    public let root: URL
    /// Per-daemon-run state; wiped by `prepare()` because sockets, tokens and locks from a previous run
    /// (or another machine, after a migration) are never trusted.
    public let run: URL
    /// `run/ompd.sock`: the daemon's unix-domain socket.
    public let socket: URL
    /// `run/token`: bearer token (0600) a client presents in `Hello`.
    public let token: URL
    /// `run/owned-sessions`: session-ownership locks consulted by ide-bridge.
    public let ownedSessions: URL
    /// `journal/`: one `<sessionKey>.jsonl` per session.
    public let journalDir: URL
    /// `sessions.json`: the session manifest.
    public let manifest: URL
    /// `pty/`: serialized terminal screens.
    public let ptySnapshots: URL
    /// `hot-exit/`: plain-file mirrors of dirty editor buffers.
    public let hotExit: URL
    /// `state.sqlite`: the app's window/editor state.
    public let stateDB: URL

    public init(root: URL) {
        self.root = root
        run = root.appending(path: "run", directoryHint: .isDirectory)
        socket = run.appending(path: "ompd.sock", directoryHint: .notDirectory)
        token = run.appending(path: "token", directoryHint: .notDirectory)
        ownedSessions = run.appending(path: "owned-sessions")
        journalDir = root.appending(path: "journal", directoryHint: .isDirectory)
        manifest = root.appending(path: "sessions.json", directoryHint: .notDirectory)
        ptySnapshots = root.appending(path: "pty", directoryHint: .isDirectory)
        hotExit = root.appending(path: "hot-exit", directoryHint: .isDirectory)
        stateDB = root.appending(path: "state.sqlite", directoryHint: .notDirectory)
    }

    /// Environment variable that relocates `standard` (tests, side-by-side daemons).
    public static let homeEnvironmentKey = "OMPD_HOME"

    /// `~/Library/Application Support/omp-ide`, or `$OMPD_HOME` when set and non-empty.
    public static var standard: AppSupportPaths {
        if let home = ProcessInfo.processInfo.environment[homeEnvironmentKey], !home.isEmpty {
            return AppSupportPaths(root: URL(filePath: NSString(string: home).expandingTildeInPath, directoryHint: .isDirectory))
        }
        return AppSupportPaths(root: URL.applicationSupportDirectory.appending(path: "omp-ide", directoryHint: .isDirectory))
    }

    /// Creates the layout with every directory at mode 0700, and recreates `run/` empty.
    public func prepare() throws {
        try StorageIO.createPrivateDirectory(root)
        do {
            try FileManager.default.removeItem(at: run)
        } catch CocoaError.fileNoSuchFile {
            // First run.
        }
        for directory in [run, journalDir, ptySnapshots, hotExit] {
            try StorageIO.createPrivateDirectory(directory)
        }
    }

    /// The client bearer token: the one in `run/token` if valid, else 32 fresh random bytes hex-encoded and
    /// written atomically with mode 0600.
    public func loadOrCreateToken() throws -> String {
        if let data = try StorageIO.readFileIfPresent(token),
            let existing = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            existing.utf8.count == 64, existing.utf8.allSatisfy({ Self.hexDigits.contains($0) })
        {
            return existing
        }
        var generator = SystemRandomNumberGenerator()
        let fresh = String(
            decoding: (0..<32).flatMap { _ -> [UInt8] in
                let byte = generator.next() as UInt8
                return [Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 0x0F)]]
            },
            as: UTF8.self
        )
        try StorageIO.writeAtomically(Data(fresh.utf8), to: token, mode: 0o600, durable: false)
        return fresh
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
}

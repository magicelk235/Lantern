import Foundation

/// A typed daemon RPC. Clients call `client.call(M.self, params)`; the daemon routes on `M.name`.
public protocol DaemonMethod: Sendable {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var name: String { get }
}

public struct Empty: Codable, Sendable, Equatable { public init() {} }

// MARK: - Daemon

public enum DaemonStatus: DaemonMethod {
    public static let name = "daemon.status"
    public typealias Params = Empty
    public struct Result: Codable, Sendable, Equatable {
        public var daemonVersion: String
        public var pid: Int32
        public var startedAt: Date
        public var readOnly: Bool
        public var sessions: [SessionManifestEntry]
        public var ptys: [PTYInfo]
        public init(daemonVersion: String, pid: Int32, startedAt: Date, readOnly: Bool, sessions: [SessionManifestEntry], ptys: [PTYInfo]) {
            self.daemonVersion = daemonVersion
            self.pid = pid
            self.startedAt = startedAt
            self.readOnly = readOnly
            self.sessions = sessions
            self.ptys = ptys
        }
    }
}

// MARK: - Sessions

public enum SessionCreate: DaemonMethod {
    public static let name = "session.create"
    public struct Params: Codable, Sendable, Equatable {
        public var workspace: String
        public var approvalMode: String?
        public var model: String?
        /// Initial TUI size (the attaching view's size), so omp's first paint fits.
        public var cols: Int
        public var rows: Int
        public init(workspace: String, approvalMode: String? = nil, model: String? = nil, cols: Int = 120, rows: Int = 40) {
            self.workspace = workspace
            self.approvalMode = approvalMode
            self.model = model
            self.cols = cols
            self.rows = rows
        }
    }
    public typealias Result = SessionManifestEntry
}

/// Adopt an existing omp session file (spawns the omp TUI with `--resume <sessionFile>` in a new PTY).
public enum SessionOpen: DaemonMethod {
    public static let name = "session.open"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionFile: String
        public var workspace: String
        public var cols: Int
        public var rows: Int
        public init(sessionFile: String, workspace: String, cols: Int = 120, rows: Int = 40) {
            self.sessionFile = sessionFile
            self.workspace = workspace
            self.cols = cols
            self.rows = rows
        }
    }
    public typealias Result = SessionManifestEntry
}

public enum ListSessions: DaemonMethod {
    public static let name = "session.list"
    public typealias Params = Empty
    public typealias Result = SessionList
}

/// Close Session: graceful omp shutdown via the ide-bridge (normal dispose, `session_exit` normal), then the
/// session PTY is closed; `closedByUser = true`.
public enum SessionClose: DaemonMethod {
    public static let name = "session.close"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public init(sessionKey: SessionKey) { self.sessionKey = sessionKey }
    }
    public typealias Result = Empty
}

/// Drops a session whose omp is not running (closed, or given up on) from the manifest. The session file on disk is
/// untouched. A session whose omp runs or is being respawned is refused (`sessionBusy`): close it first.
public enum SessionForget: DaemonMethod {
    public static let name = "session.forget"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public init(sessionKey: SessionKey) { self.sessionKey = sessionKey }
    }
    public typealias Result = Empty
}

// MARK: - PTYs

public struct PTYInfo: Codable, Sendable, Equatable {
    public var ptyId: PTYID
    public var cwd: String
    public var command: [String]
    public var cols: Int
    public var rows: Int
    public var pid: Int32?
    public var running: Bool
    /// Set when this PTY runs an omp session's TUI; nil for plain terminals. Clients list only nil ones as
    /// terminals and reach session PTYs through `SessionManifestEntry.ptyId`.
    public var sessionKey: SessionKey?
    public init(
        ptyId: PTYID, cwd: String, command: [String], cols: Int, rows: Int, pid: Int32?, running: Bool,
        sessionKey: SessionKey? = nil
    ) {
        self.ptyId = ptyId
        self.cwd = cwd
        self.command = command
        self.cols = cols
        self.rows = rows
        self.pid = pid
        self.running = running
        self.sessionKey = sessionKey
    }
}

public enum PTYOpen: DaemonMethod {
    public static let name = "pty.open"
    public struct Params: Codable, Sendable, Equatable {
        public var cwd: String
        /// nil = user's login shell.
        public var command: [String]?
        public var env: [String: String]?
        public var cols: Int
        public var rows: Int
        public init(cwd: String, command: [String]? = nil, env: [String: String]? = nil, cols: Int, rows: Int) {
            self.cwd = cwd
            self.command = command
            self.env = env
            self.cols = cols
            self.rows = rows
        }
    }
    public typealias Result = PTYInfo
}

/// Attach this connection to a PTY: returns the serialized screen (VT byte stream that repaints the
/// current buffer + scrollback), then `ServerFrame.ptyOutput` frames stream live.
public enum PTYAttach: DaemonMethod {
    public static let name = "pty.attach"
    public struct Params: Codable, Sendable, Equatable {
        public var ptyId: PTYID
        public init(ptyId: PTYID) { self.ptyId = ptyId }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var info: PTYInfo
        public var screen: Data
        public init(info: PTYInfo, screen: Data) { self.info = info; self.screen = screen }
    }
}

public enum PTYDetach: DaemonMethod {
    public static let name = "pty.detach"
    public struct Params: Codable, Sendable, Equatable {
        public var ptyId: PTYID
        public init(ptyId: PTYID) { self.ptyId = ptyId }
    }
    public typealias Result = Empty
}

public enum PTYWrite: DaemonMethod {
    public static let name = "pty.write"
    public struct Params: Codable, Sendable, Equatable {
        public var ptyId: PTYID
        public var data: Data
        public init(ptyId: PTYID, data: Data) { self.ptyId = ptyId; self.data = data }
    }
    public typealias Result = Empty
}

public enum PTYResize: DaemonMethod {
    public static let name = "pty.resize"
    public struct Params: Codable, Sendable, Equatable {
        public var ptyId: PTYID
        public var cols: Int
        public var rows: Int
        public init(ptyId: PTYID, cols: Int, rows: Int) { self.ptyId = ptyId; self.cols = cols; self.rows = rows }
    }
    public typealias Result = Empty
}

public enum PTYClose: DaemonMethod {
    public static let name = "pty.close"
    public struct Params: Codable, Sendable, Equatable {
        public var ptyId: PTYID
        public init(ptyId: PTYID) { self.ptyId = ptyId }
    }
    public typealias Result = Empty
}

public enum PTYList: DaemonMethod {
    public static let name = "pty.list"
    public typealias Params = Empty
    public struct Result: Codable, Sendable, Equatable {
        public var ptys: [PTYInfo]
        public init(ptys: [PTYInfo]) { self.ptys = ptys }
    }
}

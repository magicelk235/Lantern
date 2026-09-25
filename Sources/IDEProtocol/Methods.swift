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
        public init(workspace: String, approvalMode: String? = nil, model: String? = nil) {
            self.workspace = workspace
            self.approvalMode = approvalMode
            self.model = model
        }
    }
    public typealias Result = SessionManifestEntry
}

/// Adopt an existing omp session file (spawns `omp --resume <sessionFile>`).
public enum SessionOpen: DaemonMethod {
    public static let name = "session.open"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionFile: String
        public var workspace: String
        public init(sessionFile: String, workspace: String) { self.sessionFile = sessionFile; self.workspace = workspace }
    }
    public typealias Result = SessionManifestEntry
}

public enum ListSessions: DaemonMethod {
    public static let name = "session.list"
    public typealias Params = Empty
    public typealias Result = SessionList
}

/// User closed the tab: graceful omp shutdown (close stdin, drain), `closedByUser = true`.
public enum SessionClose: DaemonMethod {
    public static let name = "session.close"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public init(sessionKey: SessionKey) { self.sessionKey = sessionKey }
    }
    public typealias Result = Empty
}

/// Start (or restart) streaming journal records for a session. Records with `seq > since` are replayed,
/// then the subscription goes live without gaps or duplicates. Unknown `since` => `ServerFrame.resync`.
public enum Subscribe: DaemonMethod {
    public static let name = "subscribe"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public var since: Seq
        public init(sessionKey: SessionKey, since: Seq) { self.sessionKey = sessionKey; self.since = since }
    }
    public struct Result: Codable, Sendable, Equatable {
        /// Seq of the last replayed record; live records follow with seq > this.
        public var replayedThrough: Seq
        public init(replayedThrough: Seq) { self.replayedThrough = replayedThrough }
    }
}

public enum Unsubscribe: DaemonMethod {
    public static let name = "unsubscribe"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public init(sessionKey: SessionKey) { self.sessionKey = sessionKey }
    }
    public typealias Result = Empty
}

/// Full-state rebuild: omp `get_state` + `get_entries` (via the live process or read from disk if not running).
public enum SessionSnapshot: DaemonMethod {
    public static let name = "session.snapshot"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public init(sessionKey: SessionKey) { self.sessionKey = sessionKey }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var entry: SessionManifestEntry
        public var state: JSONValue?
        public var entries: JSONValue?
        public var lastSeq: Seq
        public init(entry: SessionManifestEntry, state: JSONValue?, entries: JSONValue?, lastSeq: Seq) {
            self.entry = entry
            self.state = state
            self.entries = entries
            self.lastSeq = lastSeq
        }
    }
}

/// Pass-through of any omp RPC command. `command` is the omp command
/// object without `id` (the daemon assigns ids). Result is omp's response `data` (or error).
public enum OmpCommand: DaemonMethod {
    public static let name = "omp"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public var command: JSONValue
        public init(sessionKey: SessionKey, command: JSONValue) { self.sessionKey = sessionKey; self.command = command }
    }
    public typealias Result = JSONValue
}

/// Answer a held `extension_ui_request` (payload = omp `extension_ui_response` minus `type`/`id`) or
/// `host_tool_call` (payload = `host_tool_result` minus `type`/`id`).
public enum UIRespond: DaemonMethod {
    public static let name = "ui.respond"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public var requestId: String
        public var response: JSONValue
        public init(sessionKey: SessionKey, requestId: String, response: JSONValue) {
            self.sessionKey = sessionKey
            self.requestId = requestId
            self.response = response
        }
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
    public init(ptyId: PTYID, cwd: String, command: [String], cols: Int, rows: Int, pid: Int32?, running: Bool) {
        self.ptyId = ptyId
        self.cwd = cwd
        self.command = command
        self.cols = cols
        self.rows = rows
        self.pid = pid
        self.running = running
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

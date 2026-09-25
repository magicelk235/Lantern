import Foundation

/// `$APP_SUPPORT/sessions.json`. Invariant: nothing here is invalid after a reboot
/// (no PIDs, socket paths or fds). Liveness is always re-derived at startup.
public struct SessionManifest: Sendable, Equatable, Codable {
    public var version: Int
    public var sessions: [SessionManifestEntry]
    public init(version: Int = 2, sessions: [SessionManifestEntry] = []) {
        self.version = version
        self.sessions = sessions
    }
}

/// One omp session owned by ompd. The session runs omp's own interactive TUI inside a daemon-owned PTY;
/// clients render it by attaching to `ptyId` (`pty.attach`), exactly like any other terminal.
public struct SessionManifestEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: SessionKey { sessionKey }
    public var sessionKey: SessionKey
    public var workspace: String
    /// omp session JSONL path; nil until the ide-bridge `hello` reports it.
    public var sessionFile: String?
    public var sessionId: String?
    public var title: String?
    public var launch: LaunchSpec
    public var status: SessionStatus
    /// PTY currently running this session's omp TUI. Runtime-only: cleared at daemon startup and replaced on
    /// every respawn (never trusted across a reboot).
    public var ptyId: PTYID?
    public var createdAt: Date
    /// Last time omp reported activity (bridge agent/turn events); drives sidebar ordering.
    public var lastActiveAt: Date?
    public var services: [NamedService]
    public var closedByUser: Bool

    public init(
        sessionKey: SessionKey, workspace: String, sessionFile: String? = nil, sessionId: String? = nil,
        title: String? = nil, launch: LaunchSpec, status: SessionStatus = .starting, ptyId: PTYID? = nil,
        createdAt: Date, lastActiveAt: Date? = nil, services: [NamedService] = [], closedByUser: Bool = false
    ) {
        self.sessionKey = sessionKey
        self.workspace = workspace
        self.sessionFile = sessionFile
        self.sessionId = sessionId
        self.title = title
        self.launch = launch
        self.status = status
        self.ptyId = ptyId
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.services = services
        self.closedByUser = closedByUser
    }
}

/// Everything needed to (re)spawn the same omp TUI for a session. The binary is pinned by absolute path +
/// version so a half-upgraded system never mixes versions inside one session.
public struct LaunchSpec: Sendable, Equatable, Codable {
    public var ompPath: String
    public var ompVersion: String
    public var approvalMode: String?
    public var model: String?
    /// Extra CLI args appended verbatim.
    public var extraArgs: [String]
    /// Pinned env (`PI_CODING_AGENT_DIR`, `OMP_PROFILE`, ...). Merged over the daemon env.
    public var env: [String: String]
    /// `--session-dir`; nil = omp default for the cwd.
    public var sessionDir: String?

    public init(
        ompPath: String, ompVersion: String, approvalMode: String? = nil, model: String? = nil,
        extraArgs: [String] = [], env: [String: String] = [:], sessionDir: String? = nil
    ) {
        self.ompPath = ompPath
        self.ompVersion = ompVersion
        self.approvalMode = approvalMode
        self.model = model
        self.extraArgs = extraArgs
        self.env = env
        self.sessionDir = sessionDir
    }
}

public enum SessionStatus: String, Sendable, Codable {
    /// omp TUI spawned; ide-bridge `hello` not yet received.
    case starting
    /// The agent is running a turn (bridge activity events).
    case busy
    /// TUI alive and waiting for input.
    case idle
    /// omp died unexpectedly; awaiting resume.
    case interrupted
    /// Respawning with `--resume`.
    case resuming
    /// Closed by the user (tab closed via Close Session, or omp exited normally from its TUI). Skipped by restore.
    case closed
    /// Cannot be resumed without user action (e.g. workspace folder missing).
    case needsAttention = "needs_attention"
    /// omp runs, its agents held by omp's pause gate (`/pause`): by ompd while no omp IDE window is connected, or by
    /// the user, whose pause outlasts reconnects until they dismiss omp's pause screen.
    case paused
}

/// Durable, relaunchable copy of an omp named service. omp's broker prunes its
/// own records ~5 min after a scope goes idle and cannot tell idle-out from an explicit stop, so ompd owns
/// the spec and the desired state.
public struct NamedService: Sendable, Equatable, Codable {
    /// Service name (omp: 1–48 `[A-Za-z0-9._-]`, unique per broker scope = omp cwd realpath).
    public var id: String
    /// `persist` | `session` | `detached` (omp `proc://<id>/mode`).
    public var mode: String
    /// Tool-level command as given to the bash tool.
    public var command: String?
    /// Absolute service cwd; nil = session workspace.
    public var cwd: String?
    /// Tool-level env overrides only (never the expanded shell env).
    public var env: [String: String]
    /// omp default true; `detached` forces false.
    public var pty: Bool
    /// Readiness spec as given to the tool (`{log?, port?, host?, timeout?}`).
    public var ready: JSONValue?
    /// ompd intent. Relaunch targets only services that should be running.
    public var desiredRunning: Bool

    public init(
        id: String, mode: String, command: String? = nil, cwd: String? = nil, env: [String: String] = [:],
        pty: Bool = true, ready: JSONValue? = nil, desiredRunning: Bool = true
    ) {
        self.id = id
        self.mode = mode
        self.command = command
        self.cwd = cwd
        self.env = env
        self.pty = pty
        self.ready = ready
        self.desiredRunning = desiredRunning
    }

    private enum CodingKeys: String, CodingKey { case id, mode, command, cwd, env, pty, ready, desiredRunning }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mode = try c.decode(String.self, forKey: .mode)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        pty = try c.decodeIfPresent(Bool.self, forKey: .pty) ?? true
        ready = try c.decodeIfPresent(JSONValue.self, forKey: .ready)
        desiredRunning = try c.decodeIfPresent(Bool.self, forKey: .desiredRunning) ?? true
    }
}

import Foundation

/// `$APP_SUPPORT/sessions.json`. Invariant: nothing here is invalid after a reboot
/// (no PIDs, socket paths or fds). Liveness is always re-derived at startup.
public struct SessionManifest: Sendable, Equatable, Codable {
    public var version: Int
    public var sessions: [SessionManifestEntry]
    public init(version: Int = 1, sessions: [SessionManifestEntry] = []) {
        self.version = version
        self.sessions = sessions
    }
}

public struct SessionManifestEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: SessionKey { sessionKey }
    public var sessionKey: SessionKey
    public var workspace: String
    /// omp session JSONL path; nil until omp reports it via `get_state.sessionFile`.
    public var sessionFile: String?
    public var sessionId: String?
    public var title: String?
    public var launch: LaunchSpec
    public var status: SessionStatus
    public var lastSeq: Seq
    public var lastSettledAt: Date?
    public var createdAt: Date
    public var services: [NamedService]
    public var pending: PendingRequests
    public var closedByUser: Bool

    public init(
        sessionKey: SessionKey, workspace: String, sessionFile: String? = nil, sessionId: String? = nil,
        title: String? = nil, launch: LaunchSpec, status: SessionStatus = .starting, lastSeq: Seq = 0,
        lastSettledAt: Date? = nil, createdAt: Date, services: [NamedService] = [],
        pending: PendingRequests = .init(), closedByUser: Bool = false
    ) {
        self.sessionKey = sessionKey
        self.workspace = workspace
        self.sessionFile = sessionFile
        self.sessionId = sessionId
        self.title = title
        self.launch = launch
        self.status = status
        self.lastSeq = lastSeq
        self.lastSettledAt = lastSettledAt
        self.createdAt = createdAt
        self.services = services
        self.pending = pending
        self.closedByUser = closedByUser
    }
}

/// Everything needed to (re)spawn the same omp for a session. The binary is pinned by absolute path +
/// version so a half-upgraded system never mixes protocol versions inside one session.
public struct LaunchSpec: Sendable, Equatable, Codable {
    public var ompPath: String
    public var ompVersion: String
    /// `rpc-ui` in production.
    public var mode: String
    public var approvalMode: String?
    public var model: String?
    /// Extra CLI args appended verbatim (e.g. `-e <ide-bridge.ts>`).
    public var extraArgs: [String]
    /// Pinned env (`PI_CODING_AGENT_DIR`, `OMP_PROFILE`, `PI_RPC_EMIT_TITLE`, ...). Merged over the daemon env.
    public var env: [String: String]
    /// `--session-dir`; nil = omp default for the cwd.
    public var sessionDir: String?

    public init(
        ompPath: String, ompVersion: String, mode: String = "rpc-ui", approvalMode: String? = nil,
        model: String? = nil, extraArgs: [String] = [], env: [String: String] = [:], sessionDir: String? = nil
    ) {
        self.ompPath = ompPath
        self.ompVersion = ompVersion
        self.mode = mode
        self.approvalMode = approvalMode
        self.model = model
        self.extraArgs = extraArgs
        self.env = env
        self.sessionDir = sessionDir
    }
}

public enum SessionStatus: String, Sendable, Codable {
    /// omp spawned, not yet `ready`.
    case starting
    /// Running a turn or has pending async work.
    case busy
    /// `session_settled`: nothing can wake it.
    case settled
    /// omp died unexpectedly; awaiting resume/continuation policy.
    case interrupted
    /// Respawning with `--resume`.
    case resuming
    /// Closed by the user; omp not running. Skipped by Regime B2 restore.
    case closed
    /// Cannot be resumed without user action (e.g. workspace folder missing).
    case needsAttention = "needs_attention"
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

/// UI requests omp is blocked on. Re-presented on reconnect (Regime A) or reported as lost (Regime B).
public struct PendingRequests: Sendable, Equatable, Codable {
    /// `extension_ui_request` frames still awaiting `extension_ui_response`.
    public var uiRequests: [HeldRequest]
    /// `host_tool_call` frames still awaiting `host_tool_result`.
    public var hostToolCalls: [HeldRequest]
    public init(uiRequests: [HeldRequest] = [], hostToolCalls: [HeldRequest] = []) {
        self.uiRequests = uiRequests
        self.hostToolCalls = hostToolCalls
    }
}

/// One request omp is blocked on: its verbatim frame and when ompd read it from omp's stdout. A dialog's `timeout`
/// runs from `receivedAt`, so a restored timed dialog expires when omp resolved it, not later.
public struct HeldRequest: Sendable, Equatable, Codable {
    public var frame: JSONValue
    public var receivedAt: Date

    public init(frame: JSONValue, receivedAt: Date) {
        self.frame = frame
        self.receivedAt = receivedAt
    }

    /// omp request id (`frame.id`).
    public var id: String? { frame["id"]?.stringValue }

    private enum CodingKeys: String, CodingKey { case frame, receivedAt }

    /// Also reads the bare frames of protocol-1 manifests; their arrival time was never recorded, so it becomes the
    /// decode time (a restored timed dialog then expires late, never early).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.frame), container.contains(.receivedAt) else {
            frame = try JSONValue(from: decoder)
            receivedAt = Date()
            return
        }
        frame = try container.decode(JSONValue.self, forKey: .frame)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    }
}

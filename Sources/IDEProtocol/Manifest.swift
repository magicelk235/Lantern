import Foundation

/// `$APP_SUPPORT/sessions.json`. Invariant: nothing here is invalid after a reboot
/// (no PIDs, socket paths or fds). Liveness is always re-derived at startup.
public struct SessionManifest: Sendable, Equatable, Codable {
    public var version: Int
    public var sessions: [SessionManifestEntry]
    /// What ompd does with agents a Regime-B death interrupted. Absent from older manifests.
    public var restorePolicy: RestorePolicy
    public init(version: Int = 2, sessions: [SessionManifestEntry] = [], restorePolicy: RestorePolicy = RestorePolicy()) {
        self.version = version
        self.sessions = sessions
        self.restorePolicy = restorePolicy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        sessions = try c.decode([SessionManifestEntry].self, forKey: .sessions)
        restorePolicy = try c.decodeIfPresent(RestorePolicy.self, forKey: .restorePolicy) ?? RestorePolicy()
    }
}

/// `restore.continue`: after omp died (Regime B) and was resumed, whether an agent it interrupted
/// mid-turn is told so and asked to continue.
public enum ContinuePolicy: String, Sendable, Codable, CaseIterable {
    /// Continued without asking.
    case auto
    /// Held until the user decides in omp IDE (`SessionManifestEntry.pendingContinuation`, `session.continue`).
    case ask
    /// Left as it is; the user carries on in the session TUI.
    case never
}

/// Daemon-wide continuation policy, one for the main agent and one for subagents.
public struct RestorePolicy: Sendable, Equatable, Codable {
    public var main: ContinuePolicy
    public var subagents: ContinuePolicy
    public init(main: ContinuePolicy = .ask, subagents: ContinuePolicy = .auto) {
        self.main = main
        self.subagents = subagents
    }
}

/// A tool call omp started and never recorded a result for, or reported pending when it exited (`session_exit`).
public struct InterruptedToolCall: Sendable, Equatable, Codable {
    public var toolCallId: String
    public var toolName: String
    /// One line: the call's intent, else its command or path argument (clipped).
    public var summary: String
    public init(toolCallId: String, toolName: String, summary: String) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.summary = summary
    }
}

/// A subagent that had not finished its assignment when its omp died (`<id>.jsonl` without a tombstone or an output).
public struct InterruptedAgent: Sendable, Equatable, Codable {
    /// Agent id: the transcript's file name without `.jsonl` (`Sleeper`, `Parent.Child`).
    public var id: String
    public var pendingToolCalls: [InterruptedToolCall]
    public init(id: String, pendingToolCalls: [InterruptedToolCall] = []) {
        self.id = id
        self.pendingToolCalls = pendingToolCalls
    }
}

/// What the omp of a session left unfinished when it died, read from its session file and artifacts.
public struct Interruption: Sendable, Equatable, Codable {
    public var detectedAt: Date
    /// How omp ended, for people: "omp exited (signal 9)", "ompd restarted".
    public var cause: String
    /// The main agent was mid-turn.
    public var mainInterrupted: Bool
    /// The main agent's tool calls that may not have completed.
    public var pendingToolCalls: [InterruptedToolCall]
    public var agents: [InterruptedAgent]
    /// The dead omp ran `eval`: its kernels' variables are gone.
    public var evalKernelsLost: Bool

    public init(
        detectedAt: Date, cause: String, mainInterrupted: Bool, pendingToolCalls: [InterruptedToolCall] = [],
        agents: [InterruptedAgent] = [], evalKernelsLost: Bool = false
    ) {
        self.detectedAt = detectedAt
        self.cause = cause
        self.mainInterrupted = mainInterrupted
        self.pendingToolCalls = pendingToolCalls
        self.agents = agents
        self.evalKernelsLost = evalKernelsLost
    }

    /// Nothing to continue.
    public var isEmpty: Bool { !mainInterrupted && agents.isEmpty }
}

/// One omp session owned by ompd. The session runs omp's own interactive TUI inside a daemon-owned PTY;
/// clients render it by attaching to `ptyId` (`pty.attach`), exactly like any other terminal. An `adopted` session's
/// omp was started by the user in one of the IDE's terminals instead; `ptyId` is then that terminal's PTY.
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
    /// omp runs in one of the IDE's terminals (`ptyId`), where the user started it, and ompd adopted it through the
    /// ide-bridge: the PTY is a plain terminal that ompd neither spawned nor closes with the session. Cleared once that
    /// omp exits (the session is then closed like any other, resumed in a session PTY of its own). Runtime-only like
    /// `ptyId`; absent from older manifests.
    public var adopted: Bool
    /// When the omp now (or last) serving the session started: the start of the run a death interrupts. Absent from
    /// older manifests.
    public var spawnedAt: Date?
    /// An interruption waiting for the user's decision (restore policy `ask`), answered with `session.continue`. Kept
    /// until answered, across daemon restarts (merged with what a later death leaves).
    public var pendingContinuation: Interruption?
    /// The version of the omp at `launch.ompPath` as ompd last read it: at each spawn, when an app connects, and when
    /// the file there changes; nil until then (and in older manifests). Newer than `launch.ompVersion` while omp runs:
    /// `session.restart` would upgrade it (`ompUpgrade`).
    public var installedOmpVersion: String?

    public init(
        sessionKey: SessionKey, workspace: String, sessionFile: String? = nil, sessionId: String? = nil,
        title: String? = nil, launch: LaunchSpec, status: SessionStatus = .starting, ptyId: PTYID? = nil,
        createdAt: Date, lastActiveAt: Date? = nil, services: [NamedService] = [], closedByUser: Bool = false,
        adopted: Bool = false, spawnedAt: Date? = nil, pendingContinuation: Interruption? = nil,
        installedOmpVersion: String? = nil
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
        self.adopted = adopted
        self.spawnedAt = spawnedAt
        self.pendingContinuation = pendingContinuation
        self.installedOmpVersion = installedOmpVersion
    }

    /// Manifests written before `adopted`, `spawnedAt`, `pendingContinuation` or `installedOmpVersion` existed decode
    /// without them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(SessionKey.self, forKey: .sessionKey)
        workspace = try container.decode(String.self, forKey: .workspace)
        sessionFile = try container.decodeIfPresent(String.self, forKey: .sessionFile)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        launch = try container.decode(LaunchSpec.self, forKey: .launch)
        status = try container.decode(SessionStatus.self, forKey: .status)
        ptyId = try container.decodeIfPresent(PTYID.self, forKey: .ptyId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        services = try container.decode([NamedService].self, forKey: .services)
        closedByUser = try container.decode(Bool.self, forKey: .closedByUser)
        adopted = try container.decodeIfPresent(Bool.self, forKey: .adopted) ?? false
        spawnedAt = try container.decodeIfPresent(Date.self, forKey: .spawnedAt)
        pendingContinuation = try container.decodeIfPresent(Interruption.self, forKey: .pendingContinuation)
        installedOmpVersion = try container.decodeIfPresent(String.self, forKey: .installedOmpVersion)
    }
}

/// Everything needed to (re)spawn the same omp TUI for a session. The binary is pinned by absolute path; `ompVersion` is
/// what it reported (`--version`) at the session's latest spawn. A path a package manager re-points on upgrade
/// (Homebrew's `bin/omp` link) runs the newer omp at the next spawn only — a death's respawn or `session.restart`; a
/// pinned path that is gone is replaced at the next spawn by the omp a new session would get.
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

import Foundation

// Agent supervision: what each session's omp runs — its agent tree, its async jobs, what waits for
// the user (approvals, `ask`) — pushed by ompd from the ide-bridge, and the controls over agents and named services.

/// An agent's state as omp's `AgentRegistry` reports it. The main agent's row follows the session instead (omp reports
/// it `running` for its whole life): `running` while busy, `paused` while omp's pause gate holds it, else `idle`.
public enum AgentStatus: String, Sendable, Codable, CaseIterable {
    case running, idle, parked, aborted, interrupted, paused, unknown

    /// Any status omp adds later decodes as `unknown`.
    public init(from decoder: any Decoder) throws {
        self = AgentStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// One agent of a session's omp: the main agent, a subagent at any depth, a workpool or eval `agent()` child.
public struct AgentInfo: Sendable, Equatable, Codable, Identifiable {
    /// omp's agent id (`Main`, `0-Explore`, `0-Explore.1-Check`); what `agent://<id>` names.
    public var id: String
    public var displayName: String?
    /// omp's agent kind (`main`, `task`, …), as reported.
    public var kind: String?
    /// nil for the main agent.
    public var parentId: String?
    public var status: AgentStatus
    /// A model reply is streaming right now.
    public var isStreaming: Bool
    /// The agent's transcript (`<AgentId>.jsonl` beside the session file); nil when omp did not say.
    public var sessionFile: String?
    public var createdAt: Date?
    public var lastActivity: Date?
    /// One line on what it is doing, from omp's registry row; nil when omp reports nothing readable.
    public var activity: String?

    public init(
        id: String, displayName: String? = nil, kind: String? = nil, parentId: String? = nil, status: AgentStatus,
        isStreaming: Bool = false, sessionFile: String? = nil, createdAt: Date? = nil, lastActivity: Date? = nil,
        activity: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.parentId = parentId
        self.status = status
        self.isStreaming = isStreaming
        self.sessionFile = sessionFile
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.activity = activity
    }
}

/// An async job of the session's main omp session (`getAsyncJobSnapshot`: running ones, then the recently finished;
/// omp evicts delivered jobs after 30 s, so finished ones fall off).
public struct JobInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// `bash` | `eval` | `task` | … as omp reports it.
    public var type: String
    /// `running` | `completed` | `failed` | `cancelled` | … as omp reports it.
    public var status: String
    public var label: String
    public var startedAt: Date?
    public var endedAt: Date?
    /// The agent the job runs for (a `task` job's subagent).
    public var agentId: String?

    public init(
        id: String, type: String, status: String, label: String, startedAt: Date? = nil, endedAt: Date? = nil,
        agentId: String? = nil
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.label = label
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.agentId = agentId
    }

    public var isRunning: Bool { status == "running" }
}

/// Something in the session's TUI waits for the user: a tool approval prompt or an `ask`. Answered in the TUI.
public struct AttentionItem: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case approval, ask
    }

    /// The tool call's id.
    public var id: String
    public var kind: Kind
    public var toolName: String
    /// The agent whose call it is.
    public var agentId: String?
    public var since: Date

    public init(id: String, kind: Kind, toolName: String, agentId: String? = nil, since: Date) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.agentId = agentId
        self.since = since
    }
}

/// What a session's omp runs right now. Runtime only (never in the manifest): empty while omp does not run, or before
/// its bridge said hello.
public struct SessionRuntime: Sendable, Equatable, Codable, Identifiable {
    public var id: SessionKey { sessionKey }
    public var sessionKey: SessionKey
    /// Every agent, parents before children; empty when the bridge cannot list them.
    public var agents: [AgentInfo]
    /// Running jobs first, then recently finished ones.
    public var jobs: [JobInfo]
    /// Oldest first.
    public var attention: [AttentionItem]

    public init(sessionKey: SessionKey, agents: [AgentInfo] = [], jobs: [JobInfo] = [], attention: [AttentionItem] = []) {
        self.sessionKey = sessionKey
        self.agents = agents
        self.jobs = jobs
        self.attention = attention
    }
}

/// Every session's runtime (`ServerFrame.runtime` pushes one session's at a time after this).
public enum SessionRuntimeList: DaemonMethod {
    public static let name = "session.runtime"
    public typealias Params = Empty
    public struct Result: Codable, Sendable, Equatable {
        public var sessions: [SessionRuntime]
        public init(sessions: [SessionRuntime]) { self.sessions = sessions }
    }
}

/// An agent of a running session: revive a parked one (it comes back idle), park an idle one, or kill one (its turn
/// is aborted and it is released for good). The main agent can only be revived (a no-op). Result: the agent's row
/// afterwards, nil once omp no longer lists it. `noSuchSession` for an unknown session, `bridgeUnavailable` while omp
/// does not run or its bridge lacks the capability, `ompError` when omp refuses.
public enum AgentControl: DaemonMethod {
    public static let name = "agent.control"
    public enum Action: String, Codable, Sendable { case revive, park, kill }
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public var agentId: String
        public var action: Action
        public init(sessionKey: SessionKey, agentId: String, action: Action) {
            self.sessionKey = sessionKey
            self.agentId = agentId
            self.action = action
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var agent: AgentInfo?
        public init(agent: AgentInfo?) { self.agent = agent }
    }
}

/// `write agent://<agentId>` from the main agent: revives a parked agent, which answers the main agent as for any
/// message. Errors as `AgentControl`.
public enum AgentMessage: DaemonMethod {
    public static let name = "agent.message"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        public var agentId: String
        public var body: String
        public init(sessionKey: SessionKey, agentId: String, body: String) {
            self.sessionKey = sessionKey
            self.agentId = agentId
            self.body = body
        }
    }
    public typealias Result = Empty
}

/// A named service of a workspace (omp's launch broker scope = the workspace), merged from the broker (`omp ps --json
/// --dir`) and what ompd recorded for the workspace's sessions (`SessionManifestEntry.services`).
public struct ServiceInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Broker state (`starting|running|ready|restarting|stopping|exited|failed`), `unsupervised` (a record no broker
    /// supervises) or `unknown` (the broker has no record: pruned, or never started).
    public var state: String
    /// `persist` | `session` | `detached`; nil when neither the broker nor ompd knows.
    public var mode: String?
    public var command: String?
    public var pid: Int32?
    public var startedAt: Date?
    /// The session that recorded it, when one did.
    public var sessionKey: SessionKey?
    /// ompd relaunches it after a death of omp or ompd (`NamedService.desiredRunning`); false when ompd has no record.
    public var desiredRunning: Bool

    public init(
        name: String, state: String, mode: String? = nil, command: String? = nil, pid: Int32? = nil,
        startedAt: Date? = nil, sessionKey: SessionKey? = nil, desiredRunning: Bool = false
    ) {
        self.name = name
        self.state = state
        self.mode = mode
        self.command = command
        self.pid = pid
        self.startedAt = startedAt
        self.sessionKey = sessionKey
        self.desiredRunning = desiredRunning
    }

    public var isLive: Bool { ["starting", "running", "ready", "restarting"].contains(state) }
}

public enum ServiceList: DaemonMethod {
    public static let name = "services.list"
    public struct Params: Codable, Sendable, Equatable {
        public var workspace: String
        public init(workspace: String) { self.workspace = workspace }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var services: [ServiceInfo]
        public init(services: [ServiceInfo]) { self.services = services }
    }
}

/// Stop (graceful, `omp ps stop`), kill (`omp ps kill`), restart (`omp ps restart`, from the broker's record) a named
/// service of a workspace, or change its mode (`mode` required: what `write proc://<name>/mode` does, through a running
/// session of the workspace; `bridgeUnavailable` when none runs). Stop and kill clear `desiredRunning`, restart sets
/// it. Result: the service afterwards.
public enum ServiceControlRequest: DaemonMethod {
    public static let name = "service.control"
    public enum Action: String, Codable, Sendable { case stop, kill, restart, setMode }
    public struct Params: Codable, Sendable, Equatable {
        public var workspace: String
        public var name: String
        public var action: Action
        public var mode: String?
        public init(workspace: String, name: String, action: Action, mode: String? = nil) {
            self.workspace = workspace
            self.name = name
            self.action = action
            self.mode = mode
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var service: ServiceInfo
        public init(service: ServiceInfo) { self.service = service }
    }
}

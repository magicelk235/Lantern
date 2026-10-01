import Foundation
import IDEProtocol

/// What a session's omp runs, folded from its ide-bridge: the agent tree seeded from `agents.snapshot` after
/// the hello and kept current by `registry:*` pushes (each carries an agent's whole row, so pushes buffered while the
/// snapshot was taken bring it forward), the main session's async jobs from `jobs` pushes, and what waits for the user
/// from the hello's `attention` and `attention` pushes. Rows keep the status omp reports; `runtime` applies the
/// session's view on top.
struct RuntimeTracker: Sendable {
    /// omp's `MAIN_AGENT_ID`: the main agent's id in the registry and in `agent://`.
    static let mainAgentID = "Main"

    /// Registry rows by agent id.
    private(set) var agents: [String: AgentInfo] = [:]
    /// Running jobs first, then recently finished ones.
    private(set) var jobs: [JobInfo] = []
    /// What waits for the user, oldest first as the bridge lists it (the hello's `attention`, then each `attention`
    /// push's `items`, replacing the whole list).
    var attention: [AttentionItem] = []

    /// The registry as `agents.snapshot` listed it.
    mutating func seed(agents rows: [JSONValue]) {
        agents = Dictionary(rows.compactMap(Self.agent).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// A `registry:<change>` push: `registered`, `status_changed` and `metadata_changed` put the row in place, `removed`
    /// drops it. Other changes, and rows without id or status, change nothing.
    mutating func apply(registry change: String, row: JSONValue?) {
        guard let agent = row.flatMap(Self.agent) else { return }
        switch change {
        case "registered", "status_changed", "metadata_changed": agents[agent.id] = agent
        case "removed": agents[agent.id] = nil
        default: break
        }
    }

    /// A `jobs` push (`{running, recent}`), or the `snapshot` of `jobs.snapshot`: replaces every job.
    mutating func replaceJobs(_ snapshot: JSONValue?) {
        let running = snapshot?["running"]?.arrayValue ?? []
        let recent = snapshot?["recent"]?.arrayValue ?? []
        jobs = (running + recent).compactMap(Self.job)
    }

    /// The runtime clients see: the main agent's row follows the session (`mainStatus`), and a parked subagent of the
    /// interruption waiting for the user's decision (`held`) reads `interrupted`. Agents in tree order: parents before
    /// their children, the main agent first, siblings by creation.
    func runtime(sessionKey: SessionKey, mainStatus: AgentStatus, held: Set<String>) -> SessionRuntime {
        let rows = agents.values.map { view(of: $0, mainStatus: mainStatus, held: held) }
        return SessionRuntime(sessionKey: sessionKey, agents: Self.treeOrder(rows), jobs: jobs, attention: attention)
    }

    /// `row` (a registry row from a bridge reply) as `runtime` shows it; nil when it is not one.
    func agent(fromRow row: JSONValue?, mainStatus: AgentStatus, held: Set<String>) -> AgentInfo? {
        row.flatMap(Self.agent).map { view(of: $0, mainStatus: mainStatus, held: held) }
    }

    private func view(of agent: AgentInfo, mainStatus: AgentStatus, held: Set<String>) -> AgentInfo {
        var agent = agent
        if agent.id == Self.mainAgentID {
            agent.status = mainStatus
        } else if agent.status == .parked, held.contains(agent.id) {
            agent.status = .interrupted
        }
        return agent
    }

    /// The main agent's status from the session's: `running` while busy, `paused` while omp's pause gate holds it, else
    /// `idle` (omp reports the main agent `running` for its whole life).
    static func mainStatus(_ status: SessionStatus) -> AgentStatus {
        switch status {
        case .busy: .running
        case .paused: .paused
        default: .idle
        }
    }

    /// Depth-first: every parent before its children. Rows whose parent is not listed are roots.
    static func treeOrder(_ agents: [AgentInfo]) -> [AgentInfo] {
        let ids = Set(agents.map(\.id))
        let ordered = agents.sorted { a, b in
            if (a.id == mainAgentID) != (b.id == mainAgentID) { return a.id == mainAgentID }
            if a.createdAt != b.createdAt { return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast) }
            return a.id < b.id
        }
        var children: [String: [AgentInfo]] = [:]
        var roots: [AgentInfo] = []
        for agent in ordered {
            if let parent = agent.parentId, parent != agent.id, ids.contains(parent) {
                children[parent, default: []].append(agent)
            } else {
                roots.append(agent)
            }
        }
        var result: [AgentInfo] = []
        var visited: Set<String> = []
        func visit(_ agent: AgentInfo) {
            guard visited.insert(agent.id).inserted else { return }
            result.append(agent)
            for child in children[agent.id] ?? [] { visit(child) }
        }
        for root in roots { visit(root) }
        // A parent cycle has no root; its rows still appear, after everything else.
        for agent in ordered { visit(agent) }
        return result
    }

    // MARK: - Bridge JSON

    /// An ide-bridge registry row (`refJson`: id, displayName, kind, parentId, status, isStreaming, sessionFile, createdAt
    /// and lastActivity in ms since the epoch, omp's activity, the bridge's currentTool); nil without id or status.
    static func agent(_ row: JSONValue) -> AgentInfo? {
        guard let id = row["id"]?.stringValue, let status = row["status"]?.stringValue else { return nil }
        return AgentInfo(
            id: id, displayName: row["displayName"]?.stringValue, kind: row["kind"]?.stringValue,
            parentId: row["parentId"]?.stringValue, status: AgentStatus(rawValue: status) ?? .unknown,
            isStreaming: row["isStreaming"]?.boolValue == true, sessionFile: row["sessionFile"]?.stringValue,
            createdAt: date(row["createdAt"]), lastActivity: date(row["lastActivity"]),
            activity: activity(omp: row["activity"], currentTool: row["currentTool"]))
    }

    /// A job of `getAsyncJobSnapshot` (id, type, status, label, startTime and endTime in ms since the epoch, agentId).
    static func job(_ value: JSONValue) -> JobInfo? {
        guard let id = value["id"]?.stringValue, let type = value["type"]?.stringValue, let status = value["status"]?.stringValue
        else { return nil }
        return JobInfo(
            id: id, type: type, status: status, label: value["label"]?.stringValue ?? "", startedAt: date(value["startTime"]),
            endedAt: date(value["endTime"]), agentId: value["agentId"]?.stringValue)
    }

    /// The bridge's attention items (`{id, kind, toolName, agentId, since}`); malformed ones and unknown kinds are left
    /// out.
    static func attention(_ items: JSONValue?) -> [AttentionItem] {
        (items?.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue, let kind = item["kind"]?.stringValue.flatMap(AttentionItem.Kind.init),
                  let toolName = item["toolName"]?.stringValue, let since = date(item["since"])
            else { return nil }
            return AttentionItem(id: id, kind: kind, toolName: toolName, agentId: item["agentId"]?.stringValue, since: since)
        }
    }

    private static func date(_ milliseconds: JSONValue?) -> Date? {
        milliseconds?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// What the agent is doing, one line. omp's `activity` first: a subagent's last tool-call intent as the model wrote it
    /// ("Wait for the build"), set only while the agent runs. Otherwise the tool call the bridge saw the agent start and
    /// not finish yet (`currentTool {name, detail}`) as `<tool>: <detail>` ("bash: sleep 25"), which also replaces omp's
    /// bare `running <tool>` (what omp reports when the calls had no intent). Nil when neither says anything.
    private static func activity(omp value: JSONValue?, currentTool: JSONValue?) -> String? {
        let tool = line(currentTool?["name"]).map { name in line(currentTool?["detail"]).map { "\(name): \($0)" } ?? name }
        guard let reported = line(value) else { return tool }
        let running = reported.hasPrefix("running ") ? reported.dropFirst("running ".count) : nil
        guard let running, !running.contains(" ") else { return reported }
        return tool ?? String(running)
    }

    /// A string on one line, whitespace runs collapsed; nil when it is not a string or blank.
    private static func line(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }
}

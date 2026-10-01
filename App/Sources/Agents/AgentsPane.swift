import AppKit
import IDEModel
import SwiftUI

/// The Agents pane: what omp runs in the project's running sessions. Each session's agents under the
/// session's title as a tree (the main agent first, every subagent under the agent that started it), then the
/// background jobs (running ones with how long they have run, then those that just finished, dimmed), then the
/// project's named services. A click on an agent or a job shows its session's tab. Agents take a message and are
/// revived, parked or killed; services are stopped, killed, restarted or switched to another mode, and their logs
/// follow in a terminal tab. The services load when the pane shows, after each action, and when what the sessions run
/// changes.
struct AgentsPane: View {
    let app: AppState
    let project: String
    @State private var services = ProjectServices()
    /// The agent Message… writes to.
    @State private var messageTarget: AgentTarget?

    /// How long a burst of changes in the sessions settles before the services load again.
    private static let settle: Duration = .milliseconds(500)

    var body: some View {
        let sessions = app.runningSessions(in: project)
        // Out of touch with ompd, what was listed may no longer be so.
        let listed = app.connection.isConnected ? services.services : []
        VStack(spacing: 0) {
            if let failure = services.failure {
                NoticeBar(systemImage: "exclamationmark.triangle", tint: .red, title: "Could not list the named services", message: failure) {
                    Button("Dismiss") { services.failure = nil }
                }
                .help(failure)
            }
            if sessions.isEmpty && listed.isEmpty {
                ContentUnavailableView {
                    Text("No Running Sessions")
                } description: {
                    Text("Agents, jobs and named services show here while omp runs in this project.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(sessions, services: listed)
            }
        }
        .task(id: project) { services.load(project, from: app.connection) }
        .onChange(of: ServicesTrigger(sessions: sessions)) {
            services.load(project, from: app.connection, after: Self.settle)
        }
        .onChange(of: app.connection.isConnected) { _, connected in
            if connected { services.load(project, from: app.connection) }
        }
        .sheet(item: $messageTarget) { target in
            MessageSheet(app: app, target: target)
        }
    }

    private func list(_ sessions: [RunningSession], services listed: [ServiceInfo]) -> some View {
        let jobs = Self.jobs(of: sessions)
        let connected = app.connection.isConnected
        return List {
            ForEach(sessions) { session in
                Section {
                    let outline = AgentOutline(session.runtime, session: session.entry.status)
                    ForEach(outline.rows) { row in
                        AgentRow(
                            agent: row.agent, depth: row.depth, isMain: row.isMain, waiting: outline.waiting[row.agent.id],
                            connected: connected, show: { app.showSession(session.id) }
                        ) { action in
                            perform(action, on: row.agent, in: session.id)
                        }
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(app.sessionTitle(session.id))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !jobs.isEmpty {
                Section("Jobs") {
                    ForEach(jobs) { job in
                        JobRow(job: job.job, session: app.sessionTitle(job.sessionKey)) { app.showSession(job.sessionKey) }
                            .listRowSeparator(.hidden)
                    }
                }
            }
            if !listed.isEmpty {
                Section("Services") {
                    ForEach(listed, id: \.serviceRowID) { service in
                        ServiceRow(
                            service: service, isBusy: services.busy.contains(service.name), connected: connected,
                            canSetMode: !sessions.isEmpty
                        ) { action in
                            perform(action, on: service)
                        }
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
    }

    /// Every session's jobs: the running ones first, then those that finished.
    private static func jobs(of sessions: [RunningSession]) -> [SessionJob] {
        let all = sessions.flatMap { session in session.runtime.jobs.map { SessionJob(sessionKey: session.id, job: $0) } }
        return all.filter(\.job.isRunning) + all.filter { !$0.job.isRunning }
    }

    private func perform(_ action: AgentAction, on agent: AgentInfo, in sessionKey: SessionKey) {
        switch action {
        case .message:
            messageTarget = AgentTarget(sessionKey: sessionKey, agent: agent)
        case .revive, .park:
            control(action == .revive ? .revive : .park, agent, in: sessionKey)
        case .kill:
            Task {
                let confirmed = await confirm(
                    "Kill “\(agent.id)”?",
                    "Its turn is aborted and omp lets it go for good: it cannot be revived or messaged afterwards.",
                    button: "Kill")
                if confirmed { control(.kill, agent, in: sessionKey) }
            }
        case .openTranscript:
            if let transcript = agent.sessionFile { app.showTranscript(transcript, of: sessionKey, in: project) }
        }
    }

    /// Revives, parks or kills the agent; the runtime push that follows shows the outcome.
    private func control(_ action: AgentControl.Action, _ agent: AgentInfo, in sessionKey: SessionKey) {
        Task {
            do {
                try await app.connection.control(agent: agent.id, of: sessionKey, action)
            } catch {
                app.alert = AppState.AlertMessage(title: "Could not \(action.rawValue) “\(agent.id)”", message: error.userMessage)
            }
        }
    }

    private func perform(_ action: ServiceAction, on service: ServiceInfo) {
        switch action {
        case .stop: services.control(.stop, service, in: project, app: app)
        case .restart: services.control(.restart, service, in: project, app: app)
        case .mode(let mode): services.control(.setMode, service, mode: mode, in: project, app: app)
        case .showLogs: app.showLogs(of: service, in: project)
        case .kill:
            Task {
                let confirmed = await confirm(
                    "Kill “\(service.name)”?",
                    "omp's broker ends it at once, without a graceful stop, and ompd does not start it again.",
                    button: "Kill")
                if confirmed { services.control(.kill, service, in: project, app: app) }
            }
        }
    }

    /// Asks first, in a sheet on the project's window (the app may be in the background): what `button` does cannot
    /// be undone.
    private func confirm(_ title: String, _ message: String, button: String) async -> Bool {
        let confirmation = NSAlert()
        confirmation.messageText = title
        confirmation.informativeText = message
        confirmation.addButton(withTitle: button)
        confirmation.buttons[0].hasDestructiveAction = true
        confirmation.addButton(withTitle: "Cancel")
        let response = if let window = app.window(of: project) ?? NSApp.keyWindow ?? NSApp.mainWindow {
            await confirmation.beginSheetModal(for: window)
        } else {
            confirmation.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}

/// A session of the project whose omp runs, with what it runs.
struct RunningSession: Identifiable {
    let entry: SessionManifestEntry
    let runtime: SessionRuntime
    var id: SessionKey { entry.sessionKey }
}

extension AppState {
    /// The project's sessions ompd reports a runtime for (their omp runs), oldest first.
    func runningSessions(in project: String) -> [RunningSession] {
        connection.sessions
            .filter { $0.workspace == project }
            .compactMap { entry in connection.runtimes[entry.sessionKey].map { RunningSession(entry: entry, runtime: $0) } }
            .sorted { ($0.entry.createdAt, $0.id) < ($1.entry.createdAt, $1.id) }
    }

    /// Tool approvals and `ask`s waiting in the project's session TUIs: the Agents pane's badge.
    func attentionCount(in project: String) -> Int {
        runningSessions(in: project).reduce(0) { $0 + $1.runtime.attention.count }
    }
}

/// What a named service can come and go with: which sessions run, the states of their agents and jobs (not the
/// activity lines and streaming flags, which change all the time), and the services ompd recorded for them.
private struct ServicesTrigger: Equatable {
    var sessions: [SessionKey] = []
    var agents: [String: AgentStatus] = [:]
    var jobs: [String: String] = [:]
    var recorded: [NamedService] = []

    init(sessions: [RunningSession]) {
        for session in sessions {
            self.sessions.append(session.id)
            for agent in session.runtime.agents { agents["\(session.id)/\(agent.id)"] = agent.status }
            for job in session.runtime.jobs { jobs["\(session.id)/\(job.id)"] = job.status }
            recorded += session.entry.services
        }
    }
}

/// A session's agents as rows: the main agent first, each agent's subagents right under it, deeper by one, in the
/// order omp lists them. What waits for the user is marked on the agent whose call it is (the main agent's row when
/// omp did not say or lists no such agent).
private struct AgentOutline {
    struct Row: Identifiable {
        let sessionKey: SessionKey
        let agent: AgentInfo
        let depth: Int
        let isMain: Bool
        /// Unique across the pane's sections: every session has an agent `Main`, a task job has its agent's id, and one
        /// list holds them all.
        var id: String { "agent/\(sessionKey)/\(agent.id)" }
    }

    private(set) var rows: [Row] = []
    /// The first approval or `ask` each agent waits on, by agent id.
    private(set) var waiting: [String: AttentionItem] = [:]

    /// `session`: what the session's main agent does, for a bridge that lists no agents.
    init(_ runtime: SessionRuntime, session: SessionStatus) {
        // A bridge that cannot list agents still has a main agent, the one approvals and jobs belong to; its row
        // follows the session.
        let agents =
            runtime.agents.isEmpty ? [AgentInfo(id: "Main", kind: "main", status: Self.mainStatus(session))] : runtime.agents
        let ids = Set(agents.map(\.id))
        var children: [String: [AgentInfo]] = [:]
        var roots: [AgentInfo] = []
        for agent in agents {
            if let parent = agent.parentId, parent != agent.id, ids.contains(parent) {
                children[parent, default: []].append(agent)
            } else {
                roots.append(agent)
            }
        }
        let main = roots.first { $0.kind == "main" || $0.id == "Main" }
        if let main, let index = roots.firstIndex(where: { $0.id == main.id }) {
            roots.insert(roots.remove(at: index), at: 0)
        }
        var rows: [Row] = []
        var visited = Set<String>()
        func visit(_ agent: AgentInfo, depth: Int) {
            guard visited.insert(agent.id).inserted else { return }
            rows.append(Row(sessionKey: runtime.sessionKey, agent: agent, depth: depth, isMain: agent.id == main?.id))
            for child in children[agent.id] ?? [] { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        // Agents whose parents name each other in a circle are listed at the top level.
        for agent in agents { visit(agent, depth: 0) }
        self.rows = rows
        for item in runtime.attention {
            let agentId = item.agentId.flatMap { visited.contains($0) ? $0 : nil } ?? main?.id ?? rows.first?.agent.id
            if let agentId, waiting[agentId] == nil { waiting[agentId] = item }
        }
    }

    private static func mainStatus(_ session: SessionStatus) -> AgentStatus {
        switch session {
        case .busy, .starting, .resuming: .running
        case .idle: .idle
        case .paused: .paused
        case .interrupted: .interrupted
        case .closed, .needsAttention: .unknown
        }
    }
}

/// The agent Message… writes to.
struct AgentTarget: Identifiable {
    let sessionKey: SessionKey
    let agent: AgentInfo
    var id: String { "\(sessionKey)/\(agent.id)" }
}

/// A job with the session that runs it.
private struct SessionJob: Identifiable {
    let sessionKey: SessionKey
    let job: JobInfo
    var id: String { "job/\(sessionKey)/\(job.id)" }
}

extension ServiceInfo {
    /// The service's row in the pane's one list, apart from the agent and job rows.
    fileprivate var serviceRowID: String { "service/\(name)" }
}

extension AgentInfo {
    /// The agent's own name: the last part of its id (`0-Explore.1-Check` → `1-Check`), the tree showing whose it is.
    /// omp's `displayName` names a live agent's type (`main`, `task`), which does not tell agents apart.
    var name: String { id.split(separator: ".").last.map(String.init) ?? id }

    /// omp's name for the agent's type, when it says more than the id.
    var typeName: String? { displayName.flatMap { $0.isEmpty || $0 == id ? nil : $0 } }
}

extension AgentStatus {
    /// One sentence for tooltips.
    var explanation: String {
        switch self {
        case .running: "Working"
        case .idle: "Idle: waiting for a message"
        case .parked: "Parked: out of memory until it is revived or messaged"
        case .aborted: "Aborted: its turn was stopped"
        case .interrupted: "Interrupted: omp stopped while it worked"
        case .paused: "Paused: it holds at its next step until omp's pause screen is dismissed"
        case .unknown: "omp reports no state omp IDE knows"
        }
    }
}

private enum AgentAction: Hashable {
    case message, revive, park, kill, openTranscript

    var title: String {
        switch self {
        case .message: "Message…"
        case .revive: "Revive"
        case .park: "Park"
        case .kill: "Kill…"
        case .openTranscript: "Open Transcript"
        }
    }

    var symbol: String {
        switch self {
        case .message: "paperplane"
        case .revive: "arrow.clockwise"
        case .park: "moon.zzz"
        case .kill: "xmark"
        case .openTranscript: "doc.text"
        }
    }
}

/// One agent: its state, its name, what it is doing or waits on the user for, whether a reply streams; Revive or
/// Park and Message on hover, everything it allows in the context menu.
private struct AgentRow: View {
    let agent: AgentInfo
    let depth: Int
    let isMain: Bool
    /// The approval or `ask` it waits on.
    let waiting: AttentionItem?
    let connected: Bool
    let show: () -> Void
    let perform: (AgentAction) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: show) {
                HStack(spacing: 6) {
                    AgentStatusMark(status: agent.status, needsUser: waiting != nil)
                        .frame(width: 12)
                    Text(agent.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(waiting != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if agent.isStreaming, waiting == nil {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Streaming a reply")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(quickActions, id: \.self) { action in
                Button { perform(action) } label: {
                    Image(systemName: action.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .disabled(!connected)
                .help(action.title)
                .accessibilityLabel("\(action.title) \(agent.name)")
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .onHover { hovering = $0 }
        .help("\(agent.id)\(agent.typeName.map { " (\($0))" } ?? ""): \(waiting.map(Self.waitingLine) ?? agent.status.explanation)")
        .contextMenu {
            ForEach(Array(menuGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { action in
                    Button(action.title) { perform(action) }
                        .disabled(!connected)
                }
            }
        }
    }

    /// What it waits on the user for, else what it is doing while it works (omp keeps the last intent, or a resumed
    /// agent's assignment, on agents that stopped: not what they do).
    private var detail: String? {
        if let waiting { return Self.waitingLine(waiting) }
        guard agent.status == .running, let activity = agent.activity, !activity.isEmpty else { return nil }
        return activity
    }

    private static func waitingLine(_ item: AttentionItem) -> String {
        switch item.kind {
        case .approval: "Waiting for approval: \(item.toolName)"
        case .ask: "Asking you"
        }
    }

    private var canRevive: Bool { !isMain && (agent.status == .parked || agent.status == .interrupted) }
    private var canPark: Bool { !isMain && agent.status == .idle }
    /// A killed agent is gone for good: nothing reaches it any more.
    private var canMessage: Bool { !isMain && agent.status != .aborted }

    /// On hover: Revive or Park, then Message; the main agent is talked to in its TUI.
    private var quickActions: [AgentAction] {
        (canRevive ? [.revive] : canPark ? [.park] : []) + (canMessage ? [.message] : [])
    }

    /// The context menu as the agent allows: talking to it, then its transcript, then Kill.
    private var menuGroups: [[AgentAction]] {
        let groups: [[AgentAction]] = [
            (canMessage ? [.message] : []) + (canRevive ? [.revive] : []) + (canPark ? [.park] : []),
            agent.sessionFile != nil ? [.openTranscript] : [],
            isMain || agent.status == .aborted ? [] : [.kill],
        ]
        return groups.filter { !$0.isEmpty }
    }
}

/// An agent's state as a dot: red while it waits on the user, a spinner while it works, green idle,
/// yellow paused, orange interrupted, grey parked, hollow once it ended.
private struct AgentStatusMark: View {
    let status: AgentStatus
    let needsUser: Bool

    var body: some View {
        if needsUser {
            StatusDot(color: .red)
        } else {
            switch status {
            case .running: ProgressView().controlSize(.mini)
            case .idle: StatusDot(color: .green)
            case .paused: StatusDot(color: .yellow)
            case .interrupted: StatusDot(color: .orange)
            case .parked: StatusDot(color: .secondary)
            case .aborted, .unknown: StatusDot(color: .secondary, hollow: true)
            }
        }
    }
}

/// One background job: its kind, its label, and trailing how long it has run, or how it ended (the row dimmed).
private struct JobRow: View {
    let job: JobInfo
    /// Its session's title, for the tooltip.
    let session: String
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(job.label.isEmpty ? job.id : job.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Group {
                    if job.isRunning {
                        if let startedAt = job.startedAt { Text(startedAt, style: .timer) }
                    } else {
                        Text(ending)
                            .foregroundStyle(job.status == "failed" ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(job.isRunning ? 1 : 0.5)
        .help("\(job.type) job of \(session)" + (job.agentId.map { " for \($0)" } ?? ""))
    }

    private var symbol: String {
        switch job.type {
        case "bash": "terminal"
        case "eval": "chevron.left.forwardslash.chevron.right"
        case "task": "person"
        default: "gearshape"
        }
    }

    private var ending: String {
        switch job.status {
        case "completed": "Completed"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        default: job.status.capitalized
        }
    }
}

private enum ServiceAction: Hashable {
    case stop, kill, restart, showLogs
    case mode(String)

    var title: String {
        switch self {
        case .stop: "Stop"
        case .kill: "Kill…"
        case .restart: "Restart"
        case .showLogs: "Show Logs"
        case .mode(let mode): mode.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .stop: "stop"
        case .kill: "xmark"
        case .restart: "arrow.clockwise"
        case .showLogs: "text.alignleft"
        case .mode: "switch.2"
        }
    }

    /// omp's service modes (`write proc://<name>/mode`).
    static let modes = ["persist", "session", "detached"]
}

/// One named service: its state, its name, trailing its state word and mode; Show Logs and Stop or Restart on hover,
/// everything else in the context menu.
private struct ServiceRow: View {
    let service: ServiceInfo
    /// An action on it is under way.
    let isBusy: Bool
    let connected: Bool
    /// A session of the project runs: the mode can change only through one.
    let canSetMode: Bool
    let perform: (ServiceAction) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isBusy || ["starting", "restarting", "stopping"].contains(service.state) {
                    ProgressView().controlSize(.mini)
                } else {
                    switch service.state {
                    case "running", "ready": StatusDot(color: .green)
                    case "failed": StatusDot(color: .red)
                    case "unsupervised": StatusDot(color: .orange)
                    default: StatusDot(color: .secondary, hollow: true)
                    }
                }
            }
            .frame(width: 12)
            Text(service.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ForEach(quickActions, id: \.self) { action in
                Button { perform(action) } label: {
                    Image(systemName: action.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .disabled(!connected || (isBusy && action != .showLogs))
                .help(action.title)
                .accessibilityLabel("\(action.title) \(service.name)")
            }
            Text([stateWord, service.mode].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(service.command ?? service.name)
        .contextMenu {
            Button(ServiceAction.showLogs.title) { perform(.showLogs) }
                .disabled(!connected)
            Divider()
            Button(ServiceAction.restart.title) { perform(.restart) }
                .disabled(!canRun || service.state == "unknown")
            Button(ServiceAction.stop.title) { perform(.stop) }
                .disabled(!canRun || !isRunning)
            Menu("Mode") {
                ForEach(ServiceAction.modes, id: \.self) { mode in
                    Toggle(ServiceAction.mode(mode).title, isOn: Binding(
                        get: { service.mode == mode }, set: { if $0, service.mode != mode { perform(.mode(mode)) } }))
                }
            }
            .disabled(!canRun || !canSetMode)
            Divider()
            Button(ServiceAction.kill.title) { perform(.kill) }
                .disabled(!canRun || !isRunning)
        }
        .accessibilityLabel("\(service.name), \(stateWord)")
    }

    /// ompd is there and nothing else runs on the service.
    private var canRun: Bool { connected && !isBusy }

    /// A process of it may run: something to stop or kill.
    private var isRunning: Bool { service.isLive || service.state == "stopping" || service.state == "unsupervised" }

    /// On hover: Show Logs, then Stop while it runs or Restart once it does not.
    private var quickActions: [ServiceAction] {
        [.showLogs] + (isRunning ? [.stop] : service.state == "unknown" ? [] : [.restart])
    }

    private var stateWord: String {
        switch service.state {
        case "starting": "Starting"
        case "running": "Running"
        case "ready": "Ready"
        case "restarting": "Restarting"
        case "stopping": "Stopping"
        case "exited": "Exited"
        case "failed": "Failed"
        case "unsupervised": "Unsupervised"
        case "unknown": "Unknown"
        default: service.state.capitalized
        }
    }
}

/// Message…: a note to a subagent, written to it by the main agent (`write agent://<id>`); a parked agent wakes to read
/// it, and its answer goes to the main agent. A message ompd could not deliver keeps the sheet up with the reason.
private struct MessageSheet: View {
    let app: AppState
    let target: AgentTarget
    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Message \(target.agent.id)")
                .font(.headline)
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .onSubmit(send)
            Text("The main agent writes it to agent://\(target.agent.id); the answer goes to the main agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.isEmpty || sending)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var message: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let body = message
        guard !body.isEmpty, !sending else { return }
        sending = true
        failure = nil
        Task {
            do {
                try await app.connection.message(agent: target.agent.id, of: target.sessionKey, body: body)
                dismiss()
            } catch {
                failure = error.userMessage
                sending = false
            }
        }
    }
}

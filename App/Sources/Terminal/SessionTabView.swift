import IDEModel
import IDEState
import SwiftUI

/// A session tab: omp's own TUI in a terminal emulator, following omp from PTY to PTY. While the TUI is not
/// live, a bar under the last screen says why and offers Resume or Close Session; before the tab showed anything, a
/// placeholder does. While it is live, a bar there asks whether the agents omp's last death interrupted should carry on
/// (restore policy `ask`), one shows what ompd warns about the session, and a quiet one offers to restart the session
/// on a newer omp installed since it started. Out of ompd's reach the window's banner speaks for every tab: the last
/// screen stays without a bar of its own.
struct SessionTabView: View {
    let app: AppState
    let sessionKey: SessionKey

    var body: some View {
        if let session = app.connection.openSessions[sessionKey] {
            let connected = app.connection.isConnected
            let notice = SessionNotice(
                session: session, connected: connected, daemonMessage: app.connection.latestNotice(about: sessionKey)?.message)
            VStack(spacing: 0) {
                ZStack {
                    TerminalPane { app.terminals.emulator(for: session) }
                    if !session.hasScreen, let notice {
                        SessionPlaceholder(notice: notice, perform: perform)
                    }
                }
                if session.hasScreen, connected, let notice {
                    NoticeBar(
                        systemImage: notice.systemImage, tint: notice.tint, title: notice.title, message: notice.message,
                        inProgress: notice.inProgress, rule: .top
                    ) {
                        ForEach(notice.actions, id: \.self) { action in
                            Button(action.title) { perform(action) }
                        }
                    }
                } else if notice == nil, let entry = session.entry {
                    if let interruption = entry.pendingContinuation {
                        ContinuationBar(app: app, sessionKey: sessionKey, interruption: interruption)
                            .id(interruption.detectedAt)
                    }
                    SessionReportBar(app: app, entry: entry)
                    if let installed = entry.ompUpgrade {
                        UpgradeBar(app: app, entry: entry, installed: installed)
                    }
                }
            }
        }
    }

    private func perform(_ action: SessionNotice.Action) {
        switch action {
        case .resume: app.resumeSession(sessionKey)
        case .locateFolder: app.locateFolder(sessionKey)
        case .closeSession: app.requestCloseSession(sessionKey)
        case .forget: app.requestForgetSession(sessionKey)
        case .closeTab: app.closeTab(.session(sessionKey))
        case .showTerminal:
            if let entry = app.entry(for: sessionKey), entry.adopted, let ptyId = entry.ptyId { app.showTerminal(ptyId) }
        }
    }
}

/// Why omp's TUI is not live in a session tab, and what the user can do about it.
struct SessionNotice {
    enum Action: Hashable {
        case resume, locateFolder, closeSession, forget, closeTab, showTerminal

        var title: String {
            switch self {
            case .resume: "Resume"
            case .locateFolder: "Locate Folder…"
            case .closeSession: "Close Session"
            case .forget: "Remove Session…"
            case .closeTab: "Close Tab"
            case .showTerminal: "Show Terminal"
            }
        }
    }

    var title: String
    var message: String
    var systemImage: String
    var tint: Color
    /// Something is under way that ends it by itself: a spinner instead of the icon.
    var inProgress = false
    var actions: [Action] = []

    /// nil while the TUI is live. `daemonMessage`: ompd's latest notice about the session.
    @MainActor
    init?(session: SessionTerminal, connected: Bool, daemonMessage: String?) {
        guard connected else {
            // The window's banner says why and what to do; this only stands in for the screen the tab has not shown yet.
            self.init("Waiting for ompd", "", "bolt.horizontal.circle", .orange, inProgress: true)
            return
        }
        guard let entry = session.entry else {
            self.init(
                "Unknown Session", "ompd does not list this session. Close the tab; Open Session… (⇧⌘O) can resume it from its file.",
                "questionmark.circle", .secondary, actions: [.closeTab])
            return
        }
        guard !session.isLive else { return nil }
        switch entry.status {
        case .closed:
            self.init(
                entry.closedByUser ? "Session Closed" : "omp Exited",
                entry.isResumable
                    ? "Resume starts omp again with this conversation."
                    : entry.sessionFileIsGone ? "Its session file is gone; it cannot be resumed." : "ompd has no session file to resume it from.",
                "stop.circle", .secondary, actions: entry.isResumable ? [.resume, .closeTab] : [.forget, .closeTab])
        case .interrupted:
            self.init(
                "omp Stopped Unexpectedly", "ompd is starting it again with this conversation.", "exclamationmark.triangle",
                .orange, inProgress: true)
        case .needsAttention:
            if entry.canLocateFolder {
                // Resume would fail the same way; the session resumes in the folder the user points at.
                self.init(
                    "omp Could Not Be Resumed",
                    (daemonMessage ?? "Its folder \(entry.workspace) no longer exists.") + " Locate Folder… resumes it where the folder is now.",
                    "exclamationmark.octagon", .red, actions: [.locateFolder, .forget])
                return
            }
            self.init(
                "omp Could Not Be Resumed",
                (daemonMessage ?? "It stopped again right after every restart.")
                    + (entry.isResumable ? " Resume tries once more." : " Remove it from the list; its file stays on disk."),
                "exclamationmark.octagon", .red, actions: entry.isResumable ? [.resume, .forget] : [.forget])
        case .resuming:
            self.init("Resuming…", "ompd is starting omp again with this conversation.", "arrow.clockwise", .secondary, inProgress: true)
        case .starting:
            self.init("Starting omp…", "", "terminal", .secondary, inProgress: true)
        case .busy, .idle, .paused:
            if entry.adopted {
                // omp runs in a terminal tab; this tab has nothing of it to show.
                self.init(
                    "Running in a Terminal", "omp was started in a terminal of this window; its tab shows the session.",
                    "terminal", .secondary, actions: [.showTerminal, .closeTab])
                return
            }
            // omp runs; its TUI is not on screen (yet).
            switch session.terminal?.phase {
            case .failed(let message):
                self.init("Could Not Show omp", message, "exclamationmark.triangle", .orange, actions: [.closeTab])
            case .gone:
                self.init("omp's Terminal Ended", "Waiting for ompd…", "terminal", .secondary, inProgress: true)
            case .attached where session.terminal?.hasExited == true:
                self.init("omp Exited", "Waiting for ompd…", "terminal", .secondary, inProgress: true)
            case .attached, .attaching, .detached, nil:
                self.init("Connecting to omp…", "", "terminal", .secondary, inProgress: true)
            }
        }
    }

    private init(
        _ title: String, _ message: String, _ systemImage: String, _ tint: Color, inProgress: Bool = false,
        actions: [Action] = []
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.inProgress = inProgress
        self.actions = actions
    }
}

/// omp died mid-work and ompd started it again; the restore policy says to ask before the interrupted agents are told
/// and asked to carry on (`pendingContinuation`, `session.continue`). The bar goes once ompd's push clears it.
private struct ContinuationBar: View {
    let app: AppState
    let sessionKey: SessionKey
    let interruption: Interruption
    /// An answer is on its way to ompd.
    @State private var answering = false

    var body: some View {
        NoticeBar(
            systemImage: "exclamationmark.triangle", tint: .orange, title: "omp was interrupted",
            message: Self.unfinished(interruption), inProgress: answering, rule: .top
        ) {
            if parties > 1 {
                Menu("Continue") {
                    if interruption.mainInterrupted {
                        Button("Only the Main Agent") { answer(main: true, agents: []) }
                    }
                    ForEach(interruption.agents, id: \.id) { agent in
                        Button("Only \(agent.id)") { answer(main: false, agents: [agent.id]) }
                    }
                } primaryAction: {
                    continueAll()
                }
                .fixedSize()
            } else {
                Button("Continue", action: continueAll)
            }
            Button("Leave") { answer(main: false, agents: []) }
        }
        .disabled(answering)
        .help(interruption.cause)
    }

    /// The main agent (when it was mid-turn) and each interrupted subagent.
    private var parties: Int { (interruption.mainInterrupted ? 1 : 0) + interruption.agents.count }

    private func continueAll() {
        answer(main: interruption.mainInterrupted, agents: interruption.agents.map(\.id))
    }

    private func answer(main: Bool, agents: [String]) {
        answering = true
        Task {
            // On success the bar stays busy until the push that clears the interruption removes it.
            if await !app.continueSession(sessionKey, main: main, agents: agents) { answering = false }
        }
    }

    /// "Unfinished: the main agent's turn (npm test); subagents Sleeper and Scout."
    static func unfinished(_ interruption: Interruption) -> String {
        var parts: [String] = []
        if interruption.mainInterrupted {
            let calls = interruption.pendingToolCalls.map { clipped($0.summary.isEmpty ? $0.toolName : $0.summary) }
            parts.append(calls.isEmpty ? "the main agent's turn" : "the main agent's turn (\(list(calls, limit: 2)))")
        }
        if !interruption.agents.isEmpty {
            let ids = interruption.agents.map(\.id)
            parts.append((ids.count == 1 ? "subagent " : "subagents ") + list(ids, limit: 3))
        }
        guard !parts.isEmpty else { return interruption.cause }
        return "Unfinished: \(parts.joined(separator: "; "))."
    }

    private static func list(_ items: [String], limit: Int) -> String {
        guard items.count > limit else { return items.formatted(.list(type: .and)) }
        return items.prefix(limit).joined(separator: ", ") + " and \(items.count - limit) more"
    }

    private static func clipped(_ text: String, to length: Int = 40) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }
}

/// The omp at the session's pinned path is newer than the one it runs: Restart Session stops omp gracefully
/// and resumes the conversation on the new one (`session.restart`), offered while the agent is idle. The bar goes once
/// the restarted omp runs the installed version.
private struct UpgradeBar: View {
    let app: AppState
    let entry: SessionManifestEntry
    let installed: String
    /// The restart is on its way to ompd.
    @State private var restarting = false

    var body: some View {
        NoticeBar(
            systemImage: "arrow.up.circle", tint: .secondary, title: "omp \(installed) is installed",
            message: "This session runs \(entry.launch.ompVersion); Restart Session moves it to the new one.", inProgress: restarting, rule: .top
        ) {
            Button("Restart Session") {
                restarting = true
                Task {
                    await app.restartSession(entry.sessionKey)
                    restarting = false
                }
            }
            .disabled(restarting || entry.status != .idle)
            .help(entry.status == .idle
                ? "Stops omp and resumes this conversation on omp \(installed)."
                : "Available once the agent is idle.")
        }
    }
}

/// The newest warning or error ompd sent about the session since its omp started (`DaemonNotice`), with Dismiss: a
/// notice about one session shows on its tab and nowhere else. What ompd sends as info only narrates what the
/// session's mark and bars show already (resuming, exited), and what came before the omp running now is over.
struct SessionReportBar: View {
    let app: AppState
    let entry: SessionManifestEntry

    var body: some View {
        let since = entry.spawnedAt ?? .distantPast
        if let report = app.connection.notices.last(where: { $0.sessionKey == entry.sessionKey && $0.level != "info" && $0.at >= since }) {
            NoticeBar(
                systemImage: report.level == "error" ? "exclamationmark.octagon" : "exclamationmark.triangle",
                tint: report.level == "error" ? .red : .orange, title: "", message: report.message, rule: .top
            ) {
                Button("Dismiss") { app.connection.dismissNotices(about: entry.sessionKey) }
            }
        }
    }
}

/// The notice in place of the terminal, before the tab showed anything of the session.
private struct SessionPlaceholder: View {
    let notice: SessionNotice
    let perform: (SessionNotice.Action) -> Void

    var body: some View {
        ContentUnavailableView {
            if notice.inProgress {
                ProgressView().controlSize(.large)
                Text(notice.title)
            } else {
                Label(notice.title, systemImage: notice.systemImage)
            }
        } description: {
            if !notice.message.isEmpty { Text(notice.message) }
        } actions: {
            ForEach(notice.actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
    }
}


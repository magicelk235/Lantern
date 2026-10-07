import IDEModel
import IDEState
import SwiftUI

/// A project's window, one native tab of the window group per project: an activity bar on the
/// left (Files, Changes, Projects), the pane it picked next to it (hidden again by clicking the same icon), and the
/// project's open tabs on the right. Every session and terminal of the project is one of its tabs. The window of no
/// project (`project` empty) only offers Add Project, and shows the first project once there is one.
struct ProjectWindow: View {
    @Bindable var app: AppState
    @Binding var project: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// The window's content width, as last laid out.
    @State private var width = 0.0

    /// The window's smallest content: the layout never collapses below it.
    static let minimumSize = CGSize(width: 720, height: 440)
    /// The narrowest the tabs' content gets while the pane shows: the pane gives way first, down to its minimum.
    static let minimumContentWidth = 400.0

    /// The pane's width: the one the user dragged, less what the content needs to stay usable.
    private var paneWidth: Double {
        guard width > 0 else { return app.sidebarWidth }
        let room = width - Double(ActivityBar.width) - 2 - Self.minimumContentWidth
        return min(app.sidebarWidth, max(AppState.minimumSidebarWidth, room))
    }

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar(app: app, project: project)
            Chrome.hairline.frame(width: 1)
            if app.sidebarVisible {
                SidebarPaneView(app: app, project: project)
                    .frame(width: paneWidth)
                SidebarResizeHandle(app: app, width: paneWidth)
            }
            VStack(spacing: 0) {
                StatusBanners(app: app, project: project)
                if let strip = app.strip(of: project) {
                    TabStrip(app: app, strip: strip)
                }
                Group {
                    let selected = app.selectedTab(in: project)
                    if let key = selected?.sessionKey {
                        SessionTabView(app: app, sessionKey: key)
                            .id(key)
                    } else if let ptyId = selected?.ptyId {
                        TerminalDetailView(app: app, ptyId: ptyId)
                            .id(ptyId)
                    } else if let path = selected?.editorPath, let document = app.editors.document(for: path) {
                        EditorView(app: app, document: document)
                            .id(path)
                    } else {
                        EmptyDetail(app: app, project: project.isEmpty ? nil : project)
                    }
                }
                .clipped()
                // Where a new tab's emulator will go: its PTY starts at that size.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { app.tabContentSizeChanged($0) }
                StatusBar(app: app, project: project)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width = $0 }
        .background(Chrome.surface)
        .background(WindowAccessor { app.attach($0, project: project) })
        .navigationTitle(project.isEmpty ? "Lantern" : AppState.projectName(project))
        .toolbarBackground(Chrome.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .task { app.start() }
        // The scene owns opening and closing windows; the model asks through these.
        .onAppear {
            app.openProjectWindow = { openWindow(id: LanternApp.projectWindowID, value: $0) }
            app.closeProjectWindow = { dismissWindow(id: LanternApp.projectWindowID, value: $0) }
            // The project is back: no window needs to say it keeps running (the notice shows the next time instead).
            if app.closedProjectNotice?.project == project { app.dismissClosedProjectNotice(seen: false) }
            if project.isEmpty {
                let shown = $project
                app.showInNoProjectWindow = { shown.wrappedValue = $0 }
            }
        }
        // A window can name a folder the app does not list: one open at the last quit whose project only ompd's sessions
        // named. A folder that is still there becomes a project, a gone one gives way to the first project's window,
        // else to the window of no project. After the window is up: the scene ignores opening and dismissing while it
        // is still restoring.
        .task(id: project) {
            guard !project.isEmpty, !app.projects.contains(project) else { return }
            if AppState.isFolder(project) {
                app.addProject(project)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
            openWindow(id: LanternApp.projectWindowID, value: app.projects.first ?? "")
            dismissWindow(id: LanternApp.projectWindowID, value: project)
        }
        // The tabs are the list of sessions and terminals: whatever ompd lists gets one.
        .onChange(of: app.connection.sessions, initial: true) { app.syncTabs() }
        .onChange(of: app.connection.terminals.terminals) { app.syncTabs() }
        // The no-project window shows the first project once one exists (a project can also arrive from ompd, e.g. a
        // session started elsewhere; with no window left, ompd would pause every session). It gives way instead when
        // that project has a window already.
        .onChange(of: app.projects.isEmpty) { _, empty in
            guard project.isEmpty, !empty, let first = app.projects.first else { return }
            app.showProject(first)
            if app.window(of: "") != nil { dismissWindow(id: LanternApp.projectWindowID, value: "") }
        }
        .sessionPicker(app, project: project)
        .quickLookPanel(app, project: project)
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

/// The words of a close's confirmation: Terminal's for the processes of a terminal, the session's title for one
/// session, the count for several tabs, the project's name for Remove Project, each saying what ends.
@MainActor
extension AppState.CloseRequest {
    var title: String {
        switch action {
        case .forget: "Remove this session from the list?"
        case .removeProject(let project, _): "Remove “\(AppState.projectName(project))” from the projects?"
        case .close(let closing) where closing.count > 1: "Close \(closing.count) tabs?"
        case .close: sessions.first.map { "Close \(Self.quoted($0.title))?" } ?? "Do you want to terminate running processes in this tab?"
        }
    }

    var confirmation: String {
        switch action {
        case .forget: "Remove Session"
        case .removeProject: "Remove Project"
        case .close(let closing) where closing.count > 1: "Close Tabs"
        case .close: sessions.isEmpty ? "Terminate" : "Close Session"
        }
    }

    var message: String {
        switch action {
        case .forget:
            return "ompd forgets the session and its tab closes. The conversation file on disk is kept."
        case .removeProject(_, let closing):
            let tabs = closing.count == 1 ? "Its tab closes" : "Its \(closing.count) tabs close"
            return working + "\(tabs): \(ending)." + resume + " The folder on disk is kept."
        case .close(let closing) where closing.count == 1 && sessions.isEmpty:
            return "Closing this tab will terminate the running processes: \(processes.joined(separator: ", "))."
        case .close(let closing) where closing.count == 1:
            let working = sessions.contains(where: \.working) ? "The agent is working. " : ""
            let resume = sessions.allSatisfy(\.resumable) ? "; you can resume it later from Open Session…" : "."
            return working + "The omp session ends" + resume
        case .close:
            return working + ending.prefix(1).uppercased() + ending.dropFirst() + "." + resume
        }
    }

    /// What ends, as one clause: "the omp session “X” ends, and the running process vim is terminated".
    private var ending: String {
        var ending: [String] = []
        if !sessions.isEmpty {
            let titles = ListFormatter.localizedString(byJoining: sessions.map { Self.quoted($0.title) })
            ending.append(sessions.count == 1 ? "the omp session \(titles) ends" : "the omp sessions \(titles) end")
        }
        if !processes.isEmpty {
            let names = processes.joined(separator: ", ")
            ending.append(processes.count == 1 ? "the running process \(names) is terminated" : "the running processes \(names) are terminated")
        }
        return ending.joined(separator: ", and ")
    }

    private var working: String {
        sessions.contains(where: \.working) ? "An agent is working. " : ""
    }

    /// How the ending sessions come back, when they all can.
    private var resume: String {
        guard !sessions.isEmpty, sessions.allSatisfy(\.resumable) else { return "" }
        return sessions.count == 1 ? " You can resume it later from Open Session…" : " You can resume them later from Open Session…"
    }

    /// A session's title in quotes, cut short: an untitled session goes by its whole first prompt line.
    private static func quoted(_ title: String) -> String {
        "“\(title.count > 60 ? title.prefix(59).trimmingCharacters(in: .whitespaces) + "…" : title)”"
    }
}

/// The column at the window's left edge: Files, Changes (badged in the accent with the count of changed files), Agents
/// (badged in red with the approvals and questions waiting in the project's sessions) and Projects (badged in red with
/// those waiting in the other projects), each its symbol with its name under it, the current one in the accent. A
/// click shows the pane; a click on the pane already showing hides the sidebar.
struct ActivityBar: View {
    let app: AppState
    let project: String

    static let width: CGFloat = 60

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SidebarPane.allCases, id: \.self) { pane in
                ActivityButton(
                    pane: pane, isCurrent: app.sidebarVisible && app.pane == pane, badge: badge(of: pane),
                    badgeTint: pane == .agents || pane == .projects ? .red : .accentColor
                ) {
                    app.togglePane(pane)
                }
            }
            Spacer()
        }
        .padding(.top, 6)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Chrome.surface)
    }

    private func badge(of pane: SidebarPane) -> Int {
        switch pane {
        case .changes: changeCount
        case .agents: project.isEmpty ? 0 : app.attentionCount(in: project)
        case .projects: app.connection.attentionCount - (project.isEmpty ? 0 : app.attentionCount(in: project))
        case .files: 0
        }
    }

    /// Changed files in the window's project.
    private var changeCount: Int {
        guard !project.isEmpty else { return 0 }
        let repository = app.editors.repositories.repository(for: project)
        return repository.isRepository ? repository.changes.count : 0
    }
}

private struct ActivityButton: View {
    let pane: SidebarPane
    let isCurrent: Bool
    let badge: Int
    /// Red for what waits on the user, the accent for a plain count.
    let badgeTint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 22)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            CountBadge(count: badge, tint: badgeTint)
                                .fixedSize()
                                .offset(x: 9, y: -5)
                        }
                    }
                Text(pane.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 54, height: 46)
            // The current pane is told by its accent alone: a fill under its name would take its contrast below 4.5:1.
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && !isCurrent ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .onHover { hovering = $0 }
        .help("\(pane.title) (\(pane.shortcut))")
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The hairline between the sidebar and the tabs; dragging it resizes the sidebar from the `width` it shows at.
private struct SidebarResizeHandle: View {
    let app: AppState
    let width: Double
    @State private var startWidth: Double?

    var body: some View {
        Chrome.hairline
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = width }
                                app.sidebarWidth = (startWidth ?? width) + value.translation.width
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

/// What the project in focus offers: New Session, New Terminal, Open Session…, Finder, and Remove Project, which closes
/// its tabs first (asking when that ends sessions or running commands).
struct ProjectMenu: View {
    let app: AppState
    let project: String

    var body: some View {
        Button("New Session") { app.newSession(in: project) }
            .disabled(!app.connection.isConnected)
        Button("New Terminal") { app.newTerminal(in: project) }
            .disabled(!app.connection.isConnected)
        Button("Open Session…") { app.showSessionPicker(for: project) }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: project, directoryHint: .isDirectory)])
        }
        Button("Remove Project") { app.removeProject(project) }
    }
}

/// Resume, Close Session and Remove Session, for a session's row and tab.
struct SessionMenu: View {
    let app: AppState
    let entry: SessionManifestEntry

    var body: some View {
        if entry.isResumable {
            Button("Resume Session") { app.resumeSession(entry.sessionKey) }
                .disabled(!app.connection.isConnected)
        }
        if entry.isStopped {
            Button("Remove Session…") { app.requestForgetSession(entry.sessionKey) }
                .disabled(!app.connection.isConnected)
        } else {
            Button("Close Session") { app.requestCloseSession(entry.sessionKey) }
                .disabled(!app.connection.isConnected)
        }
    }
}

/// Connection, outdated-ompd, daemon-notice and daemon-registration problems, failing state writes and crash reports,
/// above the detail pane. Notices about disk space offer Free Up Space…, which opens Settings › Storage.
struct StatusBanners: View {
    let app: AppState
    /// The window's project; empty for the window of no project.
    let project: String
    @Environment(\.openSettings) private var openSettings

    private var connection: DaemonConnection { app.connection }
    private var agent: DaemonAgent { app.agent }

    var body: some View {
        VStack(spacing: 0) {
            OutdatedDaemonBar(app: app, project: project)
            // While the out-of-date ompd restarts, ompd is out of reach by design: "Restarting ompd" says so.
            if case .daemonUnavailable(let reason) = connection.status, app.outdatedDaemon.phase != .restarting {
                NoticeBar(
                    systemImage: "bolt.horizontal.circle", tint: .orange, title: "ompd is not reachable",
                    message: agent.isRepairing ? "Registering ompd with launchd again." : unreachable(reason),
                    inProgress: agent.isRepairing
                ) {
                    if agent.state == .enabled {
                        Button("Restart ompd", action: app.restartDaemon)
                            .disabled(agent.isRepairing)
                    }
                }
            }
            if let notice = connection.latestNotice, !shownBySessionBar(notice) {
                NoticeBar(
                    systemImage: notice.level == "info" ? "info.circle" : "exclamationmark.triangle",
                    tint: notice.level == "error" ? .red : notice.level == "warning" ? .orange : .blue,
                    title: "ompd", message: notice.message
                ) {
                    if notice.topic == DaemonNotice.diskSpaceTopic {
                        Button("Free Up Space…", action: freeUpSpace)
                    }
                    Button("Dismiss", action: connection.dismissNotices)
                }
            }
            if let failure = app.persistence.writeFailure {
                NoticeBar(
                    systemImage: "exclamationmark.triangle", tint: .orange, title: "Unsaved edits may not survive a crash",
                    message: failure.outOfSpace
                        ? "The disk is full, so Lantern could not save its state. Free up space to keep them."
                        : "Lantern could not save its state: \(failure.reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))). "
                            + "It tries again with each change; quit and reopen Lantern if this stays."
                ) {
                    if failure.outOfSpace {
                        Button("Free Up Space…", action: freeUpSpace)
                    }
                }
            }
            if let report = app.crashNotices.unseen.first {
                NoticeBar(
                    systemImage: "exclamationmark.triangle", tint: .orange,
                    title: "\(report.process) quit unexpectedly \(Self.when(report.date))",
                    message: app.crashNotices.unseen.count > 1 ? "\(app.crashNotices.unseen.count - 1) earlier crash reports too." : ""
                ) {
                    Button("Show Report", action: app.crashNotices.showReport)
                    Button("Dismiss", action: app.crashNotices.dismiss)
                }
            }
            if let closed = app.closedProjectNotice, closed.project != project {
                NoticeBar(
                    systemImage: "info.circle", tint: .secondary, title: "“\(AppState.projectName(closed.project))” keeps running",
                    message: Self.keepsRunning(closed)
                ) {
                    Button("Show Project") {
                        app.dismissClosedProjectNotice(seen: true)
                        app.showProject(closed.project)
                    }
                    Button("OK") { app.dismissClosedProjectNotice(seen: true) }
                }
                .help(
                    "Closing a project’s window ends nothing in it. Its agents keep working while a Lantern window is open; "
                        + "with none open, ompd pauses them until one opens again. Terminals keep running either way.")
            }
            switch agent.state {
            case .requiresApproval:
                NoticeBar(
                    systemImage: "lock.shield", tint: .yellow, title: "Allow Lantern to run in the background",
                    message: "ompd keeps your agents running while the app is closed. Turn it on in System Settings › General › Login Items."
                ) {
                    Button("Open Login Items", action: agent.openLoginItemsSettings)
                }
            case .failed(let message):
                NoticeBar(
                    systemImage: "exclamationmark.triangle", tint: .red, title: "Could not register ompd",
                    message: "\(message) Allow Lantern in Login Items, then reopen Lantern."
                ) {
                    Button("Open Login Items", action: agent.openLoginItemsSettings)
                }
            case .notRegistered:
                NoticeBar(
                    systemImage: "exclamationmark.triangle", tint: .orange, title: "ompd is not registered",
                    message: "Register it to keep your agents running in the background."
                ) {
                    Button("Register", action: agent.registerIfNeeded)
                }
            case .notFound:
                NoticeBar(
                    systemImage: "exclamationmark.triangle", tint: .red, title: "ompd is missing from the app",
                    message: "Contents/Library/LaunchAgents/com.magicelklabs.lantern.ompd.plist was not found in the app bundle. Reinstall Lantern.")
            case .unknown, .external, .enabled:
                EmptyView()
            }
        }
    }

    /// Why ompd is out of reach and what comes next: Lantern keeps trying; the user can restart the ompd it registered,
    /// or start the developer's own.
    private func unreachable(_ reason: String) -> String {
        switch agent.state {
        case .enabled: "\(reason) Lantern keeps trying and your agents keep running; Restart ompd if this lasts."
        case .external(let home): "\(reason) Start ompd for OMPD_HOME=\(home) (`ompd run`) to reconnect."
        default: "\(reason) Lantern keeps trying, and your agents keep running."
        }
    }

    /// A notice about a session that needs attention: that session's own bar already shows it, with its actions.
    private func shownBySessionBar(_ notice: DaemonNotice) -> Bool {
        guard let key = notice.sessionKey else { return false }
        return connection.sessions.first { $0.sessionKey == key }?.status == .needsAttention
    }

    private func freeUpSpace() {
        SettingsTab.storage.select()
        openSettings()
    }

    /// Closing a project's window ends nothing: its sessions and terminals go on in ompd while another window is open;
    /// with none left, ompd holds the agents and the terminals go on.
    private static func keepsRunning(_ closed: AppState.ClosedProject) -> String {
        let what = [
            closed.sessions == 0 ? nil : closed.sessions == 1 ? "session" : "\(closed.sessions) sessions",
            closed.terminals == 0 ? nil : closed.terminals == 1 ? "terminal" : "\(closed.terminals) terminals",
        ].compactMap(\.self).joined(separator: " and ")
        let verb = closed.sessions + closed.terminals == 1 ? "goes" : "go"
        return "Its \(what) \(verb) on without its window. Projects (⇧⌘P) shows it again."
    }

    /// "at 14:02" today, else "on Sep 30 at 14:02".
    private static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard !Calendar.current.isDateInToday(date) else { return "at \(time)" }
        return "on \(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}

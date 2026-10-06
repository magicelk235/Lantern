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
        // macOS restores the windows that were open; one can name a folder the app no longer lists (its state was lost
        // or belongs to another data folder): a folder that is still there becomes a project again, a gone one gives
        // way to the first project's window, else to the window of no project. After the window is up: the scene
        // ignores opening and dismissing while it is still restoring.
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
/// session, the count for several tabs, each saying what ends.
extension AppState.CloseRequest {
    var title: String {
        switch action {
        case .forget: "Remove this session from the list?"
        case .close(let closing) where closing.count > 1: "Close \(closing.count) tabs?"
        case .close: sessions.first.map { "Close “\($0.title)”?" } ?? "Do you want to terminate running processes in this tab?"
        }
    }

    var confirmation: String {
        switch action {
        case .forget: "Remove Session"
        case .close(let closing) where closing.count > 1: "Close Tabs"
        case .close: sessions.isEmpty ? "Terminate" : "Close Session"
        }
    }

    var message: String {
        switch action {
        case .forget:
            return "ompd forgets the session and its tab closes. The conversation file on disk is kept."
        case .close(let closing) where closing.count == 1 && sessions.isEmpty:
            return "Closing this tab will terminate the running processes: \(processes.joined(separator: ", "))."
        case .close(let closing) where closing.count == 1:
            let working = sessions.contains(where: \.working) ? "The agent is working. " : ""
            let resume = sessions.allSatisfy(\.resumable) ? "; you can resume it later from Open Session…" : "."
            return working + "The omp session ends" + resume
        case .close:
            var ending: [String] = []
            if !sessions.isEmpty {
                let titles = ListFormatter.localizedString(byJoining: sessions.map { "“\($0.title)”" })
                ending.append(sessions.count == 1 ? "the omp session \(titles) ends" : "the omp sessions \(titles) end")
            }
            if !processes.isEmpty {
                let names = processes.joined(separator: ", ")
                ending.append(processes.count == 1 ? "the running process \(names) is terminated" : "the running processes \(names) are terminated")
            }
            let sentence = ending.joined(separator: ", and ")
            let working = sessions.contains(where: \.working) ? "An agent is working. " : ""
            var message = working + sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
            if !sessions.isEmpty, sessions.allSatisfy(\.resumable) {
                message += sessions.count == 1 ? " You can resume it later from Open Session…" : " You can resume them later from Open Session…"
            }
            return message
        }
    }
}

/// The column of icons at the window's left edge: Files, Changes (badged with the count of changed files), Agents
/// (badged in red with the approvals and questions waiting in the project's sessions) and Projects (badged in red with
/// those waiting in the other projects). A click shows the pane; a click on the pane already showing hides the
/// sidebar. Its own look, not an activity bar copied from elsewhere: 16pt outline symbols, the current one on a filled
/// rounded square.
struct ActivityBar: View {
    let app: AppState
    let project: String

    static let width: CGFloat = 44

    var body: some View {
        VStack(spacing: 4) {
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
            Image(systemName: pane.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isCurrent ? Color.primary.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : .clear))
                .contentShape(Rectangle())
                .overlay(alignment: .bottomTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : String(badge))
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(badgeTint, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 2, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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

/// The detail area with no tab on screen: what to do first.
private struct EmptyDetail: View {
    let app: AppState
    let project: String?

    var body: some View {
        ContentUnavailableView {
            if let project {
                Label(AppState.projectName(project), systemImage: "folder")
            } else {
                Label("No Projects", systemImage: "folder.badge.plus")
            }
        } description: {
            if project != nil {
                Text("Start omp here, or open a terminal. Sessions keep running after you quit; closing a tab ends it.")
            } else {
                Text("Add a project folder to start omp in it, open terminals, and browse its files.")
            }
        } actions: {
            if let project {
                Button("New Session") { app.newSession(in: project) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!app.connection.isConnected)
                Button("New Terminal") { app.newTerminal(in: project) }
                    .disabled(!app.connection.isConnected)
            } else {
                Button("Add Project…") { app.addProject() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
    }
}

/// What the project in focus offers: New Session, New Terminal, Open Session…, Finder, and Remove once nothing of it is
/// open.
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
            .disabled(!app.canRemoveProject(project))
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
                    message: agent.isRepairing ? "Registering ompd with launchd again." : "\(reason) Retrying; running agents are not affected.",
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
                    message: "Lantern could not save its state: \(failure.reason)"
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
                NoticeBar(systemImage: "exclamationmark.triangle", tint: .red, title: "Could not register ompd", message: message) {
                    Button("Open Login Items", action: agent.openLoginItemsSettings)
                }
            case .notRegistered:
                NoticeBar(
                    systemImage: "exclamationmark.triangle", tint: .orange, title: "ompd is not registered",
                    message: "The background daemon is not set up to run."
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

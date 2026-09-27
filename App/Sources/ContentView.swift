import IDEModel
import IDEState
import SwiftUI

/// The window: projects in the sidebar, the open tabs in the middle, the project's files in the
/// trailing Files panel.
struct ContentView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            ProjectsSidebar(app: app)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { app.sidebarWidthChanged($0) }
                // Outermost: the split view reads the column width from the column's root view.
                .navigationSplitViewColumnWidth(min: 220, ideal: app.initialSidebarWidth, max: 420)
        } detail: {
            VStack(spacing: 0) {
                StatusBanners(app: app)
                if let strip = app.tabs.selectedStrip {
                    TabStrip(app: app, strip: strip)
                }
                Group {
                    if let key = app.tabs.selection?.sessionKey {
                        SessionTabView(app: app, sessionKey: key)
                            .id(key)
                    } else if let ptyId = app.tabs.selection?.ptyId {
                        TerminalDetailView(app: app, ptyId: ptyId)
                            .id(ptyId)
                    } else if let path = app.tabs.selection?.editorPath, let document = app.editors.document(for: path) {
                        EditorView(app: app, document: document)
                            .id(path)
                    } else {
                        EmptyDetail(app: app)
                    }
                }
                // Where a new tab's emulator will go: its PTY starts at that size.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { app.tabContentSizeChanged($0) }
                StatusBar(app: app)
            }
            .inspector(isPresented: $app.filesVisible) {
                FilesPanel(app: app)
                    .inspectorColumnWidth(min: 220, ideal: 280, max: 520)
            }
        }
        // Not drawn in the compact toolbar; names the window in the Window menu and Mission Control.
        .navigationTitle(windowTitle)
        // Painted, not material: the compact toolbar would otherwise mirror the selected tab's canvas as a block above it.
        .toolbarBackground(Chrome.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // Flexible space: with no title, the action would otherwise sit at the sidebar.
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.filesVisible.toggle()
                } label: {
                    Label("Files", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the Files panel (⌥⌘0)")
            }
        }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .confirmationDialog(
            closeTitle, isPresented: Binding(get: { app.pendingClose != nil }, set: { if !$0 { app.pendingClose = nil } }),
            presenting: app.pendingClose
        ) { request in
            switch request {
            case .session(let key):
                Button("Close Session", role: .destructive) { app.closeSession(key) }
            case .forget(let key):
                Button("Remove Session", role: .destructive) { app.forgetSession(key) }
            }
        } message: { request in
            switch request {
            case .session:
                Text("The agent is working. omp exits and the session leaves the list; its conversation file on disk is kept.")
            case .forget:
                Text("ompd forgets the session and its tab closes. The conversation file on disk is kept.")
            }
        }
    }

    private var windowTitle: String {
        guard let strip = app.tabs.selectedStrip else { return "omp IDE" }
        return AppState.projectName(strip.workspace)
    }

    private var closeTitle: String {
        switch app.pendingClose {
        case .session: "Close this session while the agent works?"
        case .forget: "Remove this session from the list?"
        case nil: ""
        }
    }
}

/// The detail area with no tab on screen: what to do first.
private struct EmptyDetail: View {
    let app: AppState

    var body: some View {
        ContentUnavailableView {
            if let project = app.currentProject {
                Label(AppState.projectName(project), systemImage: "folder")
            } else {
                Label("No Projects", systemImage: "folder.badge.plus")
            }
        } description: {
            if app.currentProject != nil {
                Text("Start omp here, or open a terminal. Sessions keep running after you quit; closing a tab ends it.")
            } else {
                Text("Add a project folder to start omp in it, open terminals, and browse its files.")
            }
        } actions: {
            if let project = app.currentProject {
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

// MARK: - Sidebar

/// The projects, each with its rows: running sessions first, then terminals, then closed sessions. Add Project sits
/// at the bottom.
struct ProjectsSidebar: View {
    @Bindable var app: AppState

    var body: some View {
        let terminals = app.terminals.byWorkspace(among: app.knownWorkspaces, hosting: app.adoptedTerminals)
        List(selection: Binding(get: { app.tabs.selection }, set: { if let tab = $0 { app.showTab(tab) } })) {
            ForEach(app.projects, id: \.self) { project in
                let sessions = app.connection.workspaces.first { $0.path == project }?.sessions ?? []
                let running = sessions.filter { !$0.isStopped }
                let stopped = sessions.filter(\.isStopped)
                let ptys = terminals[project] ?? []
                Section {
                    ForEach(running, id: \.sessionKey) { entry in
                        // A session running in a terminal (the user typed `omp` there) is shown by that terminal's tab.
                        SessionRow(entry: entry, title: app.sessionTitle(entry.sessionKey))
                            .tag(app.tab(for: entry))
                            .contextMenu { SessionMenu(app: app, entry: entry) }
                    }
                    TerminalRows(app: app, terminals: ptys)
                    ForEach(stopped, id: \.sessionKey) { entry in
                        SessionRow(entry: entry, title: app.sessionTitle(entry.sessionKey))
                            .tag(app.tab(for: entry))
                            .contextMenu { SessionMenu(app: app, entry: entry) }
                    }
                    if sessions.isEmpty, ptys.isEmpty {
                        StartHereRow(app: app, project: project)
                    }
                } header: {
                    ProjectHeader(app: app, project: project)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                app.addProject()
            } label: {
                Label("Add Project", systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .help("Add a project folder (⌘O)")
        }
        .overlay {
            if app.projects.isEmpty {
                ContentUnavailableView {
                    Text("No Projects")
                } description: {
                    Text("Add a folder to start.")
                } actions: {
                    Button("Add Project…") { app.addProject() }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// A project's name over its rows, with New Session on hover and everything else in a menu.
struct ProjectHeader: View {
    let app: AppState
    let project: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(AppState.projectName(project))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                app.newSession(in: project)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .disabled(!app.connection.isConnected)
            .help("Start omp in \(AppState.projectName(project))")
        }
        .textCase(nil)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project)
        .contextMenu { ProjectMenu(app: app, project: project) }
    }
}

/// What a project offers: New Session, New Terminal, its files, Finder, and Remove once nothing of it is open.
struct ProjectMenu: View {
    let app: AppState
    let project: String

    var body: some View {
        Button("New Session") { app.newSession(in: project) }
            .disabled(!app.connection.isConnected)
        Button("New Terminal") { app.newTerminal(in: project) }
            .disabled(!app.connection.isConnected)
        Button("Show Files") {
            app.filesProject = project
            app.filesVisible = true
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: project, directoryHint: .isDirectory)])
        }
        Divider()
        Button("Remove Project") { app.removeProject(project) }
            .disabled(!app.canRemoveProject(project))
    }
}

/// The one row of a project with nothing running: starts omp there.
private struct StartHereRow: View {
    let app: AppState
    let project: String

    var body: some View {
        Button {
            app.newSession(in: project)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text("Start omp here")
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!app.connection.isConnected)
        .selectionDisabled()
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

/// A session: its state as a dot or spinner, its title, and a status word when something needs the user.
struct SessionRow: View {
    let entry: SessionManifestEntry
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if entry.status.isInProgress {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(color: entry.status.dotColor, hollow: entry.isStopped)
                }
            }
            .frame(width: 14)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(entry.isStopped ? 0.6 : 1)
        .help("\(entry.status.explanation). Last active \(AppState.age(of: entry)); started \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private var trailing: String? {
        switch entry.status {
        case .paused, .interrupted, .needsAttention: entry.status.label
        case .idle, .busy, .closed, .starting, .resuming: nil
        }
    }
}

/// Connection, daemon-notice and daemon-registration problems, above the detail pane.
struct StatusBanners: View {
    let app: AppState

    private var connection: DaemonConnection { app.connection }
    private var agent: DaemonAgent { app.agent }

    var body: some View {
        VStack(spacing: 0) {
            if case .daemonUnavailable(let reason) = connection.status {
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
            if let notice = connection.latestNotice {
                NoticeBar(
                    systemImage: notice.level == "info" ? "info.circle" : "exclamationmark.triangle",
                    tint: notice.level == "error" ? .red : notice.level == "warning" ? .orange : .blue,
                    title: "ompd", message: notice.message
                ) {
                    Button("Dismiss", action: connection.dismissNotices)
                }
            }
            switch agent.state {
            case .requiresApproval:
                NoticeBar(
                    systemImage: "lock.shield", tint: .yellow, title: "Allow omp IDE to run in the background",
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
                    message: "Contents/Library/LaunchAgents/com.omp-ide.ompd.plist was not found in the app bundle. Reinstall omp IDE.")
            case .unknown, .external, .enabled:
                EmptyView()
            }
        }
    }
}

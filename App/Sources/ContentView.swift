import IDEModel
import IDEState
import SwiftUI

/// The window: the project in focus in the sidebar (its files or changes, and the menu that switches
/// projects), its open tabs in the middle. Every session and terminal of a project is one of its tabs.
struct ContentView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            ProjectPanel(app: app)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { app.sidebarWidthChanged($0) }
                // Outermost: the split view reads the column width from the column's root view.
                .navigationSplitViewColumnWidth(min: 220, ideal: app.initialSidebarWidth, max: 480)
        } detail: {
            VStack(spacing: 0) {
                StatusBanners(app: app)
                if let strip = app.currentStrip {
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
        }
        // Not drawn in the compact toolbar; names the window in the Window menu and Mission Control.
        .navigationTitle(windowTitle)
        // Painted, not material: the compact toolbar would otherwise mirror the selected tab's canvas as a block above it.
        .toolbarBackground(Chrome.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // The tabs are the list of sessions and terminals: whatever ompd lists gets one.
        .onChange(of: app.connection.sessions, initial: true) { app.syncTabs() }
        .onChange(of: app.connection.terminals.terminals) { app.syncTabs() }
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

/// What the project in focus offers: New Session, New Terminal, Finder, and Remove once nothing of it is open.
struct ProjectMenu: View {
    let app: AppState
    let project: String

    var body: some View {
        Button("New Session") { app.newSession(in: project) }
            .disabled(!app.connection.isConnected)
        Button("New Terminal") { app.newTerminal(in: project) }
            .disabled(!app.connection.isConnected)
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

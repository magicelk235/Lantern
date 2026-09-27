import IDEModel
import IDEState
import SwiftUI

struct ContentView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            SidebarView(app: app)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { app.sidebarWidthChanged($0) }
                // Outermost: the split view reads the column width from the column's root view.
                .navigationSplitViewColumnWidth(min: 200, ideal: app.initialSidebarWidth, max: 420)
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
        }
        // Not drawn in the compact toolbar; names the window in the Window menu and Mission Control.
        .navigationTitle(windowTitle)
        // Painted, not material: the compact toolbar would otherwise mirror the selected tab's canvas as a block above it.
        .toolbarBackground(Chrome.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // Flexible space: with no title in the compact toolbar, the actions would otherwise sit at the sidebar.
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    app.newTerminal()
                } label: {
                    Label("New Terminal", systemImage: "terminal")
                }
                .help("Open a terminal in the workspace on screen (⌃`)")
                .disabled(!app.connection.isConnected)
                Button {
                    app.newSession()
                } label: {
                    Label("New Session…", systemImage: "plus")
                }
                .help("Start omp in a workspace folder (⌘N)")
                .disabled(!app.connection.isConnected)
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
            case .terminal(let ptyId):
                Button("Close Terminal", role: .destructive) { app.closeTerminal(ptyId) }
            case .forget(let key):
                Button("Remove Session", role: .destructive) { app.forgetSession(key) }
            }
        } message: { request in
            switch request {
            case .session:
                Text("omp exits. The conversation is kept, and Resume starts omp again where it left off.")
            case .terminal:
                Text("The shell and every program running in it are ended.")
            case .forget:
                Text("ompd forgets the session and its tab closes. The conversation file on disk is kept.")
            }
        }
    }

    private var windowTitle: String {
        guard let strip = app.tabs.selectedStrip else { return "omp IDE" }
        let name = URL(filePath: strip.workspace, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? strip.workspace : name
    }

    private var closeTitle: String {
        switch app.pendingClose {
        case .session: "Close this session?"
        case .terminal: "Close this terminal?"
        case .forget: "Remove this session from the list?"
        case nil: ""
        }
    }
}

/// The detail area with no tab on screen.
private struct EmptyDetail: View {
    let app: AppState

    var body: some View {
        ContentUnavailableView {
            Label("No Session Open", systemImage: "terminal")
        } description: {
            Text("Start omp in a workspace folder, or pick a session in the sidebar.")
        } actions: {
            Button("New Session…") { app.newSession() }
                .disabled(!app.connection.isConnected)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
    }
}

struct SidebarView: View {
    @Bindable var app: AppState

    var body: some View {
        let terminals = app.terminals.byWorkspace(among: app.knownWorkspaces)
        let sessionWorkspaces = Set(app.connection.workspaces.map(\.path))
        List(selection: Binding(get: { app.sidebarSelection }, set: { app.selectInSidebar($0) })) {
            ForEach(app.connection.workspaces) { workspace in
                Section {
                    ForEach(workspace.sessions, id: \.sessionKey) { entry in
                        SessionRow(entry: entry, title: app.sessionTitle(entry.sessionKey))
                            .tag(TabKind.session(entry.sessionKey))
                            .contextMenu { SessionMenu(app: app, entry: entry) }
                    }
                    TerminalRows(app: app, terminals: terminals[workspace.path] ?? [])
                    WorkspaceFiles(app: app, workspace: workspace.path)
                } header: {
                    WorkspaceHeader(app: app, path: workspace.path)
                }
            }
            ForEach(terminals.keys.filter { !sessionWorkspaces.contains($0) }.sorted(), id: \.self) { path in
                Section {
                    TerminalRows(app: app, terminals: terminals[path] ?? [])
                    WorkspaceFiles(app: app, workspace: path)
                } header: {
                    WorkspaceHeader(app: app, path: path)
                }
            }
        }
        .listStyle(.sidebar)
        .fileNavigatorActions(app)
    }
}

/// A workspace folder's name over its rows.
struct WorkspaceHeader: View {
    let app: AppState
    let path: String

    var body: some View {
        let name = URL(filePath: path, directoryHint: .isDirectory).lastPathComponent
        Text(name.isEmpty ? path : name)
            .lineLimit(1)
            .help(path)
            .contextMenu {
                Button("New Terminal Here") { app.newTerminal(in: path) }
                    .disabled(!app.connection.isConnected)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path, directoryHint: .isDirectory)])
                }
            }
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
            Button("Close Session…") { app.requestCloseSession(entry.sessionKey) }
                .disabled(!app.connection.isConnected)
        }
    }
}

struct SessionRow: View {
    let entry: SessionManifestEntry
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if entry.status.isInProgress {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(color: entry.status.dotColor, hollow: entry.status == .closed)
                }
            }
            .frame(width: 14)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 6)
            if entry.status != .idle, !entry.status.isInProgress {
                Text(entry.status.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(entry.status == .closed ? 0.6 : 1)
        .help("\(entry.status.explanation). Started \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
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

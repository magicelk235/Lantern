import IDEModel
import IDEState
import SwiftUI

/// A project's window, one native tab of the window group per project: an activity bar on the
/// left (Files, Changes, Projects), the pane it picked next to it (hidden again by clicking the same icon), and the
/// project's open tabs on the right. Every session and terminal of the project is one of its tabs. The window of no
/// project (`project` empty) only offers Add Project.
struct ProjectWindow: View {
    @Bindable var app: AppState
    let project: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar(app: app, project: project)
            Chrome.hairline.frame(width: 1)
            if app.sidebarVisible {
                SidebarPaneView(app: app, project: project)
                    .frame(width: app.sidebarWidth)
                SidebarResizeHandle(app: app)
            }
            VStack(spacing: 0) {
                StatusBanners(app: app)
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
        .background(Chrome.surface)
        .background(WindowAccessor { app.attach($0, project: project) })
        .navigationTitle(project.isEmpty ? "omp IDE" : AppState.projectName(project))
        .toolbarBackground(Chrome.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .task { app.start() }
        // The scene owns opening and closing windows; the model asks through these.
        .onAppear {
            app.openProjectWindow = { openWindow(id: OmpIDEApp.projectWindowID, value: $0) }
            app.closeProjectWindow = { dismissWindow(id: OmpIDEApp.projectWindowID, value: $0) }
        }
        // The tabs are the list of sessions and terminals: whatever ompd lists gets one.
        .onChange(of: app.connection.sessions, initial: true) { app.syncTabs() }
        .onChange(of: app.connection.terminals.terminals) { app.syncTabs() }
        // The no-project window gives way once a project exists.
        .onChange(of: app.projects.isEmpty) { _, empty in
            if project.isEmpty, !empty { dismissWindow(id: OmpIDEApp.projectWindowID, value: "") }
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

    private var closeTitle: String {
        switch app.pendingClose {
        case .session: "Close this session while the agent works?"
        case .forget: "Remove this session from the list?"
        case nil: ""
        }
    }
}

/// The column of icons at the window's left edge: Files, Changes (badged with the count of changed files) and
/// Projects. A click shows the pane; a click on the pane already showing hides the sidebar. Its own look, not an
/// activity bar copied from elsewhere: 16pt outline symbols, the current one on a filled rounded square.
struct ActivityBar: View {
    let app: AppState
    let project: String

    static let width: CGFloat = 44

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarPane.allCases, id: \.self) { pane in
                ActivityButton(
                    pane: pane, isCurrent: app.sidebarVisible && app.pane == pane,
                    badge: pane == .changes ? changeCount : 0
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
                            .background(Color.accentColor, in: Capsule())
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

/// The hairline between the sidebar and the tabs; dragging it resizes the sidebar.
private struct SidebarResizeHandle: View {
    let app: AppState
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
                                if startWidth == nil { startWidth = app.sidebarWidth }
                                app.sidebarWidth = (startWidth ?? app.sidebarWidth) + value.translation.width
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

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
                .navigationSplitViewColumnWidth(min: 220, ideal: app.initialSidebarWidth, max: 420)
        } detail: {
            VStack(spacing: 0) {
                StatusBanners(connection: app.connection, agent: app.agent)
                if let strip = app.tabs.selectedStrip {
                    TabStrip(app: app, strip: strip)
                }
                if let key = app.selectedSession, let model = app.connection.openSessions[key] {
                    SessionDetailView(
                        model: model, savedUI: app.savedUI(for: key),
                        onScrollAnchorChange: { app.scrollAnchorChanged($0, in: model) }, onClose: { app.close(key) }
                    )
                    .id(key)
                } else if let path = app.tabs.selection?.editorPath, let document = app.editors.document(for: path) {
                    EditorView(app: app, document: document)
                        .id(path)
                } else {
                    ContentUnavailableView {
                        Label("No Session", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("Pick a session in the sidebar, or start one in a workspace folder.")
                    } actions: {
                        Button("New Session…") { app.newSession() }
                            .disabled(!app.connection.isConnected)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.newSession()
                } label: {
                    Label("New Session…", systemImage: "plus.bubble")
                }
                .help("Start omp in a workspace folder")
                .disabled(!app.connection.isConnected)
            }
        }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

struct SidebarView: View {
    @Bindable var app: AppState

    var body: some View {
        List(selection: Binding(get: { app.sidebarSelection }, set: { app.selectInSidebar($0) })) {
            ForEach(app.connection.workspaces) { workspace in
                Section {
                    ForEach(workspace.sessions, id: \.sessionKey) { entry in
                        SessionRow(entry: entry)
                            .tag(TabKind.session(entry.sessionKey))
                            .badge(entry.pending.uiRequests.count)
                            .contextMenu {
                                Button("Close Session") { app.close(entry.sessionKey) }
                                    .disabled(entry.closedByUser || entry.status == .closed)
                            }
                    }
                    WorkspaceFiles(app: app, workspace: workspace.path)
                } header: {
                    Label(workspace.name, systemImage: "folder")
                        .help(workspace.path)
                }
            }
        }
        .listStyle(.sidebar)
        .fileNavigatorActions(app)
        .overlay {
            if app.connection.sessions.isEmpty, app.connection.isConnected {
                ContentUnavailableView("No Sessions", systemImage: "tray", description: Text("⌘N starts one."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionFooter(status: app.connection.status)
        }
    }
}

struct SessionRow: View {
    let entry: SessionManifestEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .lineLimit(1)
                Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            SessionStatusBadge(status: entry.status)
        }
        .opacity(entry.closedByUser ? 0.55 : 1)
    }
}

struct SessionStatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .busy || status == .starting || status == .resuming {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var label: String {
        switch status {
        case .starting: "starting"
        case .busy: "working"
        case .settled: "idle"
        case .interrupted: "interrupted"
        case .resuming: "resuming"
        case .closed: "closed"
        case .needsAttention: "attention"
        }
    }

    private var color: Color {
        switch status {
        case .settled: .green
        case .interrupted: .orange
        case .needsAttention: .red
        case .closed, .starting, .busy, .resuming: .secondary
        }
    }

    private var help: String {
        switch status {
        case .starting: "omp is starting"
        case .busy: "The agent is working"
        case .settled: "Nothing is running"
        case .interrupted: "omp stopped unexpectedly; waiting to resume"
        case .resuming: "omp is resuming the session"
        case .closed: "Closed: omp is not running for this session"
        case .needsAttention: "Needs your attention before it can resume"
        }
    }
}

struct ConnectionFooter: View {
    let status: DaemonConnection.Status

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting to ompd…")
            case .connected(let welcome):
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("ompd \(welcome.daemonVersion)")
            case .daemonUnavailable:
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("ompd unavailable")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Connection, daemon-notice and daemon-registration problems, above the detail pane.
struct StatusBanners: View {
    let connection: DaemonConnection
    let agent: DaemonAgent

    var body: some View {
        VStack(spacing: 0) {
            if case .daemonUnavailable(let reason) = connection.status {
                Banner(
                    systemImage: "bolt.horizontal.circle", tint: .orange, title: "ompd is not reachable",
                    message: "\(reason) Retrying automatically; running agents are not affected by this window.")
            }
            if let notice = connection.latestNotice {
                Banner(
                    systemImage: notice.level == "info" ? "info.circle" : "exclamationmark.triangle",
                    tint: notice.level == "error" ? .red : notice.level == "warning" ? .orange : .blue,
                    title: "Message from ompd", message: notice.message, actionTitle: "Dismiss", action: connection.dismissNotices)
            }
            switch agent.state {
            case .requiresApproval:
                Banner(
                    systemImage: "lock.shield", tint: .yellow, title: "Allow omp IDE to run in the background",
                    message: "ompd keeps your agents running while the app is closed. Turn it on in System Settings › General › Login Items.",
                    actionTitle: "Open Login Items", action: agent.openLoginItemsSettings)
            case .failed(let message):
                Banner(
                    systemImage: "exclamationmark.triangle", tint: .red, title: "Could not register ompd",
                    message: message, actionTitle: "Open Login Items", action: agent.openLoginItemsSettings)
            case .notRegistered:
                Banner(
                    systemImage: "exclamationmark.triangle", tint: .orange, title: "ompd is not registered",
                    message: "The background daemon is not set up to run.", actionTitle: "Register", action: agent.registerIfNeeded)
            case .notFound:
                Banner(
                    systemImage: "exclamationmark.triangle", tint: .red, title: "ompd is missing from the app",
                    message: "Contents/Library/LaunchAgents/com.omp-ide.ompd.plist was not found in the app bundle. Reinstall omp IDE.")
            case .unknown, .external, .enabled:
                EmptyView()
            }
        }
    }
}

struct Banner: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                // No vertical fixedSize: in the window's minimum-size pass that reports the text's height at zero
                // width and grows the window past the screen.
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

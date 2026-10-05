import IDEModel
import SwiftUI

/// File › Open Session… (⇧⌘O): the omp sessions saved for a project, newest first, as omp's own resume picker lists
/// them. A search narrows them by title and first message; Return or a double-click opens one: a session ompd runs
/// comes forward in its tab, one ompd keeps stopped resumes, any other starts in the project resuming its file.
struct SessionPicker: View {
    let app: AppState
    let project: String
    /// nil while the files are read.
    @State private var sessions: [SessionFileInfo]?
    @State private var query = ""
    /// The selected session's file.
    @State private var selection: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let running = runningFiles
        let shown = sessions?.filter { $0.matches(query) } ?? []
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open Session in \(AppState.projectName(project))")
                    .font(.headline)
                TextField("Search titles and first messages", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { open(selected(in: shown)) }
                    .onKeyPress(.downArrow) { move(by: 1, in: shown) }
                    .onKeyPress(.upArrow) { move(by: -1, in: shown) }
            }
            .padding(16)
            Divider()
            list(shown, running: running)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Chrome.canvas)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open(selected(in: shown)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOpen(selected(in: shown), running: running))
            }
            .padding(16)
        }
        .frame(width: 560, height: 460)
        .task(id: project) { await load() }
        .onChange(of: query) { keepSelection(in: sessions?.filter { $0.matches(query) } ?? []) }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func list(_ shown: [SessionFileInfo], running: Set<String>) -> some View {
        if sessions == nil {
            ProgressView()
                .controlSize(.small)
        } else if sessions?.isEmpty == true {
            ContentUnavailableView {
                Label("No Saved Sessions", systemImage: "text.bubble")
            } description: {
                Text("omp keeps a session's conversation once the agent answers. Sessions started in \(AppState.projectName(project)) show up here.")
            } actions: {
                Button("New Session") {
                    dismiss()
                    app.newSession(in: project)
                }
                .disabled(!app.connection.isConnected)
            }
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(shown, id: \.path, selection: $selection) { session in
                SessionPickerRow(session: session, isOpen: running.contains(session.path))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 26)
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { paths in
                open(shown.first { paths.contains($0.path) })
            }
        }
    }

    /// Files of the sessions ompd runs (canonical, as the listing's are).
    private var runningFiles: Set<String> {
        Set(app.connection.sessions.filter { !$0.isStopped }.compactMap(\.sessionFile).map(SessionFileListing.canonicalPath))
    }

    private func selected(in shown: [SessionFileInfo]) -> SessionFileInfo? {
        shown.first { $0.path == selection }
    }

    /// A running session's tab comes forward even while ompd is out of reach; anything else needs ompd.
    private func canOpen(_ session: SessionFileInfo?, running: Set<String>) -> Bool {
        guard let session else { return false }
        return running.contains(session.path) || app.connection.isConnected
    }

    private func open(_ session: SessionFileInfo?) {
        guard let session, canOpen(session, running: runningFiles) else { return }
        dismiss()
        app.openSessionFile(session.path, in: project)
    }

    private func move(by step: Int, in shown: [SessionFileInfo]) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        let current = shown.firstIndex { $0.path == selection } ?? (step > 0 ? -1 : shown.count)
        selection = shown[min(max(current + step, 0), shown.count - 1)].path
        return .handled
    }

    /// The selection stays while it is shown; otherwise the first match is selected.
    private func keepSelection(in shown: [SessionFileInfo]) {
        if !shown.contains(where: { $0.path == selection }) { selection = shown.first?.path }
    }

    private func load() async {
        let listed = await app.sessionFiles(of: project)
        sessions = listed
        keepSelection(in: listed.filter { $0.matches(query) })
    }
}

/// A saved session: its title, then trailing what ompd or the file's end says about it, and when it last changed.
private struct SessionPickerRow: View {
    let session: SessionFileInfo
    /// ompd runs the session.
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(session.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Group {
                if isOpen {
                    badge("Open", dot: .green)
                } else if let word = session.status.word {
                    badge(word, dot: session.status.dotColor, hollow: session.status == .aborted)
                }
                Text(session.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .help(session.firstMessage.map { "\($0.prefix(300))" } ?? session.displayTitle)
    }

    private func badge(_ word: String, dot: Color, hollow: Bool = false) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: dot, hollow: hollow)
            Text(word)
        }
    }
}

extension SessionFileInfo.Status {
    /// The word a row shows; nil when the conversation ended normally or its end says nothing.
    var word: String? {
        switch self {
        case .interrupted: "Interrupted"
        case .aborted: "Aborted"
        case .error: "Error"
        case .pending: "Pending"
        case .complete, .unknown: nil
        }
    }

    var dotColor: Color {
        switch self {
        case .interrupted, .pending: .orange
        case .error: .red
        case .aborted, .complete, .unknown: .secondary
        }
    }
}

extension AppState {
    /// File › Open Session…: the sheet over `project`'s window, which comes forward.
    func showSessionPicker(for project: String) {
        sessionPickerProject = project
        showProject(project)
    }

    /// The omp session files of `project`, newest first (`SessionFileListing`, read off the main actor).
    func sessionFiles(of project: String) async -> [SessionFileInfo] {
        // `--session-dir` folders ompd starts omp with (the launch spec's, or one passed through its extra arguments)
        // hold sessions of every workspace; the folders of the session files ompd knows find them either way. The
        // listing keeps this workspace's.
        let sessionDirectories = Set(
            connection.sessions.compactMap(\.launch.sessionDir)
                + connection.sessions.compactMap { $0.sessionFile.map { ($0 as NSString).deletingLastPathComponent } }
        ).map { URL(filePath: $0, directoryHint: .isDirectory) }
        return await SessionFileListing.list(
            workspace: URL(filePath: project, directoryHint: .isDirectory), sessionDirectories: sessionDirectories)
    }
}

extension View {
    /// Presents the Open Session sheet while it is up for `project` (this window's).
    func sessionPicker(_ app: AppState, project: String) -> some View {
        sheet(isPresented: Binding(
            get: { !project.isEmpty && app.sessionPickerProject == project },
            set: { if !$0 { app.sessionPickerProject = nil } }
        )) {
            SessionPicker(app: app, project: project)
        }
    }
}

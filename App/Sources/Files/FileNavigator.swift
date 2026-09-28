import AppKit
import IDEEditorModel
import IDEState
import SwiftUI

/// What the activity bar can show in the sidebar. The last choice is kept in the defaults.
enum SidebarPane: String, CaseIterable {
    case files
    case changes
    case projects

    static let defaultsKey = "sidebarPane"

    var title: String {
        switch self {
        case .files: "Files"
        case .changes: "Source Control"
        case .projects: "Projects"
        }
    }

    var symbol: String {
        switch self {
        case .files: "list.bullet.indent"
        case .changes: "point.3.connected.trianglepath.dotted"
        case .projects: "square.stack.3d.up"
        }
    }

    /// As shown in tooltips; the shortcuts live in `OmpIDEApp`'s View menu.
    var shortcut: String {
        switch self {
        case .files: "⇧⌘E"
        case .changes: "⌃⌘G"
        case .projects: "⇧⌘P"
        }
    }
}

/// The sidebar pane the activity bar picked: the project in focus (its title is the menu that switches projects and
/// adds one) with its files or its git changes, or the list of projects.
struct SidebarPaneView: View {
    @Bindable var app: AppState
    /// The window's project; empty for the window of no project.
    let project: String

    var body: some View {
        VStack(spacing: 0) {
            switch app.pane {
            case .files:
                if !project.isEmpty {
                    ProjectHeader(app: app, project: project)
                    Divider()
                    FilesOutline(app: app, project: project)
                } else {
                    noProject
                }
            case .changes:
                if !project.isEmpty {
                    ProjectHeader(app: app, project: project)
                    Divider()
                    SourceControlPanel(app: app, repository: app.editors.repositories.repository(for: project))
                        .id(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    noProject
                }
            case .projects:
                ProjectsPane(app: app, project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Chrome.surface)
    }

    private var noProject: some View {
        ContentUnavailableView {
            Text("No Project")
        } description: {
            Text("Add a folder to start omp in it, open terminals, and browse its files.")
        } actions: {
            Button("Add Project…") { app.addProject() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The project's name as the switcher (the projects, Add Project, then what this project offers), and + for a new
/// session.
struct ProjectHeader: View {
    let app: AppState
    let project: String

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(app.projects, id: \.self) { candidate in
                    Toggle(AppState.projectName(candidate), isOn: Binding(
                        get: { candidate == project }, set: { if $0 { app.showProject(candidate) } }))
                }
                Divider()
                Button("Add Project…") { app.addProject() }
                Divider()
                ProjectMenu(app: app, project: project)
            } label: {
                Text(AppState.projectName(project))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(project)
            Spacer(minLength: 4)
            Button {
                app.newSession(in: project)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!app.connection.isConnected)
            .help("Start omp in \(AppState.projectName(project)) (⌘N)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// The project's folder as an outline, each folder listed when first expanded. A click highlights a file; Return or
/// a double-click opens it in the project's tab strip.
private struct FilesOutline: View {
    let app: AppState
    let project: String

    var body: some View {
        let tree = app.editors.tree(for: project)
        List(selection: Binding(get: { app.filesSelection }, set: { app.selectInFiles($0) })) {
            FileRows(app: app, tree: tree, folder: tree.root)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
        .fileNavigatorActions(app)
        .task(id: project) { tree.setExpanded(tree.root, true) }
    }
}

/// The projects, this window's marked; a click brings a project's window forward.
private struct ProjectsPane: View {
    let app: AppState
    let project: String

    var body: some View {
        HStack {
            Text("Projects")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                app.addProject()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a project folder (⌘O)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        Divider()
        List(selection: Binding(get: { project.isEmpty ? nil : project }, set: { if let chosen = $0 { app.showProject(chosen) } })) {
            ForEach(app.projects, id: \.self) { candidate in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(AppState.projectName(candidate))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(candidate)
                .listRowSeparator(.hidden)
                .help(candidate)
                .contextMenu { ProjectMenu(app: app, project: candidate) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
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

extension View {
    /// Return and double-click open the files selected in the Files panel; right-click offers Open and Reveal in
    /// Finder for them.
    func fileNavigatorActions(_ app: AppState) -> some View {
        modifier(FileNavigatorActions(app: app))
    }
}

private struct FileNavigatorActions: ViewModifier {
    let app: AppState
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .contextMenu(forSelectionType: TabKind.self) { items in
                let paths = items.compactMap(\.editorPath).sorted()
                if !paths.isEmpty {
                    Button("Open") { app.openFromFiles(items) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
                    }
                }
            } primaryAction: { items in
                app.openFromFiles(items)
            }
            // A click on a file only highlights it: the list takes the keyboard so that Return opens it.
            .onChange(of: app.editors.highlight) { _, highlight in
                if highlight != nil { focused = true }
            }
    }
}

extension AppState {
    /// The file row to highlight: a file clicked once (until another tab shows), else the editor tab on screen.
    var filesSelection: TabKind? {
        if let highlight = editors.highlight, highlight.over == selectedTab { return .editor(path: highlight.path) }
        return selectedTab?.editorPath.map { .editor(path: $0) }
    }

    /// A click on a file only highlights it; Return or a double-click opens it.
    func selectInFiles(_ tab: TabKind?) {
        guard case .editor(let path) = tab else { return }
        editors.highlight = Editors.Highlight(path: path, over: selectedTab)
    }

    /// Return or a double-click in the Files panel: opens the files among `items` in their project's strip.
    func openFromFiles(_ items: Set<TabKind>) {
        for path in items.compactMap(\.editorPath).sorted() {
            guard let workspace = editors.workspace(containing: path) ?? currentProject else { continue }
            openEditor(path, in: workspace)
        }
    }
}

@MainActor
private func expansion(of folder: String, in tree: FileTree) -> Binding<Bool> {
    Binding(get: { tree.isExpanded(folder) }, set: { tree.setExpanded(folder, $0) })
}

/// The entries of one folder; subfolders nest their own rows.
private struct FileRows: View {
    let app: AppState
    let tree: FileTree
    let folder: String

    var body: some View {
        if let failure = tree.failures[folder] {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(tree.children[folder] ?? []) { entry in
            if entry.isDirectory {
                DisclosureGroup(isExpanded: expansion(of: entry.path, in: tree)) {
                    FileRows(app: app, tree: tree, folder: entry.path)
                } label: {
                    FileRow(name: entry.name, path: entry.path, isDirectory: true, isIgnored: tree.isIgnored(entry.path), isDirty: false)
                        .contentShape(Rectangle())
                        .onTapGesture { tree.setExpanded(entry.path, !tree.isExpanded(entry.path)) }
                }
                .listRowSeparator(.hidden)
            } else {
                FileRow(
                    name: entry.name, path: entry.path, isDirectory: false, isIgnored: tree.isIgnored(entry.path),
                    isDirty: app.editors.document(for: entry.path)?.isDirty ?? false
                )
                .tag(TabKind.editor(path: entry.path))
                .listRowSeparator(.hidden)
            }
        }
    }
}

private struct FileRow: View {
    let name: String
    let path: String
    let isDirectory: Bool
    /// Git ignores it: dimmed.
    let isIgnored: Bool
    /// Open with unsaved edits.
    let isDirty: Bool
    /// The folder, for find results.
    var detail: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if isDirty {
                Spacer(minLength: 4)
                Circle()
                    .fill(.primary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        .opacity(isIgnored ? 0.5 : 1)
        .help(path)
        .accessibilityLabel(name + (isDirty ? ", edited" : ""))
    }

    private var symbol: String { FileSymbol.name(for: name, isDirectory: isDirectory) }
}

/// The navigator's icon for a file, by extension; folders are folders.
enum FileSymbol {
    static func name(for fileName: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf": return "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "pdf", "icns": return "photo"
        case "sh", "zsh", "bash", "fish": return "terminal"
        default: return "doc.text"
        }
    }
}

import AppKit
import IDEEditorModel
import IDEState
import SwiftUI

/// What the activity bar can show in the sidebar. The last choice is kept in the defaults.
enum SidebarPane: String, CaseIterable {
    case files
    case changes
    case agents
    case projects

    static let defaultsKey = "sidebarPane"

    var title: String {
        switch self {
        case .files: "Files"
        case .changes: "Source Control"
        case .agents: "Agents"
        case .projects: "Projects"
        }
    }

    var symbol: String {
        switch self {
        case .files: "list.bullet.indent"
        case .changes: "point.3.connected.trianglepath.dotted"
        case .agents: "person.2"
        case .projects: "square.stack.3d.up"
        }
    }

    /// As shown in tooltips; the shortcuts live in `LanternApp`'s View menu.
    var shortcut: String {
        switch self {
        case .files: "⇧⌘E"
        case .changes: "⌃⌘G"
        case .agents: "⌃⌘A"
        case .projects: "⇧⌘P"
        }
    }
}

/// The sidebar pane the activity bar picked: the project in focus (its title is the menu that switches projects and
/// adds one) with its files, its git changes or what omp runs in it, or the list of projects. The window of no
/// project shows nothing here but the list of projects: its detail area offers Add Project.
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
                }
            case .changes:
                if !project.isEmpty {
                    ProjectHeader(app: app, project: project)
                    Divider()
                    SourceControlPanel(app: app, repository: app.editors.repositories.repository(for: project))
                        .id(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .agents:
                if !project.isEmpty {
                    ProjectHeader(app: app, project: project)
                    Divider()
                    AgentsPane(app: app, project: project)
                        .id(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .projects:
                ProjectsPane(app: app, project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Chrome.surface)
    }
}

/// The project's name as the switcher (the projects, Add Project, then what this project offers), and + with what
/// can be added to the project: a file or folder at its top level, a session or a terminal.
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
                HStack(spacing: 4) {
                    Text(AppState.projectName(project))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MenuChevron()
                }
            }
            .paneHeaderMenu()
            .help(project)
            Spacer(minLength: 4)
            Menu {
                Button("New File…") { app.newFile(in: project, project: project) }
                Button("New Folder…") { app.newFolder(in: project) }
                Divider()
                Button("New Session") { app.newSession(in: project) }
                    .disabled(!app.connection.isConnected)
                Button("New Terminal") { app.newTerminal(in: project) }
                    .disabled(!app.connection.isConnected)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("New File, Folder, Session or Terminal in \(AppState.projectName(project))")
            .accessibilityLabel("New File, Folder, Session or Terminal")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// The pull-down chevron after a pane header's menu title.
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// A pane header's title menu (the project switcher, the branch menu): its label is drawn as given, so a long title
    /// truncates in the middle (a borderless pop-up button cuts its own title at the end), and it is never wider than
    /// its title nor than the room the header leaves it.
    func paneHeaderMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }
}

/// The project's folder as an outline, each folder listed when first expanded. A click highlights a file; Return or
/// a double-click opens it in the project's tab strip; Space shows it in Quick Look. The row a context menu is open
/// for is ringed, as in Finder, while the highlight stays where it was.
private struct FilesOutline: View {
    let app: AppState
    let project: String
    /// The row whose context menu is open.
    @State private var menuTarget: String?

    var body: some View {
        let tree = app.editors.tree(for: project)
        let marks = GitMarks(repository: app.editors.repositories.repository(for: project), root: project)
        List(selection: Binding(get: { app.filesSelection }, set: { app.selectInFiles($0) })) {
            FileRows(app: app, tree: tree, folder: tree.root, marks: marks, menuTarget: menuTarget)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
        .fileNavigatorActions(app, project: project)
        .onKeyPress(.space) {
            guard let path = app.filesSelection?.editorPath else { return .ignored }
            app.toggleQuickLook(path, in: project)
            return .handled
        }
        // A right-click (or Control-click) opens a context menu for the row under it, wherever the pointer was before.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                  let path = FileRowMarker.row(at: event)?.path, path.hasPrefix(project + "/")
            else { return }
            menuTarget = path
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            if menuTarget != nil { menuTarget = nil }
        }
        .task(id: project) { tree.setExpanded(tree.root, true) }
    }
}

/// Marks a Files row in AppKit's view tree, so that the row under a click is found from where the click was: the row
/// a context menu opens for, the row clicked in a window that is not key.
private struct FileRowMarker: NSViewRepresentable {
    let path: String

    final class Marker: NSView {
        var path = ""

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Marker {
        let marker = Marker()
        marker.path = path
        return marker
    }

    func updateNSView(_ marker: Marker, context: Context) {
        marker.path = path
    }

    /// The Files row under `event`'s location and the outline it is a row of.
    @MainActor
    static func row(at event: NSEvent) -> (path: String, outline: NSTableView)? {
        guard let content = event.window?.contentView else { return nil }
        var view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        while let current = view, !(current is NSTableRowView) { view = current.superview }
        guard let row = view, let outline = row.superview as? NSTableView, let marker = marker(in: row) else { return nil }
        return (marker.path, outline)
    }

    @MainActor
    private static func marker(in view: NSView) -> Marker? {
        if let marker = view as? Marker { return marker }
        for subview in view.subviews {
            if let marker = marker(in: subview) { return marker }
        }
        return nil
    }
}

/// Finder's ring around the row a context menu is open for.
private struct MenuTargetRing: View {
    let isShown: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(.horizontal, 10)
            .opacity(isShown ? 1 : 0)
    }
}

/// The projects, this window's marked, each with what waits on the user in its sessions; a click brings a project's
/// window forward.
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
                    Spacer(minLength: 4)
                    let waiting = app.attentionCount(in: candidate)
                    if waiting > 0 {
                        Text(waiting > 99 ? "99+" : String(waiting))
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                            .help(waiting == 1 ? "An approval or question waits for you" : "\(waiting) approvals or questions wait for you")
                    }
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
            // The window of no project: its detail area offers Add Project.
            if app.projects.isEmpty {
                Text("No Projects")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// Return and double-click open the files selected in the Files pane; right-click offers `FileItemMenu` for one
    /// file (Open and Reveal in Finder for several), and the project folder's own menu on the empty area.
    func fileNavigatorActions(_ app: AppState, project: String) -> some View {
        modifier(FileNavigatorActions(app: app, project: project))
    }
}

private struct FileNavigatorActions: ViewModifier {
    let app: AppState
    let project: String
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .contextMenu(forSelectionType: TabKind.self) { items in
                let paths = items.compactMap(\.editorPath).sorted()
                if paths.count == 1, let path = paths.first {
                    FileItemMenu(app: app, project: project, path: path, isDirectory: false)
                } else if !paths.isEmpty {
                    Button("Open") { app.openFromFiles(items) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
                    }
                } else {
                    FileItemMenu(app: app, project: project, path: project, isDirectory: true)
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

    /// A click on a Files row of a window that is not key acts on the row at once, as in Finder: the first click of a
    /// double-click that brings the window forward opens the file with the second. AppKit hands that click to the view
    /// under it only when the view takes the first mouse, and a list row's SwiftUI cell never does: the click only
    /// made the window key, and the second click of the double-click arrived as the row's first. Here the window
    /// becomes key first and gets the click as any other. Installed once at launch.
    func installFilesFirstMouse() {
        LocalEventMonitors.add(matching: .leftMouseDown) { event in
            guard let window = event.window, !window.isKeyWindow, window.canBecomeKey,
                  FileRowMarker.row(at: event) != nil
            else { return event }
            window.makeKeyAndOrderFront(nil)
            guard window.isKeyWindow else { return event }
            window.sendEvent(event)
            return nil
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
    let marks: GitMarks
    let menuTarget: String?

    var body: some View {
        if let failure = tree.failures[folder] {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(tree.children[folder] ?? []) { entry in
            if entry.isDirectory {
                DisclosureGroup(isExpanded: expansion(of: entry.path, in: tree)) {
                    FileRows(app: app, tree: tree, folder: entry.path, marks: marks, menuTarget: menuTarget)
                } label: {
                    FileRow(
                        name: entry.name, path: entry.path, isDirectory: true, isIgnored: tree.isIgnored(entry.path), isDirty: false,
                        mark: marks.folders[entry.path])
                        .onTapGesture { tree.setExpanded(entry.path, !tree.isExpanded(entry.path)) }
                        .contextMenu { FileItemMenu(app: app, project: tree.root, path: entry.path, isDirectory: true) }
                        .listRowBackground(MenuTargetRing(isShown: menuTarget == entry.path))
                }
                .listRowSeparator(.hidden)
            } else {
                FileRow(
                    name: entry.name, path: entry.path, isDirectory: false, isIgnored: tree.isIgnored(entry.path),
                    isDirty: app.editors.document(for: entry.path)?.isDirty ?? false, mark: marks.files[entry.path]
                )
                .tag(TabKind.editor(path: entry.path))
                .listRowSeparator(.hidden)
                .listRowBackground(MenuTargetRing(isShown: menuTarget == entry.path))
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
    /// What git says about it (or about something inside it).
    var mark: GitMarks.Mark?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(mark.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary))
            if isDirty {
                Circle()
                    .fill(.primary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            if let mark, !isDirectory {
                Spacer(minLength: 4)
                Text(mark.letter)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(mark.color)
                    .help(mark.explanation)
            }
        }
        // The whole row: a click anywhere on it is on it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(FileRowMarker(path: path))
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

/// What git says about the files of a project, for the Files pane, with the Changes list's letters: untracked files
/// (U) and staged additions (A) in green, changed ones (M) in yellow; a folder carries the color of what it holds
/// (changed wins).
@MainActor
struct GitMarks {
    enum Mark {
        case untracked, added, modified

        var color: Color {
            switch self {
            case .untracked, .added: Chrome.gitAdded
            case .modified: Chrome.gitModified
            }
        }

        var letter: String {
            switch self {
            case .untracked: "U"
            case .added: "A"
            case .modified: "M"
            }
        }

        var explanation: String {
            switch self {
            case .untracked: "Untracked: not in the repository yet"
            case .added: "Added to the repository, staged"
            case .modified: "Changed since the last commit"
            }
        }
    }

    private(set) var files: [String: Mark] = [:]
    private(set) var folders: [String: Mark] = [:]

    init(repository: GitRepository, root: String) {
        guard repository.isRepository else { return }
        for change in repository.changes {
            let mark: Mark = change.isUntracked ? .untracked : change.staged == "A" ? .added : .modified
            files[change.path] = mark
            var folder = (change.path as NSString).deletingLastPathComponent
            while folder.hasPrefix(root), folder != root {
                if folders[folder] != .modified { folders[folder] = mark }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
    }
}

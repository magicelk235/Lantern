import AppKit
import IDEEditorModel
import IDEState
import SwiftUI

/// The trailing panel's two sides: the project's files, or its git changes (`SourceControlPanel`). The choice is
/// remembered in the defaults.
enum FilesPanelTab: String, CaseIterable {
    case files
    case changes

    static let defaultsKey = "filesPanelTab"

    /// Puts `tab` on screen: what the panel's `@AppStorage` reads.
    static func select(_ tab: FilesPanelTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: defaultsKey)
    }
}

/// The sidebar: the project in focus, named by a menu that switches projects and adds one; below it, the project's
/// folder as an outline (each folder listed when first expanded) or, on its Changes side, its git changes. A click
/// highlights a file; Return or a double-click opens it in the project's tab strip.
struct ProjectPanel: View {
    @Bindable var app: AppState
    @AppStorage(FilesPanelTab.defaultsKey) private var tab = FilesPanelTab.files

    var body: some View {
        VStack(spacing: 0) {
            if let project = app.currentProject {
                header(project)
                Picker("Panel", selection: $tab) {
                    Text("Files").tag(FilesPanelTab.files)
                    Text("Changes").tag(FilesPanelTab.changes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                Divider()
                switch tab {
                case .files:
                    files(project)
                case .changes:
                    SourceControlPanel(app: app, repository: app.editors.repositories.repository(for: project))
                        .id(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Text("No Project")
                } description: {
                    Text("Add a folder to start omp in it, open terminals, and browse its files.")
                } actions: {
                    Button("Add Project…") { app.addProject() }
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The project's folder as an outline.
    private func files(_ project: String) -> some View {
        let tree = app.editors.tree(for: project)
        return List(selection: Binding(get: { app.filesSelection }, set: { app.selectInFiles($0) })) {
            FileRows(app: app, tree: tree, folder: tree.root)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
        .fileNavigatorActions(app)
        .task(id: project) { tree.setExpanded(tree.root, true) }
    }

    /// The project's name as the switcher: the projects, Add Project, then what this project offers.
    private func header(_ project: String) -> some View {
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
        if let highlight = editors.highlight, highlight.over == tabs.selection { return .editor(path: highlight.path) }
        return tabs.selection?.editorPath.map { .editor(path: $0) }
    }

    /// A click on a file only highlights it; Return or a double-click opens it.
    func selectInFiles(_ tab: TabKind?) {
        guard case .editor(let path) = tab else { return }
        editors.highlight = Editors.Highlight(path: path, over: tabs.selection)
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
            } else {
                FileRow(
                    name: entry.name, path: entry.path, isDirectory: false, isIgnored: tree.isIgnored(entry.path),
                    isDirty: app.editors.document(for: entry.path)?.isDirty ?? false
                )
                .tag(TabKind.editor(path: entry.path))
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

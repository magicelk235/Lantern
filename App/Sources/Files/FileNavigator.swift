import AppKit
import IDEEditorModel
import IDEState
import SwiftUI

/// The Files panel, trailing the detail area: one project's folder as an outline, each folder listed when first
/// expanded. A click highlights a file; Return or a double-click opens it in the project's tab strip.
struct FilesPanel: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let project = app.filesProject {
                header(project)
                Divider()
                let tree = app.editors.tree(for: project)
                List(selection: Binding(get: { app.filesSelection }, set: { app.selectInFiles($0) })) {
                    FileRows(app: app, tree: tree, folder: tree.root)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 22)
                .fileNavigatorActions(app)
                .task(id: project) { tree.setExpanded(tree.root, true) }
            } else {
                ContentUnavailableView {
                    Text("No Project")
                } description: {
                    Text("Add a project to browse its files.")
                } actions: {
                    Button("Add Project…") { app.addProject() }
                        .controlSize(.small)
                }
            }
        }
        .background(Chrome.surface)
    }

    /// The project's name; a menu of the projects when there are several, and Finder.
    private func header(_ project: String) -> some View {
        HStack(spacing: 6) {
            if app.projects.count > 1 {
                Menu {
                    ForEach(app.projects, id: \.self) { candidate in
                        Button(AppState.projectName(candidate)) { app.filesProject = candidate }
                    }
                } label: {
                    Text(AppState.projectName(project))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(AppState.projectName(project))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: project, directoryHint: .isDirectory)])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .help(project)
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
            guard let workspace = editors.workspace(containing: path) ?? filesProject else { continue }
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

    private var symbol: String {
        if isDirectory { return "folder" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf": return "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "pdf", "icns": return "photo"
        case "sh", "zsh", "bash", "fish": return "terminal"
        default: return "doc.text"
        }
    }
}

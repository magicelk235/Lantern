import AppKit
import IDEEditorModel
import IDEState
import SwiftUI

/// The "Files" row of a workspace in the sidebar: the folder's outline, each folder listed when first expanded. A
/// click highlights a file; Return or a double-click opens it in the workspace's tab strip.
struct WorkspaceFiles: View {
    let app: AppState
    let workspace: String

    var body: some View {
        let tree = app.editors.tree(for: workspace)
        DisclosureGroup(isExpanded: expansion(of: tree.root, in: tree)) {
            FileRows(app: app, tree: tree, folder: tree.root)
        } label: {
            Label("Files", systemImage: "folder")
                .contentShape(Rectangle())
                .onTapGesture { tree.setExpanded(tree.root, !tree.isExpanded(tree.root)) }
        }
    }
}

extension View {
    /// Return and double-click open the files selected in the sidebar list; right-click offers Open and Reveal in
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
                    Button("Open") { app.openFromSidebar(items) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
                    }
                }
            } primaryAction: { items in
                app.openFromSidebar(items)
            }
            // A click on a file only highlights it: the list takes the keyboard (from the composer, say) so that
            // Return opens it.
            .onChange(of: app.editors.highlight) { _, highlight in
                if highlight != nil { focused = true }
            }
    }
}

extension AppState {
    /// The sidebar row to highlight: a file clicked once in the navigator (until another tab shows), else the tab on
    /// screen.
    var sidebarSelection: TabKind? {
        if let highlight = editors.highlight, highlight.over == tabs.selection { return .editor(path: highlight.path) }
        return tabs.selection
    }

    /// A click in the sidebar: a session shows at once; a file is only highlighted, Return or a double-click opens it.
    func selectInSidebar(_ tab: TabKind?) {
        guard let tab else { return }
        switch tab {
        case .editor(let path):
            editors.highlight = Editors.Highlight(path: path, over: tabs.selection)
        case .session(let key):
            editors.highlight = nil
            showSession(key)
        }
    }

    /// Return or a double-click in the sidebar: opens the files among `items` in their workspace's strip.
    func openFromSidebar(_ items: Set<TabKind>) {
        for path in items.compactMap(\.editorPath).sorted() {
            guard let workspace = editors.workspace(containing: path) else { continue }
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
                    FileRow(entry: entry, isIgnored: tree.isIgnored(entry.path), isDirty: false)
                        .contentShape(Rectangle())
                        .onTapGesture { tree.setExpanded(entry.path, !tree.isExpanded(entry.path)) }
                }
            } else {
                FileRow(
                    entry: entry, isIgnored: tree.isIgnored(entry.path),
                    isDirty: app.editors.document(for: entry.path)?.isDirty ?? false
                )
                .tag(TabKind.editor(path: entry.path))
            }
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    /// Git ignores it: dimmed.
    let isIgnored: Bool
    /// Open with unsaved edits.
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 4) {
            Label(entry.name, systemImage: symbol)
                .lineLimit(1)
                .truncationMode(.middle)
            if isDirty {
                Spacer(minLength: 4)
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        .opacity(isIgnored ? 0.5 : 1)
        .help(entry.path)
        .accessibilityLabel(entry.name + (isDirty ? ", edited" : ""))
    }

    private var symbol: String {
        if entry.isDirectory { return "folder" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf": return "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "pdf", "icns": return "photo"
        case "sh", "zsh", "bash", "fish": return "terminal"
        default: return "doc.text"
        }
    }
}

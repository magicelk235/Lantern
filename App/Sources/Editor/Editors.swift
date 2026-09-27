import AppKit
import IDEEditorModel
import IDEState

/// Every open editor document and file navigator of the window, and the FSEvents watchers (one per workspace folder)
/// that keep them in step with the disk — the agent edits files too.
@MainActor @Observable
final class Editors {
    /// A file row clicked once in the navigator, over the tab that was on screen then: it stays highlighted until the
    /// user opens it or another tab shows.
    struct Highlight: Equatable {
        var path: String
        var over: TabKind?
    }

    private(set) var documents: [String: EditorDocument] = [:]
    var highlight: Highlight?
    /// The git repository of each project folder, refreshed when FSEvents reports changes under it.
    let repositories = GitRepositories()

    @ObservationIgnored private let persistence: StatePersistence
    /// Hot-exit copies from the previous run not claimed by an open document yet.
    @ObservationIgnored private var restoredBuffers: [String: DirtyBuffer]
    @ObservationIgnored private var trees: [String: FileTree] = [:]
    @ObservationIgnored private var watchers: [String: FileSystemWatcher] = [:]
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    init(persistence: StatePersistence) {
        self.persistence = persistence
        restoredBuffers = persistence.restoredDirtyBuffers
        // Editor themes are made for one appearance (`EditorStyle`).
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] application, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for document in self.documents.values { document.appearanceDidChange(application.effectiveAppearance) }
            }
        }
    }

    func document(for path: String) -> EditorDocument? {
        documents[path]
    }

    /// The document of `path`, opened (from its hot-exit copy if the previous run left one) if it is not yet.
    @discardableResult
    func open(_ path: String, in workspace: String) -> EditorDocument {
        if let document = documents[path] { return document }
        let document = EditorDocument(
            path: path, workspace: workspace, restored: restoredBuffers.removeValue(forKey: path),
            savedUI: persistence.editorUI[path], persistence: persistence)
        documents[path] = document
        watch(Self.watchRoot(for: path, in: workspace))
        return document
    }

    /// Unsaved buffers of the previous run whose tab did not come back (a lost window layout, say), with the folder
    /// whose strip should show each: the deepest of `workspaces` holding it, else its own folder.
    func unclaimedBuffers(workspaces: [String]) -> [(path: String, workspace: String)] {
        restoredBuffers.keys.sorted().map { path in
            let workspace = workspaces.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            return (path, workspace ?? (path as NSString).deletingLastPathComponent)
        }
    }

    /// Whether the tab of `path` may close: without unsaved edits it may; else the user picks Save, Don't Save or
    /// Cancel in a sheet on `window`. The document is closed when the answer is yes.
    func closeIfConfirmed(_ path: String, window: NSWindow?) async -> Bool {
        guard let document = documents[path] else { return true }
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes you made to “\(document.name)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            let dontSave = alert.addButton(withTitle: "Don’t Save")
            dontSave.keyEquivalent = "d"
            dontSave.keyEquivalentModifierMask = .command
            alert.addButton(withTitle: "Cancel")
            let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    try document.save()
                } catch {
                    let failure = NSAlert()
                    failure.messageText = "“\(document.name)” could not be saved."
                    failure.informativeText = String(describing: error)
                    _ = if let window { await failure.beginSheetModal(for: window) } else { failure.runModal() }
                    return false
                }
            case .alertSecondButtonReturn:
                document.clearHotExit()
            default:
                return false
            }
        }
        document.close()
        documents[path] = nil
        if highlight?.path == path { highlight = nil }
        return true
    }

    /// The navigator of `workspace`; it lists and watches the folder once expanded.
    func tree(for workspace: String) -> FileTree {
        if let tree = trees[workspace] { return tree }
        let tree = FileTree(root: workspace) { [weak self] in self?.watch(workspace) }
        trees[workspace] = tree
        return tree
    }

    /// The workspace of the deepest navigator that shows `path`.
    func workspace(containing path: String) -> String? {
        trees.keys.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    /// Writes every hot-exit copy still waiting for typing to pause (quit, resign key, sleep).
    func flush() {
        for document in documents.values where document.hotExitPending {
            document.writeHotExit()
        }
    }

    // MARK: - Watching

    /// The workspace folder, or for a file outside it (an orphaned hot-exit copy) its own folder.
    private static func watchRoot(for path: String, in workspace: String) -> String {
        path.hasPrefix(workspace + "/") ? workspace : (path as NSString).deletingLastPathComponent
    }

    /// Watches `root` if it is not yet: FSEvents changes under it reach its navigator, its documents and its git
    /// repository. The navigator and each opened document ask for their folder; the Changes panel asks for its project.
    func watch(_ root: String) {
        guard watchers[root] == nil else { return }
        let watcher = FileSystemWatcher(root: root) { [weak self] changes in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.filesChanged(changes, under: root) }
            }
        }
        if let watcher { watchers[root] = watcher }
    }

    private func filesChanged(_ changes: [FileSystemWatcher.Change], under root: String) {
        trees[root]?.filesChanged(changes)
        for document in documents.values where document.path.hasPrefix(root + "/") {
            let affected = changes.contains { change in
                change.mustRescan || change.path == document.path || document.path.hasPrefix(change.path + "/")
            }
            if affected { document.checkDisk() }
        }
        repositories.filesChanged(under: root)
    }
}

import AppKit
import CodeEditTextView
import IDEEditorModel
import IDEProtocol
import IDEState

/// Every open editor document and file navigator of the window, the FSEvents watchers (one per workspace folder) that
/// keep them in step with the disk — the agent edits files too — and the language servers of their files.
@MainActor @Observable
final class Editors {
    private(set) var documents: [String: EditorDocument] = [:]
    /// The git repository of each project folder, refreshed when FSEvents reports changes under it.
    let repositories = GitRepositories()
    /// One per project folder and language, for as long as an editor of it is open.
    let languageServers = LanguageServers()

    @ObservationIgnored private let persistence: StatePersistence
    /// Hot-exit copies from the previous run not claimed by an open document yet.
    @ObservationIgnored private var restoredBuffers: [String: DirtyBuffer]
    @ObservationIgnored private var trees: [String: FileTree] = [:]
    @ObservationIgnored private var watchers: [String: FileSystemWatcher] = [:]
    /// Project folders being renamed (`holdFolder`): FSEvents under them waits until the rename is over.
    @ObservationIgnored private var heldFolders: Set<String> = []
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var fontSize = EditorSettings.fontSize
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

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
        // View › Bigger, Smaller and Actual Size: every editor gets a configuration in the new size.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, EditorSettings.fontSize != self.fontSize else { return }
                self.fontSize = EditorSettings.fontSize
                for document in self.documents.values { document.appearanceDidChange(NSApplication.shared.effectiveAppearance) }
            }
        }
    }

    func document(for path: String) -> EditorDocument? {
        documents[path]
    }

    /// The document whose text view `view` is, or is inside of.
    func document(showing view: NSView) -> EditorDocument? {
        guard let textView = sequence(first: view, next: \.superview).first(where: { $0 is TextView }) else { return nil }
        return documents.values.first { $0.controller?.textView === textView }
    }

    /// The document of `path`, opened (from its hot-exit copy if the previous run left one) if it is not yet.
    @discardableResult
    func open(_ path: String, in workspace: String) -> EditorDocument {
        if let document = documents[path] { return document }
        // In an autorelease pool of its own: the previous run's tabs open before the app's run loop starts, where
        // nothing drains what AppKit autoreleases, and the text view controller's child list (autoreleased when it is
        // made, and holding its find view and with it the whole editor) kept a restored tab's editor after it closed.
        let document = autoreleasepool {
            EditorDocument(
                path: path, workspace: workspace, restored: restoredBuffers.removeValue(forKey: path),
                savedUI: persistence.editorUI[path], persistence: persistence, repository: repositories.repository(for: workspace),
                languageServers: languageServers)
        }
        documents[path] = document
        watch(Self.watchRoot(for: path, in: workspace))
        return document
    }

    /// The file of `path` was renamed to `newPath` (or a folder holding it was): its document follows it with its text,
    /// undo history, selection and scroll position. Nothing is written to the old path.
    func move(_ path: String, to newPath: String) {
        guard let document = documents.removeValue(forKey: path) else { return }
        document.relocate(to: newPath)
        documents[newPath] = document
        watch(Self.watchRoot(for: newPath, in: document.workspace))
    }

    /// `path` was renamed to `destination`: the navigators showing it keep its folders expanded under the new name.
    func itemMoved(from path: String, to destination: String) {
        for tree in trees.values where path.hasPrefix(tree.root + "/") { tree.itemMoved(from: path, to: destination) }
    }

    /// Lists `folder` again in the navigators that list it: a change the app made shows before FSEvents reports it.
    func relist(_ folder: String) {
        for tree in trees.values where folder == tree.root || folder.hasPrefix(tree.root + "/") { tree.relist(folder) }
    }

    /// The project folder `folder` is about to be renamed: its documents write nothing and leave the disk alone, and
    /// FSEvents under it is not heeded (the folder going away is not its files being deleted), until `folderMoved` or
    /// `releaseFolder`. The unsaved text waiting for its hot-exit copy gets it now.
    func holdFolder(_ folder: String) {
        heldFolders.insert(folder)
        for document in documents.values where Self.isInside(document.path, folder) || Self.isInside(document.workspace, folder) {
            document.holdWrites()
        }
    }

    /// The rename of `folder` did not happen: its documents carry on there.
    func releaseFolder(_ folder: String) {
        heldFolders.remove(folder)
        for document in documents.values { document.releaseWrites() }
    }

    /// The project folder `move.from` is at `move.to` now (Rename Project…, Locate Folder…): its documents follow with
    /// their text, undo history, selection and scroll (each joining the language server of the new folder, while the old
    /// folder's shuts down with its last document), its navigators keep their expanded folders, its repository its
    /// commit message, and the watchers watch the new folder. Then the documents write again. A folder found where
    /// Lantern already shows one (Locate Folder… onto an open project) keeps its own documents and navigator.
    func folderMoved(_ move: FolderMove) {
        repositories.folderMoved(move)
        for (path, document) in documents {
            let newWorkspace = move.moved(document.workspace)
            let newPath = move.moved(path) ?? path
            guard newPath != path || newWorkspace != nil else { continue }
            documents[path] = nil
            if newPath != path, documents[newPath] != nil {
                document.close()
                continue
            }
            document.relocate(to: newPath, workspace: newWorkspace, repository: newWorkspace.map(repositories.repository(for:)))
            documents[newPath] = document
        }
        for (path, buffer) in restoredBuffers {
            guard let newPath = move.moved(path) else { continue }
            var moved = buffer
            moved.path = newPath
            restoredBuffers[path] = nil
            restoredBuffers[newPath] = moved
        }
        for (root, tree) in trees {
            guard let newRoot = move.moved(root) else { continue }
            trees[root] = nil
            guard trees[newRoot] == nil else { continue }
            tree.moveRoot(move)
            trees[newRoot] = tree
        }
        for root in watchers.keys {
            guard let moved = move.moved(root) else { continue }
            watchers[root] = nil
            watch(moved)
        }
        heldFolders.remove(move.from)
        for document in documents.values { document.releaseWrites() }
    }

    /// `path` is `folder` or inside it.
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
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
        // Autosave writes what it can first; what is left is a conflict or a vanished file, which the user decides.
        document.autosaveNow()
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
                    failure.messageText = (error as? EditorDocument.SaveFailure)?.message ?? error.localizedDescription
                    failure.informativeText = "The tab stays open with your changes. Use Save As… in its notice to save them in another location."
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
        return true
    }

    /// The navigator of `workspace`; it lists and watches the folder once expanded.
    func tree(for workspace: String) -> FileTree {
        if let tree = trees[workspace] { return tree }
        let tree = FileTree(root: workspace) { [weak self] root in self?.watch(root) }
        trees[workspace] = tree
        return tree
    }

    /// The workspace of the deepest navigator that shows `path`.
    func workspace(containing path: String) -> String? {
        trees.keys.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    /// Writes every hot-exit copy still waiting for typing to pause (quit, resign key, sleep).
    func flush() {
        for document in documents.values {
            document.autosaveNow()
            if document.hotExitPending { document.writeHotExit() }
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
        guard !heldFolders.contains(where: { Self.isInside(root, $0) }) else { return }
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

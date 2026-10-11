import AppKit
import IDEEditorModel
import IDEProtocol
import IDEState
import QuickLookUI
import SwiftUI

/// The project's folder as an outline (`NSOutlineView`): each folder is listed when first expanded and kept current as
/// FSEvents reports changes, a change to one folder updating its rows alone, and only the rows on screen are views. A
/// click selects (⌘ and ⇧ add to the selection); a double-click opens a file in the project's tab strip or expands a
/// folder. The keys are Finder's (`FilesOutlineView`), and so are drags: rows dragged onto a folder move there, files
/// from Finder are copied in, and rows dragged out are their files. The rows a context menu is for are ringed, as in
/// Finder. A click on a row of a window in the background acts on it at once. The outline outlives the pane
/// (`FilesOutlines`): showing Files again shows it as it was, scrolled and selected, at once.
struct FilesOutline: NSViewRepresentable {
    let app: AppState
    let project: String

    /// Holds the outline this pane shows.
    final class Coordinator {
        var controller: FilesOutlineController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = app.filesOutlines.outline(of: project, app: app)
        context.coordinator.controller = controller
        return controller.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    /// The outline leaves the pane, ready for the next time Files shows.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        scrollView.removeFromSuperview()
    }
}

/// The Files outline of each project, kept while the pane shows something else; and what Cut put on the pasteboard.
@MainActor
final class FilesOutlines {
    /// Items cut in a Files pane: Paste moves them while the pasteboard still holds them (its change count is the one
    /// Cut left).
    struct Cut {
        let changeCount: Int
        let paths: [String]
    }

    var cut: Cut?
    private var outlines: [String: FilesOutlineController] = [:]

    /// `project`'s outline. One a window of the project still shows (a second window SwiftUI opens for the project, on
    /// its way to close) is left there, and this window gets an outline of its own.
    func outline(of project: String, app: AppState) -> FilesOutlineController {
        for (folder, outline) in outlines where !app.projects.contains(folder) {
            outline.stop()
            outlines[folder] = nil
        }
        if let outline = outlines[project] {
            guard outline.scrollView.window?.isVisible == true else { return outline }
            return FilesOutlineController(app: app, project: project)
        }
        let outline = FilesOutlineController(app: app, project: project)
        outlines[project] = outline
        return outline
    }

    /// The project folder `move.from` is at `move.to` now (Rename Project…): the outlines of it and of the folders
    /// inside it go (the pane shows a new one from the moved `FileTree`, its folders expanded as they were), and so does
    /// a Cut of items in it, whose paths on the pasteboard are gone.
    func folderMoved(_ move: FolderMove) {
        for (project, outline) in outlines where move.contains(project) {
            outline.stop()
            outlines[project] = nil
        }
        if cut?.paths.contains(where: move.contains) == true { cut = nil }
    }
}

/// A row's item: one per path, the same object for as long as the path is listed, as `NSOutlineView` needs.
final class FileNode: NSObject {
    let path: String
    let name: String
    let isDirectory: Bool
    /// A symlink (Finder's alias): its icon carries the alias arrow.
    let isSymlink: Bool
    /// A link back to a folder above: it lists as a folder that doesn't open, or expanding everything would never end.
    let isLinkLoop: Bool
    /// Why the folder above could not be listed, shown as its only row.
    let failure: String?

    init(entry: FileEntry) {
        path = entry.path
        name = entry.name
        isDirectory = entry.isDirectory
        isSymlink = entry.isSymlink
        isLinkLoop = entry.isLinkLoop
        failure = nil
    }

    init(failure: String, in folder: String) {
        path = folder
        name = ""
        isDirectory = false
        isSymlink = false
        isLinkLoop = false
        self.failure = failure
    }

    /// Tells a file from a folder of the same path, a link from either, and a failure from all of them.
    var key: String {
        failure != nil ? path + "/\u{0}" : (isDirectory ? path + "/" : path) + (isSymlink ? "\u{0}@" : "")
    }

    /// A folder whose contents the outline shows.
    var isExpandable: Bool { isDirectory && !isLinkLoop }
}

/// Data source and delegate of one Files outline. The listings, the expanded folders and what git ignores come from the
/// project's `FileTree`; git's marks from its repository; the unsaved dot from the open documents.
@MainActor
final class FilesOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let app: AppState
    let project: String
    let scrollView = NSScrollView()
    let outline = FilesOutlineView()
    private let tree: FileTree
    private let repository: GitRepository
    /// The item of each path listed.
    private var nodes: [String: FileNode] = [:]
    /// The children of each folder as the outline has them: the root's, and those of every folder it listed.
    private var shown: [String: [FileNode]] = [:]
    private var marks: GitMarks
    /// The tab on screen when the selection last followed it.
    private var followedTab: TabKind?
    /// Expanding and collapsing rows to match the tree: the outline's notifications of it are not the user's.
    private var syncing = false
    private var stopped = false
    /// The row whose name edits in place (Return, Rename, New Folder).
    private var renaming: FileNode?
    private weak var renamingCell: FileCell?
    /// Esc ended the edit: nothing is renamed.
    private var renameCancelled = false
    /// A rename asked for before its row could edit (Files not on screen yet), with the name to start from.
    private var pendingRename: (path: String, name: String?)?
    /// The items Quick Look shows while this outline controls its panel: the selection when it last changed.
    private var previewItems: [URL] = []
    /// Space or Quick Look opened the panel for this outline, until it closes.
    private var ownsQuickLook = false
    /// The outline closed the panel, which is still zooming back into the row.
    private var quickLookClosing = false
    /// Space came again while the panel was zooming back: it opens once it is gone.
    private var reopenQuickLook = false

    init(app: AppState, project: String) {
        self.app = app
        self.project = project
        tree = app.editors.tree(for: project)
        repository = app.editors.repositories.repository(for: project)
        marks = GitMarks(repository: repository, root: project)
        super.init()
        configure()
        tree.setExpanded(tree.root, true)
        shown[tree.root] = listing(of: tree.root)
        outline.reloadData()
        syncExpansion()
        selectTabFile()
        observeTree()
        observeDecorations()
        observeSelectedTab()
    }

    private func configure() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.controller = self
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.setAccessibilityLabel("Files")
        // Rows dragged within the app move or copy; dragged out (to Finder, Mail) they are copied, as from Xcode's
        // navigator, never taken out of the project.
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    /// The project is gone: the outline stops following the tree.
    func stop() {
        stopped = true
    }

    // MARK: - Listings

    /// The rows of `folder`: its entries, or why it could not be listed.
    private func listing(of folder: String) -> [FileNode] {
        if let failure = tree.failures[folder] { return [FileNode(failure: failure, in: folder)] }
        return (tree.children[folder] ?? []).map { entry in
            if let node = nodes[entry.path], node.isDirectory == entry.isDirectory, node.isSymlink == entry.isSymlink,
               node.isLinkLoop == entry.isLinkLoop, node.name == entry.name, node.failure == nil {
                return node
            }
            let node = FileNode(entry: entry)
            nodes[entry.path] = node
            return node
        }
    }

    /// Lists `folder` for the outline before it shows its rows.
    private func ensureListed(_ folder: String) {
        tree.setExpanded(folder, true)
        if shown[folder] == nil { shown[folder] = listing(of: folder) }
    }

    private func observeTree() {
        withObservationTracking {
            _ = tree.children
            _ = tree.failures
            _ = tree.expanded
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.syncWithTree()
                self.observeTree()
            }
        }
    }

    /// Brings the rows in line with the tree's listings: each folder whose entries changed gets its rows removed and
    /// inserted where they changed, the others stay as they are (with their selection and expansion).
    private func syncWithTree() {
        let folders = shown.keys.sorted { $0.count < $1.count }
        outline.beginUpdates()
        for folder in folders where shown[folder] != nil {
            update(folder)
        }
        outline.endUpdates()
        syncExpansion()
        // The item being renamed left under the edit: the edit goes with it.
        if let renaming, outline.row(forItem: renaming) < 0 { endRename(cancelled: true) }
        startPendingRename()
    }

    private func update(_ folder: String) {
        let old = shown[folder] ?? []
        let parent = folder == tree.root ? nil : nodes[folder]
        guard folder == tree.root || parent != nil else {
            shown[folder] = nil
            return
        }
        let new = listing(of: folder)
        let oldKeys = old.map(\.key)
        let newKeys = new.map(\.key)
        guard oldKeys != newKeys else { return }
        shown[folder] = new
        let removed = Set(oldKeys).subtracting(newKeys)
        for node in old where removed.contains(node.key) { forget(node) }
        // A folder the outline shows collapsed is read again when it expands.
        guard parent == nil || outline.isItemExpanded(parent) else {
            outline.reloadItem(parent, reloadChildren: true)
            return
        }
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in newKeys.difference(from: oldKeys) {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        if !removals.isEmpty { outline.removeItems(at: removals, inParent: parent, withAnimation: []) }
        if !insertions.isEmpty { outline.insertItems(at: insertions, inParent: parent, withAnimation: []) }
    }

    /// `node` left its folder: it, and what was listed under it, go.
    private func forget(_ node: FileNode) {
        guard node.failure == nil, nodes[node.path] === node else { return }
        nodes[node.path] = nil
        guard node.isDirectory else { return }
        let prefix = node.path + "/"
        for folder in shown.keys where folder == node.path || folder.hasPrefix(prefix) { shown[folder] = nil }
        for path in nodes.keys where path.hasPrefix(prefix) { nodes[path] = nil }
    }

    /// Expands the folders the tree has expanded (under expanded parents), and collapses those it no longer has.
    private func syncExpansion() {
        syncing = true
        defer { syncing = false }
        let expanded = tree.expanded
        for folder in expanded.sorted(by: { $0.count < $1.count }) where folder != tree.root {
            guard let node = nodes[folder], node.isExpandable, !outline.isItemExpanded(node) else { continue }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent == tree.root || nodes[parent].map(outline.isItemExpanded) == true else { continue }
            ensureListed(folder)
            outline.expandItem(node)
        }
        for (path, node) in nodes where node.isDirectory && !expanded.contains(path) && outline.isItemExpanded(node) {
            outline.collapseItem(node)
        }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        shown[(item as? FileNode)?.path ?? tree.root]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        shown[(item as? FileNode)?.path ?? tree.root]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isExpandable == true
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        if let failure = node.failure {
            let cell = outlineView.makeView(withIdentifier: FailureCell.identifier, owner: nil) as? FailureCell ?? FailureCell()
            cell.textField?.stringValue = failure
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        decorate(cell, node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileNode)?.failure == nil
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? FileNode)?.name
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileNode, node.isExpandable else { return false }
        ensureListed(node.path)
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        tree.setExpanded(node.path, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        tree.setExpanded(node.path, false)
    }

    // MARK: - Decorations

    /// git's marks, what it ignores and the unsaved dots: the rows on screen follow them.
    private func observeDecorations() {
        let marks = withObservationTracking {
            _ = tree.ignored
            for document in app.editors.documents.values { _ = document.isDirty }
            return GitMarks(repository: repository, root: project)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observeDecorations()
            }
        }
        self.marks = marks
        outline.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? FileCell, let node = self.outline.item(atRow: row) as? FileNode else { return }
            self.decorate(cell, node)
        }
    }

    private func decorate(_ cell: FileCell, _ node: FileNode) {
        cell.show(
            node, mark: node.isDirectory ? marks.folders[node.path] : marks.files[node.path], isIgnored: tree.isIgnored(node.path),
            isDirty: !node.isDirectory && app.editors.document(for: node.path)?.isDirty == true)
    }

    // MARK: - Selection

    var selectedNodes: [FileNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }.filter { $0.failure == nil }
    }

    var hasSelection: Bool { !selectedNodes.isEmpty }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        followQuickLook()
    }

    /// The tab on screen is an editor's: its file's row is selected, when it shows.
    private func observeSelectedTab() {
        let tab = withObservationTracking {
            app.selectedTab(in: project)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observeSelectedTab()
            }
        }
        guard tab != followedTab else { return }
        selectTabFile()
    }

    private func selectTabFile() {
        followedTab = app.selectedTab(in: project)
        guard let path = followedTab?.editorPath, let node = nodes[path] else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, !outline.selectedRowIndexes.contains(row) else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    // MARK: - Actions

    /// ⌘↓, ⌘O, Open: the selected files open in the project's tab strip; selected folders alone expand.
    func openSelection() {
        let selected = selectedNodes
        let files = selected.filter { !$0.isDirectory }
        guard !files.isEmpty else {
            for folder in selected { outline.expandItem(folder) }
            return
        }
        for file in files.sorted(by: { $0.path < $1.path }) { app.openEditor(file.path, in: project) }
    }

    @objc private func doubleClicked() {
        activate(row: outline.clickedRow)
    }

    /// A double-click on a row: a file opens, a folder expands or collapses.
    func activate(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, node.failure == nil else { return }
        if node.isDirectory { toggle(node) } else { app.openEditor(node.path, in: project) }
    }

    private func toggle(_ folder: FileNode) {
        if outline.isItemExpanded(folder) { outline.collapseItem(folder) } else { outline.expandItem(folder) }
    }

    /// ⌘⌫, Move to Trash: the selected items go to the Trash.
    func trashSelection() {
        trash(selectedNodes.map(\.path))
    }

    private func trash(_ paths: [String]) {
        let undoManager = outline.undoManager
        Task {
            await app.trashItems(paths, undoManager: undoManager)
        }
    }

    /// ⇧⌘R, Reveal in Finder: the selected items, or the project's folder when nothing is selected.
    func revealSelection() {
        let paths = selectedNodes.map(\.path)
        revealInFinder(paths.isEmpty ? [project] : paths)
    }

    private func revealInFinder(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
    }

    /// ⇧⌘N, New Folder: an "untitled folder" where Paste would put items, its name edited in place at once.
    func newFolder() {
        newFolder(in: pasteFolder)
    }

    func newFolder(in folder: String) {
        guard let path = app.createFolder(in: folder, undoManager: outline.undoManager) else { return }
        reveal([path])
        beginRename(path)
    }

    // MARK: - Rename in place

    /// Return, Rename: the selected item's name edits in its row.
    func renameSelection() {
        guard selectedNodes.count == 1, let node = selectedNodes.first else { return NSSound.beep() }
        beginRename(node.path)
    }

    /// The name of `path` edits in its row, selected up to its extension (a folder's whole name), as in Finder; `name`
    /// is what the field starts with, the item's name by default. A row not on screen yet (Files about to show)
    /// starts editing once it is.
    func beginRename(_ path: String, name: String? = nil) {
        endRename(cancelled: true)
        guard let node = nodes[path], node.failure == nil, outline.window != nil, outline.row(forItem: node) >= 0 else {
            pendingRename = (path, name)
            return
        }
        pendingRename = nil
        let row = outline.row(forItem: node)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell else { return }
        renaming = node
        renamingCell = cell
        renameCancelled = false
        cell.beginEditing(name ?? node.name, delegate: self, selectingBaseName: !node.isDirectory)
    }

    /// A rename asked for while its row could not edit yet: now, if it can.
    func startPendingRename() {
        guard let pending = pendingRename, outline.window != nil, nodes[pending.path].map(outline.row(forItem:)) ?? -1 >= 0 else { return }
        beginRename(pending.path, name: pending.name)
    }

    /// Return and Tab keep the name typed, Esc the name it had; either way the outline has the keyboard again.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renaming != nil else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            renameCancelled = true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            break
        default:
            return false
        }
        outline.window?.makeFirstResponder(outline)
        return true
    }

    /// The edit ended (Return, Esc, a click elsewhere).
    func controlTextDidEndEditing(_ notification: Notification) {
        endRename(cancelled: renameCancelled)
    }

    /// Unless `cancelled`, the item takes the name typed; one Finder would refuse is explained in a sheet, then edits
    /// again. An empty or unchanged name renames nothing.
    private func endRename(cancelled: Bool) {
        guard let node = renaming else { return }
        renaming = nil
        let typed = FileNamePrompt.trimmed(renamingCell?.editedName ?? node.name)
        renamingCell?.endEditing(showing: node.name)
        renamingCell = nil
        guard !cancelled, !typed.isEmpty, typed != node.name else { return }
        if let problem = FileNamePrompt.problem(naming: typed, in: (node.path as NSString).deletingLastPathComponent, renaming: node.path) {
            refuse(typed, problem, renaming: node.path)
            return
        }
        if let renamed = app.renameItem(node.path, to: typed, undoManager: outline.undoManager) { reveal([renamed]) }
    }

    /// Why `name` can't be the item's, in a sheet, as Finder says it; then the name typed edits again.
    private func refuse(_ name: String, _ problem: String, renaming path: String) {
        guard let window = outline.window else { return }
        let alert = NSAlert()
        alert.messageText = problem
        alert.informativeText = "Please choose a different name."
        Task {
            _ = await alert.beginSheetModal(for: window)
            beginRename(path, name: name)
        }
    }

    // MARK: - Quick Look

    /// Space, Quick Look: the selected items show in Quick Look (one after the other in its panel), and the panel
    /// follows the selection; Space again, or Esc, closes it.
    func toggleQuickLook() {
        if closeQuickLook() { return }
        showQuickLook()
    }

    func showQuickLook() {
        guard hasSelection, let panel = QLPreviewPanel.shared() else { return }
        if quickLookClosing, panel.isVisible {
            // Still zooming back into the row: it opens again once it is gone.
            reopenQuickLook = true
            return
        }
        ownsQuickLook = true
        quickLookClosing = false
        if (panel.dataSource as AnyObject?) === self {
            followQuickLook()
        } else if (panel.currentController as AnyObject?) === outline {
            // Another Quick Look (the agents' output) took the panel's items while the outline controlled it.
            beginQuickLook(panel)
        } else {
            panel.updateController()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes Quick Look while it shows this outline's items; false when it doesn't.
    @discardableResult
    func closeQuickLook() -> Bool {
        guard let panel = quickLookShown else { return false }
        // The panel zooms back into the row's icon before it goes; Space meanwhile opens it again.
        quickLookClosing = true
        panel.orderOut(nil)
        return true
    }

    /// The panel, while it shows this outline's items.
    private var quickLookShown: QLPreviewPanel? {
        guard ownsQuickLook, !quickLookClosing, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, (panel.dataSource as AnyObject?) === self
        else { return nil }
        return panel
    }

    /// Whether the outline takes the panel when the panel looks for its controller: while it opened it, not once it
    /// closed it (another view's Quick Look, the agents' output, is then not the outline's to show).
    var controlsQuickLook: Bool {
        ownsQuickLook && !quickLookClosing
    }

    /// The selection changed: Quick Look shows the items selected now, and closes when nothing is.
    private func followQuickLook() {
        guard let panel = quickLookShown else { return }
        let urls = selectedNodes.map { URL(filePath: $0.path) }
        guard !urls.isEmpty else {
            closeQuickLook()
            return
        }
        guard urls != previewItems else { return }
        previewItems = urls
        panel.reloadData()
    }

    /// The panel found the outline in the responder chain: it shows the selection.
    fileprivate func beginQuickLook(_ panel: QLPreviewPanel) {
        previewItems = selectedNodes.map { URL(filePath: $0.path) }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    /// The panel left the outline: it closed, or the keyboard went elsewhere (it comes back with the keyboard while the
    /// panel is open).
    fileprivate func endQuickLook(_ panel: QLPreviewPanel) {
        if (panel.dataSource as AnyObject?) === self {
            panel.dataSource = nil
            panel.delegate = nil
        }
        if !panel.isVisible || quickLookClosing { quickLookClosed() }
    }

    /// The panel closed (its close button too).
    func windowWillClose(_ notification: Notification) {
        quickLookClosed()
    }

    private func quickLookClosed() {
        ownsQuickLook = false
        quickLookClosing = false
        guard reopenQuickLook else { return }
        reopenQuickLook = false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.showQuickLook() }
        }
    }

    // MARK: - Copy, cut, paste and duplicate

    /// Where Paste puts items: into the selected folder, else the selected file's folder, else the top level.
    private var pasteFolder: String {
        guard let first = selectedNodes.first else { return project }
        return first.isDirectory ? first.path : (first.path as NSString).deletingLastPathComponent
    }

    var canCopy: Bool { !selectedNodes.isEmpty }

    func copySelection(cut: Bool) {
        app.putOnPasteboard(selectedNodes.map(\.path), cut: cut)
    }

    /// Paste (⌘V), or Move Item Here (⌥⌘V): into the selected folder, or the selected file's folder.
    func paste(moving: Bool) {
        paste(into: pasteFolder, moving: moving)
    }

    private func paste(into folder: String, moving: Bool) {
        let undoManager = outline.undoManager
        Task {
            reveal(await app.pasteFiles(into: folder, moving: moving, undoManager: undoManager))
        }
    }

    /// Duplicate (⌘D): a copy of each selected item next to it.
    func duplicateSelection() {
        duplicate(selectedNodes.map(\.path))
    }

    private func duplicate(_ paths: [String]) {
        let undoManager = outline.undoManager
        Task {
            reveal(await app.copyItems(paths, into: nil, undoManager: undoManager))
        }
    }

    /// Selects `paths` (copies, moved items), expanding the folders they are in.
    func reveal(_ paths: [String]) {
        guard !paths.isEmpty, !stopped else { return }
        for path in paths {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.hasPrefix(project + "/") {
                tree.setExpanded(folder, true)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        syncWithTree()
        let rows = IndexSet(paths.compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        guard let first = rows.first else { return }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        outline.scrollRowToVisible(first)
    }

    // MARK: - Context menu

    /// The paths a context menu acts on: the selection when it was right-clicked, else the row clicked; none for the
    /// empty area.
    private var menuTargets: [FileNode] {
        let row = outline.clickedRow
        guard row >= 0, let clicked = outline.item(atRow: row) as? FileNode, clicked.failure == nil else { return [] }
        return outline.selectedRowIndexes.contains(row) ? selectedNodes : [clicked]
    }

    /// Each item shows the key the outline answers for it (the keys themselves are the outline's, `FilesOutlineView`).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = menuTargets
        let paths = targets.map(\.path)
        @discardableResult
        func add(
            _ title: String, _ action: Selector, _ represented: Any? = nil, key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
            enabled: Bool = true
        ) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.representedObject = represented
            item.isEnabled = enabled
            return item
        }
        /// Paste Item, and Move Item Here while ⌥ is down.
        func addPaste(into folder: String) {
            let count = AppState.pasteboardFiles().count
            add(count > 1 ? "Paste \(count) Items" : "Paste Item", #selector(pasteItems(_:)), folder, key: "v", enabled: count > 0)
            let move = add(
                count > 1 ? "Move \(count) Items Here" : "Move Item Here", #selector(moveItemsHere(_:)), folder, key: "v", [.command, .option],
                enabled: count > 0)
            move.isAlternate = true
        }
        guard let first = targets.first else {
            // The empty area: the project folder's own menu.
            add("Open in Terminal", #selector(openInTerminal(_:)), project, enabled: app.connection.isConnected)
            add("Reveal in Finder", #selector(showInFinder(_:)), [project], key: "r", [.command, .shift])
            menu.addItem(.separator())
            addPaste(into: project)
            menu.addItem(.separator())
            add("Copy Path", #selector(copyPath(_:)), project)
            menu.addItem(.separator())
            add("New File…", #selector(newFile(_:)), project)
            add("New Folder", #selector(newFolder(_:)), project, key: "n", [.command, .shift])
            return
        }
        let folder = first.isDirectory ? first.path : (first.path as NSString).deletingLastPathComponent
        if targets.contains(where: { !$0.isDirectory }) { add("Open", #selector(openPaths(_:)), paths, key: "o") }
        add("Quick Look", #selector(quickLook(_:)), paths, key: " ", [])
        if targets.count == 1 { add("Open in Terminal", #selector(openInTerminal(_:)), folder, enabled: app.connection.isConnected) }
        add("Reveal in Finder", #selector(showInFinder(_:)), paths, key: "r", [.command, .shift])
        menu.addItem(.separator())
        add("Cut", #selector(cutItems(_:)), paths, key: "x")
        add("Copy", #selector(copyItems(_:)), paths, key: "c")
        addPaste(into: folder)
        add("Duplicate", #selector(duplicateItems(_:)), paths, key: "d")
        if targets.count == 1 {
            menu.addItem(.separator())
            add("Copy Path", #selector(copyPath(_:)), first.path)
            add("Copy Relative Path", #selector(copyPath(_:)), AppState.relativePath(first.path, in: project))
            menu.addItem(.separator())
            add("New File…", #selector(newFile(_:)), folder)
            add("New Folder", #selector(newFolder(_:)), folder, key: "n", [.command, .shift])
        }
        menu.addItem(.separator())
        if targets.count == 1 { add("Rename", #selector(rename(_:)), first.path, key: "\r", []) }
        add("Move to Trash", #selector(moveToTrash(_:)), paths, key: "\u{8}")
    }

    @objc private func cutItems(_ sender: NSMenuItem) {
        app.putOnPasteboard(sender.representedObject as? [String] ?? [], cut: true)
    }

    @objc private func copyItems(_ sender: NSMenuItem) {
        app.putOnPasteboard(sender.representedObject as? [String] ?? [], cut: false)
    }

    @objc private func pasteItems(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        paste(into: folder, moving: false)
    }

    @objc private func moveItemsHere(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        paste(into: folder, moving: true)
    }

    @objc private func duplicateItems(_ sender: NSMenuItem) {
        duplicate(sender.representedObject as? [String] ?? [])
    }

    @objc private func openPaths(_ sender: NSMenuItem) {
        for path in sender.representedObject as? [String] ?? [] where nodes[path]?.isDirectory != true {
            app.openEditor(path, in: project)
        }
    }

    /// Quick Look for the rows the menu is for, which become the selection the panel follows.
    @objc private func quickLook(_ sender: NSMenuItem) {
        reveal(sender.representedObject as? [String] ?? [])
        showQuickLook()
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        app.newTerminal(in: folder)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        revealInFinder(sender.representedObject as? [String] ?? [])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        app.copyToPasteboard(path)
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        app.newFile(in: folder, project: project)
    }

    @objc private func newFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        newFolder(in: folder)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        beginRename(path)
    }

    @objc private func moveToTrash(_ sender: NSMenuItem) {
        trash(sender.representedObject as? [String] ?? [])
    }

    // MARK: - Drag and drop

    /// A dragged row is its file's URL, which Finder, Mail, the terminal and the editor take.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileNode, node.failure == nil else { return nil }
        return URL(filePath: node.path) as NSURL
    }

    /// A drop goes into a folder, which is highlighted: the folder under the pointer, the folder of the file under it,
    /// or the project's top level below the rows (and the whole outline lights up). A folder never goes into itself,
    /// and items never move into the folder they are in.
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        let paths = AppState.pasteboardFiles(info.draggingPasteboard)
        let folder = dropFolder(onto: item as? FileNode)
        guard !paths.isEmpty, !paths.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) else { return [] }
        let operation = dropOperation(info)
        if operation == .move, paths.allSatisfy({ ($0 as NSString).deletingLastPathComponent == folder }) { return [] }
        outlineView.setDropItem(folder == project ? nil : nodes[folder], dropChildIndex: NSOutlineViewDropOnItemIndex)
        return operation
    }

    /// The dragged items move or are copied into the folder, as one step of Undo; open editors follow moved files.
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let paths = AppState.pasteboardFiles(info.draggingPasteboard)
        let folder = dropFolder(onto: item as? FileNode)
        guard !paths.isEmpty else { return false }
        let undoManager = outline.undoManager
        if dropOperation(info) == .move {
            reveal(app.moveItems(paths, into: folder, undoManager: undoManager))
        } else {
            Task { reveal(await app.copyItems(paths, into: folder, undoManager: undoManager)) }
        }
        return true
    }

    /// The folder a drop on `item` goes into: a folder (or a folder that could not be listed) itself, a file's folder,
    /// and the project's top level for the space below the rows.
    private func dropFolder(onto item: FileNode?) -> String {
        guard let item else { return project }
        return item.isDirectory || item.failure != nil ? item.path : (item.path as NSString).deletingLastPathComponent
    }

    /// Rows from a Files outline move (⌥ copies); items from Finder or another app are copied (⌘ moves them), as Finder
    /// treats a drag from another disk. ⌥ leaves Copy alone in the drag's operations, ⌘ Generic.
    private func dropOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        let allowed = info.draggingSourceOperationMask
        let moves = info.draggingSource is FilesOutlineView ? allowed != .copy : !allowed.contains(.copy)
        if moves, allowed.contains(.move) || allowed.contains(.generic) { return .move }
        return allowed.contains(.copy) ? .copy : []
    }
}

extension FilesOutlineController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems.indices.contains(index) ? previewItems[index] as NSURL : nil
    }

    /// Keys pressed in the panel act in the outline, as in Finder: ↑ and ↓ move the selection (the panel follows),
    /// Space and Esc close it, letters select by name. Return is left alone: it would rename.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              // kVK_Return, kVK_ANSI_KeypadEnter
              event.keyCode != 36, event.keyCode != 76
        else { return false }
        outline.keyDown(with: event)
        return true
    }

    /// The panel zooms out of the row's icon, and back into it when it closes; from the middle of the screen for an
    /// item scrolled out of view.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let path = item?.previewItemURL?.path(percentEncoded: false), let node = nodes[path], let window = outline.window else { return .zero }
        let row = outline.row(forItem: node)
        guard row >= 0, NSLocationInRange(row, outline.rows(in: outline.visibleRect)),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell
        else { return .zero }
        return window.convertToScreen(cell.iconFrameInWindow)
    }
}

/// The Files outline's view, with Finder's keys while it has the keyboard: Return renames, ⌘↓ and ⌘O open, Space is
/// Quick Look, ⌘⌫ moves to the Trash, ⇧⌘N makes a folder, ⇧⌘R reveals in Finder, ⌘D duplicates, ⌥⌘V moves the items
/// on the pasteboard here; ← and → collapse and expand (with ⌥ everything inside), letters select by name (all three
/// `NSOutlineView`'s own). Edit › Cut, Copy and Paste act on the selected items. A click in a window in the background
/// acts on the row at once, and the outline controls the Quick Look panel while it shows the outline's items.
final class FilesOutlineView: NSOutlineView {
    weak var controller: FilesOutlineController?

    /// A click on a row of a window in the background selects it (and a double-click there opens it), as in Finder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, modifiers) {
        // kVK_Return, kVK_ANSI_KeypadEnter
        case (36, []), (76, []):
            controller?.renameSelection()
        // kVK_Space
        case (49, []):
            controller?.toggleQuickLook()
        // kVK_Escape, while Quick Look shows the outline's items
        case (53, []) where controller?.closeQuickLook() == true:
            break
        default:
            super.keyDown(with: event)
        }
    }

    /// The keys with ⌘. ⌘O is File › Add Project… unless the outline has the keyboard and something selected.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let controller, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (modifiers, event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        // kVK_Delete
        case ([.command], 51, _):
            guard controller.hasSelection else { return false }
            controller.trashSelection()
        // kVK_DownArrow
        case ([.command], 125, _):
            controller.openSelection()
        case ([.command], _, "o"):
            guard controller.hasSelection else { return false }
            controller.openSelection()
        case ([.command, .shift], _, "n"):
            controller.newFolder()
        case ([.command, .shift], _, "r"):
            controller.revealSelection()
        case ([.command, .option], _, "v"):
            guard !AppState.pasteboardFiles().isEmpty else { return false }
            controller.paste(moving: true)
        case ([.command], _, "d"):
            guard controller.canCopy else { return false }
            controller.duplicateSelection()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection(cut: false)
    }

    @objc func cut(_ sender: Any?) {
        controller?.copySelection(cut: true)
    }

    @objc func paste(_ sender: Any?) {
        controller?.paste(moving: false)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): controller?.canCopy == true
        case #selector(paste(_:)): !AppState.pasteboardFiles().isEmpty
        default: super.validateUserInterfaceItem(item)
        }
    }

    // VoiceOver's Show Menu (VO-⇧-M) brings up the context menu a right-click would.

    /// On the outline: the selection's menu, as a right-click on a selected row shows it; with nothing selected, the
    /// project folder's, as a right-click below the rows shows it. None while a sheet is up (a rename's alert), which
    /// keeps the mouse off the outline too.
    override func accessibilityPerformShowMenu() -> Bool {
        guard window?.attachedSheet == nil else { return false }
        let visible = rows(in: visibleRect)
        if let row = selectedRowIndexes.first(where: { NSLocationInRange($0, visible) }) ?? selectedRowIndexes.first {
            return showContextMenu(forRow: row)
        }
        let below = max(numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0, visibleRect.minY)
        // The rows fill the view: there is no empty area to click.
        guard below < visibleRect.maxY - 1 else { return super.accessibilityPerformShowMenu() }
        return rightClick(at: NSPoint(x: visibleRect.minX + 24, y: min(below + rowHeight / 2, visibleRect.maxY - 1)))
    }

    /// On a row (`FileCell`): its menu, the row ringed as for a right-click, scrolled into view first.
    func showContextMenu(forRow row: Int) -> Bool {
        guard row >= 0, row < numberOfRows else { return false }
        scrollRowToVisible(row)
        let cell = frameOfCell(atColumn: 0, row: row)
        return rightClick(at: NSPoint(x: cell.minX + 8, y: cell.midY))
    }

    /// A right-click at `point`, once VoiceOver has its answer: the menu tracks the mouse until it closes, and an action
    /// still running when it opens reads as failed. A main-queue turn is too soon for the answer to have gone out.
    private func rightClick(at point: NSPoint) -> Bool {
        guard let window else { return false }
        let location = convert(point, to: nil)
        let windowNumber = window.windowNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            MainActor.assumeIsolated {
                guard let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return }
                self?.rightMouseDown(with: event)
            }
        }
        return true
    }

    /// Folders a drag sprang open stay open once it dropped into them, where the dropped items are selected; a drag
    /// that leaves or is cancelled closes them again.
    override func shouldCollapseAutoExpandedItems(forDeposited deposited: Bool) -> Bool {
        !deposited
    }

    /// A rename asked for while Files was not on screen starts once the outline is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.controller?.startPendingRename() }
        }
    }

    // Quick Look asks the responder chain for its controller: the outline, while it opened the panel for its items.

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { controller?.controlsQuickLook == true }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let panel else { return }
            controller?.beginQuickLook(panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let panel else { return }
            controller?.endQuickLook(panel)
        }
    }
}

/// A Files row: the icon (with Finder's alias arrow for a symlink), the name (in git's color while git has something to
/// say about the file, or about something in the folder), a dot while it has unsaved edits and git's letter trailing;
/// dimmed while git ignores it. On the accent of a selected row in a focused outline the text and icon are white. The
/// name edits in place for a rename.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")

    private let icon = NSImageView()
    /// Finder's alias arrow, on the icon's bottom-left corner.
    private let alias = NSImageView()
    private let name = NameField(labelWithString: "")
    private let unsaved = UnsavedDot()
    private let letter = NSTextField(labelWithString: "")
    private var mark: GitMarks.Mark?
    /// While the name edits, it reaches as far as git's letter, to show what is typed.
    private var editingWidth: NSLayoutConstraint?
    private var isEditing = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        identifier = Self.identifier
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        alias.image = NSImage(systemSymbolName: "arrow.up.right.square.fill", accessibilityDescription: nil)
        // VoiceOver reads the row by its label (see `show`): the icon, the arrow, the name and git's letter are drawn,
        // not read. A control's cell is the element VoiceOver sees, and the folder symbol describes itself as "move".
        for control in [icon, alias, name, letter] as [NSControl] {
            control.setAccessibilityElement(false)
            control.cell?.setAccessibilityElement(false)
        }
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        unsaved.toolTip = "Unsaved changes"
        unsaved.setAccessibilityElement(false)
        letter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        letter.setContentCompressionResistancePriority(.required, for: .horizontal)
        letter.setContentHuggingPriority(.required, for: .horizontal)
        imageView = icon
        textField = name

        let leading = NSStackView(views: [icon, name, unsaved])
        leading.orientation = .horizontal
        leading.spacing = 4
        leading.alignment = .centerY
        leading.detachesHiddenViews = true
        leading.setHuggingPriority(.defaultLow, for: .horizontal)
        for view in [leading, letter, alias] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            unsaved.widthAnchor.constraint(equalToConstant: 6),
            unsaved.heightAnchor.constraint(equalToConstant: 6),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            letter.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 4),
            letter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            letter.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            alias.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -1),
            alias.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
        ])
        editingWidth = leading.trailingAnchor.constraint(equalTo: letter.leadingAnchor, constant: -4)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The icons, made once each.
    private static var symbols: [String: NSImage] = [:]

    private static func symbol(_ name: String) -> NSImage? {
        if let image = symbols[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbols[name] = image
        return image
    }

    func show(_ node: FileNode, mark: GitMarks.Mark?, isIgnored: Bool, isDirty: Bool) {
        self.mark = mark
        icon.image = Self.symbol(FileSymbol.name(for: node.name, isDirectory: node.isDirectory))
        alias.isHidden = !node.isSymlink
        if !isEditing { name.stringValue = node.name }
        unsaved.isHidden = !isDirty
        let letterShown = !node.isDirectory ? mark : nil
        letter.isHidden = letterShown == nil
        letter.stringValue = letterShown?.letter ?? ""
        letter.toolTip = letterShown?.explanation
        alphaValue = isIgnored ? 0.5 : 1
        toolTip = node.path
        // VoiceOver reads the row's cell (AppKit's, around this view) by this label: the name, "alias" for a symlink,
        // then what git says and whether it has unsaved edits.
        let git = mark.map { node.isDirectory ? "changes inside" : $0.word }
        setAccessibilityLabel(
            [node.name, node.isSymlink ? "alias" : nil, git, isDirty ? "edited" : nil].compactMap(\.self).joined(separator: ", "))
        applyColors()
    }

    /// VoiceOver's Show Menu (VO-⇧-M) on the row: its context menu, as a right-click on it brings it up; none while a
    /// sheet is up, as for the mouse.
    override func accessibilityPerformShowMenu() -> Bool {
        guard window?.attachedSheet == nil, let outline = superview?.superview as? FilesOutlineView else { return false }
        return outline.showContextMenu(forRow: outline.row(for: self))
    }

    /// None, said outright. The row's cell (AppKit's, around this view) asks this view for its custom actions on every
    /// action VoiceOver performs on it, and a view that has none to report leaves an "unsupported attribute" error
    /// behind, which VoiceOver gets as the action's result (Show Menu failing though its menu opened).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        []
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    /// The alias arrow, cut out of its square in the color of the row.
    private static let aliasColors = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.textBackgroundColor, .secondaryLabelColor]))
    private static let selectedAliasColors = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.selectedContentBackgroundColor, .alternateSelectedControlTextColor]))

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        let white = NSColor.alternateSelectedControlTextColor
        icon.contentTintColor = selected ? white : .secondaryLabelColor
        alias.symbolConfiguration = selected ? Self.selectedAliasColors : Self.aliasColors
        name.textColor = isEditing ? .textColor : selected ? white : mark?.color ?? .labelColor
        letter.textColor = selected ? white : mark?.color
        unsaved.color = selected ? white : .labelColor
    }

    /// Where Quick Look's panel zooms from: the icon, in the window.
    var iconFrameInWindow: NSRect {
        icon.convert(icon.bounds, to: nil)
    }

    /// The name as typed in place.
    var editedName: String {
        name.stringValue
    }

    /// The name becomes a field like Finder's holding `text`, selected up to its extension when `selectingBaseName`
    /// (all of it otherwise), with the keyboard.
    func beginEditing(_ text: String, delegate: any NSTextFieldDelegate, selectingBaseName: Bool) {
        isEditing = true
        name.stringValue = text
        name.isEditable = true
        name.isSelectable = true
        name.drawsBackground = true
        name.backgroundColor = .textBackgroundColor
        name.lineBreakMode = .byClipping
        name.cell?.isScrollable = true
        name.delegate = delegate
        // The field is VoiceOver's while it edits.
        name.cell?.setAccessibilityElement(true)
        editingWidth?.isActive = true
        applyColors()
        window?.makeFirstResponder(name)
        let base = (text as NSString).deletingPathExtension
        let length = selectingBaseName && !base.isEmpty ? (base as NSString).length : (text as NSString).length
        name.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
    }

    /// The name is a label again, showing `text`.
    func endEditing(showing text: String) {
        isEditing = false
        name.delegate = nil
        name.cell?.setAccessibilityElement(false)
        name.isEditable = false
        name.isSelectable = false
        name.drawsBackground = false
        name.cell?.isScrollable = false
        name.lineBreakMode = .byTruncatingMiddle
        name.stringValue = text
        editingWidth?.isActive = false
        applyColors()
    }
}

/// The 6-point dot of a file with unsaved edits.
private final class UnsavedDot: NSView {
    var color = NSColor.labelColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Why a folder could not be listed, in its place.
private final class FailureCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("failure")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        identifier = Self.identifier
        let label = NSTextField(labelWithString: "")
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = Chrome.secondaryTextColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

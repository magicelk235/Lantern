import AppKit
import IDEEditorModel
import IDEState
import SwiftUI

/// The project's folder as an outline (`NSOutlineView`): each folder is listed when first expanded and kept current as
/// FSEvents reports changes, a change to one folder updating its rows alone, and only the rows on screen are views. A
/// click selects (⌘ and ⇧ add to the selection); Return or a double-click opens the files selected in the project's
/// tab strip, or expands a folder; Space shows the file in Quick Look; → and ← expand and collapse. The rows a context
/// menu is for are ringed, as in Finder. A click on a row of a window in the background acts on it at once. The outline
/// outlives the pane (`FilesOutlines`): showing Files again shows it as it was, scrolled and selected, at once.
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
}

/// A row's item: one per path, the same object for as long as the path is listed, as `NSOutlineView` needs.
final class FileNode: NSObject {
    let path: String
    let name: String
    let isDirectory: Bool
    /// Why the folder above could not be listed, shown as its only row.
    let failure: String?

    init(entry: FileEntry) {
        path = entry.path
        name = entry.name
        isDirectory = entry.isDirectory
        failure = nil
    }

    init(failure: String, in folder: String) {
        path = folder
        name = ""
        isDirectory = false
        self.failure = failure
    }

    /// Tells a file from a folder of the same path, and a failure from both.
    var key: String { failure != nil ? path + "/\u{0}" : isDirectory ? path + "/" : path }
}

/// Data source and delegate of one Files outline. The listings, the expanded folders and what git ignores come from the
/// project's `FileTree`; git's marks from its repository; the unsaved dot from the open documents.
@MainActor
final class FilesOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
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
            if let node = nodes[entry.path], node.isDirectory == entry.isDirectory, node.name == entry.name, node.failure == nil {
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
            guard let node = nodes[folder], node.isDirectory, !outline.isItemExpanded(node) else { continue }
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
        (item as? FileNode)?.isDirectory == true
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
        guard let node = item as? FileNode, node.isDirectory else { return false }
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

    /// Return: the selected files open in the project's tab strip; a selected folder alone expands or collapses.
    func openSelection() {
        let selected = selectedNodes
        let files = selected.filter { !$0.isDirectory }
        if files.isEmpty, selected.count == 1, let folder = selected.first {
            toggle(folder)
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

    /// Space: Quick Look shows the selected file, or closes.
    func toggleQuickLook() {
        guard let node = selectedNodes.first, selectedNodes.count == 1 else { return }
        app.toggleQuickLook(node.path, in: project)
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = menuTargets
        let paths = targets.map(\.path)
        @discardableResult
        func add(_ title: String, _ action: Selector, _ represented: Any? = nil, enabled: Bool = true) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = represented
            item.isEnabled = enabled
            return item
        }
        /// Paste Item, and Move Item Here while ⌥ is down.
        func addPaste(into folder: String) {
            let count = AppState.pasteboardFiles().count
            let paste = add(count > 1 ? "Paste \(count) Items" : "Paste Item", #selector(pasteItems(_:)), folder, enabled: count > 0)
            paste.keyEquivalentModifierMask = []
            let move = add(count > 1 ? "Move \(count) Items Here" : "Move Item Here", #selector(moveItemsHere(_:)), folder, enabled: count > 0)
            move.keyEquivalentModifierMask = .option
            move.isAlternate = true
        }
        guard let first = targets.first else {
            // The empty area: the project folder's own menu.
            add("Open in Terminal", #selector(openInTerminal(_:)), project, enabled: app.connection.isConnected)
            add("Reveal in Finder", #selector(revealInFinder(_:)), [project])
            menu.addItem(.separator())
            addPaste(into: project)
            menu.addItem(.separator())
            add("Copy Path", #selector(copyPath(_:)), project)
            menu.addItem(.separator())
            add("New File…", #selector(newFile(_:)), project)
            add("New Folder…", #selector(newFolder(_:)), project)
            return
        }
        let folder = first.isDirectory ? first.path : (first.path as NSString).deletingLastPathComponent
        if targets.contains(where: { !$0.isDirectory }) { add("Open", #selector(openPaths(_:)), paths) }
        if targets.count == 1, !first.isDirectory { add("Quick Look", #selector(quickLook(_:)), first.path) }
        if targets.count == 1 { add("Open in Terminal", #selector(openInTerminal(_:)), folder, enabled: app.connection.isConnected) }
        add("Reveal in Finder", #selector(revealInFinder(_:)), paths)
        menu.addItem(.separator())
        add("Cut", #selector(cutItems(_:)), paths)
        add("Copy", #selector(copyItems(_:)), paths)
        addPaste(into: folder)
        add("Duplicate", #selector(duplicateItems(_:)), paths)
        guard targets.count == 1 else { return }
        menu.addItem(.separator())
        add("Copy Path", #selector(copyPath(_:)), first.path)
        add("Copy Relative Path", #selector(copyPath(_:)), AppState.relativePath(first.path, in: project))
        menu.addItem(.separator())
        add("New File…", #selector(newFile(_:)), folder)
        add("New Folder…", #selector(newFolder(_:)), folder)
        menu.addItem(.separator())
        add("Rename…", #selector(rename(_:)), first.path)
        add("Move to Trash", #selector(moveToTrash(_:)), first.path)
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

    @objc private func quickLook(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        app.toggleQuickLook(path, in: project)
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        app.newTerminal(in: folder)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        let paths = sender.representedObject as? [String] ?? []
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
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
        app.newFolder(in: folder)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        app.renameItem(path, project: project)
    }

    @objc private func moveToTrash(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        app.trashItem(path, project: project)
    }
}

/// The Files outline's view: the keys Finder's list answers, Edit › Cut, Copy and Paste for the selected items, and a
/// click in a window in the background that acts on the row at once.
final class FilesOutlineView: NSOutlineView {
    weak var controller: FilesOutlineController?

    /// A click on a row of a window in the background selects it (and a double-click there opens it), as in Finder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, modifiers) {
        // kVK_Return, kVK_ANSI_KeypadEnter
        case (36, []), (76, []):
            controller?.openSelection()
        // kVK_Space
        case (49, []):
            controller?.toggleQuickLook()
        default:
            super.keyDown(with: event)
        }
    }

    /// The Finder keys the menus do not carry: ⌥⌘V (Move Item Here) and ⌘D (Duplicate), while the outline has the
    /// keyboard.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let controller, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command, .option], "v"):
            guard !AppState.pasteboardFiles().isEmpty else { return false }
            controller.paste(moving: true)
        case ([.command], "d"):
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
}

/// A Files row: the icon, the name (in git's color while git has something to say about the file, or about something
/// in the folder), a dot while it has unsaved edits and git's letter trailing; dimmed while git ignores it. On the
/// accent of a selected row in a focused outline the text and icon are white.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let unsaved = UnsavedDot()
    private let letter = NSTextField(labelWithString: "")
    private var mark: GitMarks.Mark?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        identifier = Self.identifier
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        unsaved.toolTip = "Unsaved changes"
        unsaved.setAccessibilityElement(false)
        letter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        letter.setContentCompressionResistancePriority(.required, for: .horizontal)
        letter.setContentHuggingPriority(.required, for: .horizontal)
        letter.setAccessibilityElement(false)
        imageView = icon
        textField = name

        let leading = NSStackView(views: [icon, name, unsaved])
        leading.orientation = .horizontal
        leading.spacing = 4
        leading.alignment = .centerY
        leading.detachesHiddenViews = true
        leading.setHuggingPriority(.defaultLow, for: .horizontal)
        for view in [leading, letter] {
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
        ])
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
        name.stringValue = node.name
        unsaved.isHidden = !isDirty
        let letterShown = !node.isDirectory ? mark : nil
        letter.isHidden = letterShown == nil
        letter.stringValue = letterShown?.letter ?? ""
        letter.toolTip = letterShown?.explanation
        alphaValue = isIgnored ? 0.5 : 1
        toolTip = node.path
        // One element for VoiceOver: the name, then what git says and whether it has unsaved edits.
        let git = mark.map { node.isDirectory ? "changes inside" : $0.word }
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(node.name)
        setAccessibilityValue([git, isDirty ? "edited" : nil].compactMap(\.self).joined(separator: ", "))
        name.setAccessibilityElement(false)
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        let white = NSColor.alternateSelectedControlTextColor
        icon.contentTintColor = selected ? white : .secondaryLabelColor
        name.textColor = selected ? white : mark?.color ?? .labelColor
        letter.textColor = selected ? white : mark?.color
        unsaved.color = selected ? white : .labelColor
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

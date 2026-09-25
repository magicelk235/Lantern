import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import IDEEditorModel
import IDEState

/// One open file. The text lives in a CodeEditSourceEditor `TextViewController` kept for as long as
/// the tab is open, so undo, selection and scroll survive switching tabs; an `EditorBuffer` measures it against the file
/// on disk. Unsaved text is copied to `state.sqlite` ~300 ms after typing pauses (hot-exit), and the file is
/// re-read when FSEvents reports a change: a buffer without edits follows it silently, one with edits gets a conflict.
@MainActor @Observable
final class EditorDocument {
    enum Content: Equatable {
        /// Editable text, in `controller`.
        case text
        /// Nothing at the path, and no unsaved copy of it.
        case missing
        case unsupported(UnsupportedReason)
    }

    /// The file on disk next to the unsaved text, for the compare sheet.
    struct Comparison: Identifiable {
        let id = UUID()
        let diskText: String
        let hunks: [LineDiff.Hunk]
    }

    let path: String
    let workspace: String
    private(set) var content: Content
    private(set) var isDirty = false
    /// A version of the file written on disk under unsaved edits, until the user reloads it or keeps theirs.
    private(set) var conflict: TextSnapshot? = nil
    private(set) var gone: EditorBuffer.Gone? = nil
    private(set) var language = CodeLanguage.default
    /// Line and column (1-based) of the first caret.
    private(set) var caret: CursorPosition.Position? = nil
    var comparison: Comparison? = nil

    var name: String { (path as NSString).lastPathComponent }
    /// Save writes the text: it has edits, or the file is gone and saving puts it back.
    var canSave: Bool { content == .text && (isDirty || gone != nil) }
    var canRevert: Bool { content == .text && isDirty && gone == nil }

    @ObservationIgnored private(set) var controller: TextViewController?
    @ObservationIgnored private var buffer: EditorBuffer?
    @ObservationIgnored private let persistence: StatePersistence
    /// The file as last read or written, to skip re-reading it when nothing touched it.
    @ObservationIgnored private var stamp: FileStamp?
    /// Receives the text view's changes; the controller only holds it weakly.
    @ObservationIgnored private var coordinator: Coordinator?
    @ObservationIgnored private var scrollObserver: (any NSObjectProtocol)?
    /// Where the view scrolls when it first appears (restored from the previous run).
    @ObservationIgnored private var pendingScroll: CGPoint?
    /// Indentation the file uses, detected when it opened.
    @ObservationIgnored private var indent = IndentOption.spaces(count: 4)
    /// Take the keyboard focus when the view next appears (opened from the navigator).
    @ObservationIgnored var focusOnAppear = false
    @ObservationIgnored private var hotExitWrite: Task<Void, Never>?
    /// When the oldest edit not in the hot-exit copy yet was made.
    @ObservationIgnored private var hotExitDueSince: ContinuousClock.Instant?
    /// `state.sqlite` holds a hot-exit copy for this path.
    @ObservationIgnored private var hotExitStored: Bool

    /// Opens `path` from disk, or from `restored` (its hot-exit copy), which wins: the unsaved text comes back even if
    /// the file changed meanwhile. `savedUI` puts the selection and scroll position back.
    init(path: String, workspace: String, restored: DirtyBuffer?, savedUI: EditorUIState?, persistence: StatePersistence) {
        self.path = path
        self.workspace = workspace
        self.persistence = persistence
        hotExitStored = restored != nil
        content = .missing
        stamp = FileStamp(path: path)
        load(EditorBuffer.open(path: path, disk: TextFile.read(path), restored: restored), savedUI: savedUI)
        // The copy matched the file: nothing is unsaved anymore.
        if !isDirty { clearHotExit() }
    }

    // MARK: - Commands

    /// Writes the text to the file (⌘S). On failure the edits stay unsaved, and in hot-exit.
    func save() throws {
        guard var buffer, let textView = controller?.textView else { return }
        let saved = try TextFile.write(textView.string, to: path)
        stamp = FileStamp(path: path)
        buffer.didSave(saved)
        self.buffer = buffer
        publish()
        clearHotExit()
    }

    /// Throws the edits away for the file as it is on disk now (Revert to Saved, and Reload in a conflict).
    func revert() {
        stamp = FileStamp(path: path)
        switch TextFile.read(path) {
        case .text(let snapshot):
            buffer?.reload(from: snapshot)
            show(snapshot.text)
            publish()
            clearHotExit()
        case .missing:
            // Deleted meanwhile: the text is all that is left, keep it.
            _ = diskDidChange(.missing)
        case .unsupported(let reason):
            becomeUnsupported(reason)
        }
    }

    /// Keeps the edits over the version in `conflict`: they now count against it, and saving overwrites it.
    func keepMine() {
        guard var buffer, let textView = controller?.textView else { return }
        buffer.keepMine(utf16Count: textView.textStorage.length) { textView.string }
        self.buffer = buffer
        publish()
        // The copy records the new baseline, so the conflict does not come back after a relaunch.
        if isDirty { writeHotExit() } else { clearHotExit() }
    }

    /// Diffs the file on disk against the unsaved text, off the main thread, then shows it in a sheet.
    func compare() {
        guard let conflict, let textView = controller?.textView else { return }
        let diskText = conflict.text
        let mine = textView.string
        Task {
            let hunks = await Task.detached(priority: .userInitiated) { LineDiff.hunks(from: diskText, to: mine) }.value
            comparison = Comparison(diskText: diskText, hunks: hunks)
        }
    }

    // MARK: - Disk

    /// The file may have changed: FSEvents reported it, its folder, or lost events. Read again unless `stat` shows
    /// nothing touched it since it was last read or written.
    func checkDisk() {
        let current = FileStamp(path: path)
        guard current != stamp else { return }
        stamp = current
        let disk = TextFile.read(path)
        switch content {
        case .text:
            _ = diskDidChange(disk)
        case .missing, .unsupported:
            load(EditorBuffer.open(path: path, disk: disk, restored: nil), savedUI: persistence.editorUI[path])
        }
    }

    private func diskDidChange(_ disk: FileContents) -> EditorBuffer.DiskChange {
        guard var buffer, let textView = controller?.textView else { return .none }
        let change = buffer.diskDidChange(disk, utf16Count: textView.textStorage.length) { textView.string }
        self.buffer = buffer
        switch change {
        case .none, .conflict, .gone:
            break
        case .reload(let snapshot):
            show(snapshot.text)
        case .becameClean:
            clearHotExit()
        case .unsupported(let reason):
            becomeUnsupported(reason)
        }
        publish()
        return change
    }

    private func load(_ opening: EditorBuffer.Opening, savedUI: EditorUIState?) {
        switch opening {
        case .text(let buffer, let text):
            self.buffer = buffer
            makeController(text: text, savedUI: savedUI)
            content = .text
            publish()
        case .missing:
            content = .missing
        case .unsupported(let reason):
            content = .unsupported(reason)
        }
    }

    private func becomeUnsupported(_ reason: UnsupportedReason) {
        tearDownController()
        buffer = nil
        content = .unsupported(reason)
        publish()
        clearHotExit()
    }

    /// Mirrors the buffer's state into the observed properties, touching only what changed.
    private func publish() {
        let dirty = buffer?.isDirty ?? false
        if isDirty != dirty { isDirty = dirty }
        if conflict != buffer?.conflict { conflict = buffer?.conflict }
        if gone != buffer?.gone { gone = buffer?.gone }
    }

    // MARK: - Text view

    private func makeController(text: String, savedUI: EditorUIState?) {
        tearDownController()
        let length = (text as NSString).length
        let selections = (savedUI?.selections ?? []).compactMap { selection -> CursorPosition? in
            let location = min(max(0, selection.location), length)
            return CursorPosition(range: NSRange(location: location, length: min(max(0, selection.length), length - location)))
        }
        language = CodeLanguage.detectLanguageFrom(url: URL(filePath: path), prefixBuffer: String(text.prefix(512)))
        indent = EditorStyle.indent(of: text)
        let coordinator = Coordinator(document: self)
        let controller = TextViewController(
            string: text, language: language,
            configuration: EditorStyle.configuration(indent: indent, appearance: NSApplication.shared.effectiveAppearance),
            cursorPositions: selections, highlightProviders: [TreeSitterClient()], coordinators: [coordinator])
        self.coordinator = coordinator
        self.controller = controller
        if let savedUI, savedUI.scrollX != 0 || savedUI.scrollY != 0 {
            pendingScroll = CGPoint(x: savedUI.scrollX, y: savedUI.scrollY)
        }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: TextViewController.scrollPositionDidUpdateNotification, object: controller, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveUI() }
        }
    }

    private func tearDownController() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        controller = nil
        coordinator = nil
        caret = nil
    }

    /// The system appearance changed: the theme's colors are concrete, so the editor needs new ones.
    func appearanceDidChange(_ appearance: NSAppearance) {
        controller?.configuration = EditorStyle.configuration(indent: indent, appearance: appearance)
    }

    /// Replaces the text with `newText` as one undoable edit of only the part that differs, so carets and the scroll
    /// position outside it stay where they were.
    private func show(_ newText: String) {
        guard let controller, let textView = controller.textView else { return }
        let old = textView.textStorage.string as NSString
        let new = newText as NSString
        let change = Self.differingRange(old, new)
        guard change.old.length > 0 || change.new.length > 0 else { return }
        let delta = change.new.length - change.old.length
        let changeEnd = NSMaxRange(change.old)
        let selections = textView.selectionManager.textSelections.map { selection -> NSRange in
            let range = selection.range
            if NSMaxRange(range) <= change.old.location { return range }
            if range.location >= changeEnd { return NSRange(location: range.location + delta, length: range.length) }
            return NSRange(location: min(range.location, NSMaxRange(change.new)), length: 0)
        }
        let origin = controller.isViewLoaded ? controller.scrollView.contentView.bounds.origin : nil
        textView.replaceCharacters(in: change.old, with: new.substring(with: change.new), skipUpdateSelection: true)
        textView.selectionManager.setSelectedRanges(selections)
        if let origin {
            controller.scrollView.contentView.scroll(to: origin)
            controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        }
    }

    /// The span that differs between `old` and `new` (after their common prefix, before their common suffix), in each,
    /// never splitting a surrogate pair.
    private static func differingRange(_ old: NSString, _ new: NSString) -> (old: NSRange, new: NSRange) {
        let oldLength = old.length
        let newLength = new.length
        var oldChars = [unichar](repeating: 0, count: oldLength)
        var newChars = [unichar](repeating: 0, count: newLength)
        old.getCharacters(&oldChars, range: NSRange(location: 0, length: oldLength))
        new.getCharacters(&newChars, range: NSRange(location: 0, length: newLength))
        var prefix = 0
        while prefix < oldLength, prefix < newLength, oldChars[prefix] == newChars[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(oldChars[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < oldLength - prefix, suffix < newLength - prefix,
              oldChars[oldLength - 1 - suffix] == newChars[newLength - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(oldChars[oldLength - suffix]) { suffix -= 1 }
        return (NSRange(location: prefix, length: oldLength - prefix - suffix),
                NSRange(location: prefix, length: newLength - prefix - suffix))
    }

    fileprivate func textDidChange() {
        guard var buffer, let textView = controller?.textView else { return }
        buffer.textDidChange(utf16Count: textView.textStorage.length) { textView.string }
        self.buffer = buffer
        publish()
        if isDirty { scheduleHotExit() } else { clearHotExit() }
    }

    fileprivate func selectionDidChange(_ positions: [CursorPosition]) {
        let first = positions.first?.start
        if caret != first { caret = first }
        saveUI()
    }

    fileprivate func controllerDidAppear() {
        guard let controller else { return }
        if let pendingScroll {
            self.pendingScroll = nil
            // After the first layout pass, which sizes the text view to its content.
            DispatchQueue.main.async {
                controller.scrollView.contentView.scroll(to: pendingScroll)
                controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
            }
        }
        if focusOnAppear {
            focusOnAppear = false
            controller.view.window?.makeFirstResponder(controller.textView)
        }
    }

    /// Remembers the selection and scroll position (debounced by the store).
    private func saveUI() {
        guard let controller, controller.isViewLoaded else { return }
        let origin = pendingScroll ?? controller.scrollView.contentView.bounds.origin
        let selections = controller.textView.selectionManager.textSelections.map {
            EditorUIState.Selection(location: $0.range.location, length: $0.range.length)
        }
        persistence.updateEditorUI(
            EditorUIState(path: path, selections: selections, scrollX: Double(origin.x), scrollY: Double(origin.y)))
    }

    // MARK: - Hot-exit

    /// Copies the unsaved text 300 ms after the last edit, and at least every 2 s while edits keep coming.
    private func scheduleHotExit() {
        let now = ContinuousClock.now
        let since = hotExitDueSince ?? now
        hotExitDueSince = since
        hotExitWrite?.cancel()
        let delay = min(Duration.milliseconds(300), max(.zero, since + .seconds(2) - now))
        hotExitWrite = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.writeHotExit()
        }
    }

    /// Writes the hot-exit copy now (typing paused, or the app is going away) if the text has unsaved edits.
    func writeHotExit() {
        hotExitWrite?.cancel()
        hotExitWrite = nil
        hotExitDueSince = nil
        guard let buffer, buffer.isDirty, let textView = controller?.textView else { return }
        persistence.saveDirtyBuffer(buffer.hotExitCopy(contents: textView.string))
        hotExitStored = true
    }

    /// A copy is still to be written: typing has not paused long enough yet.
    var hotExitPending: Bool { hotExitWrite != nil }

    /// Drops the hot-exit copy: the text is saved, reverted or discarded.
    func clearHotExit() {
        hotExitWrite?.cancel()
        hotExitWrite = nil
        hotExitDueSince = nil
        guard hotExitStored else { return }
        persistence.clearDirtyBuffer(path: path)
        hotExitStored = false
    }

    /// The tab closed: remember where it was and let go of the text view. Unsaved edits were saved or discarded first.
    func close() {
        saveUI()
        hotExitWrite?.cancel()
        hotExitWrite = nil
        tearDownController()
    }

    /// Forwards the text view's changes; CodeEditSourceEditor calls it on the main thread.
    private final class Coordinator: TextViewCoordinator {
        weak var document: EditorDocument?

        init(document: EditorDocument) {
            self.document = document
        }

        func prepareCoordinator(controller: TextViewController) {}

        func controllerDidAppear(controller: TextViewController) {
            let document = document
            MainActor.assumeIsolated { document?.controllerDidAppear() }
        }

        func textViewDidChangeText(controller: TextViewController) {
            let document = document
            MainActor.assumeIsolated { document?.textDidChange() }
        }

        func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
            let document = document
            MainActor.assumeIsolated { document?.selectionDidChange(newPositions) }
        }
    }
}

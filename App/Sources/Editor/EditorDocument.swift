import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import IDEEditorModel
import IDELanguageModel
import IDEState

/// One open file. The text lives in a CodeEditSourceEditor `TextViewController` kept for as long as
/// the tab is open, so undo, selection and scroll survive switching tabs; an `EditorBuffer` measures it against the file
/// on disk. Unsaved text is copied to `state.sqlite` ~300 ms after typing pauses (hot-exit), and the file is
/// re-read when FSEvents reports a change: a buffer without edits follows it silently, one with edits gets a conflict.
/// A `GitGutterView` over the gutter marks what differs from HEAD, and a `LanguageDocument` connects the text to the
/// project's language server for its language.
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
    /// The text's side of its language server; nil for a file no server takes, and without text.
    private(set) var languageDocument: LanguageDocument? = nil
    var comparison: Comparison? = nil

    var name: String { (path as NSString).lastPathComponent }
    /// Save writes the text: it has edits, or the file is gone and saving puts it back.
    var canSave: Bool { content == .text && (isDirty || gone != nil) }
    var canRevert: Bool { content == .text && isDirty && gone == nil }

    @ObservationIgnored private(set) var controller: TextViewController?
    @ObservationIgnored private var buffer: EditorBuffer?
    @ObservationIgnored private let persistence: StatePersistence
    @ObservationIgnored private let repository: GitRepository
    @ObservationIgnored private let languageServers: LanguageServers
    /// The file as last read or written, to skip re-reading it when nothing touched it.
    @ObservationIgnored private var stamp: FileStamp?
    /// Receives the text view's changes; the controller only holds it weakly.
    @ObservationIgnored private var coordinator: Coordinator?
    /// Hears every edit of the text storage (`textDidChange`); made with the controller and dropped with it.
    @ObservationIgnored private var storageObserver: StorageObserver?
    @ObservationIgnored private var textChangePending = false
    @ObservationIgnored private var scrollObserver: (any NSObjectProtocol)?
    /// Marks the gutter with what differs from HEAD; made with the controller and dropped with it.
    @ObservationIgnored private var gitGutter: GitGutterView?
    /// Where the view scrolls when it first appears (restored from the previous run).
    @ObservationIgnored private var pendingScroll: CGPoint?
    /// What a jump to a definition selects when the view first appears.
    @ObservationIgnored private var pendingReveal: NSRange?
    /// Indentation the file uses, detected when it opened.
    @ObservationIgnored private var indent = IndentOption.spaces(count: 4)
    /// Take the keyboard focus when the view next appears (opened from the navigator).
    @ObservationIgnored var focusOnAppear = false
    @ObservationIgnored private var hotExitWrite: Task<Void, Never>?
    /// The pending autosave: the edits are written to the file once typing pauses.
    @ObservationIgnored private var autosave: Task<Void, Never>?
    /// When the oldest edit not in the hot-exit copy yet was made.
    @ObservationIgnored private var hotExitDueSince: ContinuousClock.Instant?
    /// `state.sqlite` holds a hot-exit copy for this path.
    @ObservationIgnored private var hotExitStored: Bool

    /// Opens `path` from disk, or from `restored` (its hot-exit copy), which wins: the unsaved text comes back even if
    /// the file changed meanwhile. `savedUI` puts the selection and scroll position back; `repository` is the
    /// project's, whose refreshes tell the gutter marks when HEAD moved; `languageServers` start the text's server.
    init(
        path: String, workspace: String, restored: DirtyBuffer?, savedUI: EditorUIState?, persistence: StatePersistence,
        repository: GitRepository, languageServers: LanguageServers
    ) {
        self.path = path
        self.workspace = workspace
        self.persistence = persistence
        self.repository = repository
        self.languageServers = languageServers
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
        gitGutter?.textDidSave()
        languageDocument?.didSave()
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
        let storageObserver = StorageObserver { [weak self] _, _ in self?.scheduleTextDidChange() }
        controller.textView.addStorageDelegate(storageObserver)
        self.storageObserver = storageObserver
        let gitGutter = GitGutterView(path: path, textView: controller.textView, repository: repository)
        gitGutter.refresh()
        self.gitGutter = gitGutter
        languageDocument = LanguageDocument(path: path, workspace: workspace, controller: controller, servers: languageServers)
        if let savedUI, savedUI.scrollX != 0 || savedUI.scrollY != 0 {
            pendingScroll = CGPoint(x: savedUI.scrollX, y: savedUI.scrollY)
        }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: TextViewController.scrollPositionDidUpdateNotification, object: controller, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveUI()
                self?.gitGutter?.syncFrame()
            }
        }
    }

    private func tearDownController() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let storageObserver { controller?.textView.removeStorageDelegate(storageObserver) }
        storageObserver = nil
        gitGutter?.detach()
        gitGutter = nil
        languageDocument?.close()
        languageDocument = nil
        pendingReveal = nil
        controller = nil
        coordinator = nil
        caret = nil
    }

    /// The system appearance changed: the theme's colors are concrete, so the editor needs new ones (and keeps the
    /// characters its language server completes after).
    func appearanceDidChange(_ appearance: NSAppearance) {
        var configuration = EditorStyle.configuration(indent: indent, appearance: appearance)
        configuration.peripherals.codeSuggestionTriggerCharacters = languageDocument?.completionTriggers ?? []
        controller?.configuration = configuration
        languageDocument?.render()
    }

    /// Selects `target` (a definition jumped to) and scrolls it into the middle of the view if it is out of sight; when
    /// the view has not appeared yet, once it has.
    func reveal(_ target: DefinitionTarget) {
        guard let controller, let textView = controller.textView else { return }
        let range = target.range(in: textView.textStorage.mutableString)
        guard controller.isViewLoaded, textView.window != nil else {
            pendingReveal = range
            pendingScroll = nil
            return
        }
        select(range, in: textView)
    }

    private func select(_ range: NSRange, in textView: TextView) {
        textView.selectionManager.setSelectedRange(range)
        textView.scrollToRange(range, center: true)
        textView.window?.makeFirstResponder(textView)
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

    /// The text changed: once the edit (and any the typing filters add to it) is done, the buffer's state follows.
    private func scheduleTextDidChange() {
        guard !textChangePending else { return }
        textChangePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.textChangePending = false
                self?.textDidChange()
            }
        }
    }

    private func textDidChange() {
        guard var buffer, let textView = controller?.textView else { return }
        buffer.textDidChange(utf16Count: textView.textStorage.length) { textView.string }
        self.buffer = buffer
        publish()
        gitGutter?.textDidChange()
        if isDirty { scheduleHotExit(); scheduleAutosave() } else { clearHotExit(); autosave?.cancel() }
    }

    // MARK: - Autosave

    /// Edits are saved by themselves once typing pauses for this long (hot-exit covers the gap).
    static let autosaveDelay: Duration = .seconds(1)

    /// Saves after `autosaveDelay` without edits, unless the file changed on disk underneath (then the conflict
    /// notice decides) or is gone (Save puts it back on purpose).
    private func scheduleAutosave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            autosaveNow()
        }
    }

    /// Writes the edits now if nothing stands in the way (the window resigns key, the tab closes).
    func autosaveNow() {
        autosave?.cancel()
        autosave = nil
        guard isDirty, conflict == nil, gone == nil, content == .text else { return }
        // A failed write keeps the edits (and their hot-exit copy); ⌘S reports the reason.
        try? save()
    }

    fileprivate func selectionDidChange(_ positions: [CursorPosition]) {
        let first = positions.first?.start
        if caret != first { caret = first }
        saveUI()
        languageDocument?.selectionDidChange()
    }

    fileprivate func controllerDidAppear() {
        guard let controller else { return }
        gitGutter?.attach(to: controller)
        if let pendingScroll {
            self.pendingScroll = nil
            // After the first layout pass, which sizes the text view to its content.
            DispatchQueue.main.async {
                controller.scrollView.contentView.scroll(to: pendingScroll)
                controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
            }
        }
        if let pendingReveal {
            self.pendingReveal = nil
            // After the first layout pass, like the restored scroll position.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.select(pendingReveal, in: controller.textView) }
            }
        } else if focusOnAppear {
            controller.view.window?.makeFirstResponder(controller.textView)
        }
        focusOnAppear = false
        languageDocument?.render()
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

    /// Forwards the text view's appearance and selection changes; CodeEditSourceEditor calls it on the main thread. Text
    /// changes come from the storage (`StorageObserver`): this delegate misses the typing filters' edits.
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

        func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
            let document = document
            MainActor.assumeIsolated { document?.selectionDidChange(newPositions) }
        }
    }
}

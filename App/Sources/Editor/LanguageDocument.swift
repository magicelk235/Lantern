import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import IDELanguageModel

/// An editor's side of its language server, for as long as the editor has a text view: it tells the
/// server about the text (`didOpen` once the server is up, every edit as `didChange`, `didSave`, `didClose`), underlines
/// the errors (red) and warnings (yellow) it publishes and counts them for the status bar, and asks it for hover text,
/// definitions and completions. Edits are read off the text storage, so every change counts, including those the
/// editor's typing filters make (auto-indent, closing brackets), which bypass the text view's delegate.
@MainActor @Observable
final class LanguageDocument {
    let path: String
    let key: LanguageServers.Key
    /// The errors and warnings in the text, for the status bar.
    private(set) var counts = DiagnosticCounts(errors: 0, warnings: 0)
    /// What the server offers; nil until it has the document open, and after it ended.
    private(set) var features: ServerFeatures?

    /// What the server published last, moved along with edits since.
    @ObservationIgnored private(set) var diagnostics: [EditorDiagnostic] = []
    @ObservationIgnored private let language: DocumentLanguage
    @ObservationIgnored private weak var controller: TextViewController?
    @ObservationIgnored private var sync: DocumentSync
    @ObservationIgnored private var server: LanguageServer?
    @ObservationIgnored private let servers: LanguageServers
    @ObservationIgnored private var storageObserver: StorageObserver?
    @ObservationIgnored private var completion: LanguageCompletion?
    @ObservationIgnored private var hover: LanguageHover?
    @ObservationIgnored private var renderPending = false
    @ObservationIgnored private var isClosed = false
    /// The underlines of errors and of warnings, sublayers of the text view's layer.
    @ObservationIgnored private var underlineLayers: [CAShapeLayer] = []
    @ObservationIgnored private var frameObserver: (any NSObjectProtocol)?

    /// The language side of the editor of `path` in `workspace`, with `controller`'s text; nil for a file no language
    /// server takes. It joins (or starts) the project's server for the file's language.
    init?(path: String, workspace: String, controller: TextViewController, servers: LanguageServers) {
        guard let language = DocumentLanguage(path: path) else { return nil }
        self.path = path
        self.language = language
        key = LanguageServers.Key(root: workspace, kind: language.kind)
        self.controller = controller
        self.servers = servers
        sync = DocumentSync(path: path, languageId: language.languageId, text: controller.textView.textStorage.mutableString)
        let observer = StorageObserver { [weak self] range, newLength in self?.textDidReplace(range, newLength: newLength) }
        controller.textView.addStorageDelegate(observer)
        storageObserver = observer
        let completion = LanguageCompletion(document: self)
        controller.completionDelegate = completion
        self.completion = completion
        hover = LanguageHover(document: self, textView: controller.textView)
        servers.attach(self)
    }

    private var textView: TextView? { controller?.textView }

    // MARK: - Server

    /// The server is up: it gets the text as it is now.
    func connect(_ server: LanguageServer, _ features: ServerFeatures) {
        guard !isClosed, let controller else { return }
        let text = controller.textView.textStorage.mutableString
        sync = DocumentSync(path: path, languageId: language.languageId, text: text)
        self.server = server
        self.features = features
        if features.openClose { server.open(sync.openParams(text: text as String)) }
        controller.configuration.peripherals.codeSuggestionTriggerCharacters = completionTriggers
    }

    /// The server ended by itself: what it said no longer holds.
    func disconnect() {
        server = nil
        features = nil
        hover?.close()
        show([])
        controller?.configuration.peripherals.codeSuggestionTriggerCharacters = []
    }

    /// The characters after which the editor asks for completions.
    var completionTriggers: Set<String> {
        Set(features?.completionTriggers ?? [])
    }

    /// The server published diagnostics for the file. Those found in an older version of the text than the one it has
    /// now wait for the next publication; the ones shown move with the edits meanwhile.
    func publish(_ published: PublishedDiagnostics) {
        guard features != nil, !published.isOlder(than: sync.version), let textView else { return }
        show(published.editorDiagnostics(lines: sync.lines, in: textView.textStorage.mutableString))
    }

    /// The text was saved.
    func didSave() {
        guard let server, let features, features.openClose, features.save, let textView else { return }
        server.save(sync.saveParams(text: features.saveIncludesText ? textView.string : nil))
    }

    /// The editor lets go of its text view: the server hears `didClose`, and stops when this was its last editor.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let server, features?.openClose == true { server.close(sync.closeParams) }
        server = nil
        features = nil
        hover?.detach()
        hover = nil
        if let storageObserver { textView?.removeStorageDelegate(storageObserver) }
        storageObserver = nil
        for layer in underlineLayers { layer.removeFromSuperlayer() }
        underlineLayers = []
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        if controller?.completionDelegate === completion { controller?.completionDelegate = nil }
        completion = nil
        servers.detach(self)
    }

    // MARK: - Text

    /// `range` of the text was replaced with `newLength` characters (the text storage's edit, after the fact).
    private func textDidReplace(_ range: NSRange, newLength: Int) {
        guard !isClosed, let textView else { return }
        if let params = sync.didReplace(range, newLength: newLength, in: textView.textStorage.mutableString, features: features) {
            server?.change(params)
        }
        hover?.close()
        guard !diagnostics.isEmpty else { return }
        diagnostics = diagnostics.map { $0.adjusted(replacing: range, newLength: newLength) }
        scheduleRender()
    }

    /// The caret moved: a popover about the text under the mouse goes.
    func selectionDidChange() {
        hover?.close()
    }

    // MARK: - Diagnostics

    private func show(_ diagnostics: [EditorDiagnostic]) {
        self.diagnostics = diagnostics
        let counts = DiagnosticCounts(diagnostics)
        if self.counts != counts { self.counts = counts }
        scheduleRender()
    }

    /// The diagnostics whose text holds `offset` (or, for an empty one, whose underlined character does).
    func diagnostics(at offset: Int) -> [EditorDiagnostic] {
        guard let textView else { return [] }
        let text = textView.textStorage.mutableString
        return diagnostics.filter { diagnostic in
            let range = diagnostic.underline(in: text) ?? diagnostic.range
            return range.location <= offset && offset < NSMaxRange(range)
        }
    }

    /// Underlines the errors and warnings once the current edit is done (the text view lays the text out first).
    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.renderPending = false
                self?.render()
            }
        }
    }

    /// Draws the underlines: in the text view's layer, so only once it is in a window (the editor appeared), again when
    /// the appearance changes (the colors are resolved when drawn) and when the text view's width does (lines wrap
    /// anew). Own shape layers, not the text view's emphases: those also lay a black copy of the text over it, which
    /// dims the code they underline.
    func render() {
        guard !isClosed, let textView, textView.window != nil, let host = textView.layer, let layoutManager = textView.layoutManager
        else { return }
        observeFrame(of: textView)
        if underlineLayers.isEmpty {
            underlineLayers = [CAShapeLayer(), CAShapeLayer()]
            for layer in underlineLayers {
                layer.lineWidth = 1
                layer.lineCap = .round
                layer.fillColor = nil
                layer.zPosition = 1
                layer.actions = ["path": NSNull(), "strokeColor": NSNull()]
                host.addSublayer(layer)
            }
        }
        let text = textView.textStorage.mutableString
        let lineHeight = layoutManager.estimateLineHeight()
        let inset = (lineHeight - lineHeight / layoutManager.lineHeightMultiplier) / 4
        let paths = [CGMutablePath(), CGMutablePath()]
        for diagnostic in diagnostics where diagnostic.severity <= .warning {
            guard let range = diagnostic.underline(in: text) else { continue }
            let path = paths[diagnostic.severity == .error ? 0 : 1]
            for rect in layoutManager.rectsFor(range: range) {
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
            }
        }
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            underlineLayers[0].strokeColor = NSColor.systemRed.cgColor
            underlineLayers[1].strokeColor = NSColor.systemYellow.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, path) in zip(underlineLayers, paths) {
            if layer.superlayer !== host { host.addSublayer(layer) }
            layer.frame = host.bounds
            layer.path = path
        }
        CATransaction.commit()
    }

    private func observeFrame(of textView: TextView) {
        guard frameObserver == nil else { return }
        textView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRender() }
        }
    }

    // MARK: - Requests

    /// What the server says about the text at `offset`; empty without hover or a server.
    func hover(at offset: Int) async -> [HoverBlock] {
        guard let server, features?.hover == true else { return [] }
        let position = sync.lines.position(at: offset)
        return (try? await server.hover(sync.uri, at: position)) ?? []
    }

    /// Where the symbol at `offset` is defined.
    func definitions(at offset: Int) async -> [DefinitionTarget] {
        guard let server, features?.definition == true else { return [] }
        let position = sync.lines.position(at: offset)
        return (try? await server.definitions(sync.uri, at: position)) ?? []
    }

    /// The completions at `offset`, asked for after typing `trigger` or as the user types a word (nil).
    func completions(at offset: Int, trigger: String?) async -> [CompletionCandidate] {
        guard let server, features?.completionTriggers != nil else { return [] }
        let position = sync.lines.position(at: offset)
        return (try? await server.completions(sync.uri, at: position, trigger: trigger)) ?? []
    }

    /// Puts `candidate` in place of the text typed from `start` to `cursor`, with its other edits, as one undo step.
    func accept(_ candidate: CompletionCandidate, typedFrom start: Int, to cursor: Int) {
        guard let textView else { return }
        let text = textView.textStorage.mutableString
        let edits = candidate.edits(replacingTypedTextFrom: start, to: min(cursor, text.length), lines: sync.lines, in: text)
        textView.undoManager?.beginUndoGrouping()
        for edit in edits { textView.replaceCharacters(in: edit.range, with: edit.text) }
        textView.undoManager?.endUndoGrouping()
    }

    var canJumpToDefinition: Bool { features?.definition == true }

    var canShowQuickHelp: Bool { features != nil }

    /// Navigate › Show Quick Help: the popover for the text at the caret.
    func showQuickHelp() {
        hover?.showAtCaret()
    }
}

/// Reports the text storage's character edits as the range they replaced in the text before and the length of what
/// replaced it. A batch of edits (multiple carets, an undo) arrives as one: the span from the first change to the last.
/// Every edit comes through, also those the editor's typing filters write straight to the storage (auto-indent,
/// closing brackets, Tab), which the text view's delegate never hears of.
final class StorageObserver: NSObject, NSTextStorageDelegate {
    private let edited: @MainActor @Sendable (NSRange, Int) -> Void

    init(edited: @escaping @MainActor @Sendable (NSRange, Int) -> Void) {
        self.edited = edited
    }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let replaced = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let edited = edited
        MainActor.assumeIsolated { edited(replaced, editedRange.length) }
    }
}

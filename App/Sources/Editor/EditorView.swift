import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import IDEEditorModel
import SwiftUI

/// An editor tab: the file's text with syntax highlighting, its find bar, and the notices about the file on disk. An
/// image, PDF, video or audio file shows as itself (`MediaView`); other files the editor does not open as text show a
/// notice instead. Caret and language, or what the media is, show in the window's status bar.
struct EditorView: View {
    let app: AppState
    @Bindable var document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            DiskNotices(app: app, document: document)
            switch document.content {
            case .text:
                if let controller = document.controller {
                    if #available(macOS 26, *) {
                        SourceEditorHost(document: document, controller: controller)
                            .id(ObjectIdentifier(controller))
                            .overlay(alignment: .topTrailing) {
                                if document.find.isShown {
                                    FloatingFindBar(document: document)
                                }
                            }
                            .onChange(of: document.find.isShown) { _, shown in
                                if !shown { document.setFindBarInset(0) }
                            }
                    } else {
                        VStack(spacing: 0) {
                            if document.find.isShown {
                                FindBar(find: document.find)
                            }
                            SourceEditorHost(document: document, controller: controller)
                                .id(ObjectIdentifier(controller))
                        }
                    }
                }
            case .missing:
                ContentUnavailableView {
                    Label("“\(document.name)” no longer exists", systemImage: "questionmark.folder")
                } description: {
                    Text(document.path)
                } actions: {
                    Button("Close Tab") { app.closeTab(.editor(path: document.path)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Chrome.canvas)
            case .media:
                if let media = document.media {
                    MediaView(app: app, document: document, media: media)
                }
            case .unsupported(let reason):
                FileNotice(app: app, document: document, title: "“\(document.name)” can’t be shown here", explanation: reason.explanation)
            }
        }
        .sheet(item: $document.comparison) { comparison in
            CompareSheet(document: document, comparison: comparison)
        }
    }
}

/// From macOS 26 the find bar is a panel of Liquid Glass floating over the text's top trailing corner, the text
/// scrolling under it; the text starts below it (`EditorDocument.setFindBarInset`).
@available(macOS 26, *)
private struct FloatingFindBar: View {
    let document: EditorDocument

    /// Room around the panel, from the editor's edges and from the text below it.
    private static let margin: CGFloat = 8
    /// Wide enough for the field to take a long query; narrower editors give it their width less the margins.
    private static let maximumWidth: CGFloat = 560

    var body: some View {
        FindBar(find: document.find, floats: true)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .frame(maxWidth: Self.maximumWidth)
            .padding(Self.margin)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                document.setFindBarInset(height)
            }
    }
}

/// The document's `TextViewController`, the same one each time the tab shows (`EditorHostingView`). Clipped to its
/// frame: the gutter floats in the scroll view as tall as the text and would draw its line numbers over the find bar
/// above.
private struct SourceEditorHost: NSViewRepresentable {
    let document: EditorDocument
    let controller: TextViewController

    func makeNSView(context: Context) -> EditorHostingView {
        controller.view.clipsToBounds = true
        return EditorHostingView(document: document)
    }

    func updateNSView(_ nsView: EditorHostingView, context: Context) {}
}

/// Where the document's text shows while the host is in a window (`EditorDocument.host(in:)`): the controller has one
/// view, and a second window SwiftUI opens for the same project gets a host of its own until it closes again. Files
/// dropped on the text (from Files, from Finder) type their paths where they land: relative to the project for its
/// own files, whole for others, one per line.
final class EditorHostingView: NSView {
    private let document: EditorDocument
    private var closeObserver: (any NSObjectProtocol)?
    /// Where dropped paths would go, while files are dragged over the text.
    private let dropCaret = NSView()

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        dropCaret.wantsLayer = true
        dropCaret.layer?.backgroundColor = NSColor.textInsertionPointColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatchingWindow()
        guard let window else {
            document.unhost(self)
            return
        }
        // A window that closes may keep its views: the text leaves with the window, not with the view.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopWatchingWindow()
                self.document.unhost(self)
            }
        }
        document.host(in: self)
    }

    /// Shows the controller's view, filling the host.
    func embed(_ view: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func stopWatchingWindow() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let (textView, offset) = dropTarget(sender), let rect = textView.layoutManager.rectForOffset(offset) else {
            dropCaret.removeFromSuperview()
            return []
        }
        if dropCaret.superview !== textView { textView.addSubview(dropCaret) }
        dropCaret.frame = NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropCaret.removeFromSuperview()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropCaret.removeFromSuperview()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropCaret.removeFromSuperview()
        guard let (textView, offset) = dropTarget(sender) else { return false }
        let text = AppState.pasteboardFiles(sender.draggingPasteboard)
            .map { AppState.relativePath($0, in: document.workspace) }
            .joined(separator: textView.layoutManager.detectedLineEnding.rawValue)
        textView.replaceCharacters(in: NSRange(location: offset, length: 0), with: text)
        textView.selectionManager.setSelectedRange(NSRange(location: offset, length: (text as NSString).length))
        window?.makeFirstResponder(textView)
        return true
    }

    /// The text view and the place in its text under a drag of files, when the text takes them.
    private func dropTarget(_ info: any NSDraggingInfo) -> (TextView, Int)? {
        guard let textView = document.controller?.textView, textView.isEditable, textView.window === window,
              !AppState.pasteboardFiles(info.draggingPasteboard).isEmpty,
              let offset = textView.layoutManager.textOffsetAtPoint(textView.convert(info.draggingLocation, from: nil))
        else { return nil }
        return (textView, offset)
    }
}

/// Jump to Line (⌘L), from the status bar's caret position: a line, or line:column, for the caret; Return goes there,
/// Esc leaves.
struct JumpToLine: View {
    let document: EditorDocument
    @State private var target = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Line", text: $target, prompt: Text("Line or Line:Column"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($focused)
                .onSubmit { if !document.jump(to: target) { NSSound.beep() } }
            Text("Lines 1–\(document.lineCount)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.chromeSecondary)
        }
        .padding(10)
        .onAppear { focused = true }
    }
}

/// What happened to the file on disk under this tab, and a save that failed.
private struct DiskNotices: View {
    let app: AppState
    let document: EditorDocument

    var body: some View {
        if let failure = document.saveFailure {
            NoticeBar(systemImage: "exclamationmark.triangle", tint: .red, title: "", message: failure.message) {
                Button("Save As…") { Task { await app.saveAs(document) } }
                Button("Reveal in Finder") { app.revealInFinder(document.path) }
                Button("Try Again") { try? document.save() }
            }
        } else if document.conflict != nil {
            NoticeBar(
                systemImage: "exclamationmark.triangle", tint: .orange, title: "Changed on disk",
                message: "Another program changed “\(document.name)” while you had unsaved edits."
            ) {
                Button("Compare…") { document.compare() }
                Button("Keep Mine") { document.keepMine() }
                Button("Reload") { document.revert() }
            }
        } else if let gone = document.gone {
            NoticeBar(
                systemImage: "trash", tint: .orange,
                title: gone == .deleted ? "Deleted on disk" : "Replaced on disk",
                message: gone == .deleted
                    ? "“\(document.name)” no longer exists. Saving writes this text back."
                    : "“\(document.name)” is no longer a text file. Saving replaces it with this text."
            ) {
                Button("Save") { app.saveSelectedEditor() }
                Button("Close Tab") { app.closeTab(.editor(path: document.path)) }
            }
        }
    }
}

/// A file the tab can't show: why, and the ways to see it elsewhere (its default app, Quick Look, Finder).
struct FileNotice: View {
    let app: AppState
    let document: EditorDocument
    let title: String
    let explanation: String
    @State private var width: CGFloat = 0

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc.questionmark")
        } description: {
            Text(explanation)
        } actions: {
            // The view offers its actions less than its own width, too little for them all in a row: they are
            // measured against the notice's width (less its margins) and stack when even that is too narrow.
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize()
                VStack { actions }.fixedSize()
            }
            .frame(width: width > 0 ? max(0, width - 40) : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Chrome.canvas)
    }

    @ViewBuilder
    private var actions: some View {
        let url = URL(filePath: document.path)
        if let opener = NSWorkspace.shared.urlForApplication(toOpen: url) {
            Button("Open with \(Self.appName(opener))") { NSWorkspace.shared.open(url) }
        }
        // Quick Look has nothing to show for a folder.
        if document.content != .unsupported(.directory) {
            Button("Quick Look") { app.toggleQuickLook(document.path, in: app.currentProject ?? document.workspace) }
        }
        Button("Reveal in Finder") { app.revealInFinder(document.path) }
        Button("Close Tab") { app.closeTab(.editor(path: document.path)) }
    }

    /// "Preview", the way the Finder names the app at `url`, without its extension.
    private static func appName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

extension UnsupportedReason {
    /// Why the file is not shown, in a sentence.
    var explanation: String {
        switch self {
        case .tooLarge(let bytes):
            "It is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); the editor opens files up to \(ByteCountFormatter.string(fromByteCount: Int64(TextFile.sizeLimit), countStyle: .file))."
        case .binary:
            "It is a binary file, or text that is not UTF-8."
        case .directory:
            "It is a folder."
        case .unreadable(let message):
            "It could not be read: \(message)."
        }
    }
}

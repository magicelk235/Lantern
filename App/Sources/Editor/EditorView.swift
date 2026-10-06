import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import IDEEditorModel
import SwiftUI

/// An editor tab: the file's text with syntax highlighting, its find bar, and the notices about the file on disk. Files
/// the editor does not open as text show a notice instead. Caret and language show in the window's status bar.
struct EditorView: View {
    let app: AppState
    @Bindable var document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            DiskNotices(app: app, document: document)
            switch document.content {
            case .text:
                if let controller = document.controller {
                    VStack(spacing: 0) {
                        if document.find.isShown {
                            FindBar(find: document.find)
                        }
                        SourceEditorHost(controller: controller)
                            .id(ObjectIdentifier(controller))
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
            case .unsupported(let reason):
                UnsupportedNotice(document: document, reason: reason) { app.closeTab(.editor(path: document.path)) }
            }
        }
        .sheet(item: $document.comparison) { comparison in
            CompareSheet(document: document, comparison: comparison)
        }
    }
}

/// The document's `TextViewController`, the same one each time the tab shows. Clipped to its frame: the gutter floats
/// in the scroll view as tall as the text and would draw its line numbers over the find bar above.
private struct SourceEditorHost: NSViewControllerRepresentable {
    let controller: TextViewController

    func makeNSViewController(context: Context) -> TextViewController {
        controller.view.clipsToBounds = true
        return controller
    }

    func updateNSViewController(_ controller: TextViewController, context: Context) {}
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
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .onAppear { focused = true }
    }
}

/// What happened to the file on disk under this tab.
private struct DiskNotices: View {
    let app: AppState
    let document: EditorDocument

    var body: some View {
        if document.conflict != nil {
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

private struct UnsupportedNotice: View {
    let document: EditorDocument
    let reason: UnsupportedReason
    let close: () -> Void
    @State private var width: CGFloat = 0

    var body: some View {
        ContentUnavailableView {
            Label("“\(document.name)” can’t be shown here", systemImage: "doc.questionmark")
        } description: {
            Text(explanation)
        } actions: {
            // The view offers its actions less than its own width, too little for the three in a row: they are
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
        Button("Open with Default App") { NSWorkspace.shared.open(URL(filePath: document.path)) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: document.path)]) }
        Button("Close Tab", action: close)
    }

    private var explanation: String {
        switch reason {
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

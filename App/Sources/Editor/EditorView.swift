import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import IDEEditorModel
import SwiftUI

/// An editor tab: the file's text with syntax highlighting, and the notices about the file on disk. Files the editor
/// does not open as text show a notice instead. Caret and language show in the window's status bar.
struct EditorView: View {
    let app: AppState
    @Bindable var document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            DiskNotices(app: app, document: document)
            switch document.content {
            case .text:
                if let controller = document.controller {
                    SourceEditorHost(controller: controller)
                        .id(ObjectIdentifier(controller))
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

/// The document's `TextViewController`, the same one each time the tab shows.
private struct SourceEditorHost: NSViewControllerRepresentable {
    let controller: TextViewController

    func makeNSViewController(context: Context) -> TextViewController { controller }

    func updateNSViewController(_ controller: TextViewController, context: Context) {}
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

    var body: some View {
        ContentUnavailableView {
            Label("“\(document.name)” can’t be shown here", systemImage: "doc.questionmark")
        } description: {
            Text(explanation)
        } actions: {
            HStack {
                Button("Open with Default App") { NSWorkspace.shared.open(URL(filePath: document.path)) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: document.path)])
                }
                Button("Close Tab", action: close)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
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

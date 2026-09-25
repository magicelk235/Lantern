import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import IDEEditorModel
import SwiftUI

/// An editor tab: the file's text with syntax highlighting, the banners about the file on disk, and a status line.
/// Files the editor does not open as text show a notice instead.
struct EditorView: View {
    let app: AppState
    @Bindable var document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            DiskBanners(app: app, document: document)
            switch document.content {
            case .text:
                if let controller = document.controller {
                    SourceEditorHost(controller: controller)
                        .id(ObjectIdentifier(controller))
                }
                Divider()
                EditorStatusLine(document: document)
            case .missing:
                ContentUnavailableView {
                    Label("“\(document.name)” no longer exists", systemImage: "questionmark.folder")
                } description: {
                    Text(document.path)
                } actions: {
                    Button("Close Tab") { app.closeTab(.editor(path: document.path)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unsupported(let reason):
                UnsupportedNotice(document: document, reason: reason) { app.closeTab(.editor(path: document.path)) }
            }
        }
        .navigationTitle(document.name)
        .navigationSubtitle(relativePath)
        .sheet(item: $document.comparison) { comparison in
            CompareSheet(document: document, comparison: comparison)
        }
    }

    private var relativePath: String {
        let parent = (document.path as NSString).deletingLastPathComponent
        guard parent.hasPrefix(document.workspace) else { return parent }
        let relative = parent.dropFirst(document.workspace.count).drop { $0 == "/" }
        let workspaceName = (document.workspace as NSString).lastPathComponent
        return relative.isEmpty ? workspaceName : "\(workspaceName)/\(relative)"
    }
}

/// The document's `TextViewController`, the same one each time the tab shows.
private struct SourceEditorHost: NSViewControllerRepresentable {
    let controller: TextViewController

    func makeNSViewController(context: Context) -> TextViewController { controller }

    func updateNSViewController(_ controller: TextViewController, context: Context) {}
}

/// What happened to the file on disk under this tab.
private struct DiskBanners: View {
    let app: AppState
    let document: EditorDocument

    var body: some View {
        if document.conflict != nil {
            EditorBanner(
                systemImage: "exclamationmark.triangle", tint: .orange, title: "Changed on disk",
                message: "“\(document.name)” was changed by another program while you had unsaved edits."
            ) {
                Button("Compare…") { document.compare() }
                Button("Keep Mine") { document.keepMine() }
                Button("Reload") { document.revert() }
            }
        } else if let gone = document.gone {
            EditorBanner(
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

private struct EditorBanner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct EditorStatusLine: View {
    let document: EditorDocument

    var body: some View {
        HStack(spacing: 12) {
            if let caret = document.caret {
                Text("Line \(caret.line), Column \(caret.column)")
            }
            Spacer()
            if document.isDirty {
                Text("Edited")
            }
            Text(document.language.id == .plainText ? "Plain Text" : document.language.tsName.capitalized)
            Text("UTF-8")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
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

import AppKit
import IDEModel
import IDEState
import SwiftUI

/// The tabs of the workspace on screen, above the detail area: flat, hairline-separated, the selected one attached
/// to the content by sharing its canvas. Selecting a tab shows it; closing one leaves its omp session or terminal
/// running, and closing an editor with unsaved edits asks first.
struct TabStrip: View {
    let app: AppState
    let strip: TabLayout.Strip

    var body: some View {
        ZStack(alignment: .bottom) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(strip.tabs, id: \.self) { tab in
                        TabItem(
                            tab: tab, title: title(of: tab), entry: tab.sessionKey.flatMap(app.entry(for:)),
                            terminalExited: tab.ptyId.map { app.terminals.model($0)?.hasExited == true },
                            document: tab.editorPath.flatMap(app.editors.document(for:)),
                            isSelected: app.tabs.selection == tab, select: { app.selectTab(tab) }, close: { app.closeTab(tab) }
                        )
                        .contextMenu { TabMenu(app: app, tab: tab) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(height: Chrome.tabStripHeight)
        .background(Chrome.surface)
    }

    private func title(of tab: TabKind) -> String {
        switch tab {
        case .session(let key): app.sessionTitle(key)
        case .terminal(let ptyId): app.terminals.title(for: ptyId)
        case .editor(let path): (path as NSString).lastPathComponent
        }
    }
}

/// Close Tab, and what the tab's kind allows: Resume or Close Session, Close Terminal, Reveal in Finder.
private struct TabMenu: View {
    let app: AppState
    let tab: TabKind

    var body: some View {
        Button("Close Tab") { app.closeTab(tab) }
        Divider()
        switch tab {
        case .session(let key):
            if let entry = app.entry(for: key) {
                SessionMenu(app: app, entry: entry)
            }
        case .terminal(let ptyId):
            Button("Close Terminal…") { app.requestCloseTerminal(ptyId) }
                .disabled(!app.connection.isConnected)
        case .editor(let path):
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        }
    }
}

private struct TabItem: View {
    let tab: TabKind
    let title: String
    /// The session, for a session tab.
    let entry: SessionManifestEntry?
    /// Whether the program ended, for a terminal tab.
    let terminalExited: Bool?
    /// The file an editor tab shows.
    let document: EditorDocument?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 6) {
                    indicator
                        .frame(width: 12)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 200, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.editorPath ?? title)
            .accessibilityLabel("Tab \(title)" + (document?.isDirty == true ? ", edited" : ""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || hovering ? 1 : 0)
            .help(tab.ptyId != nil ? "Close Tab (the terminal keeps running)" : document != nil ? "Close Tab" : "Close Tab (the session keeps running)")
            .accessibilityLabel("Close Tab \(title)")
        }
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background(isSelected ? Chrome.canvas : hovering ? Color.primary.opacity(0.04) : .clear)
        .overlay(alignment: .trailing) { Chrome.hairline.frame(width: 1) }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var indicator: some View {
        if let terminalExited {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(terminalExited ? .tertiary : .secondary)
        } else if let document {
            if document.isDirty {
                Circle().fill(.primary).frame(width: 7, height: 7).help("Unsaved changes")
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else if let status = entry?.status {
            if status.isInProgress {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(color: status.dotColor, hollow: status == .closed)
            }
        } else {
            StatusDot(color: .secondary, hollow: true)
        }
    }
}

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

    /// Widest a tab gets; with many tabs they shrink evenly to `minimumTabWidth`, then the strip scrolls.
    static let maximumTabWidth: CGFloat = 220
    static let minimumTabWidth: CGFloat = 72
    private static let newTabButtonWidth: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - Self.newTabButtonWidth
            let width = min(Self.maximumTabWidth, max(Self.minimumTabWidth, available / CGFloat(max(strip.tabs.count, 1))))
            ZStack(alignment: .bottom) {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(strip.tabs, id: \.self) { tab in
                            // A terminal running an adopted session stands for that session: its title, status and menu.
                            let hosted = tab.ptyId.flatMap(app.adoptedSession(on:))
                            TabItem(
                                tab: tab, title: title(of: tab), entry: tab.sessionKey.flatMap(app.entry(for:)) ?? hosted,
                                terminalExited: hosted == nil ? tab.ptyId.map { app.terminals.model($0)?.hasExited == true } : nil,
                                document: tab.editorPath.flatMap(app.editors.document(for:)),
                                isSelected: app.tabs.selection == tab, width: width,
                                select: { app.selectTab(tab) }, close: { app.closeTab(tab) }
                            )
                            .contextMenu { TabMenu(app: app, tab: tab) }
                        }
                        Menu {
                            Button("New Session") { app.newSession(in: strip.workspace) }
                            Button("New Terminal") { app.newTerminal(in: strip.workspace) }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: Self.newTabButtonWidth, height: Chrome.tabStripHeight)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(.secondary)
                        .disabled(!app.connection.isConnected)
                        .help("New session or terminal in \(AppState.projectName(strip.workspace))")
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(height: Chrome.tabStripHeight)
        .background(Chrome.surface)
    }

    private func title(of tab: TabKind) -> String {
        switch tab {
        case .session(let key): app.sessionTitle(key)
        case .terminal(let ptyId):
            app.adoptedSession(on: ptyId).map { app.sessionTitle($0.sessionKey) } ?? app.terminals.title(for: ptyId)
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
            if let hosted = app.adoptedSession(on: ptyId) {
                SessionMenu(app: app, entry: hosted)
                Divider()
            }
            Button("Close Terminal") { app.requestCloseTerminal(ptyId) }
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
    /// The tab's width, shared out by the strip.
    let width: CGFloat
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
            .help(tab.ptyId != nil ? "Close Terminal" : document != nil ? "Close Tab" : "Close Session")
            .accessibilityLabel("Close Tab \(title)")
        }
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: width)
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

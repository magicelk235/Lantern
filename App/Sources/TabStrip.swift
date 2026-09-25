import IDEModel
import IDEState
import SwiftUI

/// The tabs of the workspace on screen, above the detail area. Selecting a tab shows it; closing one leaves its omp
/// session running, and closing an editor with unsaved edits asks first.
struct TabStrip: View {
    let app: AppState
    let strip: TabLayout.Strip

    var body: some View {
        HStack(spacing: 0) {
            Label(workspaceName, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .help(strip.workspace)
            Divider()
                .frame(height: 16)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(strip.tabs, id: \.self) { tab in
                        TabItem(
                            tab: tab, entry: tab.sessionKey.flatMap(app.entry(for:)),
                            document: tab.editorPath.flatMap(app.editors.document(for:)),
                            isSelected: app.tabs.selection == tab, select: { app.selectTab(tab) }, close: { app.closeTab(tab) })
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
        }
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var workspaceName: String {
        let name = URL(filePath: strip.workspace, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? strip.workspace : name
    }
}

private struct TabItem: View {
    let tab: TabKind
    let entry: SessionManifestEntry?
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
                    if let document {
                        EditorTabIndicator(document: document)
                    } else {
                        TabStatusIndicator(status: entry?.status)
                    }
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 220)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.editorPath ?? title)
            .accessibilityLabel("Tab \(title)" + (document?.isDirty == true ? ", edited" : ""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected || hovering ? .secondary : .tertiary)
            .help(document == nil ? "Close Tab (the session keeps running)" : "Close Tab")
            .accessibilityLabel("Close Tab \(title)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    private var title: String {
        switch tab {
        case .session(let key): entry?.displayTitle ?? "Session \(key.prefix(8))"
        case .editor(let path): (path as NSString).lastPathComponent
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        return hovering ? Color.secondary.opacity(0.1) : .clear
    }
}

private struct TabStatusIndicator: View {
    let status: SessionStatus?

    var body: some View {
        switch status {
        case .busy, .starting, .resuming:
            ProgressView().controlSize(.mini)
        case .settled:
            dot(.green)
        case .interrupted:
            dot(.orange)
        case .needsAttention:
            dot(.red)
        case .closed, nil:
            dot(.secondary)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// A file icon, or a dot while the file has unsaved edits.
private struct EditorTabIndicator: View {
    let document: EditorDocument

    var body: some View {
        if document.isDirty {
            Circle()
                .fill(.primary)
                .frame(width: 7, height: 7)
                .help("Unsaved changes")
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

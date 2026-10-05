import QuickLook
import SwiftUI

/// A file Quick Look shows: one of the project's files or an agent's output (`<artifacts>/<AgentId>.md`).
/// Only the window of `project` presents it: Quick Look's panel is one for the whole app.
struct QuickLookItem: Equatable {
    var url: URL
    var project: String
}

extension AppState {
    /// Shows `path` in Quick Look; Space on the file Quick Look already shows closes it, as in the Finder.
    func toggleQuickLook(_ path: String, in project: String) {
        let item = QuickLookItem(url: URL(filePath: path), project: project)
        quickLookItem = quickLookItem == item ? nil : item
    }
}

extension View {
    /// Presents `app.quickLookItem` when it belongs to `project`'s window.
    func quickLookPanel(_ app: AppState, project: String) -> some View {
        quickLookPreview(
            Binding(
                get: { app.quickLookItem?.project == project ? app.quickLookItem?.url : nil },
                set: { url in
                    guard app.quickLookItem?.project == project else { return }
                    app.quickLookItem = url.map { QuickLookItem(url: $0, project: project) }
                }))
    }
}

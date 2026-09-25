import AppKit
import SwiftUI

extension AppState {
    /// The document of the tab on screen, when it is an editor.
    var selectedEditor: EditorDocument? {
        tabs.selection?.editorPath.flatMap(editors.document(for:))
    }

    /// File › Save (⌘S). A failure leaves the edits unsaved (and in hot-exit) and says why.
    func saveSelectedEditor() {
        guard let document = selectedEditor, document.canSave else { return }
        do {
            try document.save()
        } catch {
            alert = AlertMessage(title: "“\(document.name)” could not be saved", message: String(describing: error))
        }
    }

    /// File › Revert to Saved: after a confirmation, the edits give way to the file on disk (undoable with ⌘Z).
    func revertSelectedEditor() {
        guard let document = selectedEditor, document.canRevert else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "Do you want to revert “\(document.name)” to the version on disk?"
        confirmation.informativeText = "Your unsaved changes will be replaced. Undo brings them back."
        confirmation.addButton(withTitle: "Revert")
        confirmation.addButton(withTitle: "Cancel")
        Task {
            let response = if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                await confirmation.beginSheetModal(for: window)
            } else {
                confirmation.runModal()
            }
            if response == .alertFirstButtonReturn { document.revert() }
        }
    }
}

/// Save and Revert to Saved in the File menu, for the editor on screen. Quitting never asks: unsaved edits survive it
/// (hot-exit).
struct EditorCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.saveSelectedEditor() }
                .keyboardShortcut("s")
                .disabled(!(app.selectedEditor?.canSave ?? false))
            Button("Revert to Saved…") { app.revertSelectedEditor() }
                .disabled(!(app.selectedEditor?.canRevert ?? false))
        }
    }
}

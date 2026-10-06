import AppKit
import IDELanguageModel
import SwiftUI

extension AppState {
    /// The document of the tab on screen, when it is an editor.
    var selectedEditor: EditorDocument? {
        selectedTab?.editorPath.flatMap(editors.document(for:))
    }

    /// The find bar of the editor on screen, when it shows text.
    var selectedFind: EditorFind? {
        selectedEditor.flatMap { $0.content == .text ? $0.find : nil }
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

    // MARK: - Language server

    /// Navigate › Jump to Definition (⌃⌘J) and ⌘-click: asks the editor's language server where the symbol at `offset`
    /// (else the caret) is defined, and shows it selected: in this editor, or in the file's tab in the same project,
    /// opened if needed. Several definitions are a menu under the symbol; none is a beep.
    func jumpToDefinition(in document: EditorDocument, at offset: Int? = nil) {
        guard let language = document.languageDocument, language.canJumpToDefinition, let textView = document.controller?.textView,
              let offset = offset ?? textView.selectionManager.textSelections.first?.range.location else {
            NSSound.beep()
            return
        }
        Task {
            let targets = await language.definitions(at: offset)
            switch targets.count {
            case 0: NSSound.beep()
            case 1: show(targets[0], from: document)
            default: chooseDefinition(among: targets, from: document, under: offset)
            }
        }
    }

    private func show(_ target: DefinitionTarget, from document: EditorDocument) {
        if target.path != document.path { openEditor(target.path, in: document.workspace) }
        editors.document(for: target.path)?.reveal(target)
    }

    /// A menu of `targets` ("file — line 12") under the symbol at `offset`; the one picked is shown.
    private func chooseDefinition(among targets: [DefinitionTarget], from document: EditorDocument, under offset: Int) {
        guard let textView = document.controller?.textView, let rect = textView.layoutManager.rectForOffset(offset) else { return }
        let menu = NSMenu()
        let choice = MenuChoice()
        for (index, target) in targets.enumerated() {
            let item = NSMenuItem(
                title: "\((target.path as NSString).lastPathComponent) — line \(target.lineNumber)",
                action: #selector(MenuChoice.choose(_:)), keyEquivalent: "")
            item.target = choice
            item.tag = index
            item.toolTip = target.path
            menu.addItem(item)
        }
        // Text views are flipped: maxY is the bottom of the line.
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: textView)
        if let index = choice.chosen { show(targets[index], from: document) }
    }

    /// ⌘-click in an editor whose language server finds definitions jumps to the one under the mouse; ⌃⌘J in an editor
    /// to the one at the caret; ⌘F in an editor opens its find bar (`EditorFind`). Installed at launch and kept ahead of
    /// the editors' own event monitors (`LocalEventMonitors`): CodeEditSourceEditor answers ⌃⌘J itself, with a beep for
    /// want of a definition provider, and has no way to be given one when the app holds its controller directly; and it
    /// answers ⌘F with a find panel of its own.
    func installEditorNavigation() {
        LocalEventMonitors.add(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.editorNavigation(event)
        }
    }

    /// The event, or nil when it was taken.
    private func editorNavigation(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.type {
        case .leftMouseDown where modifiers == .command && event.clickCount == 1:
            guard let view = event.window?.contentView?.hitTest(event.locationInWindow),
                  let document = editors.document(showing: view), document.languageDocument?.canJumpToDefinition == true,
                  let textView = document.controller?.textView,
                  let offset = textView.layoutManager.textOffsetAtPoint(textView.convert(event.locationInWindow, from: nil))
            else { return event }
            // The click still puts the caret there.
            jumpToDefinition(in: document, at: offset)
            return event
        case .keyDown where modifiers == [.command, .control] && event.charactersIgnoringModifiers == "j":
            guard let responder = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSView,
                  let document = editors.document(showing: responder) else { return event }
            jumpToDefinition(in: document)
            return nil
        case .keyDown where modifiers == .command && event.charactersIgnoringModifiers == "f":
            guard let responder = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSView,
                  let document = editors.document(showing: responder) else { return event }
            document.find.show(.find)
            return nil
        default:
            return event
        }
    }
}

/// Records which item of a pop-up menu was picked.
private final class MenuChoice: NSObject {
    var chosen: Int?

    @objc func choose(_ sender: NSMenuItem) {
        chosen = sender.tag
    }
}

/// Save and Revert to Saved in the File menu, for the editor on screen; Edit › Find (the editor's find bar); and the
/// Navigate menu (Jump to Line, the editor's language server). Quitting never asks: unsaved edits survive it (hot-exit).
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
        CommandGroup(replacing: .textEditing) {
            let find = app.selectedFind
            Menu("Find") {
                Button("Find…") { find?.show(.find) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { find?.show(.replace) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { find?.next() }
                    .keyboardShortcut("g")
                Button("Find Previous") { find?.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { find?.useSelection() }
                    .keyboardShortcut("e")
            }
            .disabled(find == nil)
        }
        CommandMenu("Navigate") {
            let document = app.selectedEditor
            let language = document?.languageDocument
            Button("Jump to Line…") { document?.isJumpingToLine = true }
                .keyboardShortcut("l")
                .disabled(document?.content != .text)
            Divider()
            Button("Jump to Definition") { if let document { app.jumpToDefinition(in: document) } }
                .keyboardShortcut("j", modifiers: [.command, .control])
                .disabled(!(language?.canJumpToDefinition ?? false))
            Button("Show Quick Help") { language?.showQuickHelp() }
                .disabled(!(language?.canShowQuickHelp ?? false))
        }
    }
}

/// The Session menu: Resume, Close Session, Remove Session and Close Terminal for the tab on screen. Each asks the same
/// way the tab's menu does.
struct SessionCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandMenu("Session") {
            let entry = app.selectedTab?.sessionKey.flatMap(app.entry(for:))
            let ptyId = app.selectedTab?.ptyId
            Button("Resume Session") { if let entry { app.resumeSession(entry.sessionKey) } }
                .disabled(!app.connection.isConnected || entry?.isResumable != true)
            Button("Close Session") { if let entry { app.requestCloseSession(entry.sessionKey) } }
                .disabled(!app.connection.isConnected || entry == nil || entry?.isStopped == true)
            Button("Remove Session…") { if let entry { app.requestForgetSession(entry.sessionKey) } }
                .disabled(!app.connection.isConnected || entry?.isStopped != true)
            Divider()
            Button("Close Terminal") { if let ptyId { app.requestCloseTerminal(ptyId) } }
                .disabled(!app.connection.isConnected || ptyId == nil)
        }
    }
}

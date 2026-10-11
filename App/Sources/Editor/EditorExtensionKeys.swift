import AppKit

extension AppState {
    /// The keys extensions give editors: Tab, Shift-Tab and Escape while a snippet is being filled in (`SnippetSession`),
    /// and, in a language an extension adds, ⌘/ with its comment tokens and typing its closing pairs. Ahead of each
    /// editor's own monitor (`LocalEventMonitors`), which answers ⌘/ with the comment tokens of the editor's grammar and
    /// Tab with an indent. The suggestion window's monitor comes before both: Tab and Escape there accept or close it.
    func installEditorExtensionKeys() {
        LocalEventMonitors.add(matching: .keyDown) { [weak self] event in
            guard let self, let responder = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSView,
                  let document = editors.document(showing: responder) else { return event }
            return document.handleExtensionKey(event) ? nil : event
        }
    }
}

extension EditorDocument {
    /// Takes `event` when it is a key an extension gives the editor (`installEditorExtensionKeys`).
    func handleExtensionKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let tab: UInt16 = 0x30
        let escape: UInt16 = 0x35
        if let snippetSession {
            switch (event.keyCode, modifiers) {
            case (tab, []):
                snippetSession.next()
                return true
            case (tab, .shift):
                snippetSession.previous()
                return true
            case (escape, []):
                snippetSession.end()
                return true
            default:
                break
            }
        }
        if modifiers == .command, event.charactersIgnoringModifiers == "/" { return toggleExtensionComment() }
        if modifiers.isSubset(of: .shift), let typed = event.characters, typed.count == 1 { return typeExtensionPair(typed) }
        return false
    }
}

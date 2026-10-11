import AppKit
import CodeEditSourceEditor
import IDEEditorModel
import IDEExtensions

/// What an editor takes from installed extensions: snippets, and for a file in a language one adds, its name, comment
/// tokens and closing pairs (`EditorExtensions`).
extension EditorDocument {
    /// The snippets for the file's language.
    var snippets: [Snippet] {
        EditorExtensions.shared.snippets(path: path, treeSitterId: language.id.rawValue)
    }

    /// The language's name for the status bar: the editor's own, else the one an extension adds for the file.
    var languageName: String {
        let extensions = EditorExtensions.shared
        if let added = extensions.contributedLanguage(path: path, treeSitterId: language.id.rawValue) {
            return extensions.catalog.displayName(forLanguage: added.id) ?? LanguageName.display(id: added.id)
        }
        return LanguageName.display(id: language.id.rawValue)
    }

    /// The comment tokens and pairs of the language an extension adds for the file.
    private var extensionConfiguration: LanguageConfiguration? {
        EditorExtensions.shared.configuration(path: path, treeSitterId: language.id.rawValue)
    }

    /// Puts `snippet` in place of `range` (the word typed for it) and selects its first placeholder.
    func insert(_ snippet: Snippet, replacing range: NSRange) {
        guard let controller, let textView = controller.textView else { return }
        snippetSession?.end()
        let text = textView.textStorage.mutableString
        let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        var indentationEnd = lineStart
        while indentationEnd < range.location, [0x20, 0x09].contains(text.character(at: indentationEnd)) { indentationEnd += 1 }
        let indentation = text.substring(with: NSRange(location: lineStart, length: indentationEnd - lineStart))
        let indentUnit = switch controller.indentOption {
        case .tab: "\t"
        case .spaces(let count): String(repeating: " ", count: count)
        }
        let configuration = extensionConfiguration
        let comment = configuration?.lineComment ?? (controller.language.lineCommentString.isEmpty ? nil : controller.language.lineCommentString)
        let block = configuration?.blockComment.map { (open: $0.open, close: $0.close) }
            ?? (controller.language.rangeCommentStrings.0.isEmpty ? nil : controller.language.rangeCommentStrings)
        let variables = SnippetVariables(
            path: path, workspace: workspace, text: text, range: range, lineComment: comment, blockComment: block)
        let expansion = SnippetExpander.expand(snippet.body, indentation: indentation, indentUnit: indentUnit) { variables.value($0) }
        snippetSession = SnippetSession(inserting: expansion, replacing: range, in: textView) { [weak self] in
            self?.snippetSession = nil
        }
    }

    /// ⌘/ in a language an extension adds, which the editor's grammar has no comment tokens for: toggles comments on the
    /// selected lines with the extension's. False where the editor's own ⌘/ applies.
    func toggleExtensionComment() -> Bool {
        guard let controller, let textView = controller.textView, controller.language.lineCommentString.isEmpty,
              controller.language.rangeCommentStrings.0.isEmpty, let configuration = extensionConfiguration,
              configuration.lineComment != nil || configuration.blockComment != nil else { return false }
        guard let selection = textView.selectionManager.textSelections.first?.range,
              let toggled = CommentToggle.toggle(
                in: textView.textStorage.mutableString, selection: selection, lineComment: configuration.lineComment,
                blockComment: configuration.blockComment)
        else { return true }
        textView.undoManager?.beginUndoGrouping()
        for edit in toggled.edits { textView.replaceCharacters(in: edit.range, with: edit.text, skipUpdateSelection: true) }
        textView.undoManager?.endUndoGrouping()
        textView.selectionManager.setSelectedRange(toggled.selection)
        return true
    }

    /// Typing `typed` in a language an extension adds: an opening character of one of its closing pairs the editor does
    /// not close by itself (a backtick, say) gets its closing one after the caret, or around the selection; its closing
    /// character right before that same character steps over it. False for everything else, which types as usual.
    func typeExtensionPair(_ typed: String) -> Bool {
        guard let configuration = extensionConfiguration, let textView = controller?.textView,
              textView.selectionManager.textSelections.count == 1,
              let selection = textView.selectionManager.textSelections.first?.range else { return false }
        let pairs = configuration.autoClosingPairs.filter {
            $0.open.utf16.count == 1 && $0.close.utf16.count == 1 && !Self.editorPairs.contains($0.open)
        }
        guard !pairs.isEmpty else { return false }
        let text = textView.textStorage.mutableString
        let next = NSMaxRange(selection) < text.length ? text.substring(with: NSRange(location: NSMaxRange(selection), length: 1)) : nil
        if selection.length == 0, next == typed, pairs.contains(where: { $0.close == typed }) {
            textView.selectionManager.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        }
        guard let pair = pairs.first(where: { $0.open == typed }) else { return false }
        if selection.length > 0 {
            guard configuration.surroundingPairs.contains(where: { $0.open == pair.open && $0.close == pair.close }) else { return false }
            let selected = text.substring(with: selection)
            textView.replaceCharacters(in: selection, with: pair.open + selected + pair.close, skipUpdateSelection: true)
            textView.selectionManager.setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
            return true
        }
        // Only before whitespace, the end of the line or a closing bracket, as VS Code does: not in front of a word.
        guard next.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.closers.contains($0) }) ?? true
        else { return false }
        textView.replaceCharacters(in: selection, with: pair.open + pair.close, skipUpdateSelection: true)
        textView.selectionManager.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        return true
    }

    /// The pairs CodeEditSourceEditor closes in every language.
    private static let editorPairs: Set<String> = ["{", "[", "(", "\"", "'"]
    private static let closers: Set<String> = ["}", "]", ")", ",", ";", ":", ">", "\"", "'", "`"]
}

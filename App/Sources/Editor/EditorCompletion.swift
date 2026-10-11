import AppKit
import CodeEditSourceEditor
import IDEExtensions
import IDELanguageModel
import SwiftUI

/// Completions in CodeEditSourceEditor's suggestion window: the language server's, and the snippets of installed
/// extensions for the file's language. The window opens as a word is typed, after a trigger character the server names
/// ("." in Swift) and on ⌃Space. The list is asked for once per word and narrowed as typing goes on; Return or Tab puts
/// the selected completion in place of what was typed, with the edits it brings (an import), as one undo step. A
/// snippet then has its first placeholder selected (`SnippetSession`).
@MainActor
final class EditorCompletion: CodeSuggestionDelegate {
    private weak var editor: EditorDocument?
    /// The server's completions and the language's snippets for the word being typed, and where that word starts.
    private var candidates: [CompletionCandidate] = []
    private var snippets: [Snippet] = []
    private var start = 0

    init(editor: EditorDocument) {
        self.editor = editor
    }

    func completionSuggestionsRequested(
        textView: TextViewController, cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let editor, cursorPosition.range.length == 0 else { return nil }
        let language = editor.languageDocument
        let text = textView.textView.textStorage.mutableString
        let cursor = cursorPosition.range.location
        guard cursor <= text.length else { return nil }
        let wordStart = Self.wordStart(before: cursor, in: text)
        // A number being typed (`1`, `0x1F`, `1.5`) is not a name: Xcode offers nothing there.
        guard !Self.startsNumber(at: wordStart, before: cursor, in: text) else { return nil }
        // Right after a trigger character, say which: the server completes members, not words.
        let before = cursor > 0 && wordStart == cursor ? text.substring(with: NSRange(location: cursor - 1, length: 1)) : nil
        let trigger = before.flatMap { language?.completionTriggers.contains($0) == true ? $0 : nil }
        if trigger == ".", Self.startsNumber(at: Self.wordStart(before: cursor - 1, in: text), before: cursor - 1, in: text) {
            return nil
        }
        // Snippets go with words, not members.
        let snippets = trigger == nil ? editor.snippets : []
        let candidates = await language?.completions(at: cursor, trigger: trigger) ?? []
        guard !Task.isCancelled, !candidates.isEmpty || !snippets.isEmpty else { return nil }
        self.candidates = candidates
        self.snippets = snippets
        start = wordStart
        guard let items = narrowed(to: textView.cursorPositions.first ?? cursorPosition, in: text) else { return nil }
        return (CursorPosition(range: NSRange(location: wordStart, length: 0)), items)
    }

    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        narrowed(to: cursorPosition, in: textView.textView.textStorage.mutableString)
    }

    func completionWindowApplyCompletion(item: CodeSuggestionEntry, textView: TextViewController, cursorPosition: CursorPosition?) {
        guard let entry = item as? CompletionEntry, let editor else { return }
        let cursor = max(cursorPosition?.range.location ?? start, start)
        switch entry.item {
        case .server(let candidate):
            editor.languageDocument?.accept(candidate, typedFrom: start, to: cursor)
        case .snippet(let snippet, _):
            editor.insert(snippet, replacing: NSRange(location: start, length: cursor - start))
        }
    }

    func completionWindowDidClose() {
        candidates = []
        snippets = []
    }

    /// The completions that match what was typed from the word's start to `position`; nil once the caret left the
    /// word (or nothing matches), which closes the window. Snippets need a letter typed: those whose prefix starts with
    /// what was typed come first, those that merely contain its letters in order come last.
    private func narrowed(to position: CursorPosition, in text: NSString) -> [CodeSuggestionEntry]? {
        let cursor = position.range.location
        guard !candidates.isEmpty || !snippets.isEmpty, position.range.length == 0, cursor >= start, cursor <= text.length,
              Self.wordStart(before: cursor, in: text) == start || cursor == start else { return nil }
        let typed = text.substring(with: NSRange(location: start, length: cursor - start))
        var leading: [CodeSuggestionEntry] = []
        var trailing: [CodeSuggestionEntry] = []
        if !typed.isEmpty {
            let lowered = typed.lowercased()
            for snippet in snippets {
                if let prefix = snippet.prefixes.first(where: { $0.lowercased().hasPrefix(lowered) }) {
                    leading.append(CompletionEntry(item: .snippet(snippet, prefix: prefix)))
                } else if let prefix = snippet.prefixes.first(where: { Self.isSubsequence(lowered, of: $0.lowercased()) }) {
                    trailing.append(CompletionEntry(item: .snippet(snippet, prefix: prefix)))
                }
            }
        }
        let server = CompletionCandidate.filter(candidates, by: typed).map { CompletionEntry(item: .server($0)) }
        let items = leading + server + trailing
        return items.isEmpty ? nil : items
    }

    /// Where the identifier ending at `offset` starts (letters, digits, `_` and `$`).
    private static func wordStart(before offset: Int, in text: NSString) -> Int {
        var start = offset
        while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
        return start
    }

    /// The word from `start` to `end` is a number: it starts with a digit.
    private static func startsNumber(at start: Int, before end: Int, in text: NSString) -> Bool {
        guard start < end, let scalar = Unicode.Scalar(text.character(at: start)) else { return false }
        return CharacterSet.decimalDigits.contains(scalar)
    }

    private static func isIdentifier(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isSubsequence(_ wanted: String, of text: String) -> Bool {
        var next = wanted.startIndex
        for character in text where next < wanted.endIndex && character == wanted[next] {
            next = wanted.index(after: next)
        }
        return next == wanted.endIndex
    }
}

/// One completion in the suggestion window: an icon for what it is (a letter on a square in a color per kind, after
/// Xcode), the label, the server's detail (a signature or type) and its documentation in the preview. A snippet shows
/// its prefix, its name and the text it inserts.
private struct CompletionEntry: CodeSuggestionEntry {
    enum Item {
        case server(CompletionCandidate)
        /// A snippet, under the prefix that matched what was typed.
        case snippet(Snippet, prefix: String)
    }

    let item: Item

    var label: String {
        switch item {
        case .server(let candidate): candidate.label
        case .snippet(_, let prefix): prefix
        }
    }

    var detail: String? {
        switch item {
        case .server(let candidate): candidate.detail
        case .snippet(let snippet, _): snippet.name
        }
    }

    /// A snippet's is the text it inserts, then its description. Not the source preview: the suggestion window caches
    /// that by row and keeps it when typing narrows the list, so a row would show another snippet's text.
    var documentation: String? {
        switch item {
        case .server(let candidate):
            return candidate.documentation
        case .snippet(let snippet, _):
            let text = SnippetExpander.expand(snippet.body, indentation: "", indentUnit: "    ") { _ in nil }.text
            return [text, snippet.summary].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }

    var deprecated: Bool {
        guard case .server(let candidate) = item else { return false }
        return candidate.deprecated
    }

    private var category: CompletionCandidate.Category {
        switch item {
        case .server(let candidate): candidate.category
        case .snippet: .snippet
        }
    }

    var image: Image {
        let symbol = switch category {
        case .function: "f.square.fill"
        case .method, .constructor: "m.square.fill"
        case .variable, .field, .constant: "v.square.fill"
        case .property: "p.square.fill"
        case .type: "t.square.fill"
        case .enumMember: "e.square.fill"
        case .module: "shippingbox.fill"
        case .keyword: "k.square.fill"
        case .snippet: "curlybraces.square.fill"
        case .other: "circle.fill"
        }
        return Image(systemName: symbol)
    }

    var imageColor: Color {
        switch category {
        case .function, .method, .constructor: Color(nsColor: .systemTeal)
        case .variable, .field, .constant, .property: Color(nsColor: .systemGreen)
        case .type: Color(nsColor: .systemPurple)
        case .enumMember: Color(nsColor: .systemOrange)
        case .module: Color(nsColor: .systemBrown)
        case .keyword: Color(nsColor: .systemPink)
        case .snippet, .other: Color(nsColor: .systemGray)
        }
    }
}

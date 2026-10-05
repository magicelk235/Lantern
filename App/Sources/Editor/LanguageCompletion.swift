import AppKit
import CodeEditSourceEditor
import IDELanguageModel
import SwiftUI

/// The language server's completions in CodeEditSourceEditor's suggestion window, which opens as a word is typed,
/// after a trigger character the server names ("." in Swift) and on ⌃Space. The list is asked for once per word and
/// narrowed as typing goes on; Return or Tab puts the selected completion in place of what was typed, with the edits
/// it brings (an import), as one undo step.
@MainActor
final class LanguageCompletion: CodeSuggestionDelegate {
    private weak var document: LanguageDocument?
    /// The server's completions for the word being typed, and where that word starts.
    private var candidates: [CompletionCandidate] = []
    private var start = 0

    init(document: LanguageDocument) {
        self.document = document
    }

    func completionSuggestionsRequested(
        textView: TextViewController, cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let document, cursorPosition.range.length == 0 else { return nil }
        let text = textView.textView.textStorage.mutableString
        let cursor = cursorPosition.range.location
        guard cursor <= text.length else { return nil }
        let wordStart = Self.wordStart(before: cursor, in: text)
        // Right after a trigger character, say which: the server completes members, not words.
        let before = cursor > 0 && wordStart == cursor ? text.substring(with: NSRange(location: cursor - 1, length: 1)) : nil
        let trigger = before.flatMap { document.completionTriggers.contains($0) ? $0 : nil }
        let candidates = await document.completions(at: cursor, trigger: trigger)
        guard !Task.isCancelled, !candidates.isEmpty else { return nil }
        self.candidates = candidates
        start = wordStart
        guard let items = narrowed(to: textView.cursorPositions.first ?? cursorPosition, in: text) else { return nil }
        return (CursorPosition(range: NSRange(location: wordStart, length: 0)), items)
    }

    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        narrowed(to: cursorPosition, in: textView.textView.textStorage.mutableString)
    }

    func completionWindowApplyCompletion(item: CodeSuggestionEntry, textView: TextViewController, cursorPosition: CursorPosition?) {
        guard let entry = item as? CompletionEntry, let document else { return }
        let cursor = cursorPosition?.range.location ?? start
        document.accept(entry.candidate, typedFrom: start, to: max(cursor, start))
    }

    func completionWindowDidClose() {
        candidates = []
    }

    /// The completions that match what was typed from the word's start to `position`; nil once the caret left the
    /// word (or nothing matches), which closes the window.
    private func narrowed(to position: CursorPosition, in text: NSString) -> [CodeSuggestionEntry]? {
        let cursor = position.range.location
        guard !candidates.isEmpty, position.range.length == 0, cursor >= start, cursor <= text.length,
              Self.wordStart(before: cursor, in: text) == start || cursor == start else { return nil }
        let typed = text.substring(with: NSRange(location: start, length: cursor - start))
        let items = CompletionCandidate.filter(candidates, by: typed).map(CompletionEntry.init)
        return items.isEmpty ? nil : items
    }

    /// Where the identifier ending at `offset` starts (letters, digits, `_` and `$`).
    private static func wordStart(before offset: Int, in text: NSString) -> Int {
        var start = offset
        while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
        return start
    }

    private static func isIdentifier(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }
}

/// One completion in the suggestion window: an icon for what it is (a letter on a square in a color per kind, after
/// Xcode), the label, the server's detail (a signature or type) and its documentation in the preview.
private struct CompletionEntry: CodeSuggestionEntry {
    let candidate: CompletionCandidate

    var label: String { candidate.label }
    var detail: String? { candidate.detail }
    var documentation: String? { candidate.documentation }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var deprecated: Bool { candidate.deprecated }

    var image: Image {
        let symbol = switch candidate.category {
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
        switch candidate.category {
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

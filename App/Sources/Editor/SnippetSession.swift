import AppKit
import CodeEditTextView
import IDEExtensions

/// A snippet being filled in, from when it is inserted until its last tab stop: its first placeholder is selected, Tab
/// goes to the next one and Shift-Tab back, and typing replaces the selected one. Places that repeat a tab stop take
/// its text when the caret leaves it. It ends at the last stop, with Escape, and with an edit outside the placeholder
/// it is at.
@MainActor
final class SnippetSession {
    private weak var textView: TextView?
    private var stops: SnippetStops
    private var observer: StorageObserver?
    /// Copying a placeholder's text to its mirrors: those edits are the session's own.
    private var isSyncing = false
    private var ended = false
    private let onEnd: () -> Void

    /// Inserts `expansion` in place of `range` of `textView`'s text as one undo step and selects its first stop. Nil when
    /// there is nothing to fill in (a snippet without placeholders): the caret is then at its end, or its `$0`.
    init?(inserting expansion: SnippetExpansion, replacing range: NSRange, in textView: TextView, onEnd: @escaping () -> Void) {
        self.textView = textView
        self.onEnd = onEnd
        stops = SnippetStops(expansion, at: range.location)
        textView.undoManager?.beginUndoGrouping()
        textView.replaceCharacters(in: range, with: expansion.text)
        textView.undoManager?.endUndoGrouping()
        guard stops.count > 1, let first = stops.primary else {
            textView.selectionManager.setSelectedRange(stops.primary ?? NSRange(location: range.location + (expansion.text as NSString).length, length: 0))
            return nil
        }
        let observer = StorageObserver { [weak self] range, newLength in self?.textDidReplace(range, newLength: newLength) }
        textView.addStorageDelegate(observer)
        self.observer = observer
        textView.selectionManager.setSelectedRange(first)
    }

    /// Tab: the next placeholder, or the end of the snippet.
    func next() {
        move(by: 1)
    }

    /// Shift-Tab: the placeholder before.
    func previous() {
        move(by: -1)
    }

    /// Escape, or the editor closed: the caret stays where it is.
    func end() {
        guard !ended else { return }
        syncMirrors()
        finish()
    }

    private func move(by step: Int) {
        guard !ended, let textView else { return finish() }
        syncMirrors()
        guard stops.advance(by: step), let range = stops.primary else {
            return finish()
        }
        textView.selectionManager.setSelectedRange(range)
        if stops.isAtLast { finish() }
    }

    /// The text of the placeholder the caret leaves goes to the places that repeat it, as one undo step.
    private func syncMirrors() {
        guard let textView, let primary = stops.primary, !stops.mirrors.isEmpty else { return }
        let text = textView.textStorage.mutableString
        guard NSMaxRange(primary) <= text.length else { return }
        let value = text.substring(with: primary)
        let mirrors = stops.mirrors.filter { text.substring(with: $0) != value }
        guard !mirrors.isEmpty else { return }
        let selection = textView.selectionManager.textSelections.map(\.range)
        isSyncing = true
        textView.undoManager?.beginUndoGrouping()
        // Last first, so each range is still where it was.
        for mirror in mirrors.sorted(by: { $0.location > $1.location }) {
            textView.replaceCharacters(in: mirror, with: value, skipUpdateSelection: true)
        }
        textView.undoManager?.endUndoGrouping()
        isSyncing = false
        // The mirrors may come before the selection: it moves with the text.
        if let primary = stops.primary, selection.count == 1, selection[0].location >= primary.location {
            textView.selectionManager.setSelectedRange(primary)
        }
    }

    private func textDidReplace(_ range: NSRange, newLength: Int) {
        guard !ended else { return }
        let inCurrent = stops.replace(range, newLength: newLength)
        if !inCurrent && !isSyncing || stops.primary == nil { finish() }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        if let observer { textView?.removeStorageDelegate(observer) }
        observer = nil
        onEnd()
    }
}

/// The values of snippet variables (`$TM_FILENAME`, `$CURRENT_YEAR`, …) where a snippet is inserted, after VS Code's.
/// A name it does not know has no value: the snippet shows the name as a placeholder.
@MainActor
struct SnippetVariables {
    let path: String
    let workspace: String
    /// The text and where the snippet goes: the word typed for it, which it replaces.
    let text: NSString
    let range: NSRange
    let lineComment: String?
    let blockComment: (open: String, close: String)?

    func value(_ name: String) -> String? {
        let now = Date()
        let calendar = Calendar.current
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            return formatter.string(from: now)
        }
        func twoDigits(_ value: Int) -> String { String(format: "%02d", value) }
        switch name {
        case "TM_FILENAME": return (path as NSString).lastPathComponent
        case "TM_FILENAME_BASE": return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case "TM_DIRECTORY": return (path as NSString).deletingLastPathComponent
        case "TM_FILEPATH": return path
        case "RELATIVE_FILEPATH":
            return path.hasPrefix(workspace + "/") ? String(path.dropFirst(workspace.count + 1)) : path
        case "WORKSPACE_NAME": return (workspace as NSString).lastPathComponent
        case "WORKSPACE_FOLDER": return workspace
        case "TM_SELECTED_TEXT": return ""
        case "TM_CURRENT_LINE":
            let line = text.lineRange(for: NSRange(location: range.location, length: 0))
            return text.substring(with: line).trimmingCharacters(in: .newlines)
        case "TM_CURRENT_WORD": return text.substring(with: range)
        case "TM_LINE_INDEX", "TM_LINE_NUMBER":
            var index = 0
            for offset in 0..<range.location where text.character(at: offset) == 0x0A { index += 1 }
            return String(name == "TM_LINE_INDEX" ? index : index + 1)
        case "CLIPBOARD": return NSPasteboard.general.string(forType: .string) ?? ""
        case "CURRENT_YEAR": return String(calendar.component(.year, from: now))
        case "CURRENT_YEAR_SHORT": return String(String(calendar.component(.year, from: now)).suffix(2))
        case "CURRENT_MONTH": return twoDigits(calendar.component(.month, from: now))
        case "CURRENT_MONTH_NAME": return format("LLLL")
        case "CURRENT_MONTH_NAME_SHORT": return format("LLL")
        case "CURRENT_DATE": return twoDigits(calendar.component(.day, from: now))
        case "CURRENT_DAY_NAME": return format("EEEE")
        case "CURRENT_DAY_NAME_SHORT": return format("EEE")
        case "CURRENT_HOUR": return twoDigits(calendar.component(.hour, from: now))
        case "CURRENT_MINUTE": return twoDigits(calendar.component(.minute, from: now))
        case "CURRENT_SECOND": return twoDigits(calendar.component(.second, from: now))
        case "CURRENT_SECONDS_UNIX": return String(Int(now.timeIntervalSince1970))
        case "CURRENT_TIMEZONE_OFFSET": return format("xxx")
        case "RANDOM": return String(format: "%06d", Int.random(in: 0..<1_000_000))
        case "RANDOM_HEX": return String(format: "%06x", Int.random(in: 0..<0x1000000))
        case "UUID": return UUID().uuidString.lowercased()
        case "LINE_COMMENT": return lineComment ?? blockComment?.open ?? ""
        case "BLOCK_COMMENT_START": return blockComment?.open ?? lineComment ?? ""
        case "BLOCK_COMMENT_END": return blockComment?.close ?? ""
        default: return nil
        }
    }
}

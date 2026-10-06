import AppKit
import CodeEditTextView

/// The find bar of one editor (Edit › Find, after Xcode's): what is looked for and how, the matches in the text, and
/// which one is current. It stands in for CodeEditSourceEditor's own find panel, which the app cannot drive (no Find
/// Next or Find Previous from the menu) and which never scrolled to what it found; ⌘F opens this one instead
/// (`AppState.installEditorNavigation`). Matches are found in the whole text; the ones on screen are marked in the find
/// highlight color, the current one stronger, the way the text view marks them for CodeEditSourceEditor.
@MainActor @Observable
final class EditorFind {
    enum Mode: Hashable {
        case find, replace
    }

    /// The bar's fields.
    enum Field {
        case query, replacement
    }

    /// How the query matches text, as in Xcode's find options.
    enum Matching: CaseIterable, Hashable {
        case containing, matchingWord, startingWith, endingWith, regularExpression

        var title: String {
            switch self {
            case .containing: "Containing"
            case .matchingWord: "Matching Word"
            case .startingWith: "Starting With"
            case .endingWith: "Ending With"
            case .regularExpression: "Regular Expression"
            }
        }
    }

    private(set) var isShown = false
    private(set) var mode = Mode.find
    private(set) var query = ""
    var replacement = ""
    private(set) var matchesCase = false
    private(set) var matching = Matching.containing
    var wrapsAround = true
    /// Every match in the text, in order; empty while the query is empty or not a valid pattern.
    private(set) var matches: [NSRange] = []
    /// The match moved to last, while the selection still is that match.
    private(set) var current: Int?
    /// The query is a regular expression that does not compile.
    private(set) var isInvalid = false
    /// The field that is to take the keyboard focus (with its text selected), until it has.
    private(set) var pendingFocus: Field?

    @ObservationIgnored weak var document: EditorDocument?
    /// The text changed while the bar was hidden: the matches are found again before they are used.
    @ObservationIgnored private var isStale = false
    /// The text whose matches are marked: the lines on screen when they were marked last.
    @ObservationIgnored private var markedRange: NSRange?
    @ObservationIgnored private var markingPending = false

    private static let matchesGroup = "omp.find.matches"
    private static let currentGroup = "omp.find.current"

    private var textView: TextView? { document?.controller?.textView }

    // MARK: - Commands

    /// Find… (⌘F) and Find and Replace… (⌥⌘F): shows the bar in `mode` with the find field focused and its text
    /// selected; the replacement field instead for Find and Replace when there is something to look for. It looks for
    /// the selected text when that is one line the user picked (not the match found last), else for what the system's
    /// find pasteboard holds when nothing is looked for yet.
    func show(_ mode: Mode) {
        guard let textView else { return }
        let resizes = !isShown || self.mode != mode
        if let selected = selectedText(in: textView), currentMatchIsSelected(in: textView) == false {
            query = selected
        } else if query.isEmpty, let shared = NSPasteboard(name: .find).string(forType: .string), !shared.contains("\n") {
            query = shared
        }
        isShown = true
        self.mode = mode
        pendingFocus = mode == .replace && !query.isEmpty ? .replacement : .query
        if resizes { document?.keepCaretInSightWhileResizing() }
        search(movingFrom: nil)
    }

    /// The field asked for in `pendingFocus` has the keyboard.
    func focusTaken() {
        pendingFocus = nil
    }

    /// Done and Esc: the bar goes, its marks with it, and the keyboard goes back to the text.
    func hide() {
        guard isShown else { return }
        isShown = false
        unmark()
        if let textView { textView.window?.makeFirstResponder(textView) }
    }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        document?.keepCaretInSightWhileResizing()
    }

    /// The query changed: the first match from the selection on is selected (incremental search).
    func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        searchFromSelection()
    }

    func setMatchesCase(_ matchesCase: Bool) {
        guard matchesCase != self.matchesCase else { return }
        self.matchesCase = matchesCase
        searchFromSelection()
    }

    func setMatching(_ matching: Matching) {
        guard matching != self.matching else { return }
        self.matching = matching
        searchFromSelection()
    }

    /// Use Selection for Find (⌘E): the selected text becomes the query, here and in the system's find pasteboard.
    func useSelection() {
        guard let textView, let selected = selectedText(in: textView) else {
            NSSound.beep()
            return
        }
        query = selected
        share()
        search(movingFrom: nil)
    }

    /// Find Next (⌘G, Return in the field): selects the first match after the selection, from the top past the last.
    func next() {
        move(forward: true)
    }

    /// Find Previous (⇧⌘G, ⇧Return in the field).
    func previous() {
        move(forward: false)
    }

    /// Replace: the selected match gives way to the replacement (a template when the query is a regular expression),
    /// then the next match is selected. Without a match selected it only moves to the next one.
    func replace() {
        guard let textView, let expression = expression() else {
            NSSound.beep()
            return
        }
        if isStale { search(movingFrom: nil) }
        guard let selection = textView.selectionManager.textSelections.first?.range, index(of: selection) != nil else {
            next()
            return
        }
        let text = textView.textStorage.string
        guard let match = expression.firstMatch(
            in: text, options: [.withTransparentBounds, .withoutAnchoringBounds], range: selection)
        else {
            next()
            return
        }
        let replaced = expression.replacementString(for: match, in: text, offset: 0, template: template)
        textView.replaceCharacters(in: selection, with: replaced)
        search(movingFrom: selection.location + (replaced as NSString).length)
    }

    /// Replace All: every match gives way to the replacement, as one edit (one undo).
    func replaceAll() {
        guard let textView, let document, let expression = expression() else {
            NSSound.beep()
            return
        }
        if isStale { search(movingFrom: nil) }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let text = textView.textStorage.string
        let source = textView.textStorage.mutableString
        let result = NSMutableString(capacity: source.length)
        var end = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        where match.range.length > 0 {
            result.append(source.substring(with: NSRange(location: end, length: match.range.location - end)))
            result.append(expression.replacementString(for: match, in: text, offset: 0, template: template))
            end = NSMaxRange(match.range)
        }
        result.append(source.substring(from: end))
        document.replaceText(with: result as String)
        search(movingFrom: nil)
    }

    // MARK: - Following the text

    /// The text changed (typing, undo, a reload, a replacement): the matches follow it; the selection stays.
    func textDidChange() {
        guard !query.isEmpty else { return }
        if isShown { search(movingFrom: nil) } else { isStale = true }
    }

    /// The text scrolled: the matches that came on screen are marked, once the scrolling of this turn is done.
    func viewDidScroll() {
        guard isShown, !matches.isEmpty, !markingPending else { return }
        markingPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.markingPending = false
                guard let visible = self.textView?.visibleTextRange, visible != self.markedRange else { return }
                self.markMatches()
            }
        }
    }

    /// The text view is going away (the tab closed, the file stopped being text): nothing is shown or marked anymore.
    func reset() {
        isShown = false
        matches = []
        current = nil
        markedRange = nil
    }

    // MARK: - Searching

    private func move(forward: Bool) {
        guard let textView else { return }
        guard !query.isEmpty else {
            show(mode)
            return
        }
        if isStale { search(movingFrom: nil) }
        guard !matches.isEmpty, let selection = textView.selectionManager.textSelections.first?.range else {
            NSSound.beep()
            return
        }
        let target: Int?
        if forward {
            let after = firstIndex(atOrAfter: NSMaxRange(selection))
            target = after < matches.count ? after : (wrapsAround ? 0 : nil)
        } else {
            let before = firstIndex(atOrAfter: selection.location) - 1
            target = before >= 0 ? before : (wrapsAround ? matches.count - 1 : nil)
        }
        guard let target else {
            NSSound.beep()
            return
        }
        share()
        select(target)
    }

    private func searchFromSelection() {
        search(movingFrom: textView?.selectionManager.textSelections.first?.range.location ?? 0)
    }

    /// Finds the matches again. From `location` on, the first match is selected (wrapping to the top when wrapping
    /// around); without one, the match that is selected (if any) is the current one.
    private func search(movingFrom location: Int?) {
        isStale = false
        guard let textView else { return }
        let expression = expression()
        isInvalid = expression == nil && !query.isEmpty
        let found = expression?.matches(in: textView.textStorage.string, range: NSRange(location: 0, length: textView.textStorage.length))
            .map(\.range).filter { $0.length > 0 } ?? []
        if found != matches { matches = found }
        if let location, !matches.isEmpty {
            let after = firstIndex(atOrAfter: location)
            if after < matches.count {
                select(after)
                return
            } else if wrapsAround {
                select(0)
                return
            }
        }
        let selected = textView.selectionManager.textSelections.first.flatMap { index(of: $0.range) }
        if current != selected { current = selected }
        markCurrent()
        markMatches()
    }

    /// Makes match `index` the current one: selected, in sight and marked.
    private func select(_ index: Int) {
        current = index
        document?.select(matches[index], focus: false)
        markCurrent()
        markMatches()
    }

    private func expression() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        let literal = NSRegularExpression.escapedPattern(for: query)
        // A word edge that holds whatever the query starts or ends with, unlike `\b`.
        let wordBefore = "(?<![\\p{L}\\p{N}_])"
        let wordAfter = "(?![\\p{L}\\p{N}_])"
        let pattern = switch matching {
        case .containing: literal
        case .matchingWord: wordBefore + literal + wordAfter
        case .startingWith: wordBefore + literal
        case .endingWith: literal + wordAfter
        case .regularExpression: query
        }
        var options: NSRegularExpression.Options = matchesCase ? [] : [.caseInsensitive]
        if matching == .regularExpression { options.insert(.anchorsMatchLines) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// The replacement as a template: `$1` means a group only when the query is a regular expression.
    private var template: String {
        matching == .regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// The index of the first match that starts at or after `location`; `matches.count` when none does.
    private func firstIndex(atOrAfter location: Int) -> Int {
        var low = 0
        var high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].location < location { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func index(of range: NSRange) -> Int? {
        let index = firstIndex(atOrAfter: range.location)
        return index < matches.count && matches[index] == range ? index : nil
    }

    /// The selection is one non-empty range on one line: what Find… and Use Selection for Find look for.
    private func selectedText(in textView: TextView) -> String? {
        guard textView.selectionManager.textSelections.count == 1,
              let range = textView.selectionManager.textSelections.first?.range, range.length > 0, range.length <= 1000
        else { return nil }
        let text = textView.textStorage.mutableString.substring(with: range)
        return text.contains(where: \.isNewline) ? nil : text
    }

    private func currentMatchIsSelected(in textView: TextView) -> Bool {
        guard let current, current < matches.count else { return false }
        return textView.selectionManager.textSelections.first?.range == matches[current]
    }

    /// Other apps' find fields (and the next ⌘F here) start from the query, as the system's find pasteboard does.
    private func share() {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(query, forType: .string)
    }

    // MARK: - Marks

    /// Marks the current match (it pops, as the text view does for a new find result).
    private func markCurrent() {
        guard let textView, let emphasis = textView.emphasisManager else { return }
        guard isShown, let current else {
            emphasis.removeEmphases(for: Self.currentGroup)
            return
        }
        // A mark is drawn only for laid-out lines: the lines just scrolled to are laid out first.
        textView.layoutManager.layoutLines()
        emphasis.replaceEmphases([Emphasis(range: matches[current], style: .standard)], for: Self.currentGroup)
    }

    /// Marks the other matches on the lines on screen, quietly.
    private func markMatches() {
        guard let textView, let emphasis = textView.emphasisManager else { return }
        guard isShown, !matches.isEmpty else {
            emphasis.removeEmphases(for: Self.matchesGroup)
            markedRange = nil
            return
        }
        textView.layoutManager.layoutLines()
        guard let visible = textView.visibleTextRange else { return }
        markedRange = visible
        let shown = firstIndex(atOrAfter: visible.location) ..< firstIndex(atOrAfter: NSMaxRange(visible))
        let marks = shown.filter { $0 != current }.map { Emphasis(range: matches[$0], style: .standard, inactive: true) }
        emphasis.replaceEmphases(marks, for: Self.matchesGroup)
    }

    private func unmark() {
        markedRange = nil
        textView?.emphasisManager?.removeEmphases(for: Self.matchesGroup)
        textView?.emphasisManager?.removeEmphases(for: Self.currentGroup)
    }
}

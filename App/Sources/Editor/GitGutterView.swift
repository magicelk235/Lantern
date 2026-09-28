import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import IDEEditorModel
import Observation
import SwiftUI

// MARK: - Marks

/// Which lines of an editor's text differ from HEAD's version of its file, by the text view's line index (0-based; a
/// text ending with a line break has an empty last line, as in `LineDiff`).
struct GitGutterMarks: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        /// Stands where HEAD has other lines.
        case modified
        /// New between lines HEAD has; every line when HEAD lacks the file.
        case added
    }

    /// One run of changed lines: what a mark stands for, and what a click on it shows and reverts.
    struct Change: Equatable, Sendable {
        /// The text's lines in the run; empty for a deletion, at the index of the line after it.
        var lines: Range<Int>
        /// HEAD's lines the run replaces, without their line breaks; none for an addition.
        var removed: [String]
        /// HEAD's 1-based number of the line at `lines.lowerBound` (the first removed one, or the one an addition
        /// goes before).
        var oldStart: Int
    }

    var changes: [Change] = []
    var lines: [Int: Mark] = [:]
    /// Lines after which HEAD has lines the text lacks.
    var deletedAfter: Set<Int> = []
    /// HEAD has lines before the first one.
    var deletedBeforeFirst = false

    var isEmpty: Bool { changes.isEmpty }

    /// The marks of `current` against `base`, HEAD's version (empty when HEAD lacks the file: every line is added).
    /// Each run of changed lines is one change: lines standing where removed ones were are modified, lines between
    /// kept ones added, and removed lines with nothing in their place mark the line before them. A CRLF is one line
    /// break, as the text view counts it.
    static func compute(base: String, current: String) -> GitGutterMarks {
        let base = base.replacingOccurrences(of: "\r\n", with: "\n")
        let current = current.replacingOccurrences(of: "\r\n", with: "\n")
        var marks = GitGutterMarks()
        if base.isEmpty {
            let count = current.split(separator: "\n", omittingEmptySubsequences: false).count
            marks.lines = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, Mark.added) })
            marks.changes = [Change(lines: 0..<count, removed: [], oldStart: 1)]
            return marks
        }
        // Without context every hunk is one run: its removed lines, then its inserted ones.
        var delta = 0 // Lines the text has gained over HEAD before the run.
        for hunk in LineDiff.hunks(from: base, to: current, context: 0) {
            var removed: [String] = []
            var oldStart = 1
            var inserted: [Int] = []
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if removed.isEmpty, let number = line.oldNumber { oldStart = number }
                    removed.append(line.text)
                case .inserted:
                    if let number = line.newNumber { inserted.append(number - 1) }
                case .context:
                    break
                }
            }
            if inserted.isEmpty {
                // The text's line before the run's place: old lines before it, plus what the text gained so far.
                let after = oldStart - 2 + delta
                if after < 0 { marks.deletedBeforeFirst = true } else { marks.deletedAfter.insert(after) }
                marks.changes.append(Change(lines: (after + 1)..<(after + 1), removed: removed, oldStart: oldStart))
            } else {
                let mark: Mark = removed.isEmpty ? .added : .modified
                for index in inserted { marks.lines[index] = mark }
                let first = inserted[0]
                marks.changes.append(Change(lines: first..<(first + inserted.count), removed: removed, oldStart: first - delta + 1))
            }
            delta += inserted.count - removed.count
        }
        return marks
    }

    /// The change a click on line `index` means: the run holding it.
    func change(containing index: Int) -> Int? {
        changes.firstIndex { $0.lines.contains(index) }
    }

    /// `change` as a unified diff of `base` (HEAD's text) and `current` with up to `context` rows on either side, as
    /// the whole file's diff has them (so a change nearby shows as one, with its own numbers).
    static func rows(of change: Change, base: String, current: String, context: Int = 3) -> [LineDiff.Line] {
        let base = base.replacingOccurrences(of: "\r\n", with: "\n")
        let current = current.replacingOccurrences(of: "\r\n", with: "\n")
        // As much context as there are lines: one hunk holding every line of both texts. HEAD lacking the file splits
        // into one empty line, which is no removed line.
        let all = LineDiff.hunks(from: base, to: current, context: base.utf16.count + current.utf16.count).first?.lines
            .filter { !base.isEmpty || $0.kind != .removed } ?? []
        let removed = change.oldStart..<(change.oldStart + change.removed.count)
        let isInChange = { (line: LineDiff.Line) -> Bool in
            switch line.kind {
            case .removed: line.oldNumber.map(removed.contains) ?? false
            case .inserted: line.newNumber.map { change.lines.contains($0 - 1) } ?? false
            case .context: false
            }
        }
        guard let first = all.firstIndex(where: isInChange), let last = all.lastIndex(where: isInChange) else { return [] }
        return Array(all[max(0, first - context)...min(all.count - 1, last + context)])
    }
}

// MARK: - Git

extension GitGutterMarks {
    /// HEAD's version of the file at `path`, read in its folder (`git show HEAD:./name`, so the repository above it
    /// counts, whatever the project folder): the empty text when HEAD lacks the file (untracked, added, renamed, or
    /// no commit yet); nil outside a repository or when git cannot say, for no marks at all. Synchronous: call it off
    /// the main thread.
    static func baseText(of path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        do {
            return String(decoding: try Git.output(["show", "HEAD:./\(name)"], in: directory), as: UTF8.self)
        } catch let failure as Git.Failure where failure.status == 128 {
            let lacksFile = ["not in 'HEAD'", "does not exist in 'HEAD'", "invalid object name 'HEAD'"]
            return lacksFile.contains { failure.stderr.contains($0) } ? "" : nil
        } catch {
            return nil
        }
    }
}

// MARK: - View

/// The marks over an editor's gutter, as VS Code draws them: a bar the height of the line at the gutter's trailing
/// edge, blue for a modified line and green for an added one, and a red triangle pointing right at the edge lines were
/// deleted at. It lies over CodeEditSourceEditor's gutter (following its frame as it scrolls and grows) and draws at
/// the y positions the text view's layout manager reports, so a wrapped line is one bar of its full height. The marks
/// are diffed off the main thread when the file opens, 300 ms after typing pauses (or at a save before that), and when
/// the repository's HEAD or the file's status changes; one diff runs at a time, and one more if asked meanwhile.
///
/// A click on a mark opens a `GitChangePeek` under its change (the rest of the gutter takes clicks as before).
final class GitGutterView: NSView {
    private static let barWidth: CGFloat = 3
    private static let trailingInset: CGFloat = 4
    private static let triangle: CGFloat = 6
    private static let alpha: CGFloat = 0.85
    /// How far left of the bar a click still hits it (short of the folding ribbon).
    private static let hitSlop: CGFloat = 1

    /// What a refresh depends on besides the text.
    private struct RepositoryState: Equatable {
        let head: String?
        let isRepository: Bool
        let change: GitRepository.Change?
    }

    private let path: String
    private weak var textView: TextView?
    private weak var gutter: GutterView?
    private var frameObserver: (any NSObjectProtocol)?
    private let repository: GitRepository
    private var marks = GitGutterMarks() {
        didSet {
            guard marks != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// HEAD's text the marks were diffed against; nil when there are none to diff.
    private var base: String?
    /// Counts the text's edits; `marksVersion` is the count the marks were diffed at.
    private var textVersion = 0
    private var marksVersion = 0
    private var seen: RepositoryState
    /// The refresh waiting for typing to pause.
    private var debounce: Task<Void, Never>?
    private var computing = false
    private var stale = false
    private var isDetached = false
    /// The open peek, and the change it shows.
    private var peek: NSPopover?
    private var peekIndex = 0

    init(path: String, textView: TextView, repository: GitRepository) {
        self.path = path
        self.textView = textView
        self.repository = repository
        seen = Self.state(of: repository, path: path)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        observeRepository()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The gutter's y positions start at the top of the text and grow downwards.
    override var isFlipped: Bool { true }

    /// Clicks on a mark are the view's; the rest go to the gutter and its folding ribbon underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) && changeIndex(at: local) != nil ? self : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Lifecycle

    /// Goes over the controller's gutter once its view is loaded (it appeared): a floating subview of the scroll view
    /// next to the gutter (never a subview of it: the gutter is placed by hand, and a constrained subview would make
    /// Auto Layout zero its frame), kept the gutter's size and place.
    func attach(to controller: TextViewController) {
        guard superview == nil, !isDetached, controller.isViewLoaded, let gutter = Self.findGutter(in: controller.scrollView) else { return }
        self.gutter = gutter
        controller.scrollView.addFloatingSubview(self, for: .horizontal)
        gutter.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: gutter, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFrame() }
        }
        syncFrame()
    }

    /// Takes the gutter's frame (it moves with the scroll and grows with the text).
    func syncFrame() {
        guard let gutter, superview != nil else { return }
        if frame != gutter.frame {
            frame = gutter.frame
            window?.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    /// CodeEditSourceEditor's gutter: a floating subview of the scroll view, found in its view tree (the controller
    /// keeps it internal).
    private static func findGutter(in view: NSView) -> GutterView? {
        for subview in view.subviews {
            if let gutter = subview as? GutterView { return gutter }
            if let gutter = findGutter(in: subview) { return gutter }
        }
        return nil
    }

    /// The controller goes away: stop refreshing and leave the gutter.
    func detach() {
        isDetached = true
        debounce?.cancel()
        debounce = nil
        peek?.close()
        peek = nil
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        removeFromSuperview()
    }

    // MARK: Refresh

    /// The text changed: the marks move with it now, and are recomputed once typing pauses.
    func textDidChange() {
        textVersion += 1
        syncFrame()
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// The text was saved: a refresh still waiting for typing to pause runs now.
    func textDidSave() {
        if debounce != nil { refresh() }
    }

    /// Recomputes the marks: HEAD's version is read and diffed against the text off the main thread.
    func refresh() {
        debounce?.cancel()
        debounce = nil
        guard !isDetached, let textView else { return }
        guard !computing else {
            stale = true
            return
        }
        computing = true
        let text = textView.string
        let version = textVersion
        Task { [weak self, path] in
            let (base, marks) = await Task.detached(priority: .userInitiated) { () -> (String?, GitGutterMarks) in
                let base = GitGutterMarks.baseText(of: path)
                return (base, base.map { GitGutterMarks.compute(base: $0, current: text) } ?? GitGutterMarks())
            }.value
            guard let self else { return }
            computing = false
            self.base = base
            self.marks = marks
            marksVersion = version
            if stale {
                stale = false
                refresh()
            }
        }
    }

    /// Diffs the text as it is now against the HEAD text already read, when edits came after the marks: what a peek
    /// shows and reverts has to match the text.
    private func bringMarksUpToDate() {
        guard marksVersion != textVersion, let base, let textView else { return }
        marks = GitGutterMarks.compute(base: base, current: textView.string)
        marksVersion = textVersion
    }

    /// Refreshes when the repository's refresh moved HEAD, found or lost the repository, or changed the file's status.
    private func observeRepository() {
        withObservationTracking {
            _ = Self.state(of: repository, path: path)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !isDetached else { return }
                let state = Self.state(of: repository, path: path)
                if state != seen {
                    seen = state
                    refresh()
                }
                observeRepository()
            }
        }
    }

    private static func state(of repository: GitRepository, path: String) -> RepositoryState {
        RepositoryState(
            head: repository.headCommit, isRepository: repository.isRepository,
            change: repository.changes.first { $0.path == path })
    }

    // MARK: Hit testing

    /// Where the marks are drawn: the bar's column and the slack to the gutter's edge.
    private var markColumn: ClosedRange<CGFloat> {
        (bounds.width - Self.trailingInset - Self.barWidth - Self.hitSlop)...bounds.width
    }

    /// The change whose mark is at `point`: a deletion's triangle wins near the edge it sits on, else the line's bar.
    private func changeIndex(at point: NSPoint) -> Int? {
        guard !marks.isEmpty, markColumn.contains(point.x), let layoutManager = textView?.layoutManager else { return nil }
        let reach = Self.triangle / 2 + 1
        for (index, change) in marks.changes.enumerated() where change.lines.isEmpty {
            if abs(point.y - deletionEdge(before: change.lines.lowerBound, layoutManager)) <= reach { return index }
        }
        guard let line = layoutManager.textLineForPosition(point.y) else { return nil }
        return marks.change(containing: line.index)
    }

    /// The y of the edge between line `index - 1` and line `index` (a deletion's triangle).
    private func deletionEdge(before index: Int, _ layoutManager: TextLayoutManager) -> CGFloat {
        guard index > 0, let line = layoutManager.textLineForIndex(index - 1) else { return Self.triangle / 2 }
        return line.yPos + line.height
    }

    /// The span `change`'s mark covers, in the view's (and the text view's) y.
    private func span(of change: GitGutterMarks.Change, _ layoutManager: TextLayoutManager) -> (minY: CGFloat, maxY: CGFloat)? {
        if change.lines.isEmpty {
            let edge = deletionEdge(before: change.lines.lowerBound, layoutManager)
            return (edge - Self.triangle / 2, edge + Self.triangle / 2)
        }
        guard let first = layoutManager.textLineForIndex(change.lines.lowerBound),
              let last = layoutManager.textLineForIndex(change.lines.upperBound - 1) else { return nil }
        return (first.yPos, last.yPos + last.height)
    }

    override func resetCursorRects() {
        guard let layoutManager = textView?.layoutManager else { return }
        let column = markColumn
        for change in marks.changes {
            guard let span = span(of: change, layoutManager) else { continue }
            addCursorRect(NSRect(x: column.lowerBound, y: span.minY, width: column.upperBound - column.lowerBound, height: span.maxY - span.minY), cursor: .pointingHand)
        }
    }

    // MARK: Peek

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        bringMarksUpToDate()
        guard let index = changeIndex(at: point) else { return }
        if let peek, peek.isShown, peekIndex == index {
            peek.close()
            return
        }
        showPeek(index)
    }

    /// Opens (or moves) the peek to change `index`, under its lines, across the editor.
    private func showPeek(_ index: Int) {
        guard let textView, let layoutManager = textView.layoutManager, marks.changes.indices.contains(index),
              let span = span(of: marks.changes[index], layoutManager) else { return }
        peekIndex = index
        let visible = textView.visibleRect
        let width = min(max(visible.width - 48, 360), 960)
        let content = GitChangePeek(
            fileName: (path as NSString).lastPathComponent,
            position: index + 1, count: marks.changes.count,
            rows: GitGutterMarks.rows(of: marks.changes[index], base: base ?? "", current: textView.string),
            width: width,
            revert: { [weak self] in self?.revertPeekedChange() },
            previous: { [weak self] in self?.movePeek(by: -1) },
            next: { [weak self] in self?.movePeek(by: 1) },
            close: { [weak self] in self?.peek?.close() })
        let popover: NSPopover
        if let peek, peek.isShown, let host = peek.contentViewController as? NSHostingController<GitChangePeek> {
            host.rootView = content
            popover = peek
        } else {
            peek?.close()
            let host = NSHostingController(rootView: content)
            host.sizingOptions = .preferredContentSize
            popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = host
            peek = popover
        }
        // Under the change, the arrow at its middle across the editor; the text view is flipped like the gutter.
        let anchor = NSRect(x: visible.minX, y: span.minY, width: visible.width, height: max(1, span.maxY - span.minY))
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
    }

    /// Shows the change `offset` away from the peeked one, wrapping, with the text scrolled to it.
    private func movePeek(by offset: Int) {
        bringMarksUpToDate()
        let count = marks.changes.count
        guard count > 0, let textView else {
            peek?.close()
            return
        }
        let index = ((peekIndex + offset) % count + count) % count
        reveal(marks.changes[index], in: textView)
        showPeek(index)
    }

    /// Scrolls `change` a third of the way down when it is not all in view, leaving room for the peek under it. The
    /// clip view scrolls as the editor's restored scroll does, so the gutter follows.
    private func reveal(_ change: GitGutterMarks.Change, in textView: TextView) {
        guard let layoutManager = textView.layoutManager, let span = span(of: change, layoutManager),
              let scrollView = textView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        guard span.minY < visible.minY || span.maxY > visible.maxY else { return }
        let insets = scrollView.contentInsets
        let lowest = textView.frame.height - clip.bounds.height + insets.bottom
        let y = min(max(span.minY - visible.height / 3, -insets.top), max(-insets.top, lowest))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Puts HEAD's lines back in place of the peeked change's, as one undoable edit, and closes the peek.
    private func revertPeekedChange() {
        bringMarksUpToDate()
        defer { peek?.close() }
        guard let textView, marks.changes.indices.contains(peekIndex),
              let edit = Self.revertEdit(marks.changes[peekIndex], in: textView) else { return }
        textView.replaceCharacters(in: edit.range, with: edit.text)
    }

    /// The replacement that turns `change`'s lines in the text view back into HEAD's, in the text's line breaks.
    private static func revertEdit(_ change: GitGutterMarks.Change, in textView: TextView) -> (range: NSRange, text: String)? {
        guard let layoutManager = textView.layoutManager else { return nil }
        let lineCount = layoutManager.lineCount
        let length = textView.textStorage.length
        let ending = layoutManager.detectedLineEnding.rawValue
        let (start, end) = (change.lines.lowerBound, change.lines.upperBound)
        guard start <= end, end <= lineCount else { return nil }
        if end < lineCount {
            // Whole lines with their breaks, up to the line after the run.
            guard let first = layoutManager.textLineForIndex(start), let after = layoutManager.textLineForIndex(end) else { return nil }
            return (NSRange(location: first.range.location, length: after.range.location - first.range.location),
                    change.removed.map { $0 + ending }.joined())
        }
        if start == 0 {
            return (NSRange(location: 0, length: length), change.removed.joined(separator: ending))
        }
        // The run reaches the end of the text, whose last line has no break: take the break before the run instead.
        guard let previous = layoutManager.textLineForIndex(start - 1) else { return nil }
        let string = textView.textStorage.string as NSString
        var breakStart = NSMaxRange(previous.range)
        if breakStart > previous.range.location, string.character(at: breakStart - 1) == 0x0A { breakStart -= 1 }
        if breakStart > previous.range.location, string.character(at: breakStart - 1) == 0x0D { breakStart -= 1 }
        return (NSRange(location: breakStart, length: length - breakStart),
                change.removed.isEmpty ? "" : ending + change.removed.joined(separator: ending))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty, let layoutManager = textView?.layoutManager, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAlpha(Self.alpha)
        let x = bounds.width - Self.trailingInset - Self.barWidth
        let half = Self.triangle / 2
        // A line's deletion triangle straddles its bottom edge: lines half a triangle around the rect count.
        for line in layoutManager.linesStartingAt(max(0, dirtyRect.minY - half), until: dirtyRect.maxY + half) {
            if let mark = marks.lines[line.index] {
                (mark == .added ? NSColor.systemGreen : NSColor.systemBlue).setFill()
                NSRect(x: x, y: line.yPos, width: Self.barWidth, height: line.height).pixelAligned.fill(using: .sourceOver)
            }
            if marks.deletedAfter.contains(line.index) {
                fillTriangle(x: x, y: line.yPos + line.height)
            }
        }
        // Whole, not clipped at the top edge.
        if marks.deletedBeforeFirst, dirtyRect.minY < Self.triangle { fillTriangle(x: x, y: half) }
    }

    /// A red triangle pointing right, its base on `x`, centered on `y`.
    private func fillTriangle(x: CGFloat, y: CGFloat) {
        let y = y.rounded()
        let half = Self.triangle / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y - half))
        path.line(to: NSPoint(x: x + Self.triangle, y: y))
        path.line(to: NSPoint(x: x, y: y + half))
        path.close()
        NSColor.systemRed.setFill()
        path.fill()
    }
}

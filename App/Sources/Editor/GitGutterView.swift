import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import IDEEditorModel
import Observation

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

    var lines: [Int: Mark] = [:]
    /// Lines after which HEAD has lines the text lacks.
    var deletedAfter: Set<Int> = []
    /// HEAD has lines before the first one.
    var deletedBeforeFirst = false

    var isEmpty: Bool { lines.isEmpty && deletedAfter.isEmpty && !deletedBeforeFirst }

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
            return marks
        }
        // Without context every hunk is one run: its removed lines, then its inserted ones.
        var delta = 0 // Lines the text has gained over HEAD before the run.
        for hunk in LineDiff.hunks(from: base, to: current, context: 0) {
            var removed = 0
            var oldStart = 1
            var inserted: [Int] = []
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if removed == 0, let number = line.oldNumber { oldStart = number }
                    removed += 1
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
            } else {
                let mark: Mark = removed == 0 ? .added : .modified
                for index in inserted { marks.lines[index] = mark }
            }
            delta += inserted.count - removed
        }
        return marks
    }
}

// MARK: - Git

extension GitGutterMarks {
    /// The marks of `text`, the editor's, for the file at `path`. Synchronous: call it off the main thread.
    static func load(path: String, text: String) -> GitGutterMarks {
        guard let base = baseText(of: path) else { return GitGutterMarks() }
        return compute(base: base, current: text)
    }

    /// HEAD's version of the file at `path`, read in its folder (`git show HEAD:./name`, so the repository above it
    /// counts, whatever the project folder): the empty text when HEAD lacks the file (untracked, added, renamed, or
    /// no commit yet); nil outside a repository or when git cannot say, for no marks at all.
    private static func baseText(of path: String) -> String? {
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
/// deleted at. It spans CodeEditSourceEditor's gutter (whose resizing carries it along) and draws at the y positions
/// the text view's layout manager reports, so a wrapped line is one bar of its full height. The marks are diffed off
/// the main thread when the file opens, 300 ms after typing pauses (or at a save before that), and when the
/// repository's HEAD or the file's status changes; one diff runs at a time, and one more if asked meanwhile.
final class GitGutterView: NSView {
    private static let barWidth: CGFloat = 3
    private static let trailingInset: CGFloat = 4
    private static let triangle: CGFloat = 6
    private static let alpha: CGFloat = 0.85

    /// What a refresh depends on besides the text.
    private struct RepositoryState: Equatable {
        let head: String?
        let isRepository: Bool
        let change: GitRepository.Change?
    }

    private let path: String
    private weak var textView: TextView?
    private let repository: GitRepository
    private var marks = GitGutterMarks() {
        didSet { if marks != oldValue { needsDisplay = true } }
    }
    private var seen: RepositoryState
    /// The refresh waiting for typing to pause.
    private var debounce: Task<Void, Never>?
    private var computing = false
    private var stale = false
    private var isDetached = false

    init(path: String, textView: TextView, repository: GitRepository) {
        self.path = path
        self.textView = textView
        self.repository = repository
        seen = Self.state(of: repository, path: path)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
        observeRepository()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The gutter's y positions start at the top of the text and grow downwards.
    override var isFlipped: Bool { true }

    /// Clicks go to the gutter and its folding ribbon underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Lifecycle

    /// Goes over the controller's gutter once its view is loaded (it appeared).
    func attach(to controller: TextViewController) {
        guard superview == nil, !isDetached, controller.isViewLoaded, let gutter = Self.gutter(in: controller.scrollView) else { return }
        frame = gutter.bounds
        gutter.addSubview(self)
    }

    /// The gutter floats in the scroll view, in a container of AppKit's outside the clip view that holds the text.
    private static func gutter(in view: NSView) -> GutterView? {
        for subview in view.subviews where !(subview is NSClipView) {
            if let gutter = subview as? GutterView { return gutter }
            if let gutter = gutter(in: subview) { return gutter }
        }
        return nil
    }

    /// The controller goes away: stop refreshing and leave the gutter.
    func detach() {
        isDetached = true
        debounce?.cancel()
        debounce = nil
        removeFromSuperview()
    }

    // MARK: Refresh

    /// The text changed: the marks move with it now, and are recomputed once typing pauses.
    func textDidChange() {
        needsDisplay = true
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
        Task { [weak self, path] in
            let marks = await Task.detached(priority: .userInitiated) { GitGutterMarks.load(path: path, text: text) }.value
            guard let self else { return }
            computing = false
            self.marks = marks
            if stale {
                stale = false
                refresh()
            }
        }
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

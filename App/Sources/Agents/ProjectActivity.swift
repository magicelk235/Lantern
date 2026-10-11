import AppKit
import IDEModel
import SwiftUI

/// What a project's sessions do, in the sessions' vocabulary (`SessionIndicator`): the approvals and questions waiting
/// in them, else whether one works, else whether one finished a turn the user has not seen (`FinishedTurns`); and which
/// sessions those are, with what each does ("Fix login — working, 2 subagents"). The Projects pane's badges and the
/// project windows' tabs show it.
struct ProjectActivity: Equatable {
    enum Mark: Equatable {
        /// What waits on the user: approvals, questions, interrupted work waiting for Continue or Leave.
        case waiting(Int)
        /// One of its sessions works.
        case working
        /// One of its sessions finished a turn out of the user's sight.
        case finished
    }

    /// Nil while nothing waits, works or finished unseen.
    let mark: Mark?
    /// The sessions behind the mark, one per line; nil without a mark.
    let help: String?

    @MainActor
    init(app: AppState, project: String) {
        let sessions = app.runningSessions(in: project).map { (title: app.sessionTitle($0.id), indicator: app.indicator(of: $0.entry)) }
        let waiting = sessions.reduce(0) { $0 + $1.indicator.waitingCount }
        if waiting > 0 {
            mark = .waiting(waiting)
            help = sessions.filter { $0.indicator.waitingCount > 0 }.map { "\($0.title) — \($0.indicator.words)" }.joined(separator: "\n")
            return
        }
        let working = sessions.filter(\.indicator.isWorking)
        if !working.isEmpty {
            mark = .working
            help = working.map { "\($0.title) — \($0.indicator.words)" }.joined(separator: "\n")
            return
        }
        let unseen = app.finishedTurns.unseen
        let finished = unseen.isEmpty ? [] : app.connection.sessions.filter { $0.workspace == project && unseen.contains($0.sessionKey) }
        if !finished.isEmpty {
            mark = .finished
            help = finished.map { "\(app.sessionTitle($0.sessionKey)) — finished" }.joined(separator: "\n")
            return
        }
        mark = nil
        help = nil
    }

    /// The mark in words: "2 waiting for you", "working", "finished".
    var words: String? {
        switch mark {
        case .waiting(let count): count == 1 ? "1 waiting for you" : "\(count) waiting for you"
        case .working: "working"
        case .finished: "finished"
        case nil: nil
        }
    }
}

/// A project's activity as a mark: a red count of what waits on the user, else the lit ember dot while one of its
/// sessions works, else the blue dot while one finished a turn the user has not seen (`FinishedDot`).
struct ProjectActivityMark: View {
    let mark: ProjectActivity.Mark

    var body: some View {
        switch mark {
        case .waiting(let count): CountBadge(count: count)
        case .working: WorkingDot()
        case .finished: FinishedDot()
        }
    }
}

/// Sessions that finished a turn (their agents worked, then all went idle) while their project's window was not the
/// key window of the active app, until the user looks at that project: its window turns key. The app keeps them (in
/// the defaults, so they outlive a relaunch); ompd knows nothing of who looked.
@MainActor @Observable
final class FinishedTurns {
    /// The sessions whose finished turn is unseen.
    private(set) var unseen: Set<SessionKey>
    /// The project of the key window while Lantern is active, nil otherwise (`look(at:sessions:)`).
    @ObservationIgnored private var looking: String?
    /// The sessions that worked at the last look at ompd's state.
    @ObservationIgnored private var working: Set<SessionKey> = []

    private static let defaultsKey = "unseenFinishedSessions"

    init() {
        unseen = Set(UserDefaults.lantern.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Follows the sessions' states while ompd is in reach: a session that worked and is idle now finished its turn,
    /// unseen unless its project's window is the key window. Returns the sessions that just finished unseen.
    func follow(_ app: AppState) -> [SessionKey] {
        let sessions = app.connection.sessions
        var unseen = unseen
        var working: Set<SessionKey> = []
        var finished: [SessionKey] = []
        for entry in sessions {
            let indicator = app.indicator(of: entry)
            if indicator.isWorking {
                working.insert(entry.sessionKey)
                unseen.remove(entry.sessionKey)
            } else if indicator == .idle, self.working.contains(entry.sessionKey), entry.workspace != looking {
                unseen.insert(entry.sessionKey)
                finished.append(entry.sessionKey)
            }
        }
        self.working = working
        // Sessions ompd no longer lists, or closed, have nothing left to see (none listed: the list is not in yet).
        if !sessions.isEmpty {
            let live = Set(sessions.filter { $0.status != .closed }.map(\.sessionKey))
            unseen.formIntersection(live)
        }
        update(unseen)
        return finished
    }

    /// The window of `project` turned key (nil: no project window is key now): what finished in that project is seen.
    func look(at project: String?, sessions: [SessionManifestEntry]) {
        looking = project
        guard let project, !unseen.isEmpty else { return }
        update(unseen.subtracting(sessions.filter { $0.workspace == project }.map(\.sessionKey)))
    }

    /// The window of `project` resigned key.
    func lookAway(from project: String) {
        if looking == project { looking = nil }
    }

    private func update(_ unseen: Set<SessionKey>) {
        guard unseen != self.unseen else { return }
        self.unseen = unseen
        UserDefaults.lantern.set(unseen.sorted(), forKey: Self.defaultsKey)
    }
}

/// Marks the native tab of a project's window (`NSWindowTab.accessoryView`, at the tab's trailing end) with the
/// project's activity (`ProjectActivity`); the tab's tooltip, which VoiceOver reads as its help, says it in words
/// ("viaduct-cli — 2 waiting for you", then the sessions). View › Show All Tabs draws only the windows' titles there.
/// Also tells `FinishedTurns` when the window turns key or resigns key.
struct ProjectTabMarker: NSViewRepresentable {
    let app: AppState
    let project: String

    func makeNSView(context: Context) -> MarkerView { MarkerView(app: app) }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.project = project
    }

    final class MarkerView: NSView {
        private let app: AppState
        /// The window's project; empty in the window of no project, whose tab has no mark.
        var project = "" {
            didSet {
                guard project != oldValue else { return }
                if !oldValue.isEmpty { app.finishedTurns.lookAway(from: oldValue) }
                if window?.isKeyWindow == true { looked() }
                follow()
            }
        }
        private var observers: [any NSObjectProtocol] = []
        /// What the tab shows now.
        private var shown: ProjectActivity?
        private let markView = NSHostingView(rootView: TabMark(mark: .working, words: ""))
        /// Each `follow()` supersedes the ones before: only the latest one's observation calls it again.
        private var generation = 0

        init(app: AppState) {
            self.app = app
            super.init(frame: .zero)
            markView.sizingOptions = [.intrinsicContentSize]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.looked() }
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.lookedAway() }
                },
            ]
            if window.isKeyWindow { looked() }
            shown = nil
            follow()
        }

        private func lookedAway() {
            guard !project.isEmpty else { return }
            app.finishedTurns.lookAway(from: project)
        }

        private func looked() {
            guard !project.isEmpty else { return }
            app.finishedTurns.look(at: project, sessions: app.connection.sessions)
        }

        /// Shows the project's activity on the window's tab, and again whenever it changes, while the view is in the
        /// window.
        private func follow() {
            generation += 1
            let current = generation
            guard let window else { return }
            let project = project
            let activity = withObservationTracking {
                project.isEmpty ? nil : ProjectActivity(app: app, project: project)
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == current else { return }
                    follow()
                }
            }
            guard activity != shown else { return }
            shown = activity
            let tab = window.tab
            if let activity, let mark = activity.mark, let words = activity.words {
                markView.rootView = TabMark(mark: mark, words: words)
                if tab.accessoryView !== markView { tab.accessoryView = markView }
                tab.toolTip = "\(AppState.projectName(project)) — \(words)" + (activity.help.map { "\n" + $0 } ?? "")
            } else {
                if tab.accessoryView != nil { tab.accessoryView = nil }
                tab.toolTip = nil
            }
        }
    }

    /// The mark in the tab, read by VoiceOver as its words.
    private struct TabMark: View {
        let mark: ProjectActivity.Mark
        let words: String

        var body: some View {
            ProjectActivityMark(mark: mark)
                .frame(minWidth: 15, minHeight: 15)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
        }
    }
}

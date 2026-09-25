import AppKit
import IDEModel
import IDEState
import SwiftUI

/// App-wide state: the daemon link, the agent registration, and the window's layout — sidebar, detail-area tabs,
/// frame — which lives in `state.sqlite` and comes back on relaunch.
@MainActor @Observable
final class AppState {
    /// The main window: its scene id and its row in `state.sqlite`.
    static let mainWindowID = "main"

    let connection = DaemonConnection(
        clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    let agent = DaemonAgent()
    /// Open files and the file navigators.
    let editors: Editors
    /// Detail-area tabs, one strip per workspace. The selected tab is what the detail area shows; when it is a
    /// session, the sidebar highlights it.
    private(set) var tabs: TabLayout
    /// `.detailOnly` while the user hid the sidebar.
    var columnVisibility: NavigationSplitViewVisibility {
        didSet { if columnVisibility != oldValue { saveWindow() } }
    }
    /// Width the sidebar column opens with: the one it had when the app last quit.
    let initialSidebarWidth: Double
    var alert: AlertMessage?

    @ObservationIgnored private let persistence: StatePersistence
    @ObservationIgnored private var sidebarWidth: Double?
    /// Last frame of the window outside full screen; applied to a window that attaches.
    @ObservationIgnored private var windowFrame: WindowFrame?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var windowObservers: [any NSObjectProtocol] = []

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        persistence = StatePersistence(paths: .standard)
        let restored = persistence.restoredWindow
        editors = Editors(persistence: persistence)
        tabs = restored?.tabs ?? TabLayout()
        columnVisibility = restored?.sidebarVisible == false ? .detailOnly : .all
        initialSidebarWidth = restored?.sidebarWidth ?? 270
        sidebarWidth = restored?.sidebarWidth
        windowFrame = restored?.frame
        // Regime A: each restored session tab subscribes once connected, replaying its journal from the
        // start; nothing is sent to omp.
        for sessionKey in tabs.tabs.compactMap(\.sessionKey) { openSession(sessionKey) }
        restoreEditors()
        observeSystemPower()
    }

    func start() {
        agent.registerIfNeeded()
        connection.start()
        if let reason = persistence.unavailableReason {
            alert = AlertMessage(
                title: "The window layout will not be remembered",
                message: "omp IDE could not open its state database: \(reason)")
        }
    }

    // MARK: - Sessions and tabs

    /// The session on screen.
    var selectedSession: SessionKey? { tabs.selectedSession }

    func entry(for sessionKey: SessionKey) -> SessionManifestEntry? {
        connection.sessions.first { $0.sessionKey == sessionKey }
    }

    /// Shows `sessionKey` in its tab, opening one at the end of its workspace's strip first if needed.
    func showSession(_ sessionKey: SessionKey) {
        guard let entry = entry(for: sessionKey) else { return }
        show(entry)
    }

    func selectTab(_ tab: TabKind) {
        editors.highlight = nil
        tabs.select(tab)
        saveWindow()
    }

    /// Closes the tab only: the session keeps running (Close Session is what stops omp). An editor with unsaved edits
    /// asks to save them first.
    func closeTab(_ tab: TabKind) {
        guard let path = tab.editorPath else {
            tabs.close(tab)
            saveWindow()
            return
        }
        Task {
            guard await editors.closeIfConfirmed(path, window: window) else { return }
            tabs.close(tab)
            saveWindow()
        }
    }

    /// Shows `path` in its editor tab, opening one at the end of `workspace`'s strip first if needed.
    func openEditor(_ path: String, in workspace: String) {
        editors.open(path, in: workspace).focusOnAppear = true
        editors.highlight = nil
        tabs.open(.editor(path: path), in: workspace)
        saveWindow()
    }

    /// Reopens the documents of the restored editor tabs, and gives a tab to every unsaved buffer of the previous run
    /// that has none: hot-exit never drops an edit silently.
    private func restoreEditors() {
        for strip in tabs.strips {
            for path in strip.tabs.compactMap(\.editorPath) { editors.open(path, in: strip.workspace) }
        }
        let selection = tabs.selection
        for (path, workspace) in editors.unclaimedBuffers(workspaces: tabs.strips.map(\.workspace)) {
            editors.open(path, in: workspace)
            tabs.open(.editor(path: path), in: workspace)
        }
        if let selection { tabs.select(selection) }
    }

    /// Picks a workspace folder and asks ompd to start omp there with the default approval mode.
    func newSession() {
        guard let folder = WorkspacePicker.choose() else { return }
        let mode = UserDefaults.standard.string(forKey: AppSettings.defaultApprovalModeKey).flatMap(ApprovalMode.init(rawValue:))
        Task {
            do {
                show(try await connection.createSession(workspace: folder, approvalMode: mode))
            } catch {
                alert = AlertMessage(title: "Could not start a session", message: error.userMessage)
            }
        }
    }

    func close(_ sessionKey: SessionKey) {
        Task {
            do {
                try await connection.closeSession(sessionKey)
            } catch {
                alert = AlertMessage(title: "Could not close the session", message: error.userMessage)
            }
        }
    }

    /// Where the transcript of `sessionKey` was scrolled when it was last on screen.
    func savedUI(for sessionKey: SessionKey) -> SessionUIState? {
        persistence.sessions[sessionKey]
    }

    /// `anchor`: the transcript row at the bottom edge, nil while scrolled to the end.
    func scrollAnchorChanged(_ anchor: String?, in model: SessionViewModel) {
        persistence.updateSession(model.sessionKey) { ui in
            ui.scrollAnchor = anchor
            ui.lastSeq = max(ui.lastSeq, model.lastSeq)
        }
    }

    private func show(_ entry: SessionManifestEntry) {
        openSession(entry.sessionKey)
        tabs.open(.session(entry.sessionKey), in: entry.workspace)
        saveWindow()
    }

    /// Subscribes the session (now or on connect) and gives it back its unsent draft.
    private func openSession(_ sessionKey: SessionKey) {
        guard connection.openSessions[sessionKey] == nil else { return }
        let model = connection.open(sessionKey)
        if let draft = persistence.sessions[sessionKey]?.draft, !draft.isEmpty { model.draft = draft }
        observeDraft(of: model)
    }

    private func observeDraft(of model: SessionViewModel) {
        withObservationTracking {
            _ = model.draft
        } onChange: { [weak self, weak model] in
            guard let self, let model else { return }
            // `onChange` runs before the new value is stored.
            Task { @MainActor in
                self.saveSessionUI(of: model)
                self.observeDraft(of: model)
            }
        }
    }

    private func saveSessionUI(of model: SessionViewModel) {
        persistence.updateSession(model.sessionKey) { ui in
            ui.draft = model.draft
            ui.lastSeq = max(ui.lastSeq, model.lastSeq)
        }
    }

    // MARK: - Window

    /// Called with the window hosting the main scene each time it (re)appears.
    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        // AppKit state restoration (SwiftUI's restoration class) keeps macOS "Reopen windows" and Stage Manager in
        // step; the layout itself comes from state.sqlite. A frame macOS already restored equals the saved one, so
        // the window is placed once.
        window.isRestorable = true
        if let saved = windowFrame {
            let frame = Self.visibleFrame(for: NSRect(saved), in: window)
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
        let center = NotificationCenter.default
        for observer in windowObservers { center.removeObserver(observer) }
        windowObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowFrameChanged() }
            }
        }
        windowObservers += [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushState() }
            }
        }
    }

    func sidebarWidthChanged(_ width: Double) {
        // Hiding the sidebar animates its column down to nothing; keep the width it is shown with.
        guard columnVisibility != .detailOnly, width >= 200, width != sidebarWidth else { return }
        sidebarWidth = width
        saveWindow()
    }

    /// Captures everything not saved on change and writes it all now: on resign key, window close, sleep, power off
    /// and quit.
    func flushState() {
        windowFrameChanged()
        for model in connection.openSessions.values { saveSessionUI(of: model) }
        editors.flush()
        saveWindow()
        persistence.flush()
    }

    private func windowFrameChanged() {
        guard let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let frame = WindowFrame(window.frame)
        guard frame != windowFrame else { return }
        windowFrame = frame
        saveWindow()
    }

    private func saveWindow() {
        persistence.save(
            WindowState(
                id: Self.mainWindowID, frame: windowFrame, sidebarWidth: sidebarWidth,
                sidebarVisible: columnVisibility != .detailOnly, tabs: tabs))
    }

    private func observeSystemPower() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            // AppState lives as long as the app: the observers are never removed.
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushState() }
            }
        }
    }

    /// `frame` if it shows on a screen (kept clear of the menu bar), else the same size centered on the main screen:
    /// the display it was on may be gone.
    private static func visibleFrame(for frame: NSRect, in window: NSWindow) -> NSRect {
        let overlap = { (screen: NSScreen) in screen.visibleFrame.intersection(frame).width * screen.visibleFrame.intersection(frame).height }
        if let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 {
            return window.constrainFrameRect(frame, to: screen)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return frame }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }
}

extension WindowFrame {
    init(_ rect: NSRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

extension NSRect {
    init(_ frame: WindowFrame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}

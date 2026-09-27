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
    /// Terminal emulators: `.terminal` tabs on PTYs in ompd, and `.session` tabs showing omp's TUI.
    let terminals: TerminalsController
    /// Detail-area tabs, one strip per workspace. The selected tab is what the detail area shows and what the sidebar
    /// highlights.
    private(set) var tabs: TabLayout
    /// `.detailOnly` while the user hid the sidebar.
    var columnVisibility: NavigationSplitViewVisibility {
        didSet { if columnVisibility != oldValue { saveWindow() } }
    }
    /// The Files panel, trailing the detail area, is shown.
    var filesVisible: Bool {
        didSet { if filesVisible != oldValue { saveWindow() } }
    }
    /// Project folders the user added, in the order added. `projects` (below) also lists folders that have sessions
    /// or tabs.
    private(set) var addedProjects: [String]
    /// Width the sidebar column opens with: the one it had when the app last quit.
    let initialSidebarWidth: Double
    var alert: AlertMessage?
    /// A Close Session / Close Terminal the user asked for, waiting for their confirmation in the window.
    var pendingClose: CloseRequest?

    @ObservationIgnored private let persistence: StatePersistence
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sidebarWidth: Double?
    /// Last frame of the window outside full screen; applied to a window that attaches.
    @ObservationIgnored private var windowFrame: WindowFrame?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var windowObservers: [any NSObjectProtocol] = []
    /// Size of the area below the tab strip, where a tab's content goes, and whether the strip was showing.
    @ObservationIgnored private var tabContentArea: (size: CGSize, belowStrip: Bool)?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum CloseRequest: Identifiable {
        case session(SessionKey)
        /// Remove a stopped session from ompd's list.
        case forget(SessionKey)

        var id: String {
            switch self {
            case .session(let key): "session:\(key)"
            case .forget(let key): "forget:\(key)"
            }
        }
    }

    init() {
        persistence = StatePersistence(paths: .standard)
        let restored = persistence.restoredWindow
        editors = Editors(persistence: persistence)
        tabs = restored?.tabs ?? TabLayout()
        terminals = TerminalsController(registry: connection.terminals)
        columnVisibility = restored?.sidebarVisible == false ? .detailOnly : .all
        filesVisible = restored?.filesVisible ?? true
        addedProjects = restored?.projects ?? []
        initialSidebarWidth = restored?.sidebarWidth ?? 270
        sidebarWidth = restored?.sidebarWidth
        windowFrame = restored?.frame
        // Regime A: each restored session tab attaches to omp's TUI once connected; nothing is sent to omp.
        for sessionKey in tabs.tabs.compactMap(\.sessionKey) { connection.open(sessionKey) }
        restoreEditors()
        // Terminal tabs re-attach once shown; those whose PTY ompd no longer lists close.
        for strip in tabs.strips {
            for ptyId in strip.tabs.compactMap(\.ptyId) { terminals.adopt(ptyId, workspace: strip.workspace) }
        }
        connection.terminals.onGone = { [weak self] ptyId in self?.terminalGone(ptyId) }
        observeSystemPower()
    }

    /// launchd starts a registered ompd within a moment. A daemon still out of reach this long after launch has a
    /// registration launchd cannot spawn (made by a bundle signed differently); it is redone once.
    private static let daemonStartGrace: Duration = .seconds(12)

    /// Registers the LaunchAgent and connects to ompd. Runs at launch even when no window opens (the main window may
    /// have been closed when the app last quit); the window's `.task` calls it again, which is a no-op.
    func start() {
        guard !started else { return }
        started = true
        agent.registerIfNeeded()
        connection.start()
        if let reason = persistence.unavailableReason {
            alert = AlertMessage(
                title: "The window layout will not be remembered",
                message: "omp IDE could not open its state database: \(reason)")
        }
        Task {
            try? await Task.sleep(for: Self.daemonStartGrace)
            if !connection.isConnected { await repairDaemon() }
        }
    }

    /// The user asks for ompd again: the registration is redone.
    func restartDaemon() {
        Task { await repairDaemon() }
    }

    private func repairDaemon() async {
        await agent.repair { [connection] in connection.isConnected }
    }

    // MARK: - Sessions and tabs

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

    /// Closes the tab. A session tab ends its session and a terminal tab its PTY (they are gone, not hidden; asked
    /// first when the agent is working or a program runs in the terminal). An editor with unsaved edits asks to
    /// save them first.
    func closeTab(_ tab: TabKind) {
        switch tab {
        case .session(let sessionKey):
            requestCloseSession(sessionKey)
        case .terminal(let ptyId):
            requestCloseTerminal(ptyId)
        case .editor(let path):
            Task {
                guard await editors.closeIfConfirmed(path, window: window) else { return }
                tabs.close(tab)
                saveWindow()
            }
        }
    }

    /// Closes a session's tab without touching the session.
    private func dropSessionTab(_ sessionKey: SessionKey) {
        guard tabs.contains(.session(sessionKey)) else { return }
        tabs.close(.session(sessionKey))
        terminals.releaseSession(sessionKey)
        connection.release(sessionKey)
        saveWindow()
    }

    /// Shows `tab`, opening it first if needed (sidebar selection).
    func showTab(_ tab: TabKind) {
        switch tab {
        case .session(let sessionKey): showSession(sessionKey)
        case .terminal(let ptyId): showTerminal(ptyId)
        case .editor(let path):
            if tabs.contains(tab) {
                selectTab(tab)
            } else if let workspace = editors.workspace(containing: path) {
                openEditor(path, in: workspace)
            }
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

    /// Asks for a project folder and starts omp there (the folder joins the projects).
    func newSession() {
        guard let folder = WorkspacePicker.choose(prompt: "Start Session") else { return }
        newSession(in: folder.standardizedFileURL.path(percentEncoded: false))
    }

    /// Asks ompd to start omp's TUI in `workspace`, with the default approval mode, at the size the new tab will have.
    func newSession(in workspace: String) {
        let workspace = Self.normalized(workspace)
        addProject(workspace)
        let mode = UserDefaults.standard.string(forKey: AppSettings.defaultApprovalModeKey).flatMap(ApprovalMode.init(rawValue:))
        let size = newTabSize()
        Task {
            do {
                let entry = try await connection.createSession(
                    workspace: URL(filePath: workspace, directoryHint: .isDirectory), approvalMode: mode, size: size)
                show(entry)
            } catch {
                alert = AlertMessage(title: "Could not start a session", message: error.userMessage)
            }
        }
    }

    // MARK: - Projects

    /// Every project folder the sidebar lists: the ones added, then those with sessions or tabs, by name.
    var projects: [String] {
        var seen = Set(addedProjects)
        var all = addedProjects
        for workspace in connection.workspaces.map(\.path) + tabs.strips.map(\.workspace) where seen.insert(workspace).inserted {
            all.append(workspace)
        }
        return all
    }

    /// The project the detail area shows, else the first one.
    var currentProject: String? { tabs.selectedStrip?.workspace ?? projects.first }

    /// Asks for a folder and adds it as a project; the Files panel shows it.
    func addProject() {
        guard let folder = WorkspacePicker.choose(prompt: "Add Project") else { return }
        let workspace = Self.normalized(folder.standardizedFileURL.path(percentEncoded: false))
        addProject(workspace)
        filesVisible = true
        filesProject = workspace
    }

    func addProject(_ workspace: String) {
        let workspace = Self.normalized(workspace)
        guard !addedProjects.contains(workspace) else { return }
        addedProjects.append(workspace)
        saveWindow()
    }

    /// Whether the project can leave the sidebar: nothing of it is open or running.
    func canRemoveProject(_ workspace: String) -> Bool {
        !connection.workspaces.contains { $0.path == workspace } && !tabs.strips.contains { $0.workspace == workspace }
    }

    func removeProject(_ workspace: String) {
        guard canRemoveProject(workspace) else { return }
        addedProjects.removeAll { $0 == workspace }
        if filesProject == workspace { filesProject = nil }
        saveWindow()
    }

    /// The project whose files the Files panel shows: the one picked there, else the project on screen.
    var filesProject: String? {
        get { filesProjectOverride.flatMap { projects.contains($0) ? $0 : nil } ?? currentProject }
        set { filesProjectOverride = newValue }
    }
    private var filesProjectOverride: String?

    /// `path` without a trailing slash (a folder's identity everywhere in the app).
    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func projectName(_ path: String) -> String {
        let name = URL(filePath: path, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Starts omp again for a closed session from its session file; its tab follows omp to the new PTY.
    func resumeSession(_ sessionKey: SessionKey) {
        let size = connection.openSessions[sessionKey]?.size ?? newTabSize()
        Task {
            do {
                show(try await connection.resumeSession(sessionKey, size: size))
            } catch {
                alert = AlertMessage(title: "Could not resume the session", message: error.userMessage)
            }
        }
    }

    /// Ends the session: at once, or after a confirmation while the agent is working (it lives in the window).
    func requestCloseSession(_ sessionKey: SessionKey) {
        guard connection.isConnected, let entry = entry(for: sessionKey) else {
            dropSessionTab(sessionKey)
            return
        }
        if entry.status == .busy { pendingClose = .session(sessionKey) } else { closeSession(sessionKey) }
    }

    /// Ends omp for the session gracefully and drops the session from ompd's list; its tab closes. The conversation
    /// file on disk stays (resumable through `session.open`).
    func closeSession(_ sessionKey: SessionKey) {
        Task {
            do {
                if let entry = entry(for: sessionKey), !entry.isStopped {
                    try await connection.closeSession(sessionKey)
                }
                // The stop is reported before the manifest settles: a forget refused for a running omp is retried.
                for attempt in 1...5 {
                    do {
                        try await connection.forgetSession(sessionKey)
                        break
                    } catch let error as DaemonError where error.code == .sessionBusy && attempt < 5 {
                        try await Task.sleep(for: .milliseconds(400))
                    }
                }
                dropSessionTab(sessionKey)
            } catch {
                alert = AlertMessage(title: "Could not close the session", message: error.userMessage)
            }
        }
    }

    /// Asks before dropping a stopped session from the list (the confirmation lives in the window).
    func requestForgetSession(_ sessionKey: SessionKey) {
        guard connection.isConnected, let entry = entry(for: sessionKey), entry.isStopped else { return }
        pendingClose = .forget(sessionKey)
    }

    /// Drops the session from ompd's list; its tab closes. The session file on disk stays.
    func forgetSession(_ sessionKey: SessionKey) {
        Task {
            do {
                try await connection.forgetSession(sessionKey)
                if tabs.contains(.session(sessionKey)) {
                    tabs.close(.session(sessionKey))
                    terminals.releaseSession(sessionKey)
                    saveWindow()
                }
            } catch {
                alert = AlertMessage(title: "Could not remove the session", message: error.userMessage)
            }
        }
    }

    /// omp's name for the session, else what its TUI titles its window (without the `π >` glyph, and only when it
    /// says more than the folder), else "New session".
    func sessionTitle(_ sessionKey: SessionKey) -> String {
        let entry = entry(for: sessionKey)
        if let title = entry?.title, !title.isEmpty { return title }
        if let program = connection.openSessions[sessionKey]?.programTitle {
            var title = program.trimmingCharacters(in: .whitespaces)
            if title.hasPrefix("π >") { title = String(title.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            let folder = entry.map { Self.projectName($0.workspace) }
            if !title.isEmpty, title != folder { return title }
        }
        return "New session"
    }

    /// How long ago the session was last active (else started): "6h ago".
    static func age(of entry: SessionManifestEntry, now: Date = Date()) -> String {
        let date = entry.lastActiveAt ?? entry.createdAt
        if now.timeIntervalSince(date) < 60 { return "now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    private func show(_ entry: SessionManifestEntry) {
        connection.open(entry.sessionKey)
        tabs.open(.session(entry.sessionKey), in: entry.workspace)
        saveWindow()
    }

    /// The area below the tab strip changed size.
    func tabContentSizeChanged(_ size: CGSize) {
        tabContentArea = (size, tabs.selectedStrip != nil)
    }

    /// The cells a new terminal or session tab's emulator gets: what fits the area below the tab strip.
    private func newTabSize() -> TerminalSize {
        guard var area = tabContentArea?.size else { return terminals.lastSize ?? .standard }
        // A first tab brings the strip along.
        if tabContentArea?.belowStrip == false { area.height -= Chrome.tabStripHeight }
        return terminals.cells(fitting: TerminalPane.emulatorSize(in: area))
    }

    // MARK: - Terminals

    /// Opens the login shell on a new PTY in `workspace` (default: the workspace on screen, else the home folder), in a
    /// new tab of that workspace's strip.
    func newTerminal(in workspace: String? = nil) {
        let workspace = Self.normalized(workspace ?? currentProject ?? NSHomeDirectory())
        addProject(workspace)
        let size = newTabSize()
        Task {
            do {
                let ptyId = try await terminals.open(in: workspace, size: size)
                tabs.open(.terminal(ptyId), in: workspace)
                saveWindow()
            } catch {
                alert = AlertMessage(title: "Could not open a terminal", message: error.userMessage)
            }
        }
    }

    /// Shows the terminal of `ptyId` in its tab, opening one in its workspace's strip first if needed.
    func showTerminal(_ ptyId: PTYID) {
        if tabs.contains(.terminal(ptyId)) {
            tabs.select(.terminal(ptyId))
        } else {
            guard let info = connection.terminals.info(ptyId) else { return }
            let workspace = terminals.workspace(of: info, among: knownWorkspaces)
            terminals.adopt(ptyId, workspace: workspace)
            tabs.open(.terminal(ptyId), in: workspace)
        }
        saveWindow()
    }

    /// Ends the PTY and everything on it; its tab closes.
    func requestCloseTerminal(_ ptyId: PTYID) {
        guard connection.isConnected, terminals.model(ptyId) != nil else {
            tabs.close(.terminal(ptyId))
            terminals.release(ptyId)
            saveWindow()
            return
        }
        closeTerminal(ptyId)
    }

    /// Ends the PTY and everything running on it; its tab closes.
    func closeTerminal(_ ptyId: PTYID) {
        Task {
            do {
                try await terminals.close(ptyId)
            } catch {
                alert = AlertMessage(title: "Could not close the terminal", message: error.userMessage)
            }
        }
    }

    /// Runs an exited terminal's program again, on a new PTY in the same tab.
    func restartTerminal(_ ptyId: PTYID) {
        Task {
            do {
                let restarted = try await terminals.restart(ptyId)
                terminals.release(ptyId)
                tabs.replace(.terminal(ptyId), with: .terminal(restarted))
                saveWindow()
                try await terminals.close(ptyId)
            } catch {
                alert = AlertMessage(title: "Could not restart the terminal", message: error.userMessage)
            }
        }
    }

    /// Workspaces the sidebar knows: the projects.
    var knownWorkspaces: [String] { projects }

    /// ompd no longer has the PTY: its tab goes.
    private func terminalGone(_ ptyId: PTYID) {
        terminals.forget(ptyId)
        guard tabs.contains(.terminal(ptyId)) else { return }
        tabs.close(.terminal(ptyId))
        saveWindow()
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
                sidebarVisible: columnVisibility != .detailOnly, filesVisible: filesVisible, projects: addedProjects,
                tabs: tabs))
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

extension SessionManifestEntry {
    /// ompd can resume the session and its session file is still on disk.
    var isResumable: Bool { canResume && !sessionFileIsGone }
}

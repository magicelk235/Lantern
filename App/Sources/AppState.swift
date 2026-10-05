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

    let connection = DaemonConnection(clientVersion: AppState.version)
    let agent = DaemonAgent()
    /// The menu-bar extra's login item.
    let menuBar = MenuBarAgent()
    /// What the app does about an ompd that refuses its version.
    let outdatedDaemon: OutdatedDaemon
    /// Crash reports of ompd and omp IDE the user has not seen yet (local only).
    let crashNotices = CrashNotices()
    /// Open files and the file navigators.
    let editors: Editors
    /// Terminal emulators: `.terminal` tabs on PTYs in ompd, and `.session` tabs showing omp's TUI.
    let terminals: TerminalsController
    /// Detail-area tabs, one strip per workspace. The selected tab is what the detail area shows and what the sidebar
    /// highlights.
    private(set) var tabs: TabLayout
    /// The sidebar (the pane next to the activity bar) is shown.
    var sidebarVisible: Bool {
        didSet { if sidebarVisible != oldValue { saveWindow() } }
    }
    /// Width of the sidebar pane, dragged at its trailing edge.
    var sidebarWidth: Double {
        didSet {
            sidebarWidth = min(max(sidebarWidth, Self.minimumSidebarWidth), Self.maximumSidebarWidth)
            if sidebarWidth != oldValue { saveWindow() }
        }
    }
    static let minimumSidebarWidth = 200.0
    static let maximumSidebarWidth = 520.0
    /// The pane the activity bar shows: Files, Changes or Projects. Kept in the defaults.
    var pane: SidebarPane {
        didSet { if pane != oldValue { UserDefaults.standard.set(pane.rawValue, forKey: SidebarPane.defaultsKey) } }
    }
    /// The project of the key window.
    private var keyProject: String?
    /// Project folders the user added, in the order added. `projects` (below) also lists folders that have sessions
    /// or tabs.
    private(set) var addedProjects: [String]
    var alert: AlertMessage?
    /// A Close Session / Close Terminal the user asked for, waiting for their confirmation in the window.
    var pendingClose: CloseRequest?
    /// The project whose Open Session sheet is up (its window shows it).
    var sessionPickerProject: String?
    /// The file Quick Look shows, and the project whose window shows it (`QuickLook.swift`).
    var quickLookItem: QuickLookItem?

    /// `state.sqlite` and the hot-exit copies; its `writeFailure` is the window's banner while writes fail.
    @ObservationIgnored let persistence: StatePersistence
    @ObservationIgnored private var started = false
    /// Windows `attach(_:project:)` set up, until they close, and their observers.
    @ObservationIgnored private var windowsAttached: Set<ObjectIdentifier> = []
    @ObservationIgnored private var windowObservers: [ObjectIdentifier: [any NSObjectProtocol]] = [:]
    /// Tells ompd the last window closed once `windowlessDelay` passed with none open.
    @ObservationIgnored private var windowlessReport: Task<Void, Never>?
    @ObservationIgnored private var windowsByProject: [String: ObjectIdentifier] = [:]
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
        outdatedDaemon = OutdatedDaemon(connection: connection, agent: agent)
        sidebarVisible = restored?.sidebarVisible ?? true
        sidebarWidth = restored?.sidebarWidth ?? 270
        pane = UserDefaults.standard.string(forKey: SidebarPane.defaultsKey).flatMap(SidebarPane.init(rawValue:)) ?? .files
        var restoredProjects = Set<String>()
        addedProjects = (restored?.projects ?? []).map(Self.normalized).filter { restoredProjects.insert($0).inserted }
        // Regime A: each restored session tab attaches to omp's TUI once connected; nothing is sent to omp.
        for sessionKey in tabs.tabs.compactMap(\.sessionKey) { connection.open(sessionKey) }
        restoreEditors()
        // Terminal tabs re-attach once shown; those whose PTY ompd no longer lists close.
        for strip in tabs.strips {
            for ptyId in strip.tabs.compactMap(\.ptyId) { terminals.adopt(ptyId, workspace: strip.workspace) }
        }
        connection.terminals.onGone = { [weak self] ptyId in self?.terminalGone(ptyId) }
        observeSystemPower()
        installEditorNavigation()
    }

    /// launchd starts a registered ompd within a moment. A daemon still out of reach this long after launch has a
    /// registration launchd cannot spawn (made by a bundle signed differently); it is redone once. One that refuses this
    /// app's version runs, so its registration is fine (`outdatedDaemon` restarts it).
    private static let daemonStartGrace: Duration = .seconds(12)

    /// This build's version the way ompd reports its own (`ompdVersion`), "0.1.0 (42)": ompd compares the two, and on a
    /// hello of another build moves to the ompd installed at its path.
    private static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String, !short.isEmpty else { return "dev" }
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }()

    /// Registers the LaunchAgent and the menu-bar extra's login item, and connects to ompd. Runs at launch even when no
    /// window opens (the main window may have been closed when the app last quit); the window's `.task` calls it again,
    /// which is a no-op.
    func start() {
        guard !started else { return }
        started = true
        agent.registerIfNeeded()
        menuBar.sync()
        outdatedDaemon.start()
        connection.start()
        crashNotices.start()
        if let reason = persistence.unavailableReason {
            alert = AlertMessage(
                title: "The window layout will not be remembered",
                message: "omp IDE could not open its state database: \(reason)")
        }
        Task {
            try? await Task.sleep(for: Self.daemonStartGrace)
            switch connection.status {
            case .connecting, .daemonUnavailable: await repairDaemon()
            case .connected, .versionMismatch: break
            }
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

    /// The adopted session whose omp runs in the terminal `ptyId` (the user typed `omp` there), if any: the terminal's
    /// tab and row stand for the session while it runs.
    func adoptedSession(on ptyId: PTYID) -> SessionManifestEntry? {
        connection.sessions.first { $0.adopted && $0.ptyId == ptyId }
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
                guard await editors.closeIfConfirmed(path, window: NSApp.keyWindow) else { return }
                tabs.close(tab)
                saveWindow()
            }
        }
    }

    /// Closes the editor tabs of `path` and of everything under it; false when the user kept an unsaved one.
    func closeEditors(under path: String) async -> Bool {
        for tab in tabs.tabs {
            guard let open = tab.editorPath, open == path || open.hasPrefix(path + "/") else { continue }
            guard await editors.closeIfConfirmed(open, window: NSApp.keyWindow) else { return false }
            tabs.close(tab)
            saveWindow()
        }
        return true
    }

    /// Closes a session's tab without touching the session.
    private func dropSessionTab(_ sessionKey: SessionKey) {
        guard tabs.contains(.session(sessionKey)) else { return }
        tabs.close(.session(sessionKey))
        terminals.releaseSession(sessionKey)
        connection.release(sessionKey)
        saveWindow()
    }

    /// Shows `path` in its editor tab, opening one at the end of `workspace`'s strip first if needed.
    func openEditor(_ path: String, in workspace: String) {
        editors.open(path, in: workspace).focusOnAppear = true
        editors.highlight = nil
        tabs.open(.editor(path: path), in: workspace)
        saveWindow()
        showProject(workspace)
    }

    /// Reopens the documents of the restored editor tabs, and gives a tab to every unsaved buffer of the previous run
    /// that has none: hot-exit never drops an edit silently.
    private func restoreEditors() {
        for strip in tabs.strips {
            for path in strip.tabs.compactMap(\.editorPath) { editors.open(path, in: strip.workspace) }
        }
        for (path, workspace) in editors.unclaimedBuffers(workspaces: tabs.strips.map(\.workspace)) {
            editors.open(path, in: workspace)
            tabs.add(.editor(path: path), in: workspace)
        }
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

    /// Returns once connected to ompd, or after `timeout`: for what macOS hands a just-launched app (a Service, a
    /// Spotlight result) while it is still connecting.
    func waitUntilConnected(timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while !connection.isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
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

    /// The project in focus: the key window's, else the first.
    var currentProject: String? {
        keyProject.flatMap { projects.contains($0) ? $0 : nil } ?? projects.first
    }

    /// The tabs of `project`.
    func strip(of project: String) -> TabLayout.Strip? {
        tabs.strips.first { $0.workspace == project }
    }

    /// The tab a project's window shows: the one it showed last (else its first).
    func selectedTab(in project: String) -> TabKind? {
        strip(of: project)?.preferredTab
    }

    /// The tab of the window in focus.
    var selectedTab: TabKind? {
        currentProject.flatMap(selectedTab(in:))
    }

    /// Brings `workspace`'s window forward (opening it as a tab of the group if needed).
    func showProject(_ workspace: String) {
        let workspace = Self.normalized(workspace)
        guard projects.contains(workspace) else { return }
        openProjectWindow?(workspace)
    }

    /// Asks for a folder, adds it as a project and puts it in focus.
    func addProject() {
        guard let folder = WorkspacePicker.choose(prompt: "Add Project") else { return }
        let workspace = Self.normalized(folder.standardizedFileURL.path(percentEncoded: false))
        addProject(workspace)
        showProject(workspace)
    }

    func addProject(_ workspace: String) {
        let workspace = Self.normalized(workspace)
        guard !addedProjects.contains(workspace) else { return }
        addedProjects.append(workspace)
        saveWindow()
    }

    /// Whether the project can leave the list: nothing of it is open or running.
    func canRemoveProject(_ workspace: String) -> Bool {
        !connection.workspaces.contains { $0.path == workspace } && !tabs.strips.contains { $0.workspace == workspace }
    }

    func removeProject(_ workspace: String) {
        guard canRemoveProject(workspace) else { return }
        addedProjects.removeAll { $0 == workspace }
        saveWindow()
        closeProjectWindow?(workspace)
    }

    /// Every session and terminal ompd lists gets a tab in its project's strip (the tabs are the only list of them);
    /// a session running in a terminal is the terminal's tab. Nothing changes what is on screen.
    func syncTabs() {
        var changed = false
        for entry in connection.sessions where !entry.adopted && !tabs.contains(.session(entry.sessionKey)) {
            connection.open(entry.sessionKey)
            tabs.add(.session(entry.sessionKey), in: entry.workspace)
            changed = true
        }
        for info in connection.terminals.terminals where !tabs.contains(.terminal(info.ptyId)) {
            let workspace = terminals.workspace(of: info, among: knownWorkspaces)
            terminals.adopt(info.ptyId, workspace: workspace)
            tabs.add(.terminal(info.ptyId), in: workspace)
            changed = true
        }
        if changed { saveWindow() }
    }

    /// `path` as ompd names a workspace (`Daemon.canonicalDirectory`): symlinks resolved while the folder exists (so a
    /// folder picked through `/tmp` or a linked folder is the project its sessions report), no trailing slash. A
    /// folder's identity everywhere in the app.
    static func normalized(_ path: String) -> String {
        if path.hasPrefix("/"), let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
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

    /// The session's folder is gone: asks where it is now and resumes the session there (same session, new folder).
    /// Its tab moves to that folder's project, which joins the projects if needed.
    func locateFolder(_ sessionKey: SessionKey) {
        guard let folder = WorkspacePicker.choose(prompt: "Resume Here") else { return }
        let size = connection.openSessions[sessionKey]?.size ?? newTabSize()
        Task {
            do {
                let entry = try await connection.resumeSession(sessionKey, in: folder, size: size)
                addProject(entry.workspace)
                if strip(of: entry.workspace)?.tabs.contains(.session(sessionKey)) != true {
                    tabs.close(.session(sessionKey))
                }
                show(entry)
            } catch {
                alert = AlertMessage(title: "Could not resume the session", message: error.userMessage)
            }
        }
    }

    /// Opens the omp session file at `path` (picked in the Open Session sheet, or in Spotlight) as a session of
    /// `project`: the tab of the session ompd runs for it comes forward, the stopped session ompd keeps for it resumes,
    /// else a new session resumes it in `project`.
    func openSessionFile(_ path: String, in project: String) {
        if let known = connection.session(forFile: path) {
            if known.isStopped {
                resumeSession(known.sessionKey)
            } else {
                showSession(known.sessionKey)
            }
            return
        }
        let size = newTabSize()
        Task {
            do {
                show(try await connection.openSession(
                    file: URL(filePath: path), workspace: URL(filePath: project, directoryHint: .isDirectory), size: size))
            } catch {
                alert = AlertMessage(title: "Could not open the session", message: error.userMessage)
            }
        }
    }

    /// Answers an interruption waiting for the user: the main agent (`main`) and the subagents `agents` are asked to
    /// continue, the rest is left. False when ompd refused (the alert says why).
    func continueSession(_ sessionKey: SessionKey, main: Bool, agents: [String]) async -> Bool {
        do {
            try await connection.continueSession(sessionKey, main: main, agents: agents)
            return true
        } catch {
            let leaving = !main && agents.isEmpty
            alert = AlertMessage(
                title: leaving ? "Could not leave the interrupted work" : "Could not continue the session",
                message: error.userMessage)
            return false
        }
    }

    /// Restarts the session's omp on the omp installed now; its tab follows omp to the
    /// new PTY. An alert says why ompd refused.
    func restartSession(_ sessionKey: SessionKey) async {
        do {
            try await connection.restartSession(sessionKey)
        } catch {
            alert = AlertMessage(title: "Could not restart the session", message: error.userMessage)
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
    /// says more than the folder), else "New session". A session running in a terminal is titled by that terminal.
    func sessionTitle(_ sessionKey: SessionKey) -> String {
        let entry = entry(for: sessionKey)
        if let title = entry?.title, !title.isEmpty { return title }
        let program =
            if let entry, entry.adopted, let ptyId = entry.ptyId {
                terminals.model(ptyId)?.programTitle
            } else {
                connection.openSessions[sessionKey]?.programTitle
            }
        if let program {
            var title = program.trimmingCharacters(in: .whitespaces)
            if title.hasPrefix("π >") { title = String(title.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            let folder = entry.map { Self.projectName($0.workspace) }
            if !title.isEmpty, title != folder { return title }
        }
        return "New session"
    }

    private func show(_ entry: SessionManifestEntry) {
        connection.open(entry.sessionKey)
        tabs.open(.session(entry.sessionKey), in: entry.workspace)
        saveWindow()
        showProject(entry.workspace)
    }

    /// Brings a running session's tab forward, opening one if needed: the tab of the terminal it runs in when the user
    /// started omp there.
    func showSession(_ sessionKey: SessionKey) {
        guard let entry = entry(for: sessionKey) else { return }
        if entry.adopted, let ptyId = entry.ptyId { showTerminal(ptyId) } else { show(entry) }
    }

    /// The area below the tab strip changed size.
    func tabContentSizeChanged(_ size: CGSize) {
        tabContentArea = (size, currentProject.flatMap(strip(of:)) != nil)
    }

    /// The cells a new terminal or session tab's emulator gets: what fits the area below the tab strip.
    private func newTabSize() -> TerminalSize {
        guard var area = tabContentArea?.size else { return terminals.lastSize ?? .standard }
        // A first tab brings the strip along.
        if tabContentArea?.belowStrip == false { area.height -= Chrome.tabStripHeight }
        return terminals.cells(fitting: TerminalPane.emulatorSize(in: area))
    }

    // MARK: - Terminals

    /// Opens the login shell, or `command`, on a new PTY in `workspace` (default: the workspace on screen, else the home
    /// folder), in a new tab of that workspace's strip.
    func newTerminal(in workspace: String? = nil, command: [String]? = nil) {
        let workspace = Self.normalized(workspace ?? currentProject ?? NSHomeDirectory())
        addProject(workspace)
        let size = newTabSize()
        Task {
            do {
                let ptyId = try await terminals.open(in: workspace, command: command, size: size)
                tabs.open(.terminal(ptyId), in: workspace)
                saveWindow()
                showProject(workspace)
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
        if let workspace = tabs.strips.first(where: { $0.tabs.contains(.terminal(ptyId)) })?.workspace { showProject(workspace) }
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

    // MARK: - Windows

    /// Every project window is a native tab of one tab group (Terminal-style); the tab's title is the project.
    static let windowTabbingIdentifier = "com.omp-ide.project"

    /// Opens (or brings forward) the window of a project; set by the scene, which owns `openWindow`.
    @ObservationIgnored var openProjectWindow: ((String) -> Void)?
    /// Closes the window of a project; set by the scene.
    @ObservationIgnored var closeProjectWindow: ((String) -> Void)?

    /// Called with the window hosting `project`'s scene each time it (re)appears: it joins the tab group and, while
    /// it is key, it is the project in focus.
    func attach(_ window: NSWindow, project: String) {
        guard windowsAttached.insert(ObjectIdentifier(window)).inserted else { return }
        // One window per project: a second one (state restoration plus the default window, say) closes itself.
        if !project.isEmpty, let existing = windowsByProject[project], existing != ObjectIdentifier(window) {
            windowsAttached.remove(ObjectIdentifier(window))
            DispatchQueue.main.async { window.close() }
            return
        }
        windowsByProject[project] = ObjectIdentifier(window)
        window.isRestorable = true
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.windowTabbingIdentifier
        // A window SwiftUI opened on its own joins the group of the others as a tab.
        if (window.tabGroup?.windows.count ?? 1) <= 1,
           let group = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.tabbingIdentifier == Self.windowTabbingIdentifier }) {
            group.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        if window.tabGroup?.isTabBarVisible == false { window.toggleTabBar(nil) }
        if window.isKeyWindow { keyProject = project }
        let center = NotificationCenter.default
        let id = ObjectIdentifier(window)
        let observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyProject = project }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushState() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosing(id, project: project) }
            },
        ]
        windowObservers[id] = observers
        windowsChanged()
    }

    /// The window showing `project`, while one does.
    func window(of project: String) -> NSWindow? {
        guard let id = windowsByProject[project] else { return nil }
        return NSApp.windows.first { ObjectIdentifier($0) == id }
    }

    private func windowClosing(_ id: ObjectIdentifier, project: String) {
        flushState()
        windowsAttached.remove(id)
        if windowsByProject[project] == id { windowsByProject[project] = nil }
        for observer in windowObservers.removeValue(forKey: id) ?? [] { NotificationCenter.default.removeObserver(observer) }
        if keyProject == project { keyProject = nil }
        windowsChanged()
    }

    /// A window closing only to give way to another (the no-project window to the first project's) pauses nothing.
    private static let windowlessDelay: Duration = .milliseconds(500)

    /// ompd pauses every session while no omp IDE window is open and resumes them when one opens.
    private func windowsChanged() {
        windowlessReport?.cancel()
        windowlessReport = nil
        guard windowsAttached.isEmpty else {
            connection.setHasWindow(true)
            return
        }
        windowlessReport = Task { [connection] in
            try? await Task.sleep(for: Self.windowlessDelay)
            guard !Task.isCancelled else { return }
            connection.setHasWindow(false)
        }
    }

    /// Quitting: ompd pauses every session now instead of after it notices the app is gone, and the editors' language
    /// servers shut down. Waits for ompd a moment at most, for the servers a little longer.
    func prepareToQuit() async {
        flushState()
        windowlessReport?.cancel()
        windowlessReport = nil
        connection.setHasWindow(false)
        async let presence: Void = connection.presenceReported(within: .milliseconds(500))
        await editors.languageServers.shutdownAll(within: .seconds(2))
        await presence
    }

    /// Shows `pane` in the sidebar.
    func showPane(_ pane: SidebarPane) {
        self.pane = pane
        sidebarVisible = true
    }

    /// The activity bar's click: the pane shows, or, when it is the one showing, the sidebar hides.
    func togglePane(_ pane: SidebarPane) {
        if sidebarVisible, self.pane == pane { sidebarVisible = false } else { showPane(pane) }
    }

    /// Captures everything not saved on change and writes it all now: on resign key, window close, sleep, power off
    /// and quit.
    func flushState() {
        editors.flush()
        saveWindow()
        persistence.flush()
    }

    /// The layout (window frames are AppKit's to restore, per project window).
    private func saveWindow() {
        persistence.save(
            WindowState(
                id: Self.mainWindowID, sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible,
                projects: addedProjects, tabs: tabs))
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
}

extension SessionManifestEntry {
    /// ompd can resume the session and its session file is still on disk.
    var isResumable: Bool { canResume && !sessionFileIsGone }
    /// ompd could resume the session but its folder is gone: the user can point at where it is now.
    var canLocateFolder: Bool { isResumable && workspaceIsGone }
}

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
    /// What the app does about an ompd that refuses its version.
    let outdatedDaemon: OutdatedDaemon
    /// Crash reports of ompd and Lantern the user has not seen yet (local only).
    let crashNotices = CrashNotices()
    /// The first prompt of each session omp has not titled, which titles it (`sessionTitle`).
    let sessionPrompts = SessionPrompts()
    /// Turns the agents finished while nobody looked at their project.
    let finishedTurns = FinishedTurns()
    /// Open files and the file navigators.
    let editors: Editors
    /// The Files pane's outline of each project, kept while the pane shows something else.
    let filesOutlines = FilesOutlines()
    /// Terminal emulators: `.terminal` tabs on PTYs in ompd, and `.session` tabs showing omp's TUI.
    let terminals: TerminalsController
    /// Whether the key window is a project window, for ⌘W and the tab commands.
    let keyWindow = KeyWindow()
    /// Detail-area tabs, one strip per workspace. The selected tab is what the detail area shows and what the sidebar
    /// highlights.
    private(set) var tabs: TabLayout
    /// The sidebar (the pane next to the activity bar) is shown.
    var sidebarVisible: Bool {
        didSet { if sidebarVisible != oldValue { saveWindow() } }
    }
    /// Width of the sidebar pane, dragged at its trailing edge. Setting it clamps to the allowed range.
    ///
    /// The clamp lives in a setter over separate storage: `@Observable` moves a `didSet` onto the macro's backing
    /// storage, so a `didSet` that assigned the property again would re-enter itself until the stack overflowed.
    var sidebarWidth: Double {
        get { storedSidebarWidth }
        set {
            let width = min(max(newValue, Self.minimumSidebarWidth), Self.maximumSidebarWidth)
            guard width != storedSidebarWidth else { return }
            storedSidebarWidth = width
            saveWindow()
        }
    }
    private var storedSidebarWidth: Double
    static let minimumSidebarWidth = 200.0
    static let maximumSidebarWidth = 520.0
    /// The pane the activity bar shows: Files, Changes or Projects. Kept in the defaults.
    var pane: SidebarPane {
        didSet { if pane != oldValue { UserDefaults.lantern.set(pane.rawValue, forKey: SidebarPane.defaultsKey) } }
    }
    /// The project of the key window.
    private var keyProject: String?
    /// Project folders the user added, in the order added. `projects` (below) also lists folders that have sessions
    /// or tabs.
    private(set) var addedProjects: [String]
    var alert: AlertMessage?
    /// A project whose window closed while its sessions or terminals ran: the other windows say they keep running,
    /// until the user has seen that once.
    var closedProjectNotice: ClosedProject?
    /// The project whose Open Session sheet is up (its window shows it).
    var sessionPickerProject: String?
    /// The file Quick Look shows, and the project whose window shows it (`QuickLook.swift`).
    var quickLookItem: QuickLookItem?
    /// The project folder ompd is renaming (Rename Project…, Locate Folder…), until it answers: the window says so.
    var renaming: FolderMove?
    /// What of omp's data stayed under a renamed project's old path, for the renamed project's window.
    var renameNotice: RenameNotice?

    /// `state.sqlite` and the hot-exit copies; its `writeFailure` is the window's banner while writes fail.
    @ObservationIgnored let persistence: StatePersistence
    /// The numbers the strips' sessions and terminals of the same title carry (`tabTitles(in:)`). Not observed: the
    /// strips number their tabs as they draw them.
    @ObservationIgnored private var tabNumbers: TabNumbers
    @ObservationIgnored private var started = false
    /// Windows `attach(_:project:)` set up, until they close, and their observers.
    @ObservationIgnored private var windowsAttached: Set<ObjectIdentifier> = []
    @ObservationIgnored private var windowObservers: [ObjectIdentifier: [any NSObjectProtocol]] = [:]
    /// Points each attached window's scene at another project (its `project` binding): the window of no project
    /// showing the first project, a project window following its renamed folder.
    @ObservationIgnored private var windowShows: [ObjectIdentifier: @MainActor (String) -> Void] = [:]
    /// Tells ompd the last window closed once `windowlessDelay` passed with none open.
    @ObservationIgnored private var windowlessReport: Task<Void, Never>?
    @ObservationIgnored private var windowsByProject: [String: ObjectIdentifier] = [:]
    /// Size of the area below the tab strip, where a tab's content goes, and whether the strip was showing.
    @ObservationIgnored private var tabContentArea: (size: CGSize, belowStrip: Bool)?
    /// The project windows open at the last quit still to open again, in their tab order, and the one to bring to the
    /// front once they are all up. Each opens once the window before it is up (`reopenNextWindow`).
    @ObservationIgnored private var windowsToReopen: [String] = []
    @ObservationIgnored private var frontToReopen: String?
    /// The project windows as they were when quitting began: windows closing on the way out change nothing saved.
    @ObservationIgnored private var windowsAtQuit: (windows: [String], front: String?)?
    /// Projects the user removed whose window is closing: what ran in them is ending, so no notice says it runs on.
    @ObservationIgnored private var removedProjectWindows: Set<String> = []
    /// Terminals whose program runs again on a new PTY in their tab while the old PTY closes (`restartTerminal`).
    @ObservationIgnored private var restartedTerminals: Set<PTYID> = []

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// A close, or a rename, that waits for the user's confirmation in the window of `project`, with what it ends or
    /// interrupts (`confirm`).
    struct CloseRequest {
        enum Action {
            /// Close these tabs (Close Tab, Close Other Tabs, …), or end the session or terminal (Close Session, Close
            /// Terminal).
            case close([TabKind])
            /// Remove a stopped session from ompd's list.
            case forget(SessionKey)
            /// Remove the project from the list (Remove Project): its tabs close, then its window.
            case removeProject(String, tabs: [TabKind])
            /// Rename the project's folder (Rename Project…): its running sessions stop and resume in the renamed folder,
            /// and `services` (named services that would outlive them under the old path) stop.
            case renameProject(FolderMove, services: [ServiceStop])

            /// The tabs that close.
            var closing: [TabKind] {
                switch self {
                case .close(let tabs), .removeProject(_, let tabs): tabs
                case .forget, .renameProject: []
                }
            }
        }

        /// A session whose omp the close ends.
        struct EndingSession {
            let title: String
            /// The agent is working.
            let working: Bool
            /// Its session file is on disk: Open Session… resumes it afterwards.
            let resumable: Bool
        }

        let action: Action
        /// The window the confirmation shows in.
        let project: String
        var sessions: [EndingSession] = []
        /// What runs in the foreground of the closing terminals besides their programs (`pty.processes`).
        var processes: [String] = []

        var endsSomething: Bool { !sessions.isEmpty || !processes.isEmpty }
    }

    /// See `closedProjectNotice`.
    struct ClosedProject: Equatable {
        let project: String
        let sessions: Int
        let terminals: Int
    }

    /// See `renameNotice`.
    struct RenameNotice: Equatable {
        /// The project as it is named now.
        let project: String
        /// One sentence each, from ompd.
        let notMoved: [String]
    }

    init() {
        persistence = StatePersistence(paths: .standard)
        let restored = persistence.restoredWindow
        editors = Editors(persistence: persistence)
        tabs = restored?.tabs ?? TabLayout()
        tabNumbers = restored?.tabNumbers ?? TabNumbers()
        windowsToReopen = restored?.windows ?? []
        frontToReopen = restored?.frontWindow
        terminals = TerminalsController(registry: connection.terminals)
        outdatedDaemon = OutdatedDaemon(connection: connection, agent: agent)
        sidebarVisible = restored?.sidebarVisible ?? true
        storedSidebarWidth = restored?.sidebarWidth ?? 270
        pane = UserDefaults.lantern.string(forKey: SidebarPane.defaultsKey).flatMap(SidebarPane.init(rawValue:)) ?? .files
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
        installEditorExtensionKeys()
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

    /// Registers the LaunchAgent and connects to ompd. Runs at launch even when no
    /// window opens (the main window may have been closed when the app last quit); the window's `.task` calls it again,
    /// which is a no-op.
    func start() {
        guard !started else { return }
        started = true
        agent.registerIfNeeded()
        outdatedDaemon.start()
        connection.start()
        sessionPrompts.follow(connection)
        crashNotices.start()
        // A rename the launch left to ompd: the app follows the folder once ompd has finished it.
        Task { await settleRenameLeftBehind() }
        if let reason = persistence.unavailableReason {
            alert = AlertMessage(
                title: "The window layout will not be remembered",
                message: "Lantern could not open its state database: \(reason)")
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
        tabs.select(tab)
        saveWindow()
    }

    /// The user dragged `tab` to `index` in its strip.
    func moveTab(_ tab: TabKind, to index: Int) {
        tabs.move(tab, to: index)
        saveWindow()
    }

    /// Closes the tab. A session tab ends its session and a terminal tab its PTY (they are gone, not hidden); an editor
    /// with unsaved edits asks to save them first. Asked first when that ends a running omp or a command running in the
    /// terminal (`closeTabs`).
    func closeTab(_ tab: TabKind) {
        closeTabs([tab])
    }

    /// Closes `closing` (Close Tab, Close Other Tabs, Close Tabs to the Right, Close All Tabs). What ends with them,
    /// running omp sessions and commands running in terminals, is asked about once, for all of them, in their window;
    /// Cancel keeps every tab. Then they close one after another, and an unsaved editor the user keeps stops the rest.
    func closeTabs(_ closing: [TabKind]) {
        Task {
            let request = await closeRequest(for: .close(closing))
            if request.endsSomething { confirm(request) } else { await close(closing) }
        }
    }

    /// Asks about `request` the way Terminal does: an alert sheet on its window whose default button (Return) closes
    /// (or renames), Cancel answering Esc and ⌘. (wording in `ContentView`'s `CloseRequest` extension).
    func confirm(_ request: CloseRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.addButton(withTitle: request.confirmation)
        alert.addButton(withTitle: "Cancel")
        let answered = { [weak self] (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { self?.confirmed(request) }
        }
        if let window = window(of: request.project) ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }

    /// The user confirmed `request`.
    private func confirmed(_ request: CloseRequest) {
        switch request.action {
        case .close(let closing): Task { await close(closing) }
        case .forget(let sessionKey): forgetSession(sessionKey)
        case .removeProject(let project, let closing): Task { await remove(project, closing: closing) }
        case .renameProject(let move, let services): Task { await renameFolder(move, stopping: services) }
        }
    }

    /// What `action` ends: the sessions whose omp runs, what runs in the terminals besides their programs.
    private func closeRequest(for action: CloseRequest.Action) async -> CloseRequest {
        let closing = action.closing
        var request = CloseRequest(action: action, project: confirmationProject(for: closing))
        guard connection.isConnected else { return request }
        for tab in closing {
            switch tab {
            case .session(let sessionKey):
                guard let entry = entry(for: sessionKey), entry.runsOmp else { continue }
                request.sessions.append(CloseRequest.EndingSession(
                    title: sessionTitle(sessionKey), working: entry.status == .busy,
                    resumable: entry.sessionFile != nil && !entry.sessionFileIsGone))
            case .terminal(let ptyId):
                guard terminals.model(ptyId) != nil else { continue }
                // An ompd that cannot tell (an older one) leaves the terminal to close as it did.
                request.processes += (try? await connection.ptyProcesses(ptyId)) ?? []
            case .editor:
                continue
            }
        }
        return request
    }

    /// The window a confirmation about `closing` shows in: the project window of the first of them that has one, else
    /// the key window.
    private func confirmationProject(for closing: [TabKind]) -> String {
        for tab in closing {
            let project = tabs.strips.first { $0.tabs.contains(tab) }?.workspace ?? tab.sessionKey.flatMap { entry(for: $0)?.workspace }
            if let project, windowsByProject[project] != nil { return project }
        }
        return keyProject ?? windowsByProject.keys.first ?? ""
    }

    /// Closes `closing` one after another without asking about what ends with them; false when an unsaved editor the
    /// user keeps stopped the rest.
    @discardableResult
    private func close(_ closing: [TabKind]) async -> Bool {
        for tab in closing {
            switch tab {
            case .session(let sessionKey):
                closeSession(sessionKey)
            case .terminal(let ptyId):
                closeTerminal(ptyId)
            case .editor(let path):
                guard tabs.contains(tab) else { continue }
                guard await closeEditorTab(path) else { return false }
            }
        }
        return true
    }

    /// Closes an editor's tab, asking first about unsaved edits; false when the user kept it.
    @discardableResult
    private func closeEditorTab(_ path: String) async -> Bool {
        guard await editors.closeIfConfirmed(path, window: NSApp.keyWindow) else { return false }
        tabs.close(.editor(path: path))
        saveWindow()
        return true
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

    /// `path` was renamed to `destination`: the editor tabs of it, or of the files under it, follow with their unsaved
    /// edits, selection and scroll position.
    func moveEditors(from path: String, to destination: String) {
        for tab in tabs.tabs {
            guard let open = tab.editorPath, open == path || open.hasPrefix(path + "/") else { continue }
            let moved = destination + open.dropFirst(path.count)
            editors.move(open, to: moved)
            tabs.replace(tab, with: .editor(path: moved))
        }
        saveWindow()
    }

    /// Closes a session's tab without touching the session.
    private func dropSessionTab(_ sessionKey: SessionKey) {
        guard tabs.contains(.session(sessionKey)) else { return }
        tabs.close(.session(sessionKey))
        terminals.releaseSession(sessionKey)
        connection.release(sessionKey)
        saveWindow()
    }

    /// Shows `path` in its editor tab, opening one after the tab on screen in `workspace`'s strip first if needed.
    func openEditor(_ path: String, in workspace: String) {
        editors.open(path, in: workspace).focusOnAppear = true
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
        let mode = UserDefaults.lantern.string(forKey: AppSettings.defaultApprovalModeKey).flatMap(ApprovalMode.init(rawValue:))
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

    /// Brings `workspace`'s window forward (opening it as a tab of the group if needed). The first project opens in
    /// the window of no project, which keeps its place and size.
    func showProject(_ workspace: String) {
        let workspace = Self.normalized(workspace)
        guard projects.contains(workspace) else { return }
        if windowsByProject[workspace] == nil, let blank = window(of: ""), let show = windowShows[ObjectIdentifier(blank)] {
            windowClosing(ObjectIdentifier(blank))
            attach(blank, project: workspace, show: show)
            show(workspace)
            return
        }
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

    /// Takes the project out of the list and closes its window; the folder stays on disk. Its tabs close first, the way
    /// Close All Tabs closes them, asked about once in its window when that ends omp sessions or commands running in its
    /// terminals. Its editors close before the rest: one with unsaved edits the user keeps keeps the project, and what
    /// runs in it.
    func removeProject(_ workspace: String) {
        let open = strip(of: workspace)?.tabs ?? []
        let closing = open.filter { $0.editorPath != nil } + open.filter { $0.editorPath == nil }
        Task {
            let request = await closeRequest(for: .removeProject(workspace, tabs: closing))
            if request.endsSomething { confirm(request) } else { await remove(workspace, closing: closing) }
        }
    }

    private func remove(_ workspace: String, closing: [TabKind]) async {
        guard await close(closing) else { return }
        addedProjects.removeAll { $0 == workspace }
        saveWindow()
        if window(of: workspace) != nil { removedProjectWindows.insert(workspace) }
        closeProjectWindow?(workspace)
    }

    /// The project folder `move.from` is at `move.to` now (Rename Project…, Locate Folder…): every project, tab, editor,
    /// navigator and terminal that names it or a folder inside it names the new place, and `state.sqlite` with them
    /// (durably, before this returns). Its window shows the new folder, the window tab titled by its name.
    func projectMoved(_ move: FolderMove) {
        func moved(_ path: String) -> String { move.moved(path) ?? path }
        var seen = Set<String>()
        addedProjects = addedProjects.map(moved).filter { seen.insert($0).inserted }
        tabs.moveFolder(move)
        persistence.moveFolder(move)
        editors.folderMoved(move)
        filesOutlines.folderMoved(move)
        terminals.folderMoved(move)
        windowsToReopen = windowsToReopen.map(moved)
        frontToReopen = frontToReopen.map(moved)
        removedProjectWindows = Set(removedProjectWindows.map(moved))
        keyProject = keyProject.map(moved)
        sessionPickerProject = sessionPickerProject.map(moved)
        if let closed = closedProjectNotice, let project = move.moved(closed.project) {
            closedProjectNotice = ClosedProject(project: project, sessions: closed.sessions, terminals: closed.terminals)
        }
        if let item = quickLookItem, move.contains(item.project) || move.contains(item.url.path(percentEncoded: false)) {
            quickLookItem = QuickLookItem(url: URL(filePath: moved(item.url.path(percentEncoded: false))), project: moved(item.project))
        }
        for (project, id) in windowsByProject {
            guard let newProject = move.moved(project) else { continue }
            windowsByProject[project] = nil
            // The new folder has a window of its own already (its sessions' folder was gone): this one gives way.
            guard windowsByProject[newProject] == nil else {
                NSApp.windows.first { ObjectIdentifier($0) == id }?.close()
                continue
            }
            windowsByProject[newProject] = id
            windowShows[id]?(newProject)
        }
        saveWindow()
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
        for info in connection.terminals.terminals where !tabs.contains(.terminal(info.ptyId)) && !restartedTerminals.contains(info.ptyId) {
            let workspace = terminals.workspace(of: info, among: knownWorkspaces)
            terminals.adopt(info.ptyId, workspace: workspace)
            tabs.add(.terminal(info.ptyId), in: workspace)
            changed = true
        }
        if changed { saveWindow() }
    }

    /// An existing folder at `path`.
    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
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
    /// What omp keeps under the old path and the folder's other sessions follow it there first, as they follow Rename
    /// Project… (`followFolder`), and so do its tabs and editors. Its tab moves to that folder's project, which joins
    /// the projects if needed.
    func locateFolder(_ sessionKey: SessionKey) {
        guard let folder = WorkspacePicker.choose(prompt: "Resume Here") else { return }
        let size = connection.openSessions[sessionKey]?.size ?? newTabSize()
        Task {
            if let gone = entry(for: sessionKey)?.workspace {
                await followFolder(FolderMove(from: gone, to: Self.normalized(folder.standardizedFileURL.path(percentEncoded: false))), of: sessionKey)
            }
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

    /// Ends the session (Close Session), asking first while its omp runs (`closeTabs`).
    func requestCloseSession(_ sessionKey: SessionKey) {
        closeTabs([.session(sessionKey)])
    }

    /// Ends omp for the session gracefully and drops the session from ompd's list; its tab closes. The conversation
    /// file on disk stays (resumable through `session.open`). A session ompd does not list, or any while ompd is out of
    /// reach, only loses its tab.
    private func closeSession(_ sessionKey: SessionKey) {
        guard connection.isConnected, entry(for: sessionKey) != nil else {
            dropSessionTab(sessionKey)
            return
        }
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
        confirm(CloseRequest(action: .forget(sessionKey), project: confirmationProject(for: [.session(sessionKey)])))
    }

    /// Drops the session from ompd's list; its tab closes. The session file on disk stays.
    private func forgetSession(_ sessionKey: SessionKey) {
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

    /// What the session goes by everywhere (`SessionTitle`): omp's title, else the first prompt typed into it, else
    /// what its TUI titles its window, else "New session". A session running in a terminal is titled by that terminal.
    func sessionTitle(_ sessionKey: SessionKey) -> String {
        let entry = entry(for: sessionKey)
        let windowTitle =
            if let entry, entry.adopted, let ptyId = entry.ptyId {
                terminals.model(ptyId)?.programTitle
            } else {
                connection.openSessions[sessionKey]?.programTitle
            }
        return SessionTitle.resolve(
            title: entry?.title, prompt: sessionPrompts.prompt(forFile: entry?.sessionFile), windowTitle: windowTitle,
            folder: entry.map { Self.projectName($0.workspace) })
    }

    /// What each tab of `strip` is called on it: an editor by its file's name, a session or a terminal by its title,
    /// those of the same title numbered from the second on as Terminal numbers its windows, "zsh" then "zsh 2"
    /// (`TabNumbers`, the older first: sessions and terminals in the order ompd started them).
    func tabTitles(in strip: TabLayout.Strip) -> [TabKind: TabNumbers.Number] {
        var titles: [TabKind: TabNumbers.Number] = [:]
        var numbered: [(tab: TabNumbers.Tab, age: (Int, Int, Int))] = []
        for (index, tab) in strip.tabs.enumerated() {
            switch tab {
            case .editor(let path):
                titles[tab] = TabNumbers.Number(title: (path as NSString).lastPathComponent, number: 1)
            case .session(let key):
                let age = connection.sessions.firstIndex { $0.sessionKey == key } ?? .max
                numbered.append((TabNumbers.Tab(tab: tab, title: sessionTitle(key), isSettled: titleIsSettled(tab)), (0, age, index)))
            case .terminal(let ptyId):
                let title = adoptedSession(on: ptyId).map { sessionTitle($0.sessionKey) } ?? terminalTitle(ptyId, in: strip.workspace)
                let age = connection.terminals.ptys.firstIndex { $0.ptyId == ptyId } ?? .max
                numbered.append((TabNumbers.Tab(tab: tab, title: title, isSettled: titleIsSettled(tab)), (1, age, index)))
            }
        }
        let older = numbered.sorted { $0.age < $1.age }.map(\.tab)
        return titles.merging(tabNumbers.numbered(older, open: Set(tabs.tabs))) { _, numbered in numbered }
    }

    /// Whether what titles `tab` is in: ompd listed its session or terminal, and the file of a session omp has not
    /// titled was looked at for its first prompt. Until then its title is made up ("New session", "Terminal").
    private func titleIsSettled(_ tab: TabKind) -> Bool {
        func settled(_ entry: SessionManifestEntry) -> Bool {
            guard entry.title?.isEmpty ?? true, let file = entry.sessionFile else { return true }
            return sessionPrompts.hasLooked(atFile: file)
        }
        switch tab {
        case .session(let key): return entry(for: key).map(settled) ?? false
        case .terminal(let ptyId):
            if let hosted = adoptedSession(on: ptyId) { return settled(hosted) }
            return connection.terminals.info(ptyId) != nil
        case .editor: return true
        }
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

    /// Ends the PTY and everything on it (Close Terminal), asking first while a command runs in it (`closeTabs`).
    func requestCloseTerminal(_ ptyId: PTYID) {
        closeTabs([.terminal(ptyId)])
    }

    /// Ends the PTY and everything running on it; its tab closes. A terminal ompd does not have, or any while ompd is out
    /// of reach, only loses its tab.
    private func closeTerminal(_ ptyId: PTYID) {
        guard connection.isConnected, terminals.model(ptyId) != nil else {
            tabs.close(.terminal(ptyId))
            terminals.release(ptyId)
            saveWindow()
            return
        }
        Task {
            do {
                try await terminals.close(ptyId)
            } catch {
                alert = AlertMessage(title: "Could not close the terminal", message: error.userMessage)
            }
        }
    }

    /// Runs an exited terminal's program again, on a new PTY in the same tab, which keeps its number.
    func restartTerminal(_ ptyId: PTYID) {
        Task {
            do {
                let restarted = try await terminals.restart(ptyId)
                terminals.release(ptyId)
                // ompd lists the old PTY until it is closed: it gets no tab of its own meanwhile.
                restartedTerminals.insert(ptyId)
                defer { restartedTerminals.remove(ptyId) }
                tabs.replace(.terminal(ptyId), with: .terminal(restarted))
                tabNumbers.replace(.terminal(ptyId), with: .terminal(restarted))
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
    static let windowTabbingIdentifier = "com.magicelklabs.lantern.project"

    /// Opens (or brings forward) the window of a project; set by the scene, which owns `openWindow`.
    @ObservationIgnored var openProjectWindow: ((String) -> Void)?
    /// Closes the window of a project; set by the scene.
    @ObservationIgnored var closeProjectWindow: ((String) -> Void)?

    /// Called with the window hosting `project`'s scene each time it (re)appears: it joins the tab group and, while
    /// it is key, it is the project in focus. `show` points the window's scene at another project (`windowShows`).
    func attach(_ window: NSWindow, project: String, show: @escaping @MainActor (String) -> Void) {
        guard windowsAttached.insert(ObjectIdentifier(window)).inserted else { return }
        // One window per project: another one SwiftUI opens for it (its default window, say) closes itself.
        if !project.isEmpty, let existing = windowsByProject[project], existing != ObjectIdentifier(window) {
            windowsAttached.remove(ObjectIdentifier(window))
            // SwiftUI's frame autosave keeps the frame of its window that moved last: this one's, unless it takes the
            // frame of the project's window.
            if let shown = self.window(of: project) { window.setFrame(shown.frame, display: false) }
            DispatchQueue.main.async { window.close() }
            return
        }
        windowsByProject[project] = ObjectIdentifier(window)
        windowShows[ObjectIdentifier(window)] = show
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.windowTabbingIdentifier
        // The window may have turned key before it became a project window here.
        keyWindow.update()
        NewProjectTab.install(in: window) { [weak self] in self?.addProject() }
        // A window SwiftUI opened on its own joins the group the user is in, as its last tab (Terminal's +).
        if (window.tabGroup?.windows.count ?? 1) <= 1,
           let front = NSApp.orderedWindows.first(where: { $0 !== window && $0.isVisible && KeyWindow.isProject($0) }) {
            (front.tabGroup?.windows.last ?? front).addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        if window.tabGroup?.isTabBarVisible == false { window.toggleTabBar(nil) }
        if window.isKeyWindow { keyProject = project }
        let center = NotificationCenter.default
        let id = ObjectIdentifier(window)
        let observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let shown = self.project(ofWindow: id) else { return }
                    self.keyProject = shown
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushState() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosing(id) }
            },
        ]
        windowObservers[id] = observers
        windowsToReopen.removeAll { $0 == project }
        reopenNextWindow()
        windowsChanged()
    }

    /// The window showing `project`, while one does.
    func window(of project: String) -> NSWindow? {
        guard let id = windowsByProject[project] else { return nil }
        return NSApp.windows.first { ObjectIdentifier($0) == id }
    }

    /// The project the window `id` shows now: a rename changes it under the window (`projectMoved`).
    private func project(ofWindow id: ObjectIdentifier) -> String? {
        windowsByProject.first { $0.value == id }?.key
    }

    private func windowClosing(_ id: ObjectIdentifier) {
        let project = self.project(ofWindow: id) ?? ""
        if removedProjectWindows.remove(project) == nil { noteClosedProject(project) }
        windowsAttached.remove(id)
        windowShows[id] = nil
        if windowsByProject[project] == id { windowsByProject[project] = nil }
        for observer in windowObservers.removeValue(forKey: id) ?? [] { NotificationCenter.default.removeObserver(observer) }
        if keyProject == project { keyProject = nil }
        // Once the window is no longer a project window: the windows saved to reopen leave it out.
        flushState()
        windowsChanged()
    }

    /// The first time a project's window closes while omp runs in its sessions or a terminal of it runs, the other
    /// windows say they keep running (ompd pauses the agents once no window is left; terminals go on).
    private func noteClosedProject(_ project: String) {
        guard !project.isEmpty, !UserDefaults.lantern.bool(forKey: Self.closedProjectNoticeSeenKey) else { return }
        let sessions = connection.sessions.filter { $0.workspace == project && $0.runsOmp && !$0.adopted }.count
        let terminals = (strip(of: project)?.tabs.compactMap(\.ptyId) ?? []).filter { connection.terminals.info($0)?.running == true }.count
        guard sessions + terminals > 0 else { return }
        closedProjectNotice = ClosedProject(project: project, sessions: sessions, terminals: terminals)
    }

    /// `closedProjectNotice` goes away; once the user acted on it (`seen`), it never shows again.
    func dismissClosedProjectNotice(seen: Bool) {
        closedProjectNotice = nil
        if seen { UserDefaults.lantern.set(true, forKey: Self.closedProjectNoticeSeenKey) }
    }

    private static let closedProjectNoticeSeenKey = "closedProjectNoticeSeen"

    /// A window closing only to give way to another (the no-project window to the first project's) pauses nothing.
    private static let windowlessDelay: Duration = .milliseconds(500)

    /// ompd pauses every session while no Lantern window is open and resumes them when one opens.
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
        windowsAtQuit = openWindows()
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

    /// The layout and the project windows open (their frame is SwiftUI's frame autosave, `attach(_:project:)`).
    private func saveWindow() {
        let open = windowsAtQuit ?? openWindows()
        persistence.save(
            WindowState(
                id: Self.mainWindowID, sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible,
                projects: addedProjects, tabs: tabs, tabNumbers: tabNumbers, windows: open.windows, frontWindow: open.front))
    }

    /// The project the scene's first window shows at launch: the first of the windows open at the last quit, else the
    /// first project.
    var launchProject: String? {
        windowsToReopen.first ?? projects.first
    }

    /// The projects whose windows are open, in the order of their window tabs (the frontmost window's group first),
    /// and the one in front.
    private func openWindows() -> (windows: [String], front: String?) {
        let projectOf = Dictionary(windowsByProject.map { ($0.value, $0.key) }) { first, _ in first }
        var seen = Set<ObjectIdentifier>()
        var windows: [String] = []
        for window in NSApp.orderedWindows where KeyWindow.isProject(window) {
            for tab in window.tabGroup?.windows ?? [window] where seen.insert(ObjectIdentifier(tab)).inserted {
                if let project = projectOf[ObjectIdentifier(tab)], !project.isEmpty { windows.append(project) }
            }
        }
        let front = NSApp.orderedWindows.first(where: KeyWindow.isProject).flatMap { projectOf[ObjectIdentifier($0)] }
        return (windows, front.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// At launch: opens the next project window that was open at the last quit, which joins the group as its last tab
    /// (`attach`), once the scene takes it (it ignores opening while it restores); with none left, brings the one that
    /// was in front forward.
    private func reopenNextWindow() {
        guard !windowsToReopen.isEmpty || frontToReopen != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            windowsToReopen.removeAll { $0.isEmpty || windowsByProject[$0] != nil }
            if let next = windowsToReopen.first {
                openProjectWindow?(next)
            } else if let front = frontToReopen {
                frontToReopen = nil
                window(of: front)?.makeKeyAndOrderFront(nil)
            }
        }
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
    /// omp runs for the session, or is being started: closing it ends that omp.
    var runsOmp: Bool { [.starting, .busy, .idle, .resuming, .paused].contains(status) }
    /// ompd could resume the session but its folder is gone: the user can point at where it is now.
    var canLocateFolder: Bool { isResumable && workspaceIsGone }
}

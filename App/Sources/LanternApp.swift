import AppKit
import IDEModel
import SwiftUI

@main
struct LanternApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var app: AppState { delegate.app }

    /// The project windows: one per project path, native tabs of one group; "" is the window of no project. At launch
    /// the first shows the first of the windows open at the last quit, and the others follow (`AppState.launchProject`).
    static let projectWindowID = "project"

    var body: some Scene {
        WindowGroup(id: Self.projectWindowID, for: String.self) { $project in
            ProjectWindow(app: app, project: $project)
        } defaultValue: {
            app.launchProject ?? ""
        }
        .defaultSize(width: 1100, height: 760)
        // The strip and the pane name what is on screen and hold the actions; the titlebar holds the window tabs.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { if let project = app.currentProject { app.newSession(in: project) } else { app.newSession() } }
                    .keyboardShortcut("n")
                    .disabled(!app.connection.isConnected)
                Button("New Terminal") { app.newTerminal() }
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(!app.connection.isConnected)
                Button("Open Session…") { if let project = app.currentProject { app.showSessionPicker(for: project) } }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(app.currentProject == nil)
                Button("Add Project…") { app.addProject() }
                    .keyboardShortcut("o")
                Divider()
                // ⌘W closes the tab on screen in a project window and any other key window itself (Settings, a Compare
                // window), as in Safari and Xcode; a project window without tabs closes too.
                let closesTab = app.keyWindow.kind == .project && app.selectedTab != nil
                Button(closesTab ? "Close Tab" : "Close Window") {
                    // The window key now decides, should the title lag behind it.
                    let window = NSApp.keyWindow
                    if let window, KeyWindow.isProject(window), let tab = app.selectedTab { app.closeTab(tab) } else { window?.performClose(nil) }
                }
                .keyboardShortcut("w")
                .disabled(app.keyWindow.kind == .noWindow)
                if closesTab {
                    Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                }
            }
            CommandGroup(replacing: .sidebar) {
                Button(app.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { app.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Files") { app.showPane(.files) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Agents") { app.showPane(.agents) }
                    .keyboardShortcut("a", modifiers: [.command, .control])
                Button("Projects") { app.showPane(.projects) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            EditorCommands(app: app)
            SessionCommands(app: app)
            TabCommands(app: app)
            SourceControlCommands(app: app)
            UpdateCommands(updates: delegate.updates)
        }

        Settings {
            SettingsView(app: app)
        }
    }
}

/// Owns the app state so quitting can save it first, and what tells the user about approvals waiting while they are
/// elsewhere.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppState()
    /// The Dock badge and the notifications for approvals and questions waiting in the sessions.
    private lazy var attention = AttentionAlerts(app: app)
    /// Sparkle, when this build names a feed.
    let updates = Updates()
    /// Open in Lantern / New omp Session for folders in the Finder.
    private lazy var services = FinderServices(app: app)
    /// The projects' sessions in Spotlight.
    private lazy var spotlight = SpotlightSessions(app: app)
    /// Gives a window's focus back once an alert or sheet is gone.
    private let focusKeeper = FocusKeeper()

    /// `com.magicelklabs.lantern://` links (`SessionLink`) arrive as Apple events, handled here instead of by SwiftUI, which would open
    /// a window of no project for each one. The tab keys are watched before any editor or emulator watches keys.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        app.installTabKeys()
    }

    /// The menu-bar extra's session row: that session's tab comes forward once ompd lists the session (the app may
    /// just have launched; 10 s at most).
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), let sessionKey = SessionLink.sessionKey(in: url)
        else { return }
        Task {
            await app.waitUntilConnected()
            let deadline = ContinuousClock.now + .seconds(10)
            while app.entry(for: sessionKey) == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            app.showSession(sessionKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        app.start()
        attention.start()
        spotlight.start()
    }

    /// A session chosen in Spotlight.
    func application(
        _ application: NSApplication, continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        spotlight.continue(userActivity)
    }

    /// ompd hears that no window is left (so it pauses every session) before the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await app.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.flushState()
    }
}

/// Hands the `NSWindow` hosting the view to `onAttach` whenever the view moves into a window.
struct WindowAccessor: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { AttachingView(onAttach: onAttach) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AttachingView: NSView {
        let onAttach: @MainActor (NSWindow) -> Void

        init(onAttach: @escaping @MainActor (NSWindow) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach(window) }
        }
    }
}

/// The + of a project window's tab bar and of its tab overview (View › Show All Tabs) adds a project, whose window joins
/// the group as a new tab. AppKit sends `newWindowForTab(_:)` up the window's responder chain, where SwiftUI's window
/// controller comes right after the window and would open another window of the scene for its default value: the first
/// project's, which closes itself again as a duplicate (`AppState.attach`) after its tab took that project's terminal
/// views off screen. This responder sits between the window and the controller and answers instead.
@MainActor
final class NewProjectTab: NSResponder {
    private let addProject: () -> Void
    /// Keeps each window's responder as long as the window: a window does not retain its next responder.
    private nonisolated(unsafe) static var association: UInt8 = 0

    private init(addProject: @escaping () -> Void) {
        self.addProject = addProject
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Puts the responder after `window` in its responder chain, once.
    static func install(in window: NSWindow, addProject: @escaping () -> Void) {
        guard !(window.nextResponder is NewProjectTab) else { return }
        let responder = NewProjectTab(addProject: addProject)
        responder.nextResponder = window.nextResponder
        window.nextResponder = responder
        objc_setAssociatedObject(window, &association, responder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    override func newWindowForTab(_ sender: Any?) {
        addProject()
    }
}

/// Gives a window's focus back to the view that had it when the window resigned key, when the window is key again and
/// nothing has it: after an alert or a sheet, typing goes on in the terminal or editor it went to before (and its caret
/// is not left hollow).
@MainActor
final class FocusKeeper {
    /// The view each window's focus was last in when the window resigned key.
    private let focused = NSMapTable<NSWindow, NSView>.weakToWeakObjects()
    private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.remember(window) }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.restoreSoon(window) }
            },
        ]
    }

    /// Once AppKit and SwiftUI have settled the window's first responder.
    private func restoreSoon(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.restore(window) }
        }
    }

    private func remember(_ window: NSWindow) {
        // Nothing focused (an alert took the focus first, say): the view remembered before stays.
        guard var view = window.firstResponder as? NSView, view !== window.contentView else { return }
        // A text field types through the window's field editor; the field is what gets the focus back.
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { view = field }
        focused.setObject(view, forKey: window)
    }

    private func restore(_ window: NSWindow) {
        guard window.isKeyWindow, let view = focused.object(forKey: window), view.window === window,
              !view.isHiddenOrHasHiddenAncestor
        else { return }
        // Only when the focus fell back to the window, or to a view around the one that had it.
        let responder = window.firstResponder
        guard responder == nil || responder === window || (responder as? NSView).map(view.isDescendant(of:)) == true else { return }
        window.makeFirstResponder(view)
    }
}

enum AppSettings {
    /// `ApprovalMode.rawValue`; empty or absent = use the omp configuration.
    static let defaultApprovalModeKey = "defaultApprovalMode"
}

@MainActor
enum WorkspacePicker {
    /// Asks for a project folder; `prompt` names the default button.
    static func choose(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.message = "Choose the project folder omp will work in."
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

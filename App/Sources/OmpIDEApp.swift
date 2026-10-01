import AppKit
import IDEModel
import SwiftUI

@main
struct OmpIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var app: AppState { delegate.app }

    /// The project windows: one per project path, native tabs of one group; "" is the window of no project.
    static let projectWindowID = "project"

    var body: some Scene {
        WindowGroup(id: Self.projectWindowID, for: String.self) { $project in
            ProjectWindow(app: app, project: project)
        } defaultValue: {
            app.projects.first ?? ""
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
                Button("Close Tab") { if let tab = app.selectedTab { app.closeTab(tab) } }
                    .keyboardShortcut("w")
                    .disabled(app.selectedTab == nil)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
        attention.start()
    }

    /// The + at the end of the window tab bar: a new project tab.
    @objc func newWindowForTab(_ sender: Any?) {
        app.addProject()
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

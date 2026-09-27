import AppKit
import IDEModel
import SwiftUI

@main
struct OmpIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var app: AppState { delegate.app }

    var body: some Scene {
        Window("omp IDE", id: AppState.mainWindowID) {
            ContentView(app: app)
                .background(WindowAccessor { app.attach($0) })
                .task { app.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // The user may have just allowed the agent in System Settings › Login Items.
                    app.agent.refresh()
                }
        }
        .defaultSize(width: 1100, height: 760)
        // The tab strip and the sidebar name what is on screen and hold the actions; the toolbar only toggles Files.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { if let project = app.currentProject { app.newSession(in: project) } else { app.newSession() } }
                    .keyboardShortcut("n")
                    .disabled(!app.connection.isConnected)
                Button("New Terminal") { app.newTerminal() }
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(!app.connection.isConnected)
                Button("Add Project…") { app.addProject() }
                    .keyboardShortcut("o")
                Divider()
                Button("Close Tab") { if let tab = app.tabs.selection { app.closeTab(tab) } }
                    .keyboardShortcut("w")
                    .disabled(app.tabs.selection == nil)
            }
            CommandGroup(replacing: .sidebar) {
                Button(app.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { app.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Files") { app.showPane(.files) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Projects") { app.showPane(.projects) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            EditorCommands(app: app)
            SessionCommands(app: app)
            SourceControlCommands(app: app)
        }

        Settings {
            SettingsView()
        }
    }
}

/// Owns the app state so quitting can save it first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        app.flushState()
        return .terminateNow
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

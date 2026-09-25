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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { app.newSession() }
                    .keyboardShortcut("n")
                    .disabled(!app.connection.isConnected)
                Button("New Terminal") { app.newTerminal() }
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(!app.connection.isConnected)
            }
            EditorCommands(app: app)
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
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "New Session"
        panel.message = "Choose the workspace folder omp will work in."
        panel.prompt = "Start Session"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

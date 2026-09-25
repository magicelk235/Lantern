import AppKit
import IDEModel
import SwiftUI

@main
struct OmpIDEApp: App {
    @State private var app = AppState()

    var body: some Scene {
        Window("omp IDE", id: "main") {
            ContentView(app: app)
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
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// App-wide state: the daemon link, the agent registration and what the window shows.
@MainActor @Observable
final class AppState {
    let connection = DaemonConnection(
        clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    let agent = DaemonAgent()
    /// The session shown in the detail pane; always opened (subscribed) before it is selected.
    private(set) var selection: SessionKey?
    var alert: AlertMessage?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    func start() {
        agent.registerIfNeeded()
        connection.start()
    }

    func select(_ sessionKey: SessionKey?) {
        if let sessionKey { connection.open(sessionKey) }
        selection = sessionKey
    }

    /// Picks a workspace folder and asks ompd to start omp there with the default approval mode.
    func newSession() {
        guard let folder = WorkspacePicker.choose() else { return }
        let mode = UserDefaults.standard.string(forKey: AppSettings.defaultApprovalModeKey).flatMap(ApprovalMode.init(rawValue:))
        Task {
            do {
                let entry = try await connection.createSession(workspace: folder, approvalMode: mode)
                select(entry.sessionKey)
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

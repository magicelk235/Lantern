import IDEModel
import Observation
import ServiceManagement

/// Registers ompd, bundled at `Contents/MacOS/ompd` and described by
/// `Contents/Library/LaunchAgents/com.omp-ide.ompd.plist`, as the user's LaunchAgent: launchd keeps it
/// running across app quits, crashes and logins.
@MainActor @Observable
final class DaemonAgent {
    enum State: Equatable {
        case unknown
        /// `OMPD_HOME` is set: a developer runs `ompd run` by hand, so nothing is registered.
        case external(home: String)
        case enabled
        /// Registered, but macOS waits for the user to allow it in System Settings › General › Login Items.
        case requiresApproval
        case notRegistered
        /// The bundle has no such launch agent plist.
        case notFound
        case failed(String)
    }

    private(set) var state: State = .unknown
    private let service = SMAppService.agent(plistName: "com.omp-ide.ompd.plist")

    func registerIfNeeded() {
        if let home = ProcessInfo.processInfo.environment[AppSupportPaths.homeEnvironmentKey], !home.isEmpty {
            state = .external(home: home)
            return
        }
        switch service.status {
        case .enabled, .requiresApproval:
            break
        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch {
                refresh()
                // Registration throws when approval is pending; that state speaks for itself.
                if state != .requiresApproval { state = .failed(error.localizedDescription) }
                return
            }
        @unknown default:
            break
        }
        refresh()
    }

    func refresh() {
        if case .external = state { return }
        switch service.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notRegistered: state = .notRegistered
        case .notFound: state = .notFound
        @unknown default: state = .unknown
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

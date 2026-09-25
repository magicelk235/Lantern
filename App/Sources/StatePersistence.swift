import IDEModel
import IDEState
import os

let appLog = Logger(subsystem: "com.omp-ide.app", category: "state")

/// The app's side of `state.sqlite`: what the previous run left, the latest UI of every session, and
/// debounced saving. Without a usable database the app still works for this run, it just does not remember it.
@MainActor
final class StatePersistence {
    /// Why nothing is saved this run; nil when `state.sqlite` works.
    let unavailableReason: String?
    /// The window's layout when the app last ran.
    let restoredWindow: WindowState?
    /// The latest UI of each session that has one (restored at launch, then kept current).
    private(set) var sessions: [SessionKey: SessionUIState]

    private let store: StateStore?

    init(paths: AppSupportPaths) {
        var store: StateStore?
        var window: WindowState?
        var sessions: [SessionKey: SessionUIState] = [:]
        var reason: String?
        do {
            let opened = try StateStore(paths: paths)
            if let recovery = opened.recovery {
                appLog.error(
                    "state.sqlite was unusable (\(recovery.reason, privacy: .public)); moved to \(recovery.movedAside.path(percentEncoded: false), privacy: .public); \(recovery.restoredBuffers.count) unsaved buffers restored from hot-exit copies"
                )
            }
            window = try opened.window(id: AppState.mainWindowID)
            sessions = try opened.sessionUIStates()
            store = opened
        } catch {
            reason = String(describing: error)
            appLog.error("state.sqlite unavailable, the layout will not be remembered: \(String(describing: error), privacy: .public)")
        }
        self.store = store
        restoredWindow = window
        self.sessions = sessions
        unavailableReason = reason
    }

    func save(_ window: WindowState) {
        store?.setWindow(window)
    }

    /// Applies `change` to the UI of `sessionKey`; a real change is saved (debounced).
    func updateSession(_ sessionKey: SessionKey, _ change: (inout SessionUIState) -> Void) {
        var state = sessions[sessionKey] ?? SessionUIState(sessionKey: sessionKey)
        change(&state)
        guard state != sessions[sessionKey] else { return }
        sessions[sessionKey] = state
        store?.setSessionUI(state)
    }

    /// Writes everything pending now.
    func flush() {
        do {
            try store?.flush()
        } catch {
            appLog.error("saving the window state failed: \(String(describing: error), privacy: .public)")
        }
    }
}

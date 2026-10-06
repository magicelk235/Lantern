import AppKit
import IDEModel
import UserNotifications

/// What waits for the user in the session TUIs (tool approvals, `ask`) outside the window: the Dock badge
/// counts it, and each new one posts a notification while Lantern is in the background, titled by its session
/// (permission is asked for with the first). A click on one brings the app forward on that session's tab; it is
/// withdrawn once its approval or question is answered or its omp stopped, also when an earlier run of the app posted
/// it.
@MainActor
final class AttentionAlerts: NSObject, UNUserNotificationCenterDelegate {
    private let app: AppState
    /// What waited at the last look, by notification identifier, with its session.
    private var waiting: [String: SessionKey] = [:]
    /// Notifications posted and not withdrawn, by identifier, with their session.
    private var posted: [String: SessionKey] = [:]

    /// `userInfo` key of the session a notification is about.
    private nonisolated static let sessionKeyInfo = "sessionKey"

    init(app: AppState) {
        self.app = app
    }

    /// Starts following the sessions. Runs while the app finishes launching: a click on a notification may be what
    /// launched it.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let sessionKeyInfo = Self.sessionKeyInfo
        center.getDeliveredNotifications { @Sendable [weak self] notifications in
            let earlier = notifications.compactMap { notification -> (String, SessionKey)? in
                let request = notification.request
                return (request.content.userInfo[sessionKeyInfo] as? String).map { (request.identifier, $0) }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                posted.merge(earlier) { current, _ in current }
                update(app.connection.runtimes)
            }
        }
        observe()
    }

    private func observe() {
        let runtimes = withObservationTracking {
            app.connection.runtimes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        update(runtimes)
    }

    private func update(_ runtimes: [SessionKey: SessionRuntime]) {
        let count = app.connection.attentionCount
        let badge = count > 0 ? String(count) : nil
        // Runtimes change with every step the agents take; the Dock hears only of a new count.
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        // Out of touch with ompd nothing is known to be answered: what is posted stays until it can be checked again.
        guard app.connection.isConnected else { return }
        var current: [String: SessionKey] = [:]
        var items: [(SessionKey, AttentionItem)] = []
        for runtime in runtimes.values {
            for item in runtime.attention {
                current[Self.identifier(item, in: runtime.sessionKey)] = runtime.sessionKey
                items.append((runtime.sessionKey, item))
            }
        }
        // Right after connecting, ompd has not said yet what waits in the sessions whose omp runs.
        func unknown(_ sessionKey: SessionKey) -> Bool {
            guard runtimes[sessionKey] == nil, let status = app.entry(for: sessionKey)?.status else { return false }
            return status == .busy || status == .idle || status == .paused
        }
        let answered = posted.filter { current[$0.key] == nil && !unknown($0.value) }.map(\.key)
        if !answered.isEmpty {
            for identifier in answered { posted[identifier] = nil }
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: answered)
            center.removePendingNotificationRequests(withIdentifiers: answered)
        }
        if !NSApp.isActive {
            for (sessionKey, item) in items {
                let identifier = Self.identifier(item, in: sessionKey)
                if waiting[identifier] == nil, posted[identifier] == nil { post(item, in: sessionKey, as: identifier) }
            }
        }
        waiting = current.merging(waiting.filter { unknown($0.value) }) { new, _ in new }
    }

    private func post(_ item: AttentionItem, in sessionKey: SessionKey, as identifier: String) {
        posted[identifier] = sessionKey
        let title = app.sessionTitle(sessionKey)
        let body =
            switch item.kind {
            case .approval: "Waiting for your approval: \(item.toolName)"
            case .ask: "omp is asking you something"
            }
        let userInfo = [Self.sessionKeyInfo: sessionKey]
        // Asks for permission the first time; afterwards it answers at once with the user's choice.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Answered while permission was asked for, or notifications are off.
                guard granted, posted[identifier] != nil else {
                    posted[identifier] = nil
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.threadIdentifier = sessionKey
                content.userInfo = userInfo
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private static func identifier(_ item: AttentionItem, in sessionKey: SessionKey) -> String {
        "\(sessionKey)/\(item.id)"
    }

    /// A click on a notification: the app comes forward on the session's tab.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionKey = response.notification.request.content.userInfo[Self.sessionKeyInfo] as? String
        Task { @MainActor in
            NSApp.activate()
            if let sessionKey { app.showSession(sessionKey) }
        }
        completionHandler()
    }
}

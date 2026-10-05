import AppKit
import IDEModel
import Observation
import ServiceManagement

/// Registers the menu-bar extra, bundled at `Contents/Library/LoginItems/omp IDE Menu Bar.app`, as a login
/// item while Show in Menu Bar is on (Settings › General; the extra's own Hide from Menu Bar turns it off): launchd
/// starts it at once and at every login, and it keeps running while omp IDE is closed. Turned off, it is unregistered,
/// which ends it. One that is registered but not running (it was killed), or that started before its executable was
/// replaced (omp IDE was updated or rebuilt since), is registered again, which starts the bundle's.
///
/// Never with `OMPD_HOME` set (`external`): that ompd is a developer's, who starts the extra by hand for it, and the
/// registered one is left alone.
@MainActor @Observable
final class MenuBarAgent {
    enum State: Equatable {
        case unknown
        /// `OMPD_HOME` is set: nothing is registered or unregistered.
        case external(home: String)
        case shown
        case hidden
        /// Registered, but macOS waits for the user to allow it in System Settings › General › Login Items.
        case requiresApproval
        case failed(String)
    }

    private(set) var state: State = .unknown
    @ObservationIgnored private let service = SMAppService.loginItem(identifier: MenuBarHelper.bundleIdentifier)
    /// The latest `sync()`; each waits for the one before, so the registration ends up as the latest setting says.
    @ObservationIgnored private var syncing: Task<Void, Never>?

    /// The setting: on unless the user turned it off.
    static var isShown: Bool {
        UserDefaults.standard.object(forKey: MenuBarHelper.shownKey) as? Bool ?? true
    }

    /// Brings the registration in line with the setting: at launch and whenever the setting changes.
    func sync() {
        if let home = ProcessInfo.processInfo.environment[AppSupportPaths.homeEnvironmentKey], !home.isEmpty {
            state = .external(home: home)
            return
        }
        let previous = syncing
        syncing = Task {
            await previous?.value
            await apply(shown: Self.isShown)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func apply(shown: Bool) async {
        guard shown else {
            if service.status == .enabled || service.status == .requiresApproval {
                do {
                    try await service.unregister()
                } catch {
                    state = .failed(error.localizedDescription)
                    return
                }
            }
            state = .hidden
            return
        }
        switch service.status {
        case .enabled:
            guard needsRestart else {
                state = .shown
                return
            }
            // Unregistering ends the running one; registering again starts the bundle's.
            try? await service.unregister()
            register()
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered, .notFound:
            register()
        @unknown default:
            register()
        }
    }

    private func register() {
        do {
            try service.register()
            state = .shown
        } catch {
            // Registration throws when approval is pending; that state speaks for itself.
            state = service.status == .requiresApproval ? .requiresApproval : .failed(error.localizedDescription)
        }
    }

    /// No extra runs from this bundle, or the one running started before its executable was written. The inode change
    /// time tells: a rebuild or an update writes a new file, whose modification date may be the build's.
    private var needsRestart: Bool {
        let bundled = Self.path(Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/omp IDE Menu Bar.app"))
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarHelper.bundleIdentifier)
            .filter { $0.bundleURL.map(Self.path) == bundled }
        guard !running.isEmpty else { return true }
        return running.contains { helper in
            guard let launched = helper.launchDate,
                  let written = try? helper.executableURL?.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate
            else { return false }
            return written > launched
        }
    }

    /// The real path of `url`, without a trailing slash.
    private static func path(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

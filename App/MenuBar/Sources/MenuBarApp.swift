import AppKit
import IDEModel

/// omp IDE Menu Bar, the menu-bar extra: an app without windows or Dock icon (`LSUIElement`) inside
/// Lantern (`Contents/Library/LoginItems`), which omp IDE registers as a login item while its Show in Menu Bar setting is
/// on. It shows what the agents do from login on, with omp IDE open or not. Launched while the setting is off (a login
/// after Hide from Menu Bar, before omp IDE ran again to unregister it), it ends at once, before it shows anything.
@main
@MainActor
enum MenuBarApp {
    static func main() {
        guard MenuBarSetting.isShown else { return }
        let app = NSApplication.shared
        let delegate = MenuBarAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenu()
    }
}

/// omp IDE's Show in Menu Bar setting (Settings › General), kept in omp IDE's defaults.
enum MenuBarSetting {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: MenuBarHelper.appBundleIdentifier) }

    static var isShown: Bool { defaults?.object(forKey: MenuBarHelper.shownKey) as? Bool ?? true }

    /// Hide from Menu Bar: off until the user turns it on again in omp IDE, which then unregisters the login item.
    static func hide() {
        defaults?.set(false, forKey: MenuBarHelper.shownKey)
    }
}

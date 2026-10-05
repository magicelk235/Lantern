import AppKit
import IDEModel
import os

private let menuLog = Logger(subsystem: "com.omp-ide.menubar", category: "menu")

/// The menu-bar extra's status item and its menu. omp's terminal glyph and,
/// while agents work, how many (`MenuBarStatus.runningAgents`); a dot on the glyph while an approval or a question
/// waits; dimmed while ompd is out of reach. The menu lists the sessions that are not closed by project, each with its
/// status, then Open omp IDE and Hide from Menu Bar.
///
/// It follows ompd as a `cli` client (`DaemonConnection`): it never keeps the sessions running or resumes them.
/// Nothing polls: the item and the menu change when ompd pushes a change that alters what they show, and the
/// connection retries with its backoff only while ompd is out of reach.
@MainActor
final class StatusMenu: NSObject {
    private let connection = DaemonConnection(clientVersion: StatusMenu.version, clientKind: .cli)
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    /// What the item and the menu show.
    private var shown: Shown?

    /// Everything they show, compared to skip runtime pushes that change nothing here (activity lines, jobs).
    private struct Shown: Equatable {
        var link: Link
        var status: MenuBarStatus
    }

    private enum Link: Equatable {
        case connecting
        case connected
        /// The reason, ompd's or the connection's.
        case unreachable(String)
        case outdated(String)

        init(_ status: DaemonConnection.Status) {
            switch status {
            case .connecting: self = .connecting
            case .connected: self = .connected
            case .daemonUnavailable(let reason): self = .unreachable(reason)
            case .versionMismatch(let message): self = .outdated(message)
            }
        }
    }

    override init() {
        super.init()
        item.autosaveName = "omp IDE"
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        connection.start()
        observe()
    }

    private func observe() {
        let current = withObservationTracking {
            Shown(link: Link(connection.status), status: MenuBarStatus(sessions: connection.sessions, runtimes: connection.runtimes))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        guard current != shown else { return }
        shown = current
        showItem(current)
        // An open menu changes in place.
        showMenu(current)
    }

    // MARK: - Status item

    private func showItem(_ shown: Shown) {
        guard let button = item.button else { return }
        let connected = shown.link == .connected
        let status = shown.status
        button.image = connected && status.waitingCount > 0 ? StatusGlyph.badged : StatusGlyph.plain
        button.title = connected && status.runningAgents > 0 ? "\(status.runningAgents)" : ""
        button.appearsDisabled = !connected
        let summary = Self.summary(shown)
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    /// One line for the tooltip and VoiceOver.
    private static func summary(_ shown: Shown) -> String {
        switch shown.link {
        case .connecting: return "omp IDE: connecting to ompd"
        case .unreachable(let reason): return "omp IDE: \(reason)"
        case .outdated: return "omp IDE: ompd is out of date. Open omp IDE to update it."
        case .connected:
            let status = shown.status
            var summary = "omp IDE: \(working(status.runningAgents).lowercased())"
            if status.waitingCount > 0 { summary += ", \(waiting(status.waitingCount).lowercased())" }
            return summary
        }
    }

    private static func working(_ count: Int) -> String {
        switch count {
        case 0: "No Agents Working"
        case 1: "1 Agent Working"
        default: "\(count) Agents Working"
        }
    }

    private static func waiting(_ count: Int) -> String {
        count == 1 ? "1 Waiting for You" : "\(count) Waiting for You"
    }

    // MARK: - Menu

    private func showMenu(_ shown: Shown) {
        menu.removeAllItems()
        for line in Self.headline(shown) {
            let header = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        if shown.link == .connected, !shown.status.projects.isEmpty {
            for project in shown.status.projects {
                menu.addItem(.separator())
                let header = NSMenuItem.sectionHeader(title: project.name)
                header.toolTip = project.path
                menu.addItem(header)
                for session in project.sessions { menu.addItem(sessionItem(session)) }
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Open omp IDE", #selector(openApp(_:))))
        let hide = actionItem("Hide from Menu Bar", #selector(hide(_:)))
        hide.toolTip = "Show it again in omp IDE › Settings › General."
        menu.addItem(hide)
    }

    /// The menu's first lines: how many agents work and what waits, or why nothing is known.
    private static func headline(_ shown: Shown) -> [String] {
        switch shown.link {
        case .connecting: ["Connecting to ompd…"]
        case .unreachable: ["ompd Is Not Running"]
        case .outdated: ["ompd Is Out of Date"]
        case .connected:
            [working(shown.status.runningAgents)] + (shown.status.waitingCount > 0 ? [waiting(shown.status.waitingCount)] : [])
        }
    }

    /// A session: its status as a dot, its title, and its status word trailing (what it waits for, when it does). A
    /// click opens omp IDE on its tab (`SessionLink`).
    private func sessionItem(_ session: MenuBarStatus.Session) -> NSMenuItem {
        let row = actionItem(session.title, #selector(openApp(_:)))
        row.representedObject = session.sessionKey
        row.image = StatusDot.image(for: session)
        // macOS 27 hides menu item images unless asked; this one is the session's status, not decoration.
        if #available(macOS 27.0, *) { row.preferredImageVisibility = .visible }
        row.badge = NSMenuItemBadge(string: session.waiting?.waitingLine ?? session.status.label)
        row.toolTip = session.waiting?.waitingLine ?? session.status.explanation
        return row
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    /// Launches omp IDE, or brings it forward (a window opens if none is: the sessions resume); a session
    /// row's click also hands it the session to show.
    @objc private func openApp(_ sender: NSMenuItem) {
        guard let app = Self.appURL else {
            menuLog.error("omp IDE not found")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let environment = Self.forwardedEnvironment
        if !environment.isEmpty { configuration.environment = environment }
        let report: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            if let error { menuLog.error("opening omp IDE failed: \(String(describing: error), privacy: .public)") }
        }
        if let sessionKey = sender.representedObject as? SessionKey, let link = SessionLink.url(for: sessionKey) {
            NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration, completionHandler: report)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: report)
        }
    }

    /// Off in omp IDE's settings, and the extra ends: it stays away, also at the next login, until the user turns it on
    /// again in Settings › General.
    @objc private func hide(_ sender: NSMenuItem) {
        MenuBarSetting.hide()
        NSApp.terminate(nil)
    }

    /// The omp IDE this helper is part of (`<app>/Contents/Library/LoginItems/<helper>`), else the one Launch Services
    /// knows.
    private static var appURL: URL? {
        let containing = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if Bundle(url: containing)?.bundleIdentifier == MenuBarHelper.appBundleIdentifier { return containing }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: MenuBarHelper.appBundleIdentifier)
    }

    /// A helper started for another ompd (`OMPD_HOME`, by hand: omp IDE never registers one then) opens omp IDE for that
    /// ompd too: `OMPD_HOME`, the omp storage it pins (`PI_CODING_AGENT_DIR`) and omp IDE's own overrides (`OMP_IDE_*`).
    /// Nothing otherwise: omp IDE gets the user's environment.
    private static var forwardedEnvironment: [String: String] {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment[AppSupportPaths.homeEnvironmentKey], !home.isEmpty else { return [:] }
        return environment.filter { key, _ in
            key == AppSupportPaths.homeEnvironmentKey || key == "PI_CODING_AGENT_DIR" || key.hasPrefix("OMP_IDE_")
        }
    }

    /// "0.1.0 (1)", the way omp IDE reports its own version.
    private static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return "menu bar \(short)\(build.map { " (\($0))" } ?? "")"
    }()
}

/// The status item's glyph, a template image the menu bar tints: omp's terminal (`terminal`), with a dot cut into its
/// top trailing corner while an approval or a question waits (a badge, as on the Dock icon).
@MainActor
private enum StatusGlyph {
    static let plain = make(badged: false)
    static let badged = make(badged: true)

    private static func make(badged: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: "omp IDE")?
            .withSymbolConfiguration(configuration)
        else { return NSImage() }
        guard badged else {
            symbol.isTemplate = true
            return symbol
        }
        let dot: CGFloat = 6
        let gap: CGFloat = 1.5
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            let badge = NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badge).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "omp IDE"
        return image
    }
}

/// A session's status as the dot before its title: red while it waits on the
/// user or needs attention, green idle, yellow paused, orange interrupted, a dotted ring while omp works, starts or
/// resumes (where omp IDE shows a spinner).
@MainActor
private enum StatusDot {
    static func image(for session: MenuBarStatus.Session) -> NSImage? {
        if session.waiting != nil { return dot(.systemRed) }
        switch session.status {
        case .idle: return dot(.systemGreen)
        case .paused: return dot(.systemYellow)
        case .interrupted: return dot(.systemOrange)
        case .needsAttention: return dot(.systemRed)
        case .busy, .starting, .resuming: return dot(.labelColor, symbol: "circle.dotted", weight: .bold)
        case .closed: return dot(.secondaryLabelColor, symbol: "circle")
        }
    }

    private static func dot(_ color: NSColor, symbol: String = "circle.fill", weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

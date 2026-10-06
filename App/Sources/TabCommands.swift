import AppKit
import IDEState
import SwiftUI

/// What kind of window is key: ⌘W closes a tab, and the tab commands act, only while a project window is. Read again
/// whenever the key window may have changed (a window turned key or stopped being key, a sheet ended, the app turned
/// active or inactive, a menu opens), and once more after AppKit settled it: in the middle of a change (a sheet handing
/// the key back to its window, the app coming back) `NSApp.keyWindow` can still name the window that is going.
@MainActor @Observable
final class KeyWindow {
    enum Kind {
        /// The app is not active, or has no window.
        case noWindow
        /// One of the projects' windows (`AppState.attach`).
        case project
        /// Settings, a sheet, a panel, any other window.
        case other
    }

    private(set) var kind: Kind = .noWindow
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let changes = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didEndSheetNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSMenu.didBeginTrackingNotification,
        ]
        observers = changes.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
                }
            }
        }
    }

    /// Whether `window` is a project window: a native tab of the projects' group.
    static func isProject(_ window: NSWindow) -> Bool {
        window.tabbingIdentifier == AppState.windowTabbingIdentifier
    }

    /// Reads the key window again; also when a window becomes a project window, which can happen after it turned key.
    func update() {
        let kind: Kind = NSApp.keyWindow.map { Self.isProject($0) ? .project : .other } ?? .noWindow
        if kind != self.kind { self.kind = kind }
    }
}

/// View › Bigger, Smaller and Actual Size.
enum Zoom {
    case bigger, smaller, actualSize
}

/// The text size zooming a tab changes: an editor's changes every editor's; a terminal's or session's, every
/// emulator's (the setting in Settings › Terminal).
struct TextSize {
    let key: String
    let standard: Double
    let range: ClosedRange<Double>
    /// The size now.
    let size: Double

    /// `terminalSize` and `editorSize`: the settings' values, as the caller read them.
    init(of tab: TabKind, terminalSize: Double = TerminalSettings.fontSize, editorSize: Double = EditorSettings.fontSize) {
        if tab.editorPath != nil {
            key = EditorSettings.fontSizeKey
            standard = EditorSettings.defaultFontSize
            range = EditorSettings.fontSizes
            size = min(max(editorSize, range.lowerBound), range.upperBound)
        } else {
            key = TerminalSettings.fontSizeKey
            standard = TerminalSettings.defaultFontSize
            range = TerminalSettings.fontSizes
            size = min(max(terminalSize, range.lowerBound), range.upperBound)
        }
    }

    func allows(_ zoom: Zoom) -> Bool {
        switch zoom {
        case .bigger: size < range.upperBound
        case .smaller: size > range.lowerBound
        case .actualSize: size != standard
        }
    }

    /// One point per step, as Terminal does; Actual Size goes back to the default.
    func apply(_ zoom: Zoom) {
        switch zoom {
        case .bigger: UserDefaults.standard.set(min(size + 1, range.upperBound), forKey: key)
        case .smaller: UserDefaults.standard.set(max(size - 1, range.lowerBound), forKey: key)
        case .actualSize: UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

extension AppState {
    /// The tabs of the project in focus.
    private var tabsInFocus: [TabKind] {
        currentProject.flatMap(strip(of:))?.tabs ?? []
    }

    /// Select Next Tab (⌃Tab, ⇧⌘]) and Select Previous Tab (⌃⇧Tab, ⇧⌘[): the tab `offset` places from the one on
    /// screen, wrapping around.
    func selectTab(offset: Int) {
        let tabs = tabsInFocus
        guard !tabs.isEmpty else { return }
        let index = selectedTab.flatMap(tabs.firstIndex(of:)) ?? 0
        showFocused(tabs[((index + offset) % tabs.count + tabs.count) % tabs.count])
    }

    /// Select Tab › Tab 1…8 (⌘1…⌘8): the tab at `index`, if there is one.
    func selectTab(at index: Int) {
        let tabs = tabsInFocus
        guard tabs.indices.contains(index) else { return }
        showFocused(tabs[index])
    }

    /// Select Tab › Last Tab (⌘9).
    func selectLastTab() {
        guard let tab = tabsInFocus.last else { return }
        showFocused(tab)
    }

    /// Shows `tab` with the keyboard's focus in it: typing goes on there, as after a click in it.
    private func showFocused(_ tab: TabKind) {
        guard tab != selectedTab else { return }
        if let path = tab.editorPath { editors.document(for: path)?.focusOnAppear = true }
        selectTab(tab)
    }

    /// Edit › Clear to Start (⌘K), for the terminal or session on screen.
    func clearToStart() {
        guard let tab = selectedTab else { return }
        terminals.shownEmulator(for: tab)?.clearToStart()
    }

    /// View › Bigger, Smaller and Actual Size, for the tab on screen.
    func zoom(_ zoom: Zoom) {
        guard let tab = selectedTab else { return }
        TextSize(of: tab).apply(zoom)
    }

    /// ⌃Tab, ⌃⇧Tab, ⇧⌘], ⇧⌘[ and ⌘1…⌘9 switch the key project window's tabs wherever its focus is, ⌥⌘→ and ⌥⌘← its
    /// project tabs (Window › Show Next Tab, Show Previous Tab), and ⌘= is Bigger as ⌘+ is. Installed at launch and kept
    /// ahead of the emulators' and editors' handling of keys (`LocalEventMonitors`): SwiftTerm sends ⌃Tab to the program
    /// and CodeEditSourceEditor indents with it. ⌘1…⌘9 are the Select Tab menu's too, but a menu item only answers its
    /// key while SwiftUI has it enabled, which follows the key window a moment late: a key it missed went to the
    /// responder, and SwiftTerm swallows any ⌘ key it does not know.
    func installTabKeys() {
        LocalEventMonitors.add(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.tabKey(event)
        }
        ProjectTabMenuKeys.install()
    }

    /// The event, or nil when it was taken.
    private func tabKey(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window.isKeyWindow, KeyWindow.isProject(window) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // kVK_RightArrow, kVK_LeftArrow: the project tabs, when there is another one to go to.
        if modifiers == [.command, .option], event.keyCode == 124 || event.keyCode == 123 {
            guard (window.tabbedWindows?.count ?? 0) > 1 else { return event }
            if event.keyCode == 124 { window.selectNextTab(nil) } else { window.selectPreviousTab(nil) }
            return nil
        }
        guard selectedTab != nil else { return event }
        // kVK_Tab; with Shift its characters are a back tab.
        let isTab = event.keyCode == 48
        let key = event.charactersIgnoringModifiers
        let number = key.flatMap { Int($0) }.flatMap { (1...9).contains($0) ? $0 : nil }
        switch modifiers {
        case [.control] where isTab, [.command, .shift] where key == "]" || key == "}":
            selectTab(offset: 1)
        case [.control, .shift] where isTab, [.command, .shift] where key == "[" || key == "{":
            selectTab(offset: -1)
        case [.command] where key == "=":
            zoom(.bigger)
        case [.command] where number != nil:
            // ⌘9 is the last tab; a number past the tabs is left alone, as the menu leaves it.
            let tabs = tabsInFocus
            guard let number, number == 9 ? !tabs.isEmpty : number <= tabs.count else { return event }
            if number == 9 { selectLastTab() } else { selectTab(at: number - 1) }
        default:
            return event
        }
        return nil
    }
}

/// Edit › Clear to Start; View › Bigger, Smaller, Actual Size, Select Next Tab, Select Previous Tab and Select Tab ›
/// Tab 1…8, Last Tab. All act on the key project window's tab on screen (`AppState.installTabKeys` takes their keys
/// first where a terminal or editor would).
struct TabCommands: Commands {
    let app: AppState
    @AppStorage(TerminalSettings.fontSizeKey) private var terminalFontSize = TerminalSettings.defaultFontSize
    @AppStorage(EditorSettings.fontSizeKey) private var editorFontSize = EditorSettings.defaultFontSize

    /// The tabs of the key window, when it is a project window.
    private var tabs: [TabKind] {
        guard app.keyWindow.kind == .project, let project = app.currentProject else { return [] }
        return app.strip(of: project)?.tabs ?? []
    }

    /// The tab on screen in the key window, when it is a project window.
    private var tab: TabKind? {
        app.keyWindow.kind == .project ? app.selectedTab : nil
    }

    private var textSize: TextSize? {
        tab.map { TextSize(of: $0, terminalSize: terminalFontSize, editorSize: editorFontSize) }
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Clear to Start") { app.clearToStart() }
                .keyboardShortcut("k")
                .disabled(tab == nil || tab?.editorPath != nil)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            zoomButton("Bigger", .bigger)
                .keyboardShortcut("+")
            zoomButton("Smaller", .smaller)
                .keyboardShortcut("-")
            zoomButton("Actual Size", .actualSize)
                .keyboardShortcut("0")
            Divider()
            Button("Select Next Tab") { app.selectTab(offset: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(tabs.isEmpty)
            Button("Select Previous Tab") { app.selectTab(offset: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(tabs.isEmpty)
            Menu("Select Tab") {
                ForEach(1...8, id: \.self) { number in
                    Button("Tab \(number)") { app.selectTab(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))))
                        .disabled(tabs.count < number)
                }
                Button("Last Tab") { app.selectLastTab() }
                    .keyboardShortcut("9")
                    .disabled(tabs.isEmpty)
            }
        }
    }

    private func zoomButton(_ title: String, _ zoom: Zoom) -> some View {
        Button(title) { app.zoom(zoom) }
            .disabled(!(textSize?.allows(zoom) ?? false))
    }
}

/// Window › Show Previous Tab and Show Next Tab, the items AppKit adds for the project tabs, show ⌥⌘← and ⌥⌘→: ⌃Tab and
/// ⇧⌘] belong to the tab strip. AppKit adds the items as tabbed windows come and go; each gets its keys as it is
/// added. The keys themselves are taken first (`AppState.tabKey`), where an emulator or editor would swallow them.
@MainActor
private enum ProjectTabMenuKeys {
    static func install() {
        // Installed once at launch, for the app's life: the observer is never removed.
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { notification in
            // Delivered on the main queue, as the menu itself lives there.
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            let index = notification.userInfo?["NSMenuItemIndex"] as? Int
            MainActor.assumeIsolated {
                guard let menu, let index, menu.items.indices.contains(index) else { return }
                label(menu.items[index])
            }
        }
    }

    private static func label(_ item: NSMenuItem) {
        let key: Int? =
            switch item.action {
            case #selector(NSWindow.selectNextTab(_:)): NSRightArrowFunctionKey
            case #selector(NSWindow.selectPreviousTab(_:)): NSLeftArrowFunctionKey
            default: nil
            }
        guard let key, let scalar = UnicodeScalar(key) else { return }
        item.keyEquivalent = String(Character(scalar))
        item.keyEquivalentModifierMask = [.command, .option]
    }
}

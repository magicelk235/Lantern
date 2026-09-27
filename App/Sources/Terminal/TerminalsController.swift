import AppKit
import IDEModel
import Observation
import SwiftTerm

enum TerminalSettings {
    /// Point size of terminal text (SF Mono).
    static let fontSizeKey = "terminalFontSize"
    static let defaultFontSize = 12.0
    static let fontSizes = 9.0 ... 24.0
    /// Option sends Meta (Esc + key) in omp session tabs, where omp binds Alt chords (Alt+P, Alt+M, Alt+Shift+P, …).
    static let sessionOptionAsMetaKey = "sessionOptionAsMeta"
    /// Option sends Meta in terminal tabs; off, Option types the characters of the keyboard layout.
    static let terminalOptionAsMetaKey = "terminalOptionAsMeta"

    static var fontSize: Double {
        let size = UserDefaults.standard.double(forKey: fontSizeKey)
        return size == 0 ? defaultFontSize : min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
    }

    static var sessionOptionAsMeta: Bool { UserDefaults.standard.object(forKey: sessionOptionAsMetaKey) as? Bool ?? true }
    static var terminalOptionAsMeta: Bool { UserDefaults.standard.object(forKey: terminalOptionAsMetaKey) as? Bool ?? true }

    static func font(size: Double) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// The app's terminal emulators: terminal tabs on PTYs in ompd, which it opens, restarts and closes, and
/// session tabs showing omp's TUI. Keeps an emulator per tab once it was shown, and knows which workspace each terminal
/// belongs to.
@MainActor @Observable
final class TerminalsController {
    let registry: TerminalRegistry
    /// Workspace of each PTY opened or shown in a tab during this run; a tab-less PTY from an earlier run is placed by
    /// the folder it is in.
    private var workspaces: [PTYID: String] = [:]
    /// Emulators of the terminal tabs shown so far, until their tab closes.
    @ObservationIgnored private var emulators: [PTYID: TerminalTab] = [:]
    /// Emulators of the session tabs shown so far, until their tab closes.
    @ObservationIgnored private var sessionEmulators: [SessionKey: TerminalTab] = [:]
    /// Size of the emulator that changed size last.
    @ObservationIgnored private(set) var lastSize: TerminalSize?
    @ObservationIgnored private var fontSize = TerminalSettings.fontSize
    @ObservationIgnored private var sessionOptionAsMeta = TerminalSettings.sessionOptionAsMeta
    @ObservationIgnored private var terminalOptionAsMeta = TerminalSettings.terminalOptionAsMeta
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    init(registry: TerminalRegistry) {
        self.registry = registry
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    // MARK: - Terminal tabs

    /// A terminal tab is (or will be) open in `workspace`. Its model exists from now on, so a PTY that is gone from ompd
    /// is noticed and its tab closed even before it is shown.
    func adopt(_ ptyId: PTYID, workspace: String) {
        workspaces[ptyId] = workspace
        _ = registry.model(for: ptyId)
    }

    func model(_ ptyId: PTYID) -> TerminalSessionModel? {
        registry.models[ptyId]
    }

    /// The emulator of `ptyId`'s tab, made the first time the tab is shown; it attaches the PTY.
    func emulator(for ptyId: PTYID) -> TerminalTab {
        if let emulator = emulators[ptyId] { return emulator }
        let emulator = makeEmulator(registry.model(for: ptyId), optionAsMeta: terminalOptionAsMeta)
        emulators[ptyId] = emulator
        return emulator
    }

    /// The tab closed: ompd stops streaming the PTY to the app. The PTY keeps running.
    func release(_ ptyId: PTYID) {
        if let emulator = emulators.removeValue(forKey: ptyId) {
            emulator.close()
        } else {
            registry.models[ptyId]?.detach()
        }
    }

    /// ompd no longer has the PTY.
    func forget(_ ptyId: PTYID) {
        emulators[ptyId] = nil
        workspaces[ptyId] = nil
    }

    // MARK: - Session tabs

    /// The emulator of `session`'s tab, made the first time the tab is shown; it attaches omp's TUI.
    func emulator(for session: SessionTerminal) -> TerminalTab {
        if let emulator = sessionEmulators[session.sessionKey] { return emulator }
        let emulator = makeEmulator(session, optionAsMeta: sessionOptionAsMeta)
        sessionEmulators[session.sessionKey] = emulator
        return emulator
    }

    /// The session's tab closed: its emulator goes. omp keeps running.
    func releaseSession(_ sessionKey: SessionKey) {
        sessionEmulators.removeValue(forKey: sessionKey)?.close()
    }

    // MARK: - Commands

    /// Starts the login shell on a new PTY in `workspace`, `size` big.
    func open(in workspace: String, size: TerminalSize) async throws -> PTYID {
        let model = try await registry.open(cwd: workspace, size: size)
        workspaces[model.ptyId] = workspace
        return model.ptyId
    }

    /// Starts the exited program of `ptyId` again on a new PTY, in the folder it was last in (its workspace if that is
    /// gone), at the size the tab has. Returns the new PTY; the old one is left to the caller.
    func restart(_ ptyId: PTYID) async throws -> PTYID {
        let info = registry.models[ptyId]?.info ?? registry.info(ptyId)
        let workspace = workspaces[ptyId] ?? info?.cwd ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        let cwd = info.map(\.cwd).flatMap { cwd in
            FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue ? cwd : nil
        } ?? workspace
        let size = emulators[ptyId]?.size ?? info?.size ?? lastSize ?? .standard
        let model = try await registry.open(cwd: cwd, command: info?.command, size: size)
        workspaces[model.ptyId] = workspace
        return model.ptyId
    }

    /// Ends the PTY: its programs get SIGHUP and ompd forgets it; `TerminalRegistry.onGone` follows.
    func close(_ ptyId: PTYID) async throws {
        try await registry.close(ptyId)
    }

    /// The cells an emulator `size` points big has in the current font: what a new tab's PTY should start with, so
    /// the program's first screen already fits.
    func cells(fitting size: CGSize) -> TerminalSize {
        guard size.width > 0, size.height > 0 else { return lastSize ?? .standard }
        let probe = OmpTerminalView(frame: .zero, font: TerminalSettings.font(size: fontSize), options: TerminalOptions(scrollback: 0))
        probe.setFrameSize(size)
        let terminal = probe.getTerminal()
        return TerminalSize(cols: terminal.cols, rows: terminal.rows)
    }

    // MARK: - Titles and sidebar

    /// The title the program set, else the terminal's folder and program.
    func title(for ptyId: PTYID) -> String {
        let model = registry.models[ptyId]
        if let title = model?.programTitle, !title.isEmpty { return title }
        return (model?.info ?? registry.info(ptyId))?.displayTitle ?? "Terminal"
    }

    /// The workspace a PTY belongs to: the one it was opened or shown in during this run, else the deepest of
    /// `workspaces` its folder is in, else its folder.
    func workspace(of info: PTYInfo, among workspaces: [String]) -> String {
        if let workspace = self.workspaces[info.ptyId] { return workspace }
        let containing = workspaces.filter { info.cwd == $0 || info.cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        return containing.max { $0.count < $1.count } ?? info.cwd
    }

    private func makeEmulator(_ endpoint: any TerminalEndpoint, optionAsMeta: Bool) -> TerminalTab {
        TerminalTab(endpoint: endpoint, font: TerminalSettings.font(size: fontSize), optionAsMeta: optionAsMeta) {
            [weak self] size in self?.lastSize = size
        }
    }

    private func applySettings() {
        let size = TerminalSettings.fontSize
        if size != fontSize {
            fontSize = size
            let font = TerminalSettings.font(size: size)
            for emulator in emulators.values { emulator.setFont(font) }
            for emulator in sessionEmulators.values { emulator.setFont(font) }
        }
        let sessionMeta = TerminalSettings.sessionOptionAsMeta
        if sessionMeta != sessionOptionAsMeta {
            sessionOptionAsMeta = sessionMeta
            for emulator in sessionEmulators.values { emulator.setOptionAsMeta(sessionMeta) }
        }
        let terminalMeta = TerminalSettings.terminalOptionAsMeta
        if terminalMeta != terminalOptionAsMeta {
            terminalOptionAsMeta = terminalMeta
            for emulator in emulators.values { emulator.setOptionAsMeta(terminalMeta) }
        }
    }
}

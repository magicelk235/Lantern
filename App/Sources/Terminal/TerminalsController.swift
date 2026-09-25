import AppKit
import IDEModel
import Observation

enum TerminalSettings {
    /// Point size of terminal text (SF Mono).
    static let fontSizeKey = "terminalFontSize"
    static let defaultFontSize = 12.0
    static let fontSizes = 9.0 ... 24.0

    static var fontSize: Double {
        let size = UserDefaults.standard.double(forKey: fontSizeKey)
        return size == 0 ? defaultFontSize : min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
    }

    static func font(size: Double) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// The app's terminals: opens, restarts and closes PTYs in ompd, keeps an emulator per terminal tab once it
/// was shown, and knows which workspace each PTY belongs to.
@MainActor @Observable
final class TerminalsController {
    let registry: TerminalRegistry
    /// Workspace of each PTY opened or shown in a tab during this run; a tab-less PTY from an earlier run is placed by
    /// the folder it is in.
    private var workspaces: [PTYID: String] = [:]
    /// Emulators of the terminal tabs shown so far, until their tab closes.
    @ObservationIgnored private var emulators: [PTYID: TerminalTab] = [:]
    /// Size of the terminal shown last: new PTYs start with it, so the shell's first prompt already fits.
    @ObservationIgnored private var lastSize: TerminalSize?
    @ObservationIgnored private var fontSize = TerminalSettings.fontSize
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    init(registry: TerminalRegistry) {
        self.registry = registry
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFontSize() }
        }
    }

    // MARK: - Tabs

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
        let emulator = TerminalTab(model: registry.model(for: ptyId), font: TerminalSettings.font(size: fontSize)) {
            [weak self] size in self?.lastSize = size
        }
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

    // MARK: - Commands

    /// Starts the login shell on a new PTY in `workspace`.
    func open(in workspace: String) async throws -> PTYID {
        let model = try await registry.open(cwd: workspace, size: lastSize ?? .standard)
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

    /// ompd's PTYs by the workspace they belong to, each in creation order.
    func byWorkspace(among workspaces: [String]) -> [String: [PTYInfo]] {
        Dictionary(grouping: registry.ptys) { workspace(of: $0, among: workspaces) }
    }

    private func applyFontSize() {
        let size = TerminalSettings.fontSize
        guard size != fontSize else { return }
        fontSize = size
        let font = TerminalSettings.font(size: size)
        for emulator in emulators.values { emulator.setFont(font) }
    }
}

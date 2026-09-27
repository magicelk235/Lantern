import Foundation
import IDEProtocol
import Observation

/// One omp session as its tab shows it: omp's own TUI, on the PTY in ompd that runs it now (`entry.ptyId`).
///
/// omp moves to a new PTY whenever it is started again — after a crash, a daemon restart, or Resume — and the manifest
/// then names the new one. The session follows: it stops the old PTY's stream, and the display starts over from the new
/// PTY's screen at the display's size. While omp does not run for the session (no PTY) the display keeps what it showed.
/// An adopted session's PTY is a terminal's (`entry.adopted`): the terminal's tab shows it, so the session shows nothing
/// of its own until omp runs for it in a session PTY again.
///
/// It is its PTY models' display, relaying to the display of the tab.
@MainActor @Observable
public final class SessionTerminal: Identifiable {
    public nonisolated let sessionKey: SessionKey
    public nonisolated var id: SessionKey { sessionKey }

    /// The session's manifest entry; nil while ompd does not list it (not connected yet, or no such session).
    public private(set) var entry: SessionManifestEntry?
    /// The PTY omp's TUI runs on now; nil while omp does not run for the session.
    public private(set) var terminal: TerminalSessionModel?
    /// The display shows a screen of this session: the current PTY's, or the last one before omp stopped.
    public private(set) var hasScreen = false
    /// Title omp's TUI set (OSC 0/2), as the display's emulator reports it.
    public var programTitle: String?

    @ObservationIgnored private let registry: TerminalRegistry
    @ObservationIgnored private weak var display: (any TerminalDisplay)?
    /// The display's size, for every PTY the session moves to.
    @ObservationIgnored public private(set) var size: TerminalSize?

    init(sessionKey: SessionKey, registry: TerminalRegistry) {
        self.sessionKey = sessionKey
        self.registry = registry
    }

    /// omp's TUI is on screen, streaming and taking input.
    public var isLive: Bool {
        guard let terminal else { return false }
        return terminal.isAttached && !terminal.hasExited
    }

    // MARK: - Driven by DaemonConnection

    func update(entry: SessionManifestEntry?) {
        if entry != self.entry { self.entry = entry }
        follow(entry?.adopted == true ? nil : entry?.ptyId)
    }

    /// The tab closed: ompd stops streaming here and the PTY's model goes. omp keeps running.
    func release() {
        detach()
        follow(nil)
    }

    private func follow(_ ptyId: PTYID?) {
        guard ptyId != terminal?.ptyId else { return }
        if let old = terminal {
            old.detach()
            registry.releaseSessionModel(old.ptyId)
        }
        guard let ptyId else {
            terminal = nil
            return
        }
        let model = registry.sessionModel(for: ptyId)
        terminal = model
        if let size { model.resize(size) }
        if display != nil { model.attach(to: self) }
    }
}

extension SessionTerminal: TerminalEndpoint {
    /// Shows the session on `display`: the current PTY's screen now (or once omp runs), and every later PTY's.
    public func attach(to display: any TerminalDisplay) {
        let replacing = self.display.map { $0 !== display } ?? false
        self.display = display
        // A new display starts empty, and takes a fresh screen.
        if replacing { hasScreen = false }
        guard let terminal else { return }
        if replacing { terminal.detach() }
        terminal.attach(to: self)
    }

    public func detach() {
        display = nil
        hasScreen = false
        terminal?.detach()
    }

    /// Input for omp's TUI; dropped while omp does not run.
    public func send(_ bytes: Data) {
        terminal?.send(bytes)
    }

    public func resize(_ size: TerminalSize) {
        self.size = size.clamped
        terminal?.resize(size)
    }
}

extension SessionTerminal: TerminalDisplay {
    public func reset(size: TerminalSize, screen: Data) {
        hasScreen = true
        display?.reset(size: size, screen: screen)
    }

    public func feed(_ data: Data) {
        display?.feed(data)
    }
}

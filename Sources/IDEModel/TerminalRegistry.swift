import Foundation
import IDEProtocol
import IDETransport
import Observation

/// ompd's PTYs as the app sees them: every PTY — plain terminals and the TUIs of omp sessions — and a model
/// per PTY the app shows.
///
/// The list comes from one `pty.list` per connection, then from the `ptys` frames ompd pushes whenever it changes (a PTY
/// opened, exited, closed or resized); that is how an exited program or a shell's `cd` shows up. A PTY with a model that
/// a list no longer shows is gone: the model reports it through `onGone` (its terminal tab should go). A PTY this client
/// knows to exist first-hand — it opened it, or the manifest names it as a session's TUI — stays until a list has shown
/// it once, since a list can be older than the PTY.
@MainActor @Observable
public final class TerminalRegistry {
    /// Every PTY in ompd, in creation order.
    public private(set) var ptys: [PTYInfo] = []
    /// Models of the PTYs the app shows or showed, by PTY. A model stays until its PTY is gone, or a session no longer
    /// runs on it, so attaching and detaching one PTY always go through the same model, in order.
    @ObservationIgnored public private(set) var models: [PTYID: TerminalSessionModel] = [:]

    /// Called when ompd turns out not to have a PTY that has a model: closed, or lost with a daemon restart.
    @ObservationIgnored public var onGone: (@MainActor (PTYID) -> Void)?
    /// How long a terminal's size must hold before ompd gets it.
    @ObservationIgnored public var resizeDebounce: Duration = .milliseconds(120)

    @ObservationIgnored weak var backend: (any TerminalBackend)?
    @ObservationIgnored private var connected = false
    /// Bumped by every connect and disconnect: the list asked for on an earlier connection is not applied.
    @ObservationIgnored private var connectionEpoch = 0
    /// `ptys` pushes received on this connection. The `pty.list` answer is dropped when a push arrived while it was on
    /// its way: that push is at least as new, and every later change brings another one.
    @ObservationIgnored private var pushes = 0
    /// PTYs known to exist (opened here, or a session's TUI per the manifest) that no list has shown yet.
    @ObservationIgnored private var unlisted: Set<PTYID> = []
    /// PTYs closed here that a list older than the close would still show.
    @ObservationIgnored private var closed: Set<PTYID> = []

    init() {}

    /// The plain terminals: PTYs that do not run an omp session's TUI.
    public var terminals: [PTYInfo] { ptys.filter { $0.sessionKey == nil } }

    /// The PTY's latest description, if ompd listed it.
    public func info(_ ptyId: PTYID) -> PTYInfo? {
        ptys.first { $0.ptyId == ptyId }
    }

    /// The model for `ptyId`, made the first time. It attaches once a display asks (`attach(to:)`).
    public func model(for ptyId: PTYID) -> TerminalSessionModel {
        if let model = models[ptyId] { return model }
        let model = TerminalSessionModel(
            ptyId: ptyId, info: info(ptyId), backend: backend, connected: connected, resizeDebounce: resizeDebounce,
            onGone: { [weak self] ptyId in self?.gone(ptyId) })
        models[ptyId] = model
        return model
    }

    /// Starts `command` (nil: the user's login shell) on a new PTY in `cwd`.
    public func open(cwd: String, command: [String]? = nil, size: TerminalSize) async throws -> TerminalSessionModel {
        guard let backend else { throw IDETransportError.notConnected }
        let size = size.clamped
        let info = try await backend.openPTY(PTYOpen.Params(cwd: cwd, command: command, cols: size.cols, rows: size.rows))
        if !ptys.contains(where: { $0.ptyId == info.ptyId }) {
            unlisted.insert(info.ptyId)
            ptys.append(info)
        }
        let model = model(for: info.ptyId)
        model.update(info)
        return model
    }

    /// Ends the PTY: its processes get SIGHUP and ompd forgets it. Its model reports it gone.
    public func close(_ ptyId: PTYID) async throws {
        guard let backend else { throw IDETransportError.notConnected }
        do {
            try await backend.closePTY(ptyId)
        } catch let error as DaemonError where error.code == .noSuchPTY {
            // Already gone.
        }
        closed.insert(ptyId)
        unlisted.remove(ptyId)
        ptys.removeAll { $0.ptyId == ptyId }
        models[ptyId]?.markGone()
    }

    // MARK: - Session TUIs (SessionTerminal)

    /// The model of the PTY the manifest names as a session's TUI: it exists, even if no list has shown it yet.
    func sessionModel(for ptyId: PTYID) -> TerminalSessionModel {
        if models[ptyId] == nil, info(ptyId) == nil { unlisted.insert(ptyId) }
        return model(for: ptyId)
    }

    /// The session no longer shows the PTY (omp runs on another one now, or the tab closed): its model goes, without
    /// `onGone`, and a later list decides nothing about it.
    func releaseSessionModel(_ ptyId: PTYID) {
        models[ptyId] = nil
        unlisted.remove(ptyId)
    }

    // MARK: - Driven by DaemonConnection

    func connectionOpened() {
        connected = true
        connectionEpoch += 1
        pushes = 0
        for model in models.values { model.connectionOpened() }
        Task { await listOnce() }
    }

    func connectionClosed() {
        connected = false
        connectionEpoch += 1
        for model in models.values { model.connectionClosed() }
    }

    func receive(_ output: PTYOutput) {
        models[output.ptyId]?.receive(output.data)
    }

    /// A `ptys` push: ompd's whole PTY list after a change.
    func receive(_ list: PTYList.Result) {
        pushes += 1
        apply(list.ptys)
    }

    // MARK: - Listing

    /// The list at connect time; pushes keep it current from then on.
    private func listOnce() async {
        guard connected, let backend else { return }
        let epoch = connectionEpoch
        let pushesBefore = pushes
        guard let listed = try? await backend.listPTYs(), epoch == connectionEpoch, pushes == pushesBefore else { return }
        apply(listed)
    }

    private func apply(_ listed: [PTYInfo]) {
        let byID = Dictionary(listed.map { ($0.ptyId, $0) }, uniquingKeysWith: { first, _ in first })
        unlisted.subtract(byID.keys)
        closed.formIntersection(byID.keys)
        let current = listed.filter { !closed.contains($0.ptyId) } + ptys.filter { unlisted.contains($0.ptyId) }
        if current != ptys { ptys = current }
        for (ptyId, model) in models {
            if let info = byID[ptyId] {
                model.update(info)
            } else if !unlisted.contains(ptyId) {
                model.markGone()
            }
        }
    }

    private func gone(_ ptyId: PTYID) {
        models[ptyId] = nil
        unlisted.remove(ptyId)
        ptys.removeAll { $0.ptyId == ptyId }
        onGone?(ptyId)
    }
}

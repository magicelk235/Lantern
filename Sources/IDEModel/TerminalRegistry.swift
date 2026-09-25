import Foundation
import IDEProtocol
import IDETransport
import Observation

/// ompd's PTYs as the app sees them: the list of every PTY, and a model per terminal the app shows.
///
/// ompd pushes no PTY events, so the list is refreshed with `pty.list` on every connect, after a PTY is opened or closed
/// here, and every `refreshInterval` while connected; that is how an exited program or a shell's `cd` shows up. A PTY
/// the app has a model for that ompd no longer has is reported through `onGone` (its tab should go).
@MainActor @Observable
public final class TerminalRegistry {
    /// Every PTY in ompd, in creation order.
    public private(set) var ptys: [PTYInfo] = []
    /// Models of the terminals the app shows or showed, by PTY. A model stays until its PTY is gone, so attaching and
    /// detaching one PTY always go through the same model, in order.
    @ObservationIgnored public private(set) var models: [PTYID: TerminalSessionModel] = [:]

    /// Called when ompd turns out not to have a PTY that has a model: closed, or lost with a daemon restart.
    @ObservationIgnored public var onGone: (@MainActor (PTYID) -> Void)?
    /// How often `ptys` is refreshed while connected.
    @ObservationIgnored public var refreshInterval: Duration = .seconds(2)
    /// How long a terminal's size must hold before ompd gets it.
    @ObservationIgnored public var resizeDebounce: Duration = .milliseconds(120)

    @ObservationIgnored weak var backend: (any TerminalBackend)?
    @ObservationIgnored private var connected = false
    /// Bumped by every connect and disconnect: a list requested on an earlier connection is not applied.
    @ObservationIgnored private var connectionEpoch = 0
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var isListing = false
    @ObservationIgnored private var listAgain = false
    /// `pty.list` requests sent so far.
    @ObservationIgnored private var listsSent = 0
    /// PTYs opened here, with `listsSent` when the open returned: only a list requested later proves one gone.
    @ObservationIgnored private var openedAfterList: [PTYID: Int] = [:]
    /// PTYs closed here; a list requested before the close took effect would still show them.
    @ObservationIgnored private var closed: Set<PTYID> = []

    init() {}

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
        openedAfterList[info.ptyId] = listsSent
        if !ptys.contains(where: { $0.ptyId == info.ptyId }) { ptys.append(info) }
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
        ptys.removeAll { $0.ptyId == ptyId }
        if let model = models[ptyId] { model.markGone() } else { openedAfterList[ptyId] = nil }
    }

    /// Lists the PTYs now, or right after the list in flight.
    public func refresh() {
        guard connected else { return }
        if isListing {
            listAgain = true
            return
        }
        isListing = true
        Task { await list() }
    }

    // MARK: - Driven by DaemonConnection

    func connectionOpened() {
        connected = true
        connectionEpoch += 1
        for model in models.values { model.connectionOpened() }
        let interval = refreshInterval
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func connectionClosed() {
        connected = false
        connectionEpoch += 1
        poller?.cancel()
        poller = nil
        for model in models.values { model.connectionClosed() }
    }

    func receive(_ output: PTYOutput) {
        models[output.ptyId]?.receive(output.data)
    }

    // MARK: - Listing

    /// One `pty.list` at a time, so an older list is never applied over a newer one.
    private func list() async {
        repeat {
            listAgain = false
            guard connected, let backend else { break }
            listsSent += 1
            let serial = listsSent
            let epoch = connectionEpoch
            if let ptys = try? await backend.listPTYs(), epoch == connectionEpoch {
                apply(ptys, serial: serial)
            }
        } while listAgain
        isListing = false
    }

    private func apply(_ listed: [PTYInfo], serial: Int) {
        let listedIDs = Set(listed.map(\.ptyId))
        // A PTY opened here after this list was requested is too new for it.
        let newer = ptys.filter { !listedIDs.contains($0.ptyId) && (openedAfterList[$0.ptyId] ?? -1) >= serial }
        let current = listed.filter { !closed.contains($0.ptyId) } + newer
        if current != ptys { ptys = current }
        for (ptyId, model) in models {
            if let info = listed.first(where: { $0.ptyId == ptyId }) {
                model.update(info)
            } else if (openedAfterList[ptyId] ?? -1) < serial {
                model.markGone()
            }
        }
        for ptyId in listedIDs where (openedAfterList[ptyId] ?? .max) < serial { openedAfterList[ptyId] = nil }
        closed.formIntersection(listedIDs)
    }

    private func gone(_ ptyId: PTYID) {
        models[ptyId] = nil
        openedAfterList[ptyId] = nil
        ptys.removeAll { $0.ptyId == ptyId }
        onGone?(ptyId)
    }
}

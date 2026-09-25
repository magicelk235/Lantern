import Foundation
import IDEProtocol
import IDETransport
import Observation

/// Where a `TerminalSessionModel` puts what its PTY prints: the app's terminal emulator.
@MainActor
public protocol TerminalDisplay: AnyObject {
    /// Drops everything shown and starts over with a fresh terminal of `size` (empty scrollback, default modes) fed
    /// `screen`: ompd's repaint of the PTY's scrollback, screen, cursor and modes.
    func reset(size: TerminalSize, screen: Data)
    /// Output that follows the last `reset`, in order.
    func feed(_ data: Data)
}

/// What a terminal emulator shows and types into: one PTY (`TerminalSessionModel`), or an omp session's TUI on
/// whichever PTY omp runs on now (`SessionTerminal`).
@MainActor
public protocol TerminalEndpoint: AnyObject {
    /// Shows the output on `display`, starting with a fresh screen.
    func attach(to display: any TerminalDisplay)
    /// The display is gone; ompd stops streaming to this client.
    func detach()
    /// What the user typed, or the emulator answered.
    func send(_ bytes: Data)
    /// The display's size in cells.
    func resize(_ size: TerminalSize)
    /// Title the program set (OSC 0/2), as the display's emulator reports it.
    var programTitle: String? { get set }
}

/// One PTY the app shows: a terminal, or the TUI of an omp session, attached to this client while a display
/// shows it. The PTY outlives the model, the app and the connection; only `TerminalRegistry.close` (or, for a session's
/// TUI, ompd) ends it.
///
/// - Output: `attach(to:)` sends `pty.attach`, resets the display with the returned screen, then feeds the live
///   `ptyOutput` chunks. ompd subscribes the connection and serializes the screen in one step, so every chunk that
///   arrives after the request went out continues that screen; chunks that overtake the response are held and fed
///   right after it.
/// - Reconnects: when the connection comes back (ompd restarted, or the socket dropped) a shown terminal attaches again
///   and its display starts over from the fresh screen.
/// - Input: one `pty.write` in flight at a time, everything typed meanwhile coalesced into the next one. ompd serves the
///   requests of a connection concurrently, so parallel writes could reach the PTY out of order.
/// - Size: `resize` is debounced and one `pty.resize` is in flight at a time, so ompd ends up with the latest size.
/// - Attach and detach reach ompd one at a time, in call order: the subscription belongs to the connection, so a
///   detach that overtook a later attach would silence the terminal.
@MainActor @Observable
public final class TerminalSessionModel: Identifiable, TerminalEndpoint {
    public enum Phase: Equatable, Sendable {
        /// No display, or waiting for a connection.
        case detached
        /// `pty.attach` is on its way; the display still shows what it had.
        case attaching
        /// The display shows the PTY and its output streams live.
        case attached
        /// ompd refused to attach; retried on the next connection.
        case failed(String)
        /// ompd no longer has the PTY (closed, or not restored after a daemon restart).
        case gone
    }

    /// Largest `pty.write`; a longer paste goes out as several, in order.
    public nonisolated static let maxWriteBytes = 64 * 1024

    public nonisolated let ptyId: PTYID
    public nonisolated var id: PTYID { ptyId }

    /// ompd's latest description of the PTY (from `pty.attach` and `pty.list`).
    public private(set) var info: PTYInfo?
    public private(set) var phase: Phase = .detached
    /// Title the program set (OSC 0/2), as the display's emulator reports it.
    public var programTitle: String?
    /// Why the last input or resize did not reach the PTY; cleared when one does.
    public private(set) var lastError: String?

    /// The program on the PTY ended: the screen stays readable, input goes nowhere.
    public var hasExited: Bool { info?.running == false }
    /// Output streams to the display.
    public var isAttached: Bool { phase == .attached }

    @ObservationIgnored private weak var backend: (any TerminalBackend)?
    @ObservationIgnored private weak var display: (any TerminalDisplay)?
    @ObservationIgnored private let resizeDebounce: Duration
    @ObservationIgnored private let onGone: @MainActor (PTYID) -> Void
    /// A display wants the PTY.
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var connected: Bool
    /// Bumped by every disconnect, so completions of calls made on an earlier connection are recognized.
    @ObservationIgnored private var connectionEpoch = 0
    /// Bumped by every attach, detach and disconnect; the completion of a superseded attach is dropped.
    @ObservationIgnored private var generation = 0
    /// The last attach or detach, which the next one waits for.
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    /// Output that arrived after `pty.attach` went out and before its response; nil when no attach is outstanding.
    @ObservationIgnored private var early: [Data]?
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var isWriting = false
    /// The size the display wants.
    @ObservationIgnored private var wantedSize: TerminalSize?
    /// The PTY's size in ompd as far as this client knows; nil when unknown.
    @ObservationIgnored private var ptySize: TerminalSize?
    @ObservationIgnored private var resizeTimer: Task<Void, Never>?
    @ObservationIgnored private var isResizing = false

    init(
        ptyId: PTYID, info: PTYInfo?, backend: (any TerminalBackend)?, connected: Bool, resizeDebounce: Duration,
        onGone: @escaping @MainActor (PTYID) -> Void
    ) {
        self.ptyId = ptyId
        self.info = info
        self.backend = backend
        self.connected = connected
        self.resizeDebounce = resizeDebounce
        self.onGone = onGone
    }

    // MARK: - Display

    /// Shows the PTY on `display`: attaches now if connected, else as soon as a connection is up, and again after every
    /// reconnect. Each attach resets the display with the fresh screen.
    public func attach(to display: any TerminalDisplay) {
        let replacing = self.display.map { $0 !== display } ?? false
        self.display = display
        wanted = true
        guard connected else { return }
        switch phase {
        case .gone: return
        case .attaching, .attached:
            guard replacing else { return }
            // The new display starts empty: end this subscription, then take a fresh screen.
            invalidateAttachment()
            enqueueDetach()
            beginAttach()
        case .detached, .failed:
            beginAttach()
        }
    }

    /// No display shows the PTY any more: ompd stops streaming it to this client. The PTY keeps running.
    public func detach() {
        wanted = false
        display = nil
        switch phase {
        case .attaching, .attached:
            invalidateAttachment()
            phase = .detached
            enqueueDetach()
        case .failed:
            phase = .detached
        case .detached, .gone:
            break
        }
    }

    // MARK: - Input and size

    /// Sends what the user typed (or the emulator answered) to the PTY, after everything sent before it. Dropped while
    /// disconnected or after the program exited: it would land on a screen the user cannot see.
    public func send(_ bytes: Data) {
        guard connected, !bytes.isEmpty, phase != .gone, !hasExited else { return }
        pendingInput.append(bytes)
        guard !isWriting else { return }
        isWriting = true
        Task { await writePendingInput() }
    }

    /// The display's size changed; ompd gets it once the display has kept one size for the debounce interval.
    public func resize(_ size: TerminalSize) {
        let size = size.clamped
        guard size != wantedSize else { return }
        wantedSize = size
        syncSize(debounced: true)
    }

    // MARK: - Driven by TerminalRegistry

    func connectionOpened() {
        connected = true
        if wanted, phase != .gone { beginAttach() }
    }

    func connectionClosed() {
        connected = false
        connectionEpoch += 1
        invalidateAttachment()
        pendingInput = Data()
        ptySize = nil
        if phase == .attaching || phase == .attached { phase = .detached }
    }

    func receive(_ data: Data) {
        if phase == .attached {
            display?.feed(data)
        } else if early != nil {
            early?.append(data)
        }
    }

    func update(_ info: PTYInfo) {
        guard phase != .gone, info != self.info else { return }
        self.info = info
    }

    func markGone() {
        guard phase != .gone else { return }
        invalidateAttachment()
        wanted = false
        pendingInput = Data()
        phase = .gone
        onGone(ptyId)
    }

    // MARK: - Attaching

    /// Drops the outstanding attach, if any, and the output held for it.
    private func invalidateAttachment() {
        generation += 1
        early = nil
        resizeTimer?.cancel()
        resizeTimer = nil
    }

    private func beginAttach() {
        generation += 1
        let attempt = generation
        early = nil
        phase = .attaching
        enqueueLifecycle { [weak self] backend in
            guard let self, attempt == generation else { return }
            // From here on, output for the PTY on this connection follows the screen the response brings.
            early = []
            do {
                let result = try await backend.attachPTY(ptyId)
                guard attempt == generation else { return }
                attached(result)
            } catch {
                guard attempt == generation else { return }
                early = nil
                attachFailed(error)
            }
        }
    }

    private func attached(_ result: PTYAttach.Result) {
        let held = early ?? []
        early = nil
        info = result.info
        ptySize = result.info.size
        phase = .attached
        display?.reset(size: result.info.size, screen: result.screen)
        for chunk in held { display?.feed(chunk) }
        // The display may be sized differently from the PTY: tell ompd at once.
        syncSize(debounced: false)
    }

    private func attachFailed(_ error: any Error) {
        if error.isDisconnect {
            phase = .detached
        } else if (error as? DaemonError)?.code == .noSuchPTY {
            markGone()
        } else {
            phase = .failed(error.userMessage)
        }
    }

    private func enqueueDetach() {
        let ptyId = ptyId
        enqueueLifecycle { backend in try? await backend.detachPTY(ptyId) }
    }

    /// Runs `operation` after the previous attach or detach finished. The task holds the backend, not the model: a model
    /// released right after `detach()` (a session that moved to another PTY) still ends its subscription.
    private func enqueueLifecycle(_ operation: @escaping @MainActor (any TerminalBackend) async -> Void) {
        guard let backend else { return }
        let previous = lifecycle
        lifecycle = Task {
            await previous?.value
            await operation(backend)
        }
    }

    // MARK: - Writing

    private func writePendingInput() async {
        defer { isWriting = false }
        while !pendingInput.isEmpty {
            guard connected, let backend else {
                pendingInput = Data()
                return
            }
            let batch = pendingInput
            pendingInput = Data()
            let epoch = connectionEpoch
            var start = batch.startIndex
            while start < batch.endIndex {
                let end = batch.index(start, offsetBy: Self.maxWriteBytes, limitedBy: batch.endIndex) ?? batch.endIndex
                do {
                    try await backend.writePTY(ptyId, data: batch[start ..< end])
                    if lastError != nil { lastError = nil }
                } catch {
                    guard epoch == connectionEpoch else { break } // the disconnect already dropped the input
                    // What was typed after the lost bytes would reach the program without them.
                    pendingInput = Data()
                    inputFailed(error)
                    break
                }
                start = end
            }
        }
    }

    private func inputFailed(_ error: any Error) {
        if (error as? DaemonError)?.code == .noSuchPTY {
            markGone()
        } else if !error.isDisconnect {
            lastError = error.userMessage
        }
    }

    // MARK: - Size

    private func syncSize(debounced: Bool) {
        resizeTimer?.cancel()
        resizeTimer = nil
        guard phase == .attached, let wantedSize, wantedSize != ptySize else { return }
        if debounced {
            let delay = resizeDebounce
            resizeTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.sendSize()
            }
        } else {
            Task { await sendSize() }
        }
    }

    /// Sends the wanted size until ompd has it; a size wanted while a resize is in flight goes out after it.
    private func sendSize() async {
        guard !isResizing else { return }
        isResizing = true
        defer { isResizing = false }
        while phase == .attached, let backend, let target = wantedSize, target != ptySize {
            let epoch = connectionEpoch
            do {
                try await backend.resizePTY(ptyId, size: target)
                guard epoch == connectionEpoch else { return }
                ptySize = target
                if lastError != nil { lastError = nil }
            } catch {
                guard epoch == connectionEpoch else { return }
                inputFailed(error)
                return
            }
        }
    }
}

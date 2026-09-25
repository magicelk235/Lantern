import Darwin
import Foundation
import IDEProtocol

/// Every terminal of the IDE lives here, inside the daemon: processes on pseudo-terminals,
/// a headless SwiftTerm terminal per PTY that mirrors its output, subscribers that stream live output, and
/// snapshots that let terminals come back (with their scrollback) after a daemon restart or reboot.
///
/// Execution: the pool runs on the main executor. SwiftTerm schedules work on the main queue (synchronized
/// output timeout) and every dispatch source (PTY reads/writes, child exit) is delivered there, so handlers enter
/// the pool's isolation synchronously and in order (`assumeIsolated`). The daemon must keep the main queue
/// serviced (`dispatchMain()` or an async `main`). Subscriber callbacks run on the main queue inside the pool and
/// must only hand data off (e.g. enqueue a frame).
///
/// Terminal queries (DA, cursor position reports, kitty keyboard queries, …) are answered by the attached UI's
/// terminal; while nobody is attached the headless terminal answers them, so programs never hang waiting.
public actor PTYPool {
    public nonisolated var unownedExecutor: UnownedSerialExecutor { MainActor.sharedUnownedExecutor }

    /// Grace period between SIGHUP on `close` and SIGKILL of a process group that ignores it.
    static let killGrace: DispatchTimeInterval = .seconds(3)
    static let sizeLimits = (cols: 1...1000, rows: 1...500)
    static let restartDivider = "\r\n— terminal restarted —\r\n"

    private let store: PTYSnapshotStore
    private let snapshotInterval: Duration
    private var ptys: [PTYID: ManagedPTY] = [:]
    private var nextSequence: UInt64 = 0
    private var snapshotTimer: Task<Void, Never>?
    private var isShutDown = false
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    public init(snapshotDirectory: URL, snapshotInterval: Duration = .seconds(5)) {
        store = PTYSnapshotStore(directory: snapshotDirectory)
        self.snapshotInterval = snapshotInterval
    }

    deinit {
        snapshotTimer?.cancel()
        // Releasing the PTYs hangs them up (ManagedPTY.deinit).
    }

    // MARK: - Public API

    /// Starts `params.command` (nil: the user's login shell with `-l`) on a new PTY with `TERM=xterm-256color`,
    /// in `params.cwd`, with `params.env` merged over the daemon environment.
    public func open(_ params: PTYOpen.Params) throws -> PTYInfo {
        try ensureRunning()
        try Self.validateSize(cols: params.cols, rows: params.rows)
        guard PTYSpawner.isDirectory(params.cwd) else {
            throw DaemonError(.badParams, "working directory does not exist: \(params.cwd)")
        }
        let command = params.command ?? [PTYSpawner.loginShell(), "-l"]
        let pty = try launch(id: UUID().uuidString.lowercased(), cwd: params.cwd, command: command,
                             envOverlay: params.env, cols: params.cols, rows: params.rows)
        return pty.info
    }

    /// Subscribes `subscriber` to live output. `screen` repaints scrollback, screen, cursor, attributes and modes
    /// into a fresh terminal of `info.cols`×`info.rows`; `onOutput` then receives every later chunk, with no gap
    /// or overlap. Attaching again with the same subscriber replaces its callback.
    public func attach(_ ptyId: PTYID, subscriber: UUID, onOutput: @escaping @Sendable (Data) -> Void) throws -> PTYAttach.Result {
        let pty = try existing(ptyId)
        refreshWorkingDirectory(pty)
        let screen = pty.mirror.serialize(includePending: true)
        pty.subscribers[subscriber] = onOutput
        return PTYAttach.Result(info: pty.info, screen: screen)
    }

    /// Stops streaming to `subscriber` and snapshots the PTY if it changed.
    public func detach(_ ptyId: PTYID, subscriber: UUID) {
        guard let pty = ptys[ptyId] else { return }
        pty.subscribers[subscriber] = nil
        snapshotIfDirty(pty)
    }

    /// Detaches `subscriber` from every PTY (its connection went away).
    public func detachAll(subscriber: UUID) {
        for pty in ptys.values where pty.subscribers.removeValue(forKey: subscriber) != nil {
            snapshotIfDirty(pty)
        }
    }

    /// Sends input to the PTY. Input for a PTY whose program is gone is dropped.
    public func write(_ ptyId: PTYID, _ data: Data) throws {
        let pty = try existing(ptyId)
        guard let channel = pty.channel else { return }
        try data.withUnsafeBytes { try channel.write($0) }
    }

    /// Resizes the tty (the foreground program gets SIGWINCH) and the headless terminal.
    public func resize(_ ptyId: PTYID, cols: Int, rows: Int) throws {
        let pty = try existing(ptyId)
        try Self.validateSize(cols: cols, rows: rows)
        if let channel = pty.channel {
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = withUnsafeMutablePointer(to: &size) { ioctl(channel.fd, TIOCSWINSZ, $0) }
        }
        pty.mirror.resize(cols: cols, rows: rows)
        pty.info.cols = cols
        pty.info.rows = rows
        markDirty(pty)
    }

    /// Hangs up the PTY (SIGHUP to its process group, SIGKILL if still alive after a grace period; the child is
    /// reaped), forgets it and removes its snapshot.
    public func close(_ ptyId: PTYID) throws {
        guard let pty = ptys.removeValue(forKey: ptyId) else { throw Self.noSuchPTY(ptyId) }
        pty.subscribers.removeAll()
        pty.hangUp()
        if let reaper = pty.reaper, !reaper.isReaped {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace) { reaper.signalGroup(SIGKILL) }
        }
        store.remove(ptyId)
    }

    public func list() -> [PTYInfo] {
        ptys.values.sorted { $0.sequence < $1.sequence }.map { pty in
            refreshWorkingDirectory(pty)
            return pty.info
        }
    }

    /// Writes `<dir>/<ptyId>.json` for every PTY that changed since its last snapshot. Also runs on its own
    /// `snapshotInterval` after a change (never while idle).
    public func snapshotAll() throws {
        var firstError: (any Error)?
        for pty in ptys.values where pty.dirty {
            do { try writeSnapshot(pty) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Regime B2: recreates every snapshotted PTY with its id, size, command, environment overrides
    /// and working directory, its terminal prefilled with the saved scrollback followed by a
    /// "— terminal restarted —" divider. PTYs whose program had already exited come back as exited (their
    /// command is not re-run); if a command can no longer be started the PTY also comes back exited.
    public func restoreFromSnapshots() throws -> [PTYInfo] {
        try ensureRunning()
        var restored: [PTYInfo] = []
        for snapshot in try store.loadAll() where ptys[snapshot.info.ptyId] == nil {
            var info = snapshot.info
            info.cols = min(max(info.cols, Self.sizeLimits.cols.lowerBound), Self.sizeLimits.cols.upperBound)
            info.rows = min(max(info.rows, Self.sizeLimits.rows.lowerBound), Self.sizeLimits.rows.upperBound)
            let screen = [UInt8](snapshot.screen)
            if info.running, !info.command.isEmpty {
                let cwd = PTYSpawner.isDirectory(info.cwd) ? info.cwd : PTYSpawner.homeDirectory()
                if let pty = try? launch(id: info.ptyId, cwd: cwd, command: info.command, envOverlay: snapshot.env,
                                         cols: info.cols, rows: info.rows, prefill: { mirror in
                                             mirror.feed(screen)
                                             Self.resetForRestart(mirror)
                                         }) {
                    restored.append(pty.info)
                    continue
                }
            }
            info.running = false
            info.pid = nil
            let mirror = TerminalMirror(cols: info.cols, rows: info.rows)
            mirror.feed(screen)
            let pty = register(ManagedPTY(info: info, envOverlay: snapshot.env, mirror: mirror, sequence: takeSequence()))
            restored.append(pty.info)
        }
        return restored
    }

    /// Graceful daemon exit: snapshots every changed PTY, then hangs all of them up. Snapshots are kept for
    /// `restoreFromSnapshots()`; the pool accepts no new PTYs afterwards.
    public func shutdown() throws {
        guard !isShutDown else { return }
        snapshotTimer?.cancel()
        snapshotTimer = nil
        var failure: (any Error)?
        do { try snapshotAll() } catch { failure = error }
        isShutDown = true
        for pty in ptys.values {
            pty.subscribers.removeAll()
            pty.hangUp()
        }
        ptys.removeAll()
        if let failure { throw failure }
    }

    // MARK: - Lifecycle

    private func launch(id: PTYID, cwd: String, command: [String], envOverlay: [String: String]?, cols: Int, rows: Int,
                        prefill: ((TerminalMirror) -> Void)? = nil) throws -> ManagedPTY {
        guard let program = command.first, !program.isEmpty else {
            throw DaemonError(.badParams, "empty command")
        }
        let environment = PTYSpawner.environment(overlay: envOverlay, cwd: cwd)
        let executable = try PTYSpawner.resolveExecutable(program, cwd: cwd, searchPath: environment["PATH"])
        let mirror = TerminalMirror(cols: cols, rows: rows)
        prefill?(mirror)
        let child = try PTYSpawner.spawn(executable: executable, argv: command, environment: environment,
                                         cwd: cwd, cols: cols, rows: rows)
        let info = PTYInfo(ptyId: id, cwd: cwd, command: command, cols: cols, rows: rows, pid: child.pid, running: true)
        let pty = register(ManagedPTY(info: info, envOverlay: envOverlay, mirror: mirror, sequence: takeSequence()))
        pty.channel = MasterChannel(
            fd: child.master,
            onReadable: { [weak self] in self?.assumeIsolated { $0.masterReadable(id) } },
            onWritable: { [weak self] in self?.assumeIsolated { $0.masterWritable(id) } }
        )
        pty.reaper = ChildReaper(pid: child.pid) { [weak self] _ in
            self?.assumeIsolated { $0.childExited(id, pid: child.pid) }
        }
        mirror.onReply = { [unowned pty] reply in
            // Replies come from whoever renders the terminal: the attached UI, else the headless terminal.
            guard pty.subscribers.isEmpty, let channel = pty.channel else { return }
            reply.withUnsafeBytes { try? channel.write($0) }
        }
        return pty
    }

    private func register(_ pty: ManagedPTY) -> ManagedPTY {
        ptys[pty.info.ptyId] = pty
        markDirty(pty)
        return pty
    }

    private func masterReadable(_ id: PTYID) {
        guard let pty = ptys[id], let channel = pty.channel else { return }
        // Bounded per wake-up so one chatty PTY cannot starve the others; the level-triggered source refires.
        for _ in 0..<8 {
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(channel.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                readBuffer.withUnsafeBufferPointer { ingest(pty, UnsafeBufferPointer(rebasing: $0[0..<count])) }
                if count < readBuffer.count { return }
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            // EOF / EIO: no process holds the tty any more; the buffer stays attachable until close.
            channel.close()
            pty.channel = nil
            markDirty(pty)
            return
        }
    }

    private func ingest(_ pty: ManagedPTY, _ chunk: UnsafeBufferPointer<UInt8>) {
        pty.mirror.feed(chunk)
        if !pty.subscribers.isEmpty {
            let data = Data(buffer: chunk)
            for deliver in pty.subscribers.values { deliver(data) }
        }
        markDirty(pty)
    }

    private func masterWritable(_ id: PTYID) {
        ptys[id]?.channel?.flushPending()
    }

    private func childExited(_ id: PTYID, pid: pid_t) {
        guard let pty = ptys[id], pty.info.pid == pid else { return }
        pty.info.running = false
        pty.info.pid = nil
        markDirty(pty)
    }

    // MARK: - Snapshots

    private func markDirty(_ pty: ManagedPTY) {
        pty.dirty = true
        scheduleSnapshot()
    }

    private func scheduleSnapshot() {
        guard snapshotTimer == nil, !isShutDown else { return }
        let interval = snapshotInterval
        snapshotTimer = Task { [weak self] in
            try? await Task.sleep(for: interval)
            await self?.snapshotTimerFired()
        }
    }

    private func snapshotTimerFired() {
        snapshotTimer = nil
        guard !isShutDown else { return }
        try? snapshotAll()
        // A failed write leaves the PTY dirty: try again on the next tick.
        if ptys.values.contains(where: \.dirty) { scheduleSnapshot() }
    }

    private func snapshotIfDirty(_ pty: ManagedPTY) {
        guard pty.dirty else { return }
        if (try? writeSnapshot(pty)) == nil { scheduleSnapshot() }
    }

    private func writeSnapshot(_ pty: ManagedPTY) throws {
        refreshWorkingDirectory(pty)
        let snapshot = PTYSnapshot(info: pty.info, screen: pty.mirror.serialize(includePending: false), env: pty.envOverlay)
        try store.write(snapshot)
        pty.dirty = false
    }

    /// Leaves whatever mode the old program had set (alternate screen, mouse reporting, kitty keyboard flags,
    /// scroll region, pen, …) before the new process starts writing below the divider.
    private static func resetForRestart(_ mirror: TerminalMirror) {
        if mirror.terminal.isCurrentBufferAlternate { mirror.feed(Array("\u{1b}[?1049l".utf8)) }
        mirror.terminal.softReset()
        let modesOff = [5, 9, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004, 2026].map { "\u{1b}[?\($0)l" }.joined()
        mirror.feed(Array((modesOff + "\u{1b}[<16u\u{1b}[0m" + restartDivider).utf8))
    }

    // MARK: - Helpers

    /// Follows `cd` in the shell: `info.cwd` is where a restored shell starts.
    private func refreshWorkingDirectory(_ pty: ManagedPTY) {
        guard pty.info.running, let pid = pty.info.pid, let cwd = PTYSpawner.currentDirectory(of: pid), cwd != pty.info.cwd else { return }
        pty.info.cwd = cwd
        markDirty(pty)
    }

    private func existing(_ id: PTYID) throws -> ManagedPTY {
        guard let pty = ptys[id] else { throw Self.noSuchPTY(id) }
        return pty
    }

    private func takeSequence() -> UInt64 {
        nextSequence += 1
        return nextSequence
    }

    private func ensureRunning() throws {
        if isShutDown { throw DaemonError(.internal, "PTY pool is shut down") }
    }

    private static func validateSize(cols: Int, rows: Int) throws {
        guard sizeLimits.cols.contains(cols), sizeLimits.rows.contains(rows) else {
            throw DaemonError(.badParams, "terminal size \(cols)x\(rows) outside \(sizeLimits.cols)x\(sizeLimits.rows)")
        }
    }

    private static func noSuchPTY(_ id: PTYID) -> DaemonError {
        DaemonError(.noSuchPTY, "no such PTY: \(id)")
    }
}

/// State of one PTY, confined to the pool.
private final class ManagedPTY {
    var info: PTYInfo
    let envOverlay: [String: String]?
    let mirror: TerminalMirror
    /// Creation order, for a stable `list()`.
    let sequence: UInt64
    /// Nil once the tty hung up (all processes holding it are gone) or the PTY was closed.
    var channel: MasterChannel?
    var reaper: ChildReaper?
    var subscribers: [UUID: @Sendable (Data) -> Void] = [:]
    var dirty = true

    init(info: PTYInfo, envOverlay: [String: String]?, mirror: TerminalMirror, sequence: UInt64) {
        self.info = info
        self.envOverlay = envOverlay
        self.mirror = mirror
        self.sequence = sequence
    }

    deinit { hangUp() }

    /// SIGHUP (and SIGCONT, for stopped jobs) to the process group, then closes the master. Idempotent.
    func hangUp() {
        reaper?.signalGroup(SIGHUP)
        reaper?.signalGroup(SIGCONT)
        channel?.close()
        channel = nil
    }
}

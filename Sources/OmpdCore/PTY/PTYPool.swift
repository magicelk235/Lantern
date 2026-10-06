import Darwin
import Foundation
import IDEProtocol

/// Every terminal of the IDE lives here, inside the daemon: processes on pseudo-terminals,
/// a headless SwiftTerm terminal per PTY that mirrors its output, subscribers that stream live output, and
/// snapshots that let terminals come back (with their scrollback) after a daemon restart or reboot.
///
/// Two kinds of PTY share the pool: plain terminals (`open`, restored from their snapshots after a restart) and
/// session PTYs (`openSession`), each running one omp session's TUI for its `SessionSupervisor`. A session PTY is
/// tagged with its `SessionKey`, reports its program's exit to the supervisor, and is never restored by the pool:
/// the supervisor respawns omp with `--resume`, and the new PTY starts from the previous one's scrollback. A plain
/// terminal's program starts with the variables of `terminalEnvironment` (the terminal's bridge credentials, so an omp
/// started from its shell can be adopted as a session); they are never written to snapshots.
///
/// Execution: the pool runs on the main executor. SwiftTerm schedules work on the main queue (synchronized
/// output timeout) and every dispatch source (PTY reads/writes, child exit) is delivered there, so handlers enter
/// the pool's isolation synchronously and in order (`assumeIsolated`). The daemon must keep the main queue
/// serviced (`dispatchMain()` or an async `main`). Subscriber, change and exit callbacks run on the main queue inside
/// the pool and must only hand data off (e.g. enqueue a frame, start a task).
///
/// Terminal queries (DA, cursor position reports, kitty keyboard queries, …) are answered by the attached UI's
/// terminal; while nobody is attached the headless terminal answers them, so programs never hang waiting.
public actor PTYPool {
    public nonisolated var unownedExecutor: UnownedSerialExecutor { MainActor.sharedUnownedExecutor }

    /// Grace period between SIGHUP on `close` and SIGKILL of a process group that ignores it.
    static let killGrace: DispatchTimeInterval = .seconds(3)
    static let sizeLimits = (cols: 1...1000, rows: 1...500)
    static let restartDivider = "\r\n— terminal restarted —\r\n"
    /// Output read right after a program exited, before its exit is reported (its last paint).
    static let exitDrainLimit = 16 << 20

    private let store: PTYSnapshotStore
    private let snapshotInterval: Duration
    private var ptys: [PTYID: ManagedPTY] = [:]
    /// Last snapshot of each session's PTY written before this daemon started, kept until the session's next PTY
    /// continues from it (`restoreFromSnapshots` collects them; `discardSessionScreens` drops unknown sessions).
    private var sessionScreens: [SessionKey: PTYSnapshot] = [:]
    private var onChange: (@Sendable ([PTYInfo]) -> Void)?
    private var snapshotObserver: (@Sendable ((any Error)?) -> Void)?
    /// Every snapshot on disk from before this daemon started has been taken in (`restoreFromSnapshots`): a snapshot no
    /// PTY or session refers to from now on is garbage (`unreferencedSnapshots`).
    private var snapshotsRestored = false
    private var terminalEnvironment: (@Sendable (PTYID) async -> [String: String])?
    private var nextSequence: UInt64 = 0
    private var snapshotTimer: Task<Void, Never>?
    private var isShutDown = false
    /// `freezeForHandover`: nothing is read, written or reaped until `thaw` (or the exec of the next image).
    private var isFrozen = false
    /// Programs of PTYs `close` hung up that were not reaped yet (they get SIGKILL after `killGrace`).
    private var closingPIDs: Set<pid_t> = []
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

    /// Receives the full PTY list whenever it changes: a PTY opened, its program exited, it was resized or closed
    /// (the daemon broadcasts it as `ServerFrame.ptys`).
    public func setChangeHandler(_ handler: @escaping @Sendable ([PTYInfo]) -> Void) {
        onChange = handler
    }

    /// Variables merged last into the environment of every plain terminal's program, asked per PTY (with its id)
    /// right before the program starts: on `open` and for every terminal `restoreFromSnapshots` starts again.
    public func setTerminalEnvironment(_ provider: @escaping @Sendable (PTYID) async -> [String: String]) {
        terminalEnvironment = provider
    }

    /// Receives the outcome of every pass of snapshot writes that wrote anything — the dirty tick, a detach, before
    /// sleep, at shutdown: nil when each write succeeded, else the first failure.
    public func setSnapshotObserver(_ observer: @escaping @Sendable ((any Error)?) -> Void) {
        snapshotObserver = observer
    }

    /// Starts `params.command` (nil: the user's login shell with `-l`) on a new PTY with `TERM=xterm-256color`,
    /// in `params.cwd`, with `params.env` merged over the daemon environment and the terminal environment over both.
    public func open(_ params: PTYOpen.Params) async throws -> PTYInfo {
        try ensureRunning()
        try Self.validateSize(cols: params.cols, rows: params.rows)
        guard PTYSpawner.isDirectory(params.cwd) else {
            throw DaemonError(.badParams, "working directory does not exist: \(params.cwd)")
        }
        let command = params.command ?? [PTYSpawner.loginShell(), "-l"]
        let id = UUID().uuidString.lowercased()
        let overlay = await terminalOverlay(id, over: params.env)
        try ensureRunning()
        let pty = try launch(
            id: id, cwd: params.cwd, command: command,
            environment: PTYSpawner.environment(base: ProcessInfo.processInfo.environment, overlay: overlay, cwd: params.cwd),
            persistedEnv: params.env, cols: params.cols, rows: params.rows)
        publishChange()
        return pty.info
    }

    /// Starts one omp session's TUI on a new PTY tagged with `sessionKey`. The environment is `environment`
    /// adjusted for a terminal (`TERM`, `COLORTERM`, `PWD`, …) with `overlay` merged over it; neither is written to
    /// snapshots (the overlay carries per-spawn bridge credentials). The terminal continues the session's previous
    /// screen — the PTY `continuing` if it is still in the pool, else the session's last snapshot from before this
    /// daemon started — scrolled into the scrollback below a "— terminal restarted —" divider; the program's first
    /// erase of the scrollback (omp's first paint clears it) is dropped, so that history stays above its new screen.
    /// `cols`/`rows` default to the previous screen's size (120×40 without one). The previous PTY is left alone: the
    /// caller closes it once nothing points to it. `onExit` runs once, on the main queue, after the program exited and
    /// its last output was read.
    public func openSession(
        sessionKey: SessionKey, cwd: String, command: [String], environment: [String: String], overlay: [String: String],
        cols: Int?, rows: Int?, continuing previous: PTYID?, onExit: @escaping @Sendable (PTYExit) -> Void
    ) throws -> PTYInfo {
        try ensureRunning()
        guard PTYSpawner.isDirectory(cwd) else { throw DaemonError(.badParams, "working directory does not exist: \(cwd)") }
        let saved = previous.flatMap { ptys[$0] } == nil ? sessionScreens[sessionKey] : nil
        let prefill: Prefill? =
            if let previous, let old = ptys[previous] {
                Prefill(screen: [UInt8](old.mirror.serialize(includePending: false)), cols: old.info.cols, rows: old.info.rows,
                        keepsHistory: true)
            } else if let saved {
                Prefill(screen: [UInt8](saved.screen), cols: saved.info.cols, rows: saved.info.rows, keepsHistory: true)
            } else {
                nil
            }
        let size = (cols: cols ?? prefill?.cols ?? 120, rows: rows ?? prefill?.rows ?? 40)
        try Self.validateSize(cols: size.cols, rows: size.rows)
        let pty = try launch(
            id: UUID().uuidString.lowercased(), cwd: cwd, command: command, sessionKey: sessionKey,
            environment: PTYSpawner.environment(base: environment, overlay: overlay, cwd: cwd), persistedEnv: nil,
            cols: size.cols, rows: size.rows, prefill: prefill)
        pty.onExit = onExit
        if let saved {
            sessionScreens[sessionKey] = nil
            store.remove(saved.info.ptyId)
        }
        publishChange()
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
        try ensureRunning()
        guard let channel = pty.channel else { return }
        try data.withUnsafeBytes { try channel.write($0) }
    }

    /// Resizes the tty (the foreground program gets SIGWINCH) and the headless terminal.
    public func resize(_ ptyId: PTYID, cols: Int, rows: Int) throws {
        let pty = try existing(ptyId)
        try ensureRunning()
        try Self.validateSize(cols: cols, rows: rows)
        guard cols != pty.info.cols || rows != pty.info.rows else { return }
        if let channel = pty.channel {
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = withUnsafeMutablePointer(to: &size) { ioctl(channel.fd, TIOCSWINSZ, $0) }
        }
        pty.mirror.resize(cols: cols, rows: rows)
        pty.info.cols = cols
        pty.info.rows = rows
        markDirty(pty)
        publishChange()
    }

    /// Hangs up the PTY (SIGHUP to its process group, SIGKILL if still alive after a grace period; the child is
    /// reaped), forgets it and removes its snapshot. With `refusingSessions`, a session PTY is not closed (clients
    /// close sessions with `session.close`).
    public func close(_ ptyId: PTYID, refusingSessions: Bool = false) throws {
        guard let pty = ptys[ptyId] else { throw Self.noSuchPTY(ptyId) }
        if refusingSessions, let key = pty.info.sessionKey {
            throw DaemonError(.badParams, "PTY \(ptyId) runs omp session \(key); close it with session.close")
        }
        ptys[ptyId] = nil
        pty.subscribers.removeAll()
        pty.onExit = nil
        pty.hangUp()
        if let reaper = pty.reaper, !reaper.isReaped {
            closingPIDs.insert(reaper.pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace) { reaper.signalGroup(SIGKILL) }
        }
        store.remove(ptyId)
        publishChange()
    }

    /// Sends `signal` to the process group of the PTY's program (a no-op once it exited).
    public func signal(_ ptyId: PTYID, _ signal: Int32) throws {
        try existing(ptyId).reaper?.signalGroup(signal)
    }

    public func info(_ ptyId: PTYID) -> PTYInfo? {
        ptys[ptyId]?.info
    }

    public func list() -> [PTYInfo] {
        ptys.values.sorted { $0.sequence < $1.sequence }.map { pty in
            refreshWorkingDirectory(pty)
            return pty.info
        }
    }

    /// What runs in the foreground of the PTY's terminal besides its program (`PTYProcesses`).
    public func foregroundProcesses(_ ptyId: PTYID) throws -> [String] {
        let pty = try existing(ptyId)
        guard let master = pty.channel?.fd else { return [] }
        return PTYSpawner.foregroundProcesses(master: master, program: pty.info.running ? pty.info.pid : nil)
    }

    /// Writes `<dir>/<ptyId>.json` for every PTY that changed since its last snapshot. Also runs on its own
    /// `snapshotInterval` after a change (never while idle).
    public func snapshotAll() throws {
        var firstError: (any Error)?
        var wrote = false
        for pty in ptys.values where pty.dirty {
            wrote = true
            do { try writeSnapshot(pty) } catch { firstError = firstError ?? error }
        }
        if wrote { snapshotObserver?(firstError) }
        if let firstError { throw firstError }
    }

    /// Regime B2: recreates every snapshotted plain terminal with its id, size, command, environment
    /// overrides and working directory (fresh terminal environment on top), its terminal prefilled with the saved
    /// scrollback followed by a "— terminal restarted —" divider. Terminals whose program had already exited come back
    /// as exited (their command is not re-run); if a command can no longer be started the PTY also comes back exited.
    /// Session PTYs are not recreated: their newest snapshot per session is kept for that session's next `openSession`.
    public func restoreFromSnapshots() async throws -> [PTYInfo] {
        try ensureRunning()
        var restored: [PTYInfo] = []
        for snapshot in try store.loadAll() where ptys[snapshot.info.ptyId] == nil {
            if let key = snapshot.info.sessionKey {
                keepSessionScreen(snapshot, of: key)
                continue
            }
            var info = snapshot.info
            info.cols = min(max(info.cols, Self.sizeLimits.cols.lowerBound), Self.sizeLimits.cols.upperBound)
            info.rows = min(max(info.rows, Self.sizeLimits.rows.lowerBound), Self.sizeLimits.rows.upperBound)
            let screen = [UInt8](snapshot.screen)
            if info.running, !info.command.isEmpty {
                let cwd = PTYSpawner.isDirectory(info.cwd) ? info.cwd : PTYSpawner.homeDirectory()
                let overlay = await terminalOverlay(info.ptyId, over: snapshot.env)
                try ensureRunning()
                guard ptys[info.ptyId] == nil else { continue }
                let environment = PTYSpawner.environment(base: ProcessInfo.processInfo.environment, overlay: overlay, cwd: cwd)
                if let pty = try? launch(
                    id: info.ptyId, cwd: cwd, command: info.command, environment: environment, persistedEnv: snapshot.env,
                    cols: info.cols, rows: info.rows,
                    prefill: Prefill(screen: screen, cols: info.cols, rows: info.rows, keepsHistory: false))
                {
                    restored.append(pty.info)
                    continue
                }
            }
            info.running = false
            info.pid = nil
            let mirror = TerminalMirror(cols: info.cols, rows: info.rows)
            mirror.feed(screen)
            let pty = register(ManagedPTY(info: info, persistedEnv: snapshot.env, mirror: mirror, sequence: takeSequence()))
            restored.append(pty.info)
        }
        if !restored.isEmpty { publishChange() }
        snapshotsRestored = true
        return restored
    }

    /// Forgets (and deletes) the kept screens of sessions not in `keys` (sessions the manifest no longer has).
    public func discardSessionScreens(keeping keys: Set<SessionKey>) {
        for (key, snapshot) in sessionScreens where !keys.contains(key) {
            sessionScreens[key] = nil
            store.remove(snapshot.info.ptyId)
        }
    }

    /// Snapshot files nothing will read again (`PTYSnapshotStore.unreferenced`): of PTYs no longer in the pool whose
    /// session, if any, is not in `sessions` (the manifest's), and leftovers of interrupted writes. Count and bytes on
    /// disk. None before `restoreFromSnapshots()` took in what the previous daemon left.
    public func unreferencedSnapshots(sessions: Set<SessionKey>) -> (count: Int, bytes: Int64) {
        let files = unreferencedSnapshotFiles(sessions: sessions)
        return (files.count, files.reduce(0) { $0 + $1.bytes })
    }

    /// Deletes what `unreferencedSnapshots` lists; returns the count and bytes removed. Snapshot writes run on the pool's
    /// executor, so none is in flight meanwhile.
    public func removeUnreferencedSnapshots(sessions: Set<SessionKey>) -> (count: Int, bytes: Int64) {
        var removed = (count: 0, bytes: Int64(0))
        for file in unreferencedSnapshotFiles(sessions: sessions) where unlink(file.url.path(percentEncoded: false)) == 0 {
            removed.count += 1
            removed.bytes += file.bytes
        }
        return removed
    }

    private func unreferencedSnapshotFiles(sessions: Set<SessionKey>) -> [(url: URL, bytes: Int64)] {
        guard snapshotsRestored else { return [] }
        let live = Set(ptys.keys).union(sessionScreens.values.map(\.info.ptyId))
        return store.unreferenced(live: live, sessions: sessions)
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
            pty.onExit = nil
            pty.hangUp()
        }
        ptys.removeAll()
        if let failure { throw failure }
    }

    // MARK: - In-place upgrade

    /// Stops reading, writing and reaping every PTY (the master descriptors stay open, so no program notices) and
    /// returns what the next image needs to read on from exactly here: each PTY's screen as its terminal holds it, the
    /// input the tty has not taken yet, and its program, plus the programs of closed PTYs not reaped yet and the kept
    /// screens of sessions. Refuses new PTYs, input and resizes until `thaw`.
    func freezeForHandover() -> PTYPoolHandover {
        isFrozen = true
        snapshotTimer?.cancel()
        snapshotTimer = nil
        var handed: [PTYHandover] = []
        for pty in ptys.values.sorted(by: { $0.sequence < $1.sequence }) {
            refreshWorkingDirectory(pty)
            pty.channel?.suspend()
            pty.reaper?.suspend()
            handed.append(PTYHandover(
                info: pty.info, persistedEnv: pty.persistedEnv, sequence: pty.sequence, masterFD: pty.channel?.fd,
                screen: pty.mirror.serialize(includePending: true), scrollbackEraseHeld: pty.historyGuard?.heldBytes,
                pendingInput: pty.channel?.pendingInput ?? Data()))
        }
        return PTYPoolHandover(
            ptys: handed, closing: closingPIDs.sorted(), sessionScreens: sessionScreens.mapValues(\.info.ptyId))
    }

    /// The handover did not happen: everything runs on, and what the programs wrote meanwhile is read now.
    func thaw() {
        guard isFrozen else { return }
        isFrozen = false
        for pty in ptys.values {
            pty.channel?.resume()
            pty.reaper?.resume()
        }
        if ptys.values.contains(where: \.dirty) { scheduleSnapshot() }
    }

    /// The next image of an in-place upgrade: takes over the PTYs `handover` describes, on the descriptors and programs
    /// this process inherited. Each terminal continues from its handed-over screen with the next byte its master yields;
    /// `onExit` per session PTY gets its program's exit (as `openSession`'s does), also one that happened during the
    /// handover. Closed PTYs' programs are reaped (SIGKILL after `killGrace`), and the sessions' kept screens come back
    /// from their snapshots.
    func adopt(_ handover: PTYPoolHandover, onExit: [PTYID: @Sendable (PTYExit) -> Void]) {
        for item in handover.ptys where ptys[item.info.ptyId] == nil {
            let mirror = TerminalMirror(cols: item.info.cols, rows: item.info.rows)
            mirror.feed([UInt8](item.screen))
            let pty = register(ManagedPTY(info: item.info, persistedEnv: item.persistedEnv, mirror: mirror, sequence: item.sequence))
            nextSequence = max(nextSequence, item.sequence)
            if let held = item.scrollbackEraseHeld { pty.historyGuard = ScrollbackEraseFilter(holding: held) }
            pty.onExit = onExit[item.info.ptyId]
            if let master = item.masterFD {
                _ = fcntl(master, F_SETFD, FD_CLOEXEC)
                _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
            }
            wire(pty, master: item.masterFD, pid: item.info.running ? item.info.pid : nil, pendingInput: [UInt8](item.pendingInput))
        }
        for pid in handover.closing {
            closingPIDs.insert(pid)
            let reaper = ChildReaper(pid: pid) { [weak self] _ in self?.assumeIsolated { _ = $0.closingPIDs.remove(pid) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace) { reaper.signalGroup(SIGKILL) }
        }
        let kept = Set(handover.sessionScreens.values)
        for snapshot in (try? store.loadAll()) ?? [] where kept.contains(snapshot.info.ptyId) {
            if let key = snapshot.info.sessionKey { keepSessionScreen(snapshot, of: key) }
        }
        snapshotsRestored = true
        publishChange()
    }

    // MARK: - Lifecycle

    /// A previous screen a new PTY's terminal starts from (see `resetForRestart`).
    private struct Prefill {
        var screen: [UInt8]
        var cols: Int
        var rows: Int
        /// The old screen goes into the scrollback and the program's first scrollback erase is dropped (session
        /// PTYs: omp's TUI clears screen and scrollback when it starts). Restored shells continue on the same screen.
        var keepsHistory: Bool
    }

    private func launch(
        id: PTYID, cwd: String, command: [String], sessionKey: SessionKey? = nil, environment: [String: String],
        persistedEnv: [String: String]?, cols: Int, rows: Int, prefill: Prefill? = nil
    ) throws -> ManagedPTY {
        guard let program = command.first, !program.isEmpty else {
            throw DaemonError(.badParams, "empty command")
        }
        let executable = try PTYSpawner.resolveExecutable(program, cwd: cwd, searchPath: environment["PATH"])
        let mirror: TerminalMirror
        if let prefill {
            // Replayed at the size it was serialized for, then reflowed to the new size.
            mirror = TerminalMirror(cols: prefill.cols, rows: prefill.rows)
            mirror.feed(prefill.screen)
            Self.resetForRestart(mirror)
            if prefill.cols != cols || prefill.rows != rows { mirror.resize(cols: cols, rows: rows) }
            // After the resize, which can pull scrollback back into a taller screen.
            if prefill.keepsHistory { Self.pushScreenIntoHistory(mirror) }
        } else {
            mirror = TerminalMirror(cols: cols, rows: rows)
        }
        let child = try PTYSpawner.spawn(executable: executable, argv: command, environment: environment,
                                         cwd: cwd, cols: cols, rows: rows)
        let info = PTYInfo(ptyId: id, cwd: cwd, command: command, cols: cols, rows: rows, pid: child.pid, running: true,
                           sessionKey: sessionKey)
        let pty = register(ManagedPTY(info: info, persistedEnv: persistedEnv, mirror: mirror, sequence: takeSequence()))
        if prefill?.keepsHistory == true { pty.historyGuard = ScrollbackEraseFilter() }
        wire(pty, master: child.master, pid: child.pid)
        return pty
    }

    /// Reads `master` into the PTY's terminal, reaps `pid` (its program) and routes the terminal's query replies.
    private func wire(_ pty: ManagedPTY, master: Int32?, pid: pid_t?, pendingInput: [UInt8] = []) {
        let id = pty.info.ptyId
        if let master {
            pty.channel = MasterChannel(
                fd: master, pendingInput: pendingInput,
                onReadable: { [weak self] in self?.assumeIsolated { $0.masterReadable(id) } },
                onWritable: { [weak self] in self?.assumeIsolated { $0.masterWritable(id) } }
            )
        }
        if let pid {
            pty.reaper = ChildReaper(pid: pid) { [weak self] status in
                self?.assumeIsolated { $0.childExited(id, pid: pid, status: status) }
            }
        }
        pty.mirror.onReply = { [unowned pty] reply in
            // Replies come from whoever renders the terminal: the attached UI, else the headless terminal.
            guard pty.subscribers.isEmpty, let channel = pty.channel else { return }
            reply.withUnsafeBytes { try? channel.write($0) }
        }
    }

    private func register(_ pty: ManagedPTY) -> ManagedPTY {
        ptys[pty.info.ptyId] = pty
        markDirty(pty)
        return pty
    }

    private func masterReadable(_ id: PTYID) {
        guard let pty = ptys[id] else { return }
        // Bounded per wake-up so one chatty PTY cannot starve the others; the level-triggered source refires.
        drain(pty, maxBytes: 8 * readBuffer.count)
    }

    /// Reads what the master has now, up to `maxBytes`; closes the channel on EOF/EIO (no process holds the tty any
    /// more; the buffer stays attachable until close).
    private func drain(_ pty: ManagedPTY, maxBytes: Int) {
        var budget = maxBytes
        while budget > 0, let channel = pty.channel {
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(channel.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                readBuffer.withUnsafeBufferPointer { ingest(pty, UnsafeBufferPointer(rebasing: $0[0..<count])) }
                budget -= count
                if count < readBuffer.count { return }
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            channel.close()
            pty.channel = nil
            markDirty(pty)
            return
        }
    }

    private func ingest(_ pty: ManagedPTY, _ chunk: UnsafeBufferPointer<UInt8>) {
        guard var guardian = pty.historyGuard else { return deliver(pty, chunk) }
        let bytes = guardian.filter(chunk)
        pty.historyGuard = guardian.isDone ? nil : guardian
        bytes.withUnsafeBufferPointer { deliver(pty, $0) }
    }

    /// Output as the terminal and every subscriber see it.
    private func deliver(_ pty: ManagedPTY, _ chunk: UnsafeBufferPointer<UInt8>) {
        guard !chunk.isEmpty else { return }
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

    private func childExited(_ id: PTYID, pid: pid_t, status: Int32) {
        closingPIDs.remove(pid)
        guard let pty = ptys[id], pty.info.pid == pid else { return }
        // The program's last paint may still sit in the master: take it before anyone looks at the screen.
        drain(pty, maxBytes: Self.exitDrainLimit)
        if let held = pty.historyGuard?.remainder() { held.withUnsafeBufferPointer { deliver(pty, $0) } }
        pty.historyGuard = nil
        pty.info.running = false
        pty.info.pid = nil
        markDirty(pty)
        publishChange()
        let onExit = pty.onExit
        pty.onExit = nil
        onExit?(PTYExit(waitStatus: status))
    }

    private func publishChange() {
        guard let onChange, !isShutDown else { return }
        onChange(list())
    }

    // MARK: - Snapshots

    private func keepSessionScreen(_ snapshot: PTYSnapshot, of key: SessionKey) {
        if let kept = sessionScreens[key] {
            // Two PTYs of one session on disk (the daemon died mid-respawn): the newer screen wins.
            let (newer, older) = (kept.savedAt ?? .distantPast) >= (snapshot.savedAt ?? .distantPast) ? (kept, snapshot) : (snapshot, kept)
            sessionScreens[key] = newer
            store.remove(older.info.ptyId)
        } else {
            sessionScreens[key] = snapshot
        }
    }

    private func markDirty(_ pty: ManagedPTY) {
        pty.dirty = true
        scheduleSnapshot()
    }

    private func scheduleSnapshot() {
        guard snapshotTimer == nil, !isShutDown, !isFrozen else { return }
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
        do {
            try writeSnapshot(pty)
            snapshotObserver?(nil)
        } catch {
            snapshotObserver?(error)
            scheduleSnapshot()
        }
    }

    private func writeSnapshot(_ pty: ManagedPTY) throws {
        refreshWorkingDirectory(pty)
        let snapshot = PTYSnapshot(
            info: pty.info, screen: pty.mirror.serialize(includePending: false), env: pty.persistedEnv, savedAt: Date())
        try store.write(snapshot)
        pty.dirty = false
    }

    /// Leaves whatever mode the old program had set (alternate screen, mouse reporting, kitty keyboard flags,
    /// scroll region, pen, …) before the new process starts writing below the divider. The divider goes below the
    /// last non-blank row of the old screen, wherever its cursor was: a TUI left mid-screen (omp with a dialog open
    /// below its editor) would otherwise keep rows below the divider, which the new program then paints over.
    private static func resetForRestart(_ mirror: TerminalMirror) {
        if mirror.terminal.isCurrentBufferAlternate { mirror.feed(Array("\u{1b}[?1049l".utf8)) }
        mirror.terminal.softReset()
        let modesOff = [5, 9, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004, 2026].map { "\u{1b}[?\($0)l" }.joined()
        var reset = modesOff + "\u{1b}[<16u\u{1b}[0m"
        if let lastRow = mirror.lastNonBlankScreenRow, lastRow > mirror.terminal.getCursorLocation().y {
            reset += "\u{1b}[\(lastRow + 1);1H"
        }
        mirror.feed(Array((reset + restartDivider).utf8))
    }

    /// Scrolls the whole screen (the old screen down to the divider) into the scrollback: the new program's first
    /// paint erases the screen, not the scrollback.
    private static func pushScreenIntoHistory(_ mirror: TerminalMirror) {
        let linesAboveCursor = mirror.terminal.getCursorLocation().y
        guard linesAboveCursor > 0 else { return }
        mirror.feed(Array("\u{1b}[\(mirror.rows);1H\(String(repeating: "\n", count: linesAboveCursor))".utf8))
    }

    // MARK: - Helpers

    /// Follows `cd` in the shell: `info.cwd` is where a restored shell starts.
    private func refreshWorkingDirectory(_ pty: ManagedPTY) {
        guard pty.info.running, let pid = pty.info.pid, let cwd = PTYSpawner.currentDirectory(of: pid), cwd != pty.info.cwd else { return }
        pty.info.cwd = cwd
        markDirty(pty)
    }

    /// `env` (a terminal's own overrides) with the terminal environment of `ptyId` on top.
    private func terminalOverlay(_ ptyId: PTYID, over env: [String: String]?) async -> [String: String]? {
        guard let terminalEnvironment else { return env }
        return (env ?? [:]).merging(await terminalEnvironment(ptyId)) { _, new in new }
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
        if isFrozen { throw DaemonError(.internal, "ompd is upgrading; try again in a moment") }
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

/// How the program of a PTY ended.
public struct PTYExit: Sendable, Equatable, CustomStringConvertible {
    /// Exit status of a program that exited; nil when a signal killed it.
    public var code: Int32?
    /// The signal that killed the program; nil when it exited.
    public var signal: Int32?

    public init(code: Int32?, signal: Int32?) {
        self.code = code
        self.signal = signal
    }

    /// From a `waitpid` status (`WIFEXITED`/`WEXITSTATUS`, `WTERMSIG`).
    init(waitStatus status: Int32) {
        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 {
            self.init(code: (status >> 8) & 0xff, signal: nil)
        } else {
            self.init(code: nil, signal: terminatingSignal)
        }
    }

    public var description: String {
        if let signal { return "killed by signal \(signal) (\(String(cString: strsignal(signal))))" }
        return "exit code \(code ?? 0)"
    }
}

/// State of one PTY, confined to the pool.
private final class ManagedPTY {
    var info: PTYInfo
    /// Environment overrides written to snapshots (a plain terminal's `pty.open` env; nil for session PTYs).
    let persistedEnv: [String: String]?
    let mirror: TerminalMirror
    /// Creation order, for a stable `list()`.
    let sequence: UInt64
    /// Nil once the tty hung up (all processes holding it are gone) or the PTY was closed.
    var channel: MasterChannel?
    var reaper: ChildReaper?
    var subscribers: [UUID: @Sendable (Data) -> Void] = [:]
    /// Session PTYs: the supervisor's exit callback, taken when the program exits.
    var onExit: (@Sendable (PTYExit) -> Void)?
    /// A session PTY continuing a previous screen, until its program's first scrollback erase went by.
    var historyGuard: ScrollbackEraseFilter?
    var dirty = true

    init(info: PTYInfo, persistedEnv: [String: String]?, mirror: TerminalMirror, sequence: UInt64) {
        self.info = info
        self.persistedEnv = persistedEnv
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

/// Drops the first "erase saved lines" (`CSI 3 J`) of a stream, holding back a trailing partial match until the next
/// chunk shows whether it completes.
struct ScrollbackEraseFilter {
    private static let sequence: [UInt8] = [0x1B, 0x5B, 0x33, 0x4A] // ESC [ 3 J
    private(set) var isDone = false
    private var held: [UInt8] = []

    /// `held`: what the filter of an earlier image held back (an in-place upgrade).
    init(holding held: [UInt8] = []) {
        self.held = held
    }

    /// What is held back now (the start of the sequence, until the next chunk shows whether it completes).
    var heldBytes: [UInt8] { held }

    /// `chunk` as it should be delivered.
    mutating func filter(_ chunk: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        guard !isDone else { return Array(chunk) }
        var bytes = held + chunk
        held = []
        if let match = bytes.firstRange(of: Self.sequence) {
            bytes.removeSubrange(match)
            isDone = true
            return bytes
        }
        for length in stride(from: min(Self.sequence.count - 1, bytes.count), to: 0, by: -1)
            where bytes.suffix(length).elementsEqual(Self.sequence.prefix(length))
        {
            held = Array(bytes.suffix(length))
            bytes.removeLast(length)
            break
        }
        return bytes
    }

    /// What is still held back (the stream ended mid-sequence).
    mutating func remainder() -> [UInt8] {
        defer { held = [] }
        return held
    }
}

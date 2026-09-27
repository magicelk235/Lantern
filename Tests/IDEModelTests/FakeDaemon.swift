import Foundation
@testable import IDEModel
import IDETransport
import os

/// ompd on the real `IDEServer` + `IDERouter`: a manifest of omp sessions, each running its TUI on a PTY, and plain
/// terminal PTYs; a PTY is reduced to the bytes it printed.
///
/// Like ompd it pushes `ptys` whenever the PTY list changes and `sessions` whenever the manifest does, in ompd's order:
/// a new PTY is listed before the manifest names it, and a PTY the manifest no longer names goes after. `pty.attach`
/// answers with `screenMarker` + everything printed so far and subscribes the connection in the same step, as
/// `PTYPool` does, so each later `print` streams to it exactly once. Records what it was asked, in the order it took it.
final class FakeDaemon: IDERequestHandler {
    static let screenMarker = Data("<screen>".utf8)
    /// Printed where a respawned TUI's PTY continues the previous one's scrollback.
    static let restartDivider = "— terminal restarted —\r\n"

    let router = IDERouter()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let target = OSAllocatedUnfairLock(initialState: PushTarget())

    private struct PushTarget: Sendable {
        weak var server: IDEServer?
    }

    private struct PTY: Sendable {
        var info: PTYInfo
        var output = Data()
        var subscribers: [IDEConnection] = []
    }

    private struct State: Sendable {
        var sessions: [SessionManifestEntry] = []
        var ptys: [PTYID: PTY] = [:]
        var order: [PTYID] = []
        var ptysMade = 0
        var sessionsMade = 0
        /// `attach <id>`, `detach <id>`, `close <id>` as they took effect.
        var lifecycle: [String] = []
        var writes: [PTYWrite.Params] = []
        var writesInFlight = 0
        var maxWritesInFlight = 0
        var resizes: [PTYResize.Params] = []
        var lists = 0
        var creates: [SessionCreate.Params] = []
        var opens: [SessionOpen.Params] = []
        var closes: [SessionKey] = []
        /// Printed by the next `pty.attach` after it subscribed and before it answers: output that overtakes the response.
        var printDuringAttach: [Data] = []
        /// How long each `pty.write` takes, picked at random: concurrent writes would finish out of order.
        var writeDelay: ClosedRange<Int> = 0 ... 0
        /// How long `pty.attach` takes before it subscribes.
        var attachDelay = 0
        /// `pty.attach` requests received, including those still waiting out `attachDelay`.
        var attachRequests = 0
        /// How long `pty.list` takes after it looked at the PTYs.
        var listDelay = 0
    }

    init() {
        let (state, target) = (state, target)
        router.on(PTYOpen.self) { params, _ in
            state.withLock { s in
                let info = Self.makePTY(
                    &s, cwd: params.cwd, command: params.command ?? ["/bin/zsh", "-l"],
                    size: TerminalSize(cols: params.cols, rows: params.rows))
                Self.pushPTYs(s, target)
                return info
            }
        }
        router.on(PTYAttach.self) { params, connection in
            let delay = state.withLock { s in
                s.attachRequests += 1
                return s.attachDelay
            }
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            return try state.withLock { s in
                guard var pty = s.ptys[params.ptyId] else { throw DaemonError(.noSuchPTY, "no such PTY: \(params.ptyId)") }
                let result = PTYAttach.Result(info: pty.info, screen: Self.screenMarker + pty.output)
                if !pty.subscribers.contains(connection) { pty.subscribers.append(connection) }
                s.lifecycle.append("attach \(params.ptyId)")
                for chunk in s.printDuringAttach {
                    pty.output.append(chunk)
                    connection.send(.ptyOutput(PTYOutput(ptyId: params.ptyId, data: chunk)))
                }
                s.printDuringAttach = []
                s.ptys[params.ptyId] = pty
                return result
            }
        }
        router.on(PTYDetach.self) { params, connection in
            try state.withLock { s in
                guard s.ptys[params.ptyId] != nil else { throw DaemonError(.noSuchPTY, "no such PTY: \(params.ptyId)") }
                s.ptys[params.ptyId]?.subscribers.removeAll { $0 == connection }
                s.lifecycle.append("detach \(params.ptyId)")
            }
            return Empty()
        }
        router.on(PTYWrite.self) { params, _ in
            let delay = state.withLock { s in
                s.writesInFlight += 1
                s.maxWritesInFlight = max(s.maxWritesInFlight, s.writesInFlight)
                return Int.random(in: s.writeDelay)
            }
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            try state.withLock { s in
                s.writesInFlight -= 1
                guard s.ptys[params.ptyId] != nil else { throw DaemonError(.noSuchPTY, "no such PTY: \(params.ptyId)") }
                s.writes.append(params)
            }
            return Empty()
        }
        router.on(PTYResize.self) { params, _ in
            try state.withLock { s in
                guard s.ptys[params.ptyId] != nil else { throw DaemonError(.noSuchPTY, "no such PTY: \(params.ptyId)") }
                s.ptys[params.ptyId]?.info.cols = params.cols
                s.ptys[params.ptyId]?.info.rows = params.rows
                s.resizes.append(params)
                Self.pushPTYs(s, target)
            }
            return Empty()
        }
        router.on(PTYClose.self) { params, _ in
            try state.withLock { s in
                guard s.ptys[params.ptyId] != nil else { throw DaemonError(.noSuchPTY, "no such PTY: \(params.ptyId)") }
                Self.removePTY(&s, params.ptyId)
                s.lifecycle.append("close \(params.ptyId)")
                Self.pushPTYs(s, target)
            }
            return Empty()
        }
        router.on(PTYList.self) { _, _ in
            let (result, delay) = state.withLock { s in
                s.lists += 1
                return (PTYList.Result(ptys: s.order.compactMap { s.ptys[$0]?.info }), s.listDelay)
            }
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            return result
        }
        router.on(SessionCreate.self) { params, _ in
            state.withLock { s in
                s.creates.append(params)
                return Self.startSession(
                    &s, target, workspace: params.workspace, approvalMode: params.approvalMode,
                    size: TerminalSize(cols: params.cols, rows: params.rows))
            }
        }
        router.on(SessionOpen.self) { params, _ in
            try state.withLock { s in
                s.opens.append(params)
                let size = TerminalSize(cols: params.cols, rows: params.rows)
                guard let index = s.sessions.firstIndex(where: { $0.sessionFile == params.sessionFile }) else {
                    return Self.startSession(&s, target, workspace: params.workspace, approvalMode: nil, size: size)
                }
                guard s.sessions[index].status == .closed else { throw DaemonError(.sessionBusy, "the session is running") }
                return Self.moveSession(&s, target, at: index, size: size) { $0.closedByUser = false }
            }
        }
        router.on(SessionClose.self) { params, _ in
            try state.withLock { s in
                guard let index = s.sessions.firstIndex(where: { $0.sessionKey == params.sessionKey }) else {
                    throw DaemonError(.noSuchSession, "no such session: \(params.sessionKey)")
                }
                s.closes.append(params.sessionKey)
                let ptyId = s.sessions[index].ptyId
                s.sessions[index].status = .closed
                s.sessions[index].closedByUser = true
                s.sessions[index].ptyId = nil
                Self.pushSessions(s, target)
                if let ptyId {
                    Self.removePTY(&s, ptyId)
                    Self.pushPTYs(s, target)
                }
            }
            return Empty()
        }
        router.on(ListSessions.self) { _, _ in
            state.withLock { SessionList(sessions: $0.sessions) }
        }
    }

    /// Pushes go to the clients of `server`.
    func serve(on server: IDEServer) {
        target.withLock { $0.server = server }
    }

    // MARK: - Terminals

    /// Adds a running terminal that already printed `output`.
    func addPTY(_ ptyId: PTYID, cwd: String = "/tmp", output: String = "", size: TerminalSize = .standard) {
        state.withLock { s in
            let info = PTYInfo(ptyId: ptyId, cwd: cwd, command: ["/bin/zsh", "-l"], cols: size.cols, rows: size.rows, pid: 4242, running: true)
            s.ptys[ptyId] = PTY(info: info, output: Data(output.utf8))
            s.order.append(ptyId)
            Self.pushPTYs(s, target)
        }
    }

    /// The PTY prints `text`: recorded, and streamed to its subscribers.
    func print(_ text: String, on ptyId: PTYID) {
        state.withLock { s in
            guard var pty = s.ptys[ptyId] else { return }
            let chunk = Data(text.utf8)
            pty.output.append(chunk)
            for connection in pty.subscribers { connection.send(.ptyOutput(PTYOutput(ptyId: ptyId, data: chunk))) }
            s.ptys[ptyId] = pty
        }
    }

    func printDuringNextAttach(_ chunks: [String]) {
        state.withLock { $0.printDuringAttach = chunks.map { Data($0.utf8) } }
    }

    /// The PTY's program ends; ompd keeps the PTY so its last screen stays readable.
    func exit(_ ptyId: PTYID) {
        state.withLock { s in
            s.ptys[ptyId]?.info.running = false
            s.ptys[ptyId]?.info.pid = nil
            Self.pushPTYs(s, target)
        }
    }

    /// ompd loses the PTY without anyone closing it.
    func forget(_ ptyId: PTYID) {
        state.withLock { s in
            Self.removePTY(&s, ptyId)
            Self.pushPTYs(s, target)
        }
    }

    // MARK: - Sessions

    /// Adds a session whose TUI runs on PTY `ptyId` and already printed `output`.
    func addSession(
        _ sessionKey: SessionKey, ptyId: PTYID, workspace: String = "/tmp/workspace", output: String = "",
        size: TerminalSize = .standard
    ) {
        state.withLock { s in
            let info = PTYInfo(
                ptyId: ptyId, cwd: workspace, command: ["/opt/homebrew/bin/omp"], cols: size.cols, rows: size.rows, pid: 4343,
                running: true, sessionKey: sessionKey)
            s.ptys[ptyId] = PTY(info: info, output: Data(output.utf8))
            s.order.append(ptyId)
            Self.pushPTYs(s, target)
            s.sessions.append(manifestEntry(sessionKey, workspace: workspace, status: .idle, ptyId: ptyId))
            Self.pushSessions(s, target)
        }
    }

    /// omp crashes and ompd resumes it on a new PTY, `size` big, that continues the old one's scrollback. Returns the
    /// new PTY.
    @discardableResult
    func crashAndRespawn(_ sessionKey: SessionKey, size: TerminalSize = .standard) -> PTYID? {
        state.withLock { s in
            guard let index = s.sessions.firstIndex(where: { $0.sessionKey == sessionKey }), let ptyId = s.sessions[index].ptyId
            else { return nil }
            s.ptys[ptyId]?.info.running = false
            Self.pushPTYs(s, target)
            s.sessions[index].status = .interrupted
            Self.pushSessions(s, target)
            return Self.moveSession(&s, target, at: index, size: size) { _ in }.ptyId
        }
    }

    /// omp quits from its TUI: the session is closed and its exited PTY stays, with the last screen.
    func quitFromTUI(_ sessionKey: SessionKey) {
        state.withLock { s in
            guard let index = s.sessions.firstIndex(where: { $0.sessionKey == sessionKey }) else { return }
            if let ptyId = s.sessions[index].ptyId {
                s.ptys[ptyId]?.info.running = false
                Self.pushPTYs(s, target)
            }
            s.sessions[index].status = .closed
            Self.pushSessions(s, target)
        }
    }

    /// The user resumed the session with `omp` in terminal `ptyId`: ompd adopted it there, and the PTY that kept the
    /// session's last screen (if any) went.
    func adopt(_ sessionKey: SessionKey, inTerminal ptyId: PTYID) {
        state.withLock { s in
            guard let index = s.sessions.firstIndex(where: { $0.sessionKey == sessionKey }) else { return }
            let old = s.sessions[index].ptyId
            s.sessions[index].status = .idle
            s.sessions[index].ptyId = ptyId
            s.sessions[index].adopted = true
            s.sessions[index].closedByUser = false
            Self.pushSessions(s, target)
            if let old, old != ptyId {
                Self.removePTY(&s, old)
                Self.pushPTYs(s, target)
            }
        }
    }

    /// The adopted omp exited in its terminal: the session is closed with no PTY of its own; the terminal stays.
    func adoptedOmpExits(_ sessionKey: SessionKey) {
        state.withLock { s in
            guard let index = s.sessions.firstIndex(where: { $0.sessionKey == sessionKey }) else { return }
            s.sessions[index].status = .closed
            s.sessions[index].ptyId = nil
            s.sessions[index].adopted = false
            Self.pushSessions(s, target)
        }
    }

    func setWriteDelay(milliseconds: ClosedRange<Int>) { state.withLock { $0.writeDelay = milliseconds } }
    func setAttachDelay(milliseconds: Int) { state.withLock { $0.attachDelay = milliseconds } }
    func setListDelay(milliseconds: Int) { state.withLock { $0.listDelay = milliseconds } }

    func output(of ptyId: PTYID) -> Data { state.withLock { $0.ptys[ptyId]?.output ?? Data() } }
    func entry(_ sessionKey: SessionKey) -> SessionManifestEntry? {
        state.withLock { s in s.sessions.first { $0.sessionKey == sessionKey } }
    }
    var ptyIDs: [PTYID] { state.withLock { $0.order } }
    var lifecycle: [String] { state.withLock { $0.lifecycle } }
    var writes: [Data] { state.withLock { $0.writes.map(\.data) } }
    var written: Data { state.withLock { $0.writes.reduce(Data()) { $0 + $1.data } } }
    func written(to ptyId: PTYID) -> Data {
        state.withLock { $0.writes.filter { $0.ptyId == ptyId }.reduce(Data()) { $0 + $1.data } }
    }
    var maxWritesInFlight: Int { state.withLock { $0.maxWritesInFlight } }
    var resizes: [PTYResize.Params] { state.withLock { $0.resizes } }
    var lists: Int { state.withLock { $0.lists } }
    var attachRequests: Int { state.withLock { $0.attachRequests } }
    var creates: [SessionCreate.Params] { state.withLock { $0.creates } }
    var opens: [SessionOpen.Params] { state.withLock { $0.opens } }
    var closes: [SessionKey] { state.withLock { $0.closes } }

    // MARK: - IDERequestHandler

    func sessionsForWelcome() async -> [SessionManifestEntry] { state.withLock { $0.sessions } }

    func handle(_ request: Request, from connection: IDEConnection) async -> Response {
        await router.route(request, from: connection)
    }

    func connectionClosed(_ connection: IDEConnection) async {
        state.withLock { s in
            for ptyId in s.ptys.keys { s.ptys[ptyId]?.subscribers.removeAll { $0 == connection } }
        }
    }

    // MARK: - Under the lock

    private static func makePTY(
        _ s: inout State, cwd: String, command: [String], size: TerminalSize, sessionKey: SessionKey? = nil, output: Data = Data()
    ) -> PTYInfo {
        s.ptysMade += 1
        // Tests name the PTYs they add (`p1`, `tui-1`); the ones ompd makes are `pty-<n>`.
        let info = PTYInfo(
            ptyId: "pty-\(s.ptysMade)", cwd: cwd, command: command, cols: size.cols, rows: size.rows, pid: 4242,
            running: true, sessionKey: sessionKey)
        s.ptys[info.ptyId] = PTY(info: info, output: output)
        s.order.append(info.ptyId)
        return info
    }

    private static func removePTY(_ s: inout State, _ ptyId: PTYID) {
        s.ptys[ptyId] = nil
        s.order.removeAll { $0 == ptyId }
    }

    /// A new session whose TUI prints a banner on a new PTY.
    private static func startSession(
        _ s: inout State, _ target: OSAllocatedUnfairLock<PushTarget>, workspace: String, approvalMode: String?, size: TerminalSize
    ) -> SessionManifestEntry {
        s.sessionsMade += 1
        let sessionKey = "created-\(s.sessionsMade)"
        let pty = makePTY(
            &s, cwd: workspace, command: ["/opt/homebrew/bin/omp"], size: size, sessionKey: sessionKey,
            output: Data("omp \(sessionKey) \(size.cols)x\(size.rows)\r\n".utf8))
        pushPTYs(s, target)
        var entry = manifestEntry(sessionKey, workspace: workspace, status: .starting, ptyId: pty.ptyId)
        entry.launch.approvalMode = approvalMode
        s.sessions.append(entry)
        pushSessions(s, target)
        return entry
    }

    /// omp starts again for session `index` on a new PTY that continues the previous one's scrollback; ompd lists the new
    /// PTY, names it in the manifest, then drops the old one.
    private static func moveSession(
        _ s: inout State, _ target: OSAllocatedUnfairLock<PushTarget>, at index: Int, size: TerminalSize,
        _ change: (inout SessionManifestEntry) -> Void
    ) -> SessionManifestEntry {
        let old = s.sessions[index].ptyId
        let scrollback = old.flatMap { s.ptys[$0]?.output } ?? Data()
        let pty = makePTY(
            &s, cwd: s.sessions[index].workspace, command: ["/opt/homebrew/bin/omp", "--resume"], size: size,
            sessionKey: s.sessions[index].sessionKey, output: scrollback + Data(restartDivider.utf8))
        pushPTYs(s, target)
        s.sessions[index].ptyId = pty.ptyId
        s.sessions[index].status = .idle
        change(&s.sessions[index])
        pushSessions(s, target)
        if let old {
            removePTY(&s, old)
            pushPTYs(s, target)
        }
        return s.sessions[index]
    }

    private static func pushPTYs(_ s: State, _ target: OSAllocatedUnfairLock<PushTarget>) {
        target.withLock { $0.server }?.broadcast(.ptys(PTYList.Result(ptys: s.order.compactMap { s.ptys[$0]?.info })))
    }

    private static func pushSessions(_ s: State, _ target: OSAllocatedUnfairLock<PushTarget>) {
        target.withLock { $0.server }?.broadcast(.sessions(SessionList(sessions: s.sessions)))
    }
}

// MARK: - Display double

/// Records what a terminal or session shows.
@MainActor
final class RecordingDisplay: TerminalDisplay {
    private(set) var resets: [TerminalSize] = []
    /// The screen of the last reset (without `FakeDaemon.screenMarker`) followed by everything fed since.
    private(set) var shown = Data()
    /// Calls that break the `TerminalDisplay` contract.
    private(set) var violations: [String] = []

    func reset(size: TerminalSize, screen: Data) {
        resets.append(size)
        if !screen.starts(with: FakeDaemon.screenMarker) { violations.append("reset without ompd's screen") }
        shown = screen.dropFirst(FakeDaemon.screenMarker.count)
    }

    func feed(_ data: Data) {
        if resets.isEmpty { violations.append("output before the screen") }
        shown.append(data)
    }

    var text: String { String(decoding: shown, as: UTF8.self) }
}

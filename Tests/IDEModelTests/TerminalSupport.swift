import Foundation
@testable import IDEModel
import IDETransport
import os

// MARK: - In-process PTY daemon

/// ompd's PTY methods on the real `IDEServer` + `IDERouter`, with a PTY reduced to the bytes it printed. `pty.attach`
/// answers with `screenMarker` + everything printed so far and subscribes the connection in the same step, as
/// `PTYPool` does, so each later `emit` streams to it exactly once. Records what it was asked, in the order it took it.
final class FakePTYDaemon: IDERequestHandler {
    static let screenMarker = Data("<screen>".utf8)

    let router = IDERouter()
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct PTY: Sendable {
        var info: PTYInfo
        var output = Data()
        var subscribers: [IDEConnection] = []
    }

    private struct State: Sendable {
        var ptys: [PTYID: PTY] = [:]
        var order: [PTYID] = []
        /// `attach <id>`, `detach <id>`, `close <id>` as they took effect.
        var lifecycle: [String] = []
        var writes: [Data] = []
        var writesInFlight = 0
        var maxWritesInFlight = 0
        var resizes: [PTYResize.Params] = []
        var lists = 0
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
        let state = state
        router.on(PTYOpen.self) { params, _ in
            state.withLock { s in
                let info = PTYInfo(
                    ptyId: "opened-\(s.order.count + 1)", cwd: params.cwd, command: params.command ?? ["/bin/zsh", "-l"],
                    cols: params.cols, rows: params.rows, pid: 4242, running: true)
                s.ptys[info.ptyId] = PTY(info: info)
                s.order.append(info.ptyId)
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
            state.withLock { s in
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
                s.writes.append(params.data)
            }
            return Empty()
        }
        router.on(PTYResize.self) { params, _ in
            try state.withLock { s in
                guard s.ptys[params.ptyId] != nil else { throw DaemonError(.noSuchPTY, "no such PTY: \(params.ptyId)") }
                s.ptys[params.ptyId]?.info.cols = params.cols
                s.ptys[params.ptyId]?.info.rows = params.rows
                s.resizes.append(params)
            }
            return Empty()
        }
        router.on(PTYClose.self) { params, _ in
            try state.withLock { s in
                guard s.ptys.removeValue(forKey: params.ptyId) != nil else {
                    throw DaemonError(.noSuchPTY, "no such PTY: \(params.ptyId)")
                }
                s.order.removeAll { $0 == params.ptyId }
                s.lifecycle.append("close \(params.ptyId)")
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
    }

    /// Adds a running PTY that already printed `output`.
    func addPTY(_ ptyId: PTYID, cwd: String = "/tmp", output: String = "", size: TerminalSize = .standard) {
        state.withLock { s in
            let info = PTYInfo(ptyId: ptyId, cwd: cwd, command: ["/bin/zsh", "-l"], cols: size.cols, rows: size.rows, pid: 4242, running: true)
            s.ptys[ptyId] = PTY(info: info, output: Data(output.utf8))
            s.order.append(ptyId)
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

    func exit(_ ptyId: PTYID) {
        state.withLock { s in
            s.ptys[ptyId]?.info.running = false
            s.ptys[ptyId]?.info.pid = nil
        }
    }

    /// ompd loses the PTY without anyone closing it (a daemon restart that could not bring it back).
    func forget(_ ptyId: PTYID) {
        state.withLock { s in
            s.ptys[ptyId] = nil
            s.order.removeAll { $0 == ptyId }
        }
    }

    func setWriteDelay(milliseconds: ClosedRange<Int>) { state.withLock { $0.writeDelay = milliseconds } }
    func setAttachDelay(milliseconds: Int) { state.withLock { $0.attachDelay = milliseconds } }
    func setListDelay(milliseconds: Int) { state.withLock { $0.listDelay = milliseconds } }

    func output(of ptyId: PTYID) -> Data { state.withLock { $0.ptys[ptyId]?.output ?? Data() } }
    var lifecycle: [String] { state.withLock { $0.lifecycle } }
    var writes: [Data] { state.withLock { $0.writes } }
    var written: Data { state.withLock { $0.writes.reduce(Data(), +) } }
    var maxWritesInFlight: Int { state.withLock { $0.maxWritesInFlight } }
    var resizes: [PTYResize.Params] { state.withLock { $0.resizes } }
    var lists: Int { state.withLock { $0.lists } }
    var attachRequests: Int { state.withLock { $0.attachRequests } }

    func sessionsForWelcome() async -> [SessionManifestEntry] { [] }

    func handle(_ request: Request, from connection: IDEConnection) async -> Response {
        await router.route(request, from: connection)
    }

    func connectionClosed(_ connection: IDEConnection) async {
        state.withLock { s in
            for ptyId in s.ptys.keys { s.ptys[ptyId]?.subscribers.removeAll { $0 == connection } }
        }
    }
}

extension TempHome {
    func startServer(_ daemon: FakePTYDaemon, startedAt: Date = testDate) async throws -> IDEServer {
        let server = IDEServer(
            socketPath: paths.socket.path(percentEncoded: false), token: Self.token, daemonVersion: "fake-ompd",
            startedAt: startedAt, handler: daemon)
        try await server.start()
        return server
    }
}

// MARK: - Display double

/// Records what a terminal model shows.
@MainActor
final class RecordingDisplay: TerminalDisplay {
    private(set) var resets: [TerminalSize] = []
    /// The screen of the last reset (without `FakePTYDaemon.screenMarker`) followed by everything fed since.
    private(set) var shown = Data()
    /// Calls that break the `TerminalDisplay` contract.
    private(set) var violations: [String] = []

    func reset(size: TerminalSize, screen: Data) {
        resets.append(size)
        if !screen.starts(with: FakePTYDaemon.screenMarker) { violations.append("reset without ompd's screen") }
        shown = screen.dropFirst(FakePTYDaemon.screenMarker.count)
    }

    func feed(_ data: Data) {
        if resets.isEmpty { violations.append("output before the screen") }
        shown.append(data)
    }

    var text: String { String(decoding: shown, as: UTF8.self) }
}

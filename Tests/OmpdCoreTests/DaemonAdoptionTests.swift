import Darwin
import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// `omp` typed into one of the IDE's terminals is adopted as a session: listed with the terminal's PTY, driven by its
/// bridge like a spawned omp, paused by the same policy, closed when it exits — while the terminal stays a terminal.
/// The fake omp runs inside a `/bin/sh` on a terminal PTY (as behind a real shell prompt); the scripted bridge plays
/// its terminal-mode hello, and its event stream ends when the process is gone.
@Suite(.timeLimit(.minutes(2)))
struct DaemonAdoptionTests {
    /// A terminal whose shell ran the fake omp, which is running and waiting for input.
    private struct TerminalOmp {
        let pty: PTYInfo
        let pid: Int32
        let file: String
    }

    /// Opens a terminal in the workspace whose shell runs the fake omp, then falls back to the prompt (`shell-back`).
    private func openTerminalRunningOmp(_ fixture: DaemonFixture, _ connected: Connected) async throws -> TerminalOmp {
        let before = fixture.omp.startedPIDs()
        let pty = try await connected.client.call(
            PTYOpen.self,
            .init(
                cwd: fixture.workspace, command: ["/bin/sh", "-c", "\"$0\"; printf 'shell-back\\n'; exec cat", fixture.omp.executable],
                env: ["FAKE_OMP_DIR": fixture.omp.environment["FAKE_OMP_DIR"] ?? ""], cols: 80, rows: 24))
        _ = try await connected.client.call(PTYAttach.self, .init(ptyId: pty.ptyId))
        let omp = fixture.omp
        let pid = try await eventuallyValue("the fake omp in the terminal") { omp.startedPIDs().subtracting(before).first }
        let file = try #require(omp.sessionFile(of: pid))
        return TerminalOmp(pty: pty, pid: pid, file: file)
    }

    private func adopted(_ connected: Connected, on ptyId: PTYID) async throws -> SessionManifestEntry {
        try await eventuallyValue("the adopted session of terminal \(ptyId)") {
            try await connected.client.call(ListSessions.self, Empty()).sessions.first { $0.adopted && $0.ptyId == ptyId }
        }
    }

    @Test func anOmpTypedIntoATerminalIsAdoptedAsASessionUntilItExits() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .milliseconds(300))
        let window = try await fixture.client()
        let status = try await fixture.client(.cli)
        let terminal = try await openTerminalRunningOmp(fixture, window)

        // The terminal's shell got what an omp needs to reach ompd: no session key, the terminal's own credentials.
        let environment = fixture.omp.environment(of: terminal.pid)
        #expect(environment["LANTERN_BRIDGE_SOCK"] == "/fake/bridge.sock")
        #expect(environment["LANTERN_TERMINAL_PTY"] == terminal.pty.ptyId)
        #expect(environment["LANTERN_TERMINAL_TOKEN"]?.count == 64)
        #expect(environment["LANTERN_DAEMON_PID"] == String(getpid()))
        #expect(environment["LANTERN_SESSION_KEY"] == ProcessInfo.processInfo.environment["LANTERN_SESSION_KEY"])
        #expect(await fixture.bridge.terminals == [terminal.pty.ptyId])

        await fixture.bridge.terminalOmpSaysHello(
            ptyId: terminal.pty.ptyId, pid: terminal.pid, sessionFile: terminal.file, cwd: fixture.workspace, title: "from the shell")
        let entry = try await adopted(window, on: terminal.pty.ptyId)
        #expect(entry.status == .idle && entry.title == "from the shell" && !entry.closedByUser)
        #expect(entry.workspace == (try Daemon.canonicalDirectory(fixture.workspace)))
        #expect(entry.sessionFile == terminal.file && entry.sessionId == "terminal-session")
        #expect(entry.launch.ompPath == fixture.omp.executable && entry.launch.extraArgs == ["--thinking", "off"])
        #expect(await fixture.bridge.adoptions.map(\.sessionKey) == [entry.sessionKey])
        #expect(fixture.locks.held.contains(terminal.file))
        // The PTY is still a plain terminal to every client.
        let listed = try await window.client.call(PTYList.self, Empty()).ptys
        #expect(listed.map(\.ptyId) == [terminal.pty.ptyId] && listed.first?.sessionKey == nil && listed.first?.running == true)

        // The bridge drives it like a spawned omp's.
        await fixture.bridge.push("activity", ["state": "busy"], to: entry.sessionKey)
        try await window.waitForStatus(entry.sessionKey, .busy)
        await fixture.bridge.push("title", ["title": "renamed by omp"], to: entry.sessionKey)
        try await eventually("the title") { try await window.entry(entry.sessionKey).title == "renamed by omp" }

        // No window: paused like every session; a window back: resumed to what it was doing.
        await window.close()
        try await status.waitForStatus(entry.sessionKey, .paused)
        #expect(await fixture.bridge.pausedBy(entry.sessionKey) == .daemon)
        let reopened = try await fixture.client()
        try await reopened.waitForStatus(entry.sessionKey, .busy)
        #expect(await fixture.bridge.calls == ["session.pause", "session.resume"])

        // The user quits omp in the terminal: the session is closed, the terminal is back at its prompt.
        _ = try await reopened.client.call(PTYAttach.self, .init(ptyId: terminal.pty.ptyId))
        _ = try await reopened.client.call(PTYWrite.self, .init(ptyId: terminal.pty.ptyId, data: Data("exit\n".utf8)))
        try await reopened.waitForStatus(entry.sessionKey, .closed)
        let closed = try await reopened.entry(entry.sessionKey)
        #expect(!closed.adopted && closed.ptyId == nil && !closed.closedByUser && closed.title == "renamed by omp")
        #expect(FakeOmp.sessionExits(terminal.file) == ["normal"])
        #expect(!fixture.locks.held.contains(terminal.file))
        try await eventually("the shell prompt again") { reopened.output(terminal.pty.ptyId).contains("shell-back") }
        #expect(try await reopened.client.call(PTYList.self, Empty()).ptys.first.map { $0.ptyId == terminal.pty.ptyId && $0.running } == true)
        #expect(reopened.pushes.contains { if case .notice(let n) = $0 { n.sessionKey == entry.sessionKey && n.level == "info" } else { false } })

        // Resume starts omp for it in a session PTY of its own, as for any closed session.
        let resumed = try await reopened.client.call(
            SessionOpen.self, .init(sessionFile: terminal.file, workspace: fixture.workspace, cols: 80, rows: 24))
        #expect(resumed.sessionKey == entry.sessionKey && !resumed.adopted && resumed.ptyId != nil && resumed.ptyId != terminal.pty.ptyId)
        try await reopened.waitForStatus(entry.sessionKey, .idle)
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(terminal.file)") == true)
        #expect(try await reopened.client.call(PTYList.self, Empty()).ptys.map(\.sessionKey) == [nil, entry.sessionKey])
        await status.close()
        await reopened.close()
        await fixture.daemon.shutdown()
    }

    @Test func helloesThatCannotBecomeASessionAreRefused() async throws {
        let fixture = try await DaemonFixture()
        let window = try await fixture.client()
        let terminal = try await openTerminalRunningOmp(fixture, window)
        let running = try await fixture.createSession(window)
        try await window.waitForStatus(running.sessionKey, .idle)
        let ownedFile = try #require(try await window.entry(running.sessionKey).sessionFile)
        let exited = try await window.client.call(
            PTYOpen.self, .init(cwd: fixture.workspace, command: ["/bin/sh", "-c", "exit 0"], cols: 80, rows: 24))
        try await eventually("the exited terminal") {
            try await window.client.call(PTYList.self, Empty()).ptys.first { $0.ptyId == exited.ptyId }?.running == false
        }

        // Not a running plain terminal: unknown, exited, or a session's own PTY.
        for ptyId in ["no-such-pty", exited.ptyId, try #require(running.ptyId)] {
            await fixture.bridge.terminalOmpSaysHello(ptyId: ptyId, pid: terminal.pid, sessionFile: terminal.file, cwd: fixture.workspace)
        }
        try await eventually("three refusals") { await fixture.bridge.refusals.count == 3 }
        #expect(await fixture.bridge.refusals.allSatisfy { $0.reason.contains("not a running terminal") })

        // A file another session serves right now: the existing busy semantics, nothing created.
        await fixture.bridge.terminalOmpSaysHello(ptyId: terminal.pty.ptyId, pid: terminal.pid, sessionFile: ownedFile, cwd: fixture.workspace)
        try await eventually("the owned file refused") { await fixture.bridge.refusals.count == 4 }
        #expect(await fixture.bridge.refusals.last?.reason.contains("session \(running.sessionKey) is already open") == true)
        #expect(try await window.client.call(ListSessions.self, Empty()).sessions.map(\.sessionKey) == [running.sessionKey])
        #expect(try await window.entry(running.sessionKey).status == .idle)

        // Adopted; a second omp in the same terminal (one the adopted omp started) is refused.
        await fixture.bridge.terminalOmpSaysHello(ptyId: terminal.pty.ptyId, pid: terminal.pid, sessionFile: terminal.file, cwd: fixture.workspace)
        let entry = try await adopted(window, on: terminal.pty.ptyId)
        await fixture.bridge.terminalOmpSaysHello(ptyId: terminal.pty.ptyId, pid: terminal.pid + 1, sessionFile: "/tmp/nested.jsonl", cwd: fixture.workspace)
        try await eventually("the nested omp refused") { await fixture.bridge.refusals.count == 5 }
        #expect(await fixture.bridge.refusals.last?.reason.contains("already runs omp session \(entry.sessionKey)") == true)
        #expect(await fixture.bridge.adoptions.count == 1)

        // The file of a session whose omp is not running is resumed in that session, under its key.
        _ = try await window.client.call(SessionClose.self, .init(sessionKey: running.sessionKey))
        #expect(try await window.entry(running.sessionKey).status == .closed)
        let second = try await openTerminalRunningOmp(fixture, window)
        await fixture.bridge.terminalOmpSaysHello(ptyId: second.pty.ptyId, pid: second.pid, sessionFile: ownedFile, cwd: fixture.workspace)
        let continued = try await adopted(window, on: second.pty.ptyId)
        #expect(continued.sessionKey == running.sessionKey && continued.status == .idle && !continued.closedByUser)
        #expect(try await window.client.call(ListSessions.self, Empty()).sessions.count == 2)
        #expect(fixture.locks.held.contains(ownedFile))
        await window.close()
        await fixture.daemon.shutdown()
    }

    @Test func closeSessionStopsTheAdoptedOmpThroughTheBridgeAndKeepsTheTerminal() async throws {
        let fixture = try await DaemonFixture()
        let window = try await fixture.client()
        let terminal = try await openTerminalRunningOmp(fixture, window)
        await fixture.bridge.terminalOmpSaysHello(ptyId: terminal.pty.ptyId, pid: terminal.pid, sessionFile: terminal.file, cwd: fixture.workspace)
        let entry = try await adopted(window, on: terminal.pty.ptyId)
        let busy = await #expect(throws: DaemonError.self) { try await window.client.call(SessionForget.self, .init(sessionKey: entry.sessionKey)) }
        #expect(busy?.code == .sessionBusy)

        _ = try await window.client.call(SessionClose.self, .init(sessionKey: entry.sessionKey))
        let closed = try await window.entry(entry.sessionKey)
        #expect(closed.status == .closed && closed.closedByUser && closed.ptyId == nil && !closed.adopted)
        #expect(fixture.omp.lines("events") == ["graceful"])
        #expect(FakeOmp.sessionExits(terminal.file) == ["normal"])
        #expect(!fixture.locks.held.contains(terminal.file))
        try await eventually("the shell prompt again") { window.output(terminal.pty.ptyId).contains("shell-back") }
        let listed = try await window.client.call(PTYList.self, Empty()).ptys
        #expect(listed.map(\.ptyId) == [terminal.pty.ptyId] && listed.first?.running == true)

        _ = try await window.client.call(SessionForget.self, .init(sessionKey: entry.sessionKey))
        #expect(try await window.client.call(ListSessions.self, Empty()).sessions.isEmpty)
        #expect(try await window.client.call(PTYList.self, Empty()).ptys.map(\.ptyId) == [terminal.pty.ptyId])
        _ = try await window.client.call(PTYClose.self, .init(ptyId: terminal.pty.ptyId))
        try await eventually("the terminal's credentials void") { await fixture.bridge.terminals.isEmpty }
        await window.close()
        await fixture.daemon.shutdown()
    }

    @Test func closingTheTerminalEndsOmpAndClosesTheSession() async throws {
        let fixture = try await DaemonFixture()
        let window = try await fixture.client()
        let terminal = try await openTerminalRunningOmp(fixture, window)
        await fixture.bridge.terminalOmpSaysHello(ptyId: terminal.pty.ptyId, pid: terminal.pid, sessionFile: terminal.file, cwd: fixture.workspace)
        let entry = try await adopted(window, on: terminal.pty.ptyId)

        _ = try await window.client.call(PTYClose.self, .init(ptyId: terminal.pty.ptyId))
        try await window.waitForStatus(entry.sessionKey, .closed)
        let closed = try await window.entry(entry.sessionKey)
        #expect(closed.ptyId == nil && !closed.adopted && !closed.closedByUser)
        #expect(Set(FakeOmp.sessionExits(terminal.file)) == ["signal"], "the fake's trap may record the tty hangup and the group signal")
        #expect(try await window.client.call(PTYList.self, Empty()).ptys.isEmpty)
        await window.close()
        await fixture.daemon.shutdown()
    }

    @Test func aDaemonRestartResumesAnAdoptedSessionInASessionPTY() async throws {
        let fixture = try await DaemonFixture()
        let window = try await fixture.client()
        let terminal = try await openTerminalRunningOmp(fixture, window)
        await fixture.bridge.terminalOmpSaysHello(ptyId: terminal.pty.ptyId, pid: terminal.pid, sessionFile: terminal.file, cwd: fixture.workspace)
        let entry = try await adopted(window, on: terminal.pty.ptyId)
        await window.close()
        await fixture.daemon.shutdown()
        // Stopped through the bridge, not closed by anyone: the manifest keeps it as an open session.
        #expect(fixture.omp.lines("events") == ["graceful"])
        let onDisk = try #require(try fixture.manifestOnDisk().sessions.first { $0.sessionKey == entry.sessionKey })
        #expect(onDisk.status == .idle && onDisk.adopted && onDisk.ptyId == terminal.pty.ptyId)

        let restarted = try await fixture.restarted()
        let again = try await restarted.client()
        let stale = try #require(again.welcome.sessions.first { $0.sessionKey == entry.sessionKey })
        #expect(stale.status == .interrupted && stale.ptyId == nil && !stale.adopted)
        await restarted.daemon.restore()
        try await again.waitForStatus(entry.sessionKey, .idle)
        let resumed = try await again.entry(entry.sessionKey)
        #expect(!resumed.adopted && resumed.ptyId != nil && resumed.ptyId != terminal.pty.ptyId)
        #expect(fixture.omp.lines("argv").contains { $0.contains("--resume \(terminal.file)") })
        // The terminal came back as a shell of its own, with fresh credentials.
        let terminals = try await again.client.call(PTYList.self, Empty()).ptys.filter { $0.sessionKey == nil }
        #expect(terminals.map(\.ptyId) == [terminal.pty.ptyId])
        #expect(await restarted.bridge.terminals == [terminal.pty.ptyId])
        await again.close()
        await restarted.daemon.shutdown()
    }
}

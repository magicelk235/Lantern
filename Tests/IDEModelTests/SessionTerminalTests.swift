import Foundation
@testable import IDEModel
import IDETransport
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionTerminalTests {
    @Test func theTabFollowsOmpToItsNewPTYAfterACrash() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addSession("s1", ptyId: "tui-1", output: "omp> first prompt\r\n")
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let session = connection.open("s1")
        let display = RecordingDisplay()
        let view = TerminalSize(cols: 100, rows: 30)
        session.resize(view)
        session.attach(to: display)
        try await eventually("omp's screen") { session.isLive && display.shown == daemon.output(of: "tui-1") }
        session.send(Data("a".utf8))
        try await eventually("typed into the first TUI") { daemon.written(to: "tui-1") == Data("a".utf8) }

        // omp dies; ompd starts it again on a new PTY (at its default size) that continues the scrollback.
        let respawned = try #require(daemon.crashAndRespawn("s1", size: .standard))
        try await eventually("the new PTY's screen") {
            session.terminal?.ptyId == respawned && session.isLive && display.shown == daemon.output(of: respawned)
        }
        #expect(display.resets.count == 2, "the display starts over from the new PTY's screen")
        #expect(display.text.hasPrefix("omp> first prompt\r\n") && display.text.hasSuffix(FakeDaemon.restartDivider))
        try await eventually("the new TUI gets the view's size") { daemon.resizes.last == .init(ptyId: respawned, cols: 100, rows: 30) }

        daemon.print("omp> resumed\r\n", on: respawned)
        try await eventually("live output") { display.text.hasSuffix("omp> resumed\r\n") }
        session.send(Data("b".utf8))
        try await eventually("typed into the new TUI") { daemon.written(to: respawned) == Data("b".utf8) }
        #expect(daemon.written(to: "tui-1") == Data("a".utf8))
        #expect(connection.terminals.models["tui-1"] == nil, "the old PTY's model went")
        #expect(display.violations.isEmpty)

        await connection.stop()
        await server.stop()
    }

    @Test func aDaemonRestartMovesTheTabToTheRestoredTUI() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let first = FakeDaemon()
        first.addSession("s1", ptyId: "tui-1", output: "omp> working\r\n")
        var server = try await home.startServer(first)
        let connection = try await connect(home)
        let session = connection.open("s1")
        let display = RecordingDisplay()
        session.attach(to: display)
        try await eventually("omp's screen") { session.isLive && display.shown == first.output(of: "tui-1") }

        // ompd restarts: PTY ids do not survive it; it brings the TUI back on a new PTY, prefilled from the last screen.
        await server.stop()
        try await eventually("offline") { !connection.isConnected && !session.isLive }
        let second = FakeDaemon()
        second.addSession("s1", ptyId: "tui-7", output: "omp> working\r\n" + FakeDaemon.restartDivider)
        server = try await home.startServer(second, startedAt: testDate.addingTimeInterval(60))
        try await eventually("the restored TUI") { session.isLive && display.resets.count == 2 }
        #expect(display.shown == second.output(of: "tui-7"))
        #expect(second.lifecycle == ["attach tui-7"], "nothing asks the new ompd for the old PTY")
        #expect(display.violations.isEmpty)

        await connection.stop()
        await server.stop()
    }

    @Test func aClosedSessionKeepsItsScreenAndResumesInTheSameTab() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addSession("s1", ptyId: "tui-1", output: "omp> all done\r\n")
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let session = connection.open("s1")
        let display = RecordingDisplay()
        session.attach(to: display)
        try await eventually("omp's screen") { session.isLive }

        try await connection.closeSession("s1")
        try await eventually("closed") { session.entry?.status == .closed && session.terminal == nil }
        #expect(daemon.closes == ["s1"])
        #expect(session.hasScreen && display.text == "omp> all done\r\n", "the last screen stays")
        #expect(session.entry?.canResume == true)
        session.send(Data("lost".utf8))

        let resumed = try await connection.resumeSession("s1", size: TerminalSize(cols: 90, rows: 25))
        #expect(resumed.sessionKey == "s1", "ompd keeps the session")
        #expect(daemon.opens == [.init(sessionFile: "/tmp/omp-sessions/s1.jsonl", workspace: "/tmp/workspace", cols: 90, rows: 25)])
        let ptyId = try #require(resumed.ptyId)
        try await eventually("omp is back in the tab") { session.isLive && display.resets.count == 2 }
        #expect(display.shown == daemon.output(of: ptyId))
        session.send(Data("y".utf8))
        try await eventually("typed into the resumed TUI") { daemon.written(to: ptyId) == Data("y".utf8) }
        #expect(daemon.written == Data("y".utf8), "nothing typed while omp was closed reaches it")

        await connection.stop()
        await server.stop()
    }

    @Test func quittingOmpFromItsTUILeavesTheLastScreenAndResumeStartsItAgain() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addSession("s1", ptyId: "tui-1", output: "omp> bye\r\n")
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let session = connection.open("s1")
        let display = RecordingDisplay()
        session.attach(to: display)
        try await eventually("omp's screen") { session.isLive }

        daemon.quitFromTUI("s1")
        try await eventually("omp exited") { session.entry?.status == .closed && session.terminal?.hasExited == true }
        #expect(!session.isLive)
        #expect(session.terminal?.ptyId == "tui-1", "the exited PTY keeps the last screen")
        #expect(session.entry?.canResume == true)

        let resumed = try await connection.resumeSession("s1", size: .standard)
        try await eventually("omp is back in the tab") { session.isLive && session.terminal?.ptyId == resumed.ptyId }
        #expect(display.text == "omp> bye\r\n" + FakeDaemon.restartDivider)

        await connection.stop()
        await server.stop()
    }

    /// `omp --resume` typed into a terminal: ompd adopts the session there. Its tab neither attaches the terminal's PTY
    /// (the terminal tab shows it) nor loses what it showed; once omp exits there, Resume brings it back as usual.
    @Test func aSessionResumedInATerminalIsShownByTheTerminalNotByItsTab() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addSession("s1", ptyId: "tui-1", output: "omp> bye\r\n")
        daemon.addPTY("p1", output: "$ omp --resume\r\n")
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let session = connection.open("s1")
        let display = RecordingDisplay()
        session.attach(to: display)
        try await eventually("omp's screen") { session.isLive }
        daemon.quitFromTUI("s1")
        try await eventually("omp exited") { session.entry?.status == .closed }

        daemon.adopt("s1", inTerminal: "p1")
        try await eventually("adopted") { session.entry?.adopted == true && session.terminal == nil }
        #expect(session.entry?.ptyId == "p1" && session.entry?.status == .idle && !session.isLive)
        #expect(session.hasScreen && display.text == "omp> bye\r\n", "the tab keeps the last screen of its own omp")
        #expect(connection.terminals.models["p1"] == nil && !daemon.lifecycle.contains("attach p1"))
        #expect(connection.terminals.terminals.map(\.ptyId) == ["p1"], "the terminal is still a terminal")
        session.send(Data("lost".utf8))

        daemon.adoptedOmpExits("s1")
        try await eventually("closed again") { session.entry?.status == .closed && session.entry?.ptyId == nil }
        #expect(session.entry?.canResume == true && session.terminal == nil)
        let resumed = try await connection.resumeSession("s1", size: .standard)
        try await eventually("omp is back in the tab") { session.isLive && session.terminal?.ptyId == resumed.ptyId }
        #expect(daemon.lifecycle.filter { $0.hasPrefix("attach") } == ["attach tui-1", "attach \(try #require(resumed.ptyId))"])
        #expect(daemon.written.isEmpty, "nothing typed reaches the terminal's omp through the tab")

        await connection.stop()
        await server.stop()
    }

    @Test func closingTheTabStopsTheStreamButNotOmp() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addSession("s1", ptyId: "tui-1", output: "omp> thinking\r\n")
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let display = RecordingDisplay()
        connection.open("s1").attach(to: display)
        try await eventually("omp's screen") { display.shown == daemon.output(of: "tui-1") }

        connection.release("s1")
        try await eventually("detached") { daemon.lifecycle == ["attach tui-1", "detach tui-1"] }
        daemon.print("still working\r\n", on: "tui-1")
        try await Task.sleep(for: .milliseconds(100))
        #expect(display.text == "omp> thinking\r\n")
        #expect(daemon.closes.isEmpty, "omp keeps running")

        // Reopening the tab shows what omp printed meanwhile.
        let reopened = RecordingDisplay()
        connection.open("s1").attach(to: reopened)
        try await eventually("the current screen") { reopened.text == "omp> thinking\r\nstill working\r\n" }

        await connection.stop()
        await server.stop()
    }
}

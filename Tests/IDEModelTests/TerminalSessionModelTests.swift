import Foundation
@testable import IDEModel
import IDETransport
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalSessionModelTests {
    @Test func attachShowsTheScreenThenEveryLaterChunkOnceAndInOrder() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addPTY("p1", output: "$ seq 1 300\r\n")
        // Printed after ompd subscribed the connection, before it answers: these frames overtake the attach response.
        daemon.printDuringNextAttach(["raced 1\r\n", "raced 2\r\n"])
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)

        // The program keeps printing while the attach is under way.
        let printer = Task.detached {
            for line in 1 ... 300 {
                daemon.print("\(line)\r\n", on: "p1")
                if line.isMultiple(of: 10) { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        let display = RecordingDisplay()
        let model = connection.terminals.model(for: "p1")
        model.attach(to: display)
        await printer.value
        try await eventually("the display shows everything the PTY printed") { display.shown == daemon.output(of: "p1") }
        #expect(model.phase == .attached)
        #expect(display.resets == [.standard], "one screen, at the PTY's size")
        #expect(display.violations.isEmpty)
        #expect(display.text.contains("raced 1\r\nraced 2\r\n"))

        daemon.print("live\r\n", on: "p1")
        try await eventually("live output") { display.text.hasSuffix("300\r\nlive\r\n") }
        #expect(display.shown == daemon.output(of: "p1"))
        #expect(daemon.lifecycle == ["attach p1"])

        await connection.stop()
        await server.stop()
    }

    @Test func inputReachesThePTYInOrderWithOneWriteInFlight() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addPTY("p1")
        // ompd serves a connection's requests concurrently: with writes this slow, parallel ones would overtake each other.
        daemon.setWriteDelay(milliseconds: 1 ... 12)
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let model = connection.terminals.model(for: "p1")
        model.attach(to: RecordingDisplay())
        try await eventually("attached") { model.isAttached }

        let keyboard = Keyboard(model: model)
        // Keystrokes from many tasks at once (typing, emulator replies, …) while earlier writes are still in flight.
        let typists = (0 ..< 300).map { key in
            Task {
                if key.isMultiple(of: 25) { try? await Task.sleep(for: .milliseconds(3)) }
                keyboard.type("k\(key);")
            }
        }
        for typist in typists { await typist.value }
        // A paste longer than one write.
        keyboard.type(String((0 ..< 150_000).map { Character(UnicodeScalar(UInt8(ascii: "a") + UInt8($0 % 26))) }))
        try await eventually("everything written") { daemon.written.count == keyboard.sent.count }
        #expect(daemon.written == keyboard.sent, "bytes reach the PTY in the order they were sent")
        #expect(daemon.maxWritesInFlight == 1)
        #expect(daemon.writes.count < 300, "keys typed during a write go out together")
        #expect(daemon.writes.allSatisfy { $0.count <= TerminalSessionModel.maxWriteBytes })

        await connection.stop()
        await server.stop()
    }

    @Test func reattachesAfterAReconnectAndStartsTheDisplayOverFromTheFreshScreen() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let first = FakeDaemon()
        first.addPTY("p1", output: "$ vim\r\n")
        var server = try await home.startServer(first)
        let connection = try await connect(home)
        let display = RecordingDisplay()
        let model = connection.terminals.model(for: "p1")
        model.attach(to: display)
        first.print("typed before the outage\r\n", on: "p1")
        try await eventually("live") { model.isAttached && display.shown == first.output(of: "p1") }

        // ompd restarts: the connection drops, then a new ompd brings the PTY back with its scrollback and a divider.
        await server.stop()
        try await eventually("detached") { model.phase == .detached }
        model.send(Data("typed while offline".utf8))
        let second = FakeDaemon()
        second.addPTY("p1", output: "$ vim\r\ntyped before the outage\r\n— terminal restarted —\r\n$ ")
        server = try await home.startServer(second)
        try await eventually("attached again") { model.isAttached && display.resets.count == 2 }
        #expect(display.shown == second.output(of: "p1"), "the display starts over from the new screen")
        second.print("ls\r\n", on: "p1")
        try await eventually("live again") { display.shown == second.output(of: "p1") }
        #expect(second.lifecycle == ["attach p1"])
        #expect(second.writes.isEmpty, "input typed while disconnected is dropped")
        #expect(display.violations.isEmpty)

        model.send(Data("q".utf8))
        try await eventually("input after the reconnect") { second.written == Data("q".utf8) }

        await connection.stop()
        await server.stop()
    }

    @Test func attachAndDetachReachOmpdInCallOrder() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addPTY("p1")
        daemon.setAttachDelay(milliseconds: 60)
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let model = connection.terminals.model(for: "p1")

        // The tab is closed while its attach is still being served, and reopened at once.
        let closed = RecordingDisplay()
        model.attach(to: closed)
        try await eventually("attach in flight") { daemon.attachRequests == 1 }
        model.detach()
        let reopened = RecordingDisplay()
        model.attach(to: reopened)
        try await eventually("attached") { model.isAttached }
        #expect(daemon.lifecycle == ["attach p1", "detach p1", "attach p1"])
        #expect(closed.resets.isEmpty)

        daemon.print("still streaming\r\n", on: "p1")
        try await eventually("output reaches the reopened tab") { reopened.shown == daemon.output(of: "p1") }

        await connection.stop()
        await server.stop()
    }

    @Test func resizesAreDebouncedAndOmpdEndsUpWithTheLastSize() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addPTY("p1", size: .standard)
        let server = try await home.startServer(daemon)
        let connection = try await connect(home) { $0.resizeDebounce = .milliseconds(80) }
        let model = connection.terminals.model(for: "p1")

        // The view measured itself before the screen arrived: ompd hears about it right after the attach.
        model.resize(TerminalSize(cols: 120, rows: 40))
        model.attach(to: RecordingDisplay())
        try await eventually("resized after attaching") { daemon.resizes.count == 1 }
        #expect(daemon.resizes == [.init(ptyId: "p1", cols: 120, rows: 40)])

        // A window being dragged: only the size it settles on goes out.
        for cols in 121 ... 140 { model.resize(TerminalSize(cols: cols, rows: 40)) }
        try await eventually("settled size") { daemon.resizes.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(daemon.resizes.map(\.cols) == [120, 140])

        model.resize(TerminalSize(cols: 5_000, rows: 0))
        try await eventually("clamped size") { daemon.resizes.count == 3 }
        #expect(daemon.resizes.last == .init(ptyId: "p1", cols: 1000, rows: 1))

        await connection.stop()
        await server.stop()
    }

    @Test func pushesKeepTheListCurrentWithoutPolling() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addPTY("p1")
        daemon.addPTY("p2")
        daemon.addSession("s1", ptyId: "tui-1")
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let terminals = connection.terminals
        var gone: [PTYID] = []
        terminals.onGone = { gone.append($0) }
        let shell = terminals.model(for: "p1")
        shell.attach(to: RecordingDisplay())
        let restoredTab = terminals.model(for: "p2")
        try await eventually("listed") { terminals.ptys.map(\.ptyId) == ["p1", "p2", "tui-1"] && shell.isAttached }
        #expect(terminals.terminals.map(\.ptyId) == ["p1", "p2"], "a session's TUI is not a terminal")

        daemon.exit("p1")
        try await eventually("exit noticed") { shell.hasExited }
        #expect(shell.isAttached, "the last screen stays readable")
        shell.send(Data("ignored".utf8))

        daemon.forget("p2")
        try await eventually("gone") { gone == ["p2"] }
        #expect(restoredTab.phase == .gone)
        #expect(terminals.ptys.map(\.ptyId) == ["p1", "tui-1"])

        let opened = try await terminals.open(cwd: "/tmp/project", size: TerminalSize(cols: 100, rows: 30))
        #expect(terminals.ptys.map(\.ptyId) == ["p1", "tui-1", opened.ptyId])
        #expect(opened.info?.size == TerminalSize(cols: 100, rows: 30))

        try await terminals.close("p1")
        #expect(gone == ["p2", "p1"])
        #expect(terminals.ptys.map(\.ptyId) == ["tui-1", opened.ptyId])
        #expect(daemon.lifecycle.last == "close p1")
        #expect(daemon.writes.isEmpty, "input to an exited program goes nowhere")

        // Held open long enough for any poll to have fired: the list came once, at connect.
        try await Task.sleep(for: .milliseconds(300))
        #expect(daemon.lists == 1)

        await connection.stop()
        await server.stop()
    }

    @Test func theListAtConnectLosesToAPushThatOvertookIt() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        daemon.addPTY("p1")
        // `pty.list` looks at the PTYs, then takes a while to answer: a PTY opened meanwhile is missing from it.
        daemon.setListDelay(milliseconds: 200)
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)
        let terminals = connection.terminals
        try await eventually("list requested") { daemon.lists == 1 }
        daemon.addPTY("p2")
        try await eventually("pushed") { terminals.ptys.map(\.ptyId) == ["p1", "p2"] }
        try await Task.sleep(for: .milliseconds(400))
        #expect(terminals.ptys.map(\.ptyId) == ["p1", "p2"], "the older answer does not take p2 away")

        await connection.stop()
        await server.stop()
    }
}

/// Types into a terminal model and remembers every byte, in order.
@MainActor
private final class Keyboard {
    let model: TerminalSessionModel
    private(set) var sent = Data()

    init(model: TerminalSessionModel) { self.model = model }

    func type(_ text: String) {
        let bytes = Data(text.utf8)
        sent.append(bytes)
        model.send(bytes)
    }
}

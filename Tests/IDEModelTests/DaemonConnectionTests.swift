import Foundation
@testable import IDEModel
import IDETransport
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DaemonConnectionTests {
    private let backoff = DaemonConnection.Backoff(initial: .milliseconds(20), maximum: .milliseconds(200))

    private func isUnavailable(_ connection: DaemonConnection) -> Bool {
        if case .daemonUnavailable = connection.status { return true }
        return false
    }

    @Test func waitsForADaemonThatIsStillStarting() async throws {
        let home = try TempHome(withToken: false)
        defer { home.remove() }
        let connection = DaemonConnection(paths: home.paths, clientVersion: "test", backoff: backoff)
        connection.start()
        try await eventually("no token yet") {
            if case .daemonUnavailable(let reason) = connection.status { return reason.contains("no token") }
            return false
        }

        try home.writeToken()
        try await eventually("nothing listening") {
            if case .daemonUnavailable(let reason) = connection.status { return reason.contains("nothing listens") }
            return false
        }

        let daemon = FakeDaemon()
        daemon.addSession("a", ptyId: "tui-a")
        daemon.addSession("b", ptyId: "tui-b", workspace: "/tmp/other")
        let server = try await home.startServer(daemon)
        try await eventually("connected") { connection.isConnected }
        #expect(connection.workspaces.map(\.path) == ["/tmp/other", "/tmp/workspace"])
        await connection.stop()
        await server.stop()
    }

    @Test func aNewSessionStartsAtTheSizeOfTheViewAndItsTUIShows() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon()
        let server = try await home.startServer(daemon)
        let connection = try await connect(home)

        let entry = try await connection.createSession(
            workspace: URL(filePath: "/tmp/project/", directoryHint: .isDirectory), approvalMode: .alwaysAsk,
            size: TerminalSize(cols: 132, rows: 43))
        #expect(daemon.creates == [.init(workspace: "/tmp/project", approvalMode: "always-ask", cols: 132, rows: 43)])
        #expect(connection.sessions.map(\.sessionKey) == [entry.sessionKey])
        let ptyId = try #require(entry.ptyId)

        let session = connection.open(entry.sessionKey)
        let display = RecordingDisplay()
        session.resize(TerminalSize(cols: 132, rows: 43))
        session.attach(to: display)
        try await eventually("omp's first screen") { display.text == "omp \(entry.sessionKey) 132x43\r\n" }
        #expect(session.isLive)
        #expect(daemon.resizes.isEmpty, "the TUI already has the view's size")
        session.send(Data("hello\r".utf8))
        try await eventually("typed into the TUI") { daemon.written(to: ptyId) == Data("hello\r".utf8) }

        await connection.stop()
        await server.stop()
    }

    @Test func callsFailCleanlyWhileDisconnected() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let connection = DaemonConnection(paths: home.paths, clientVersion: "test", backoff: backoff)
        await #expect(throws: IDETransportError.notConnected) {
            _ = try await connection.createSession(workspace: URL(filePath: "/tmp"), approvalMode: nil, size: .standard)
        }
        await #expect(throws: IDETransportError.notConnected) {
            try await connection.closeSession("s1")
        }
    }

    @Test func daemonNoticesCollectUntilDismissedOrTheDaemonRestarts() async throws {
        let home = try TempHome()
        defer { home.remove() }
        var server = try await home.startServer(FakeDaemon())
        let connection = try await connect(home)

        let readOnly = DaemonNotice(level: "error", message: "ompd is read-only", at: testDate)
        let slow = DaemonNotice(level: "warning", message: "omp is slow", sessionKey: "s1", at: testDate)
        server.broadcast(.notice(readOnly))
        server.broadcast(.notice(slow))
        try await eventually("notices") { connection.notices == [readOnly, slow] }
        #expect(connection.latestNotice == slow)
        connection.dismissNotices()
        #expect(connection.latestNotice == nil)

        server.broadcast(.notice(readOnly))
        try await eventually("notice") { connection.latestNotice == readOnly }
        await server.stop()
        try await eventually("daemon unavailable") { isUnavailable(connection) }
        #expect(connection.latestNotice == readOnly, "an outage alone does not clear what the daemon said")
        server = try await home.startServer(FakeDaemon(), startedAt: testDate.addingTimeInterval(60))
        try await eventually("reconnected to a new ompd") { connection.isConnected }
        #expect(connection.notices.isEmpty, "a restarted ompd starts over")

        await connection.stop()
        await server.stop()
    }

    @Test func backoffDoublesUpToItsCap() {
        let backoff = DaemonConnection.Backoff(initial: .milliseconds(250), maximum: .seconds(5))
        #expect((1 ... 7).map(backoff.delay(afterFailures:)) == [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
        ])
        #expect(backoff.delay(afterFailures: 1_000) == .seconds(5))
    }
}

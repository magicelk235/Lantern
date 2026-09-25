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

    @Test func reconnectsAfterADaemonRestartAndResubscribesFromLastSeq() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let records = try Fixture.records("bash-approve")
        let first = FakeDaemon(sessions: [manifestEntry("s1")], journal: ["s1": Array(records[0 ..< 40])])
        var server = try await home.startServer(first)
        let connection = DaemonConnection(paths: home.paths, clientVersion: "test", backoff: backoff)
        connection.start()
        try await eventually("connected") { connection.isConnected }
        #expect(connection.sessions.map(\.sessionKey) == ["s1"])

        let model = connection.open("s1")
        try await eventually("replayed") { model.lastSeq == 40 && model.sync == .live }
        #expect(first.subscribes == [.init(sessionKey: "s1", since: 0)])
        first.append(records[40])
        try await eventually("live record") { model.lastSeq == 41 }

        // ompd restarts (launchd KeepAlive): the connection drops, nobody listens for a while, then a new daemon with
        // the same journal (plus what omp produced meanwhile) comes up.
        await server.stop()
        try await eventually("daemon unavailable") { isUnavailable(connection) }
        #expect(model.sync == .detached)
        #expect(model.lastSeq == 41, "the transcript survives the outage")

        let second = FakeDaemon(sessions: [manifestEntry("s1", status: .busy)], journal: ["s1": records])
        server = try await home.startServer(second)
        try await eventually("reconnected and caught up") { model.lastSeq == Seq(records.count) && model.sync == .live }
        #expect(second.subscribes == [.init(sessionKey: "s1", since: 41)])
        #expect(second.ompCommands.isEmpty, "Regime A: restoring sends no omp command")
        #expect(second.snapshots.isEmpty)
        #expect(model.transcript == reduce(records), "identical to an always-connected client")
        #expect(model.entry?.status == .busy, "manifest from the new welcome")

        await connection.stop()
        await server.stop()
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

        let server = try await home.startServer(FakeDaemon(sessions: [manifestEntry("a"), manifestEntry("b", workspace: "/tmp/other")]))
        try await eventually("connected") { connection.isConnected }
        #expect(connection.workspaces.map(\.path) == ["/tmp/other", "/tmp/workspace"])
        await connection.stop()
        await server.stop()
    }

    @Test func createsSessionsAndPassesCommandsThrough() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemon = FakeDaemon(sessions: [])
        let server = try await home.startServer(daemon)
        let connection = DaemonConnection(paths: home.paths, clientVersion: "test", backoff: backoff)
        connection.start()
        try await eventually("connected") { connection.isConnected }

        let entry = try await connection.createSession(workspace: URL(filePath: "/tmp/project/", directoryHint: .isDirectory), approvalMode: .alwaysAsk)
        #expect(daemon.creates == [.init(workspace: "/tmp/project", approvalMode: "always-ask")])
        #expect(connection.sessions.map(\.sessionKey) == [entry.sessionKey])

        let model = connection.open(entry.sessionKey)
        try await eventually("subscribed") { model.sync == .live }
        #expect(await model.send("hi", streamingBehavior: .followUp))
        #expect(daemon.ompCommands == [.init(sessionKey: entry.sessionKey, command: ["type": "prompt", "message": "hi", "streamingBehavior": "followUp"])])

        await connection.stop()
        await server.stop()
    }

    @Test func commandsFailCleanlyWhileDisconnected() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let connection = DaemonConnection(paths: home.paths, clientVersion: "test", backoff: backoff)
        let model = connection.open("s1")
        #expect(await model.send("hello") == false)
        #expect(model.lastError == "Not connected to ompd.")
        await #expect(throws: IDETransportError.notConnected) {
            _ = try await connection.createSession(workspace: URL(filePath: "/tmp"), approvalMode: nil)
        }
    }

    @Test func backoffDoublesUpToItsCap() {
        let backoff = DaemonConnection.Backoff(initial: .milliseconds(250), maximum: .seconds(5))
        #expect((1 ... 7).map(backoff.delay(afterFailures:)) == [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
        ])
        #expect(backoff.delay(afterFailures: 1_000) == .seconds(5))
    }
}

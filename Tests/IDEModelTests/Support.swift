import Foundation
@testable import IDEModel
import IDETransport

let testDate = Date(timeIntervalSince1970: 1_790_330_000)

func manifestEntry(
    _ key: SessionKey, workspace: String = "/tmp/workspace", status: SessionStatus = .idle, ptyId: PTYID? = nil
) -> SessionManifestEntry {
    SessionManifestEntry(
        sessionKey: key, workspace: workspace, sessionFile: "/tmp/omp-sessions/\(key).jsonl",
        launch: LaunchSpec(ompPath: "/opt/homebrew/bin/omp", ompVersion: "18.3.1"), status: status, ptyId: ptyId,
        createdAt: testDate)
}

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` on the main actor until it holds.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// A private `$APP_SUPPORT` under /tmp (short enough for `sun_path`) with `run/` and, optionally, a token.
struct TempHome {
    let paths: AppSupportPaths
    static let token = String(repeating: "7e", count: 32)

    init(withToken: Bool = true) throws {
        let root = URL(filePath: "/tmp/ompd-model-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        paths = AppSupportPaths(root: root)
        try FileManager.default.createDirectory(at: paths.run, withIntermediateDirectories: true)
        if withToken { try writeToken() }
    }

    func writeToken() throws {
        try Data(Self.token.utf8).write(to: paths.token)
    }

    /// Serves `daemon` on this home's socket; its pushes go to the server's clients.
    func startServer(_ daemon: FakeDaemon, startedAt: Date = testDate) async throws -> IDEServer {
        let server = IDEServer(
            socketPath: paths.socket.path(percentEncoded: false), token: Self.token, daemonVersion: "fake-ompd",
            startedAt: startedAt, handler: daemon)
        daemon.serve(on: server)
        try await server.start()
        return server
    }

    func remove() {
        try? FileManager.default.removeItem(at: paths.root)
    }
}

/// A connection to the daemon on `home`, connected.
@MainActor
func connect(
    _ home: TempHome, configure: (TerminalRegistry) -> Void = { _ in }
) async throws -> DaemonConnection {
    let connection = DaemonConnection(
        paths: home.paths, clientVersion: "test",
        backoff: DaemonConnection.Backoff(initial: .milliseconds(20), maximum: .milliseconds(200)))
    configure(connection.terminals)
    connection.start()
    try await eventually("connected") { connection.isConnected }
    return connection
}

import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// A `Daemon` over the fake omp TUI, serving a real socket under a short /tmp home.
struct DaemonFixture {
    let temp: ShortTempDir
    let paths: AppSupportPaths
    let omp: FakeOmp
    let bridge: ScriptedBridge
    let locks: FakeLocks
    let token: String
    let workspace: String
    let daemon: Daemon

    init() async throws {
        let temp = try ShortTempDir()
        try await self.init(temp: temp, omp: try FakeOmp(in: temp.url))
    }

    private init(temp: ShortTempDir, omp: FakeOmp) async throws {
        self.temp = temp
        self.omp = omp
        paths = AppSupportPaths(root: temp.url.appending(path: "home", directoryHint: .isDirectory))
        try paths.prepare()
        token = try paths.loadOrCreateToken()
        workspace = try temp.directory("workspace")
        bridge = ScriptedBridge(omp: omp, connects: true)
        locks = FakeLocks()
        let configuration = Daemon.Configuration(
            paths: paths, ompExecutable: omp.executable, ompArguments: ["--thinking", "off"],
            sessionDirectory: temp.url.appending(path: "omp-sessions").path(percentEncoded: false),
            bridgeExtension: "/fake/ide-bridge.ts", baseEnvironment: omp.environment, timings: .fastTests,
            wakeHealthCheckDelay: .zero)
        daemon = Daemon(
            configuration: configuration, token: token, bridge: bridge, locks: locks,
            ptys: PTYPool(snapshotDirectory: paths.ptySnapshots))
        try await daemon.start()
    }

    /// A second daemon on the same `$APP_SUPPORT` and fake omp, as after a daemon restart.
    func restarted() async throws -> DaemonFixture {
        try await DaemonFixture(temp: temp, omp: omp)
    }

    func client() async throws -> Connected {
        let client = IDEClient(socketPath: paths.socket.path(percentEncoded: false), token: token, clientVersion: "daemon-tests")
        let welcome = try await client.connect()
        return Connected(client: client, welcome: welcome)
    }

    func createSession(_ connected: Connected) async throws -> SessionManifestEntry {
        try await connected.client.call(SessionCreate.self, .init(workspace: workspace, cols: 100, rows: 30))
    }

    /// The manifest as written on disk.
    func manifestOnDisk() throws -> SessionManifest {
        try IDECoding.decoder().decode(SessionManifest.self, from: Data(contentsOf: paths.manifest))
    }
}

/// A connected client and everything the daemon pushed to it.
final class Connected: Sendable {
    let client: IDEClient
    let welcome: Welcome
    private let log = Box<[ServerFrame]>([])
    private let reader: Task<Void, Never>

    init(client: IDEClient, welcome: Welcome) {
        self.client = client
        self.welcome = welcome
        let log = log
        let pushes = client.pushes
        reader = Task {
            for await frame in pushes { log.mutate { $0.append(frame) } }
        }
    }

    deinit {
        reader.cancel()
    }

    var pushes: [ServerFrame] { log.value }

    func entry(_ key: SessionKey) async throws -> SessionManifestEntry {
        try #require(try await client.call(ListSessions.self, Empty()).sessions.first { $0.sessionKey == key })
    }

    func waitForStatus(_ key: SessionKey, _ status: SessionStatus, timeout: Duration = .seconds(10)) async throws {
        try await eventually("\(key) \(status.rawValue)", timeout: timeout) { try await self.entry(key).status == status }
    }

    /// Output pushed for `ptyId` so far.
    func output(_ ptyId: PTYID) -> String {
        String(decoding: pushes.compactMap { if case .ptyOutput(let o) = $0, o.ptyId == ptyId { o.data } else { nil } }.joined(), as: UTF8.self)
    }

    func close() async {
        await client.close()
    }
}

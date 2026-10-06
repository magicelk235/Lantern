import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// A `Daemon` over the fake omp TUI, serving a real socket under a short /tmp home. `pausable: false` stands for an omp
/// whose bridge cannot pause; `pauseGrace` is the daemon's `detachedPauseGrace`; `capabilities` are advertised by every
/// bridge on top of the defaults; `services` is omp's launch broker.
struct DaemonFixture {
    let temp: ShortTempDir
    let paths: AppSupportPaths
    let omp: FakeOmp
    let bridge: ScriptedBridge
    let locks: FakeLocks
    let token: String
    let workspace: String
    let daemon: Daemon
    private let pausable: Bool
    private let pauseGrace: Duration
    private let capabilities: [String: Bool]
    let services: FakeServices

    init(
        pausable: Bool = true, pauseGrace: Duration = .seconds(3), capabilities: [String: Bool] = [:],
        services: FakeServices = FakeServices()
    ) async throws {
        let temp = try ShortTempDir()
        try await self.init(
            temp: temp, omp: try FakeOmp(in: temp.url), pausable: pausable, pauseGrace: pauseGrace, capabilities: capabilities,
            services: services)
    }

    private init(
        temp: ShortTempDir, omp: FakeOmp, pausable: Bool, pauseGrace: Duration, capabilities: [String: Bool], services: FakeServices
    ) async throws {
        self.temp = temp
        self.omp = omp
        self.pausable = pausable
        self.pauseGrace = pauseGrace
        self.capabilities = capabilities
        self.services = services
        paths = AppSupportPaths(root: temp.url.appending(path: "home", directoryHint: .isDirectory))
        try paths.prepare()
        token = try paths.loadOrCreateToken()
        workspace = try temp.directory("workspace")
        bridge = ScriptedBridge(omp: omp, connects: true, pausable: pausable, capabilities: capabilities)
        locks = FakeLocks()
        let configuration = Daemon.Configuration(
            paths: paths, ompExecutable: omp.executable, ompArguments: ["--thinking", "off"],
            sessionDirectory: temp.url.appending(path: "omp-sessions").path(percentEncoded: false),
            bridgeExtension: "/fake/ide-bridge.ts", baseEnvironment: omp.environment, timings: .fastTests,
            wakeHealthCheckDelay: .zero, detachedPauseGrace: pauseGrace, services: services)
        daemon = Daemon(
            configuration: configuration, token: token, bridge: bridge, locks: locks,
            ptys: PTYPool(snapshotDirectory: paths.ptySnapshots))
        try await daemon.start()
    }

    /// A second daemon on the same `$APP_SUPPORT` and fake omp, as after a daemon restart.
    func restarted() async throws -> DaemonFixture {
        try await DaemonFixture(
            temp: temp, omp: omp, pausable: pausable, pauseGrace: pauseGrace, capabilities: capabilities, services: services)
    }

    /// A Lantern window (`app`; `hasWindow` false: an app whose windows are all closed), or a command-line client
    /// like `ompd status` (`cli`).
    func client(_ kind: ClientKind = .app, hasWindow: Bool = true) async throws -> Connected {
        let client = IDEClient(
            socketPath: paths.socket.path(percentEncoded: false), token: token, clientVersion: "daemon-tests", clientKind: kind,
            hasWindow: hasWindow)
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

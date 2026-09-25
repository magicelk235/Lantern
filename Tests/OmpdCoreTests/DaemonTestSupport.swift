import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// A `Daemon` over the fake omp, serving a real socket under a short /tmp home.
struct DaemonFixture {
    let temp: ShortTempDir
    let paths: AppSupportPaths
    let omp: FakeOmp
    let bridge: FakeBridge
    let locks: FakeLocks
    let token: String
    let workspace: String
    let daemon: Daemon

    init(bridgeConnects: Bool = false, timings: SupervisorTimings = .fastTests) async throws {
        let temp = try ShortTempDir()
        try await self.init(temp: temp, omp: try FakeOmp(in: temp.url), bridgeConnects: bridgeConnects, timings: timings)
    }

    private init(temp: ShortTempDir, omp: FakeOmp, bridgeConnects: Bool, timings: SupervisorTimings) async throws {
        self.temp = temp
        self.omp = omp
        paths = AppSupportPaths(root: temp.url.appending(path: "home", directoryHint: .isDirectory))
        try paths.prepare()
        token = try paths.loadOrCreateToken()
        workspace = try temp.directory("workspace")
        bridge = FakeBridge(connects: bridgeConnects, sessionFile: omp.sessionFile)
        locks = FakeLocks()
        let configuration = Daemon.Configuration(
            paths: paths, ompExecutable: omp.executable, ompArguments: ["--thinking", "off"],
            sessionDirectory: temp.url.appending(path: "omp-sessions").path(percentEncoded: false),
            bridgeExtension: "/fake/ide-bridge.ts", baseEnvironment: omp.environment, timings: timings,
            wakeHealthCheckDelay: .zero)
        daemon = Daemon(
            configuration: configuration, token: token, bridge: bridge, locks: locks,
            ptys: PTYPool(snapshotDirectory: paths.ptySnapshots))
        try await daemon.start()
    }

    /// A second daemon on the same `$APP_SUPPORT` and fake omp, as after a daemon restart.
    func restarted() async throws -> DaemonFixture {
        try await DaemonFixture(temp: temp, omp: omp, bridgeConnects: false, timings: .fastTests)
    }

    func client() async throws -> Connected {
        let client = IDEClient(socketPath: paths.socket.path(percentEncoded: false), token: token, clientVersion: "daemon-tests")
        let welcome = try await client.connect()
        return Connected(client: client, welcome: welcome)
    }

    func createSession(_ connected: Connected) async throws -> SessionManifestEntry {
        try await connected.client.call(SessionCreate.self, .init(workspace: workspace))
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

    func events(_ key: SessionKey) -> [JournalRecord] {
        pushes.compactMap { if case .event(let record) = $0, record.sessionKey == key { record } else { nil } }
    }

    func waitForEvent(_ key: SessionKey, _ what: String, where match: @escaping @Sendable (JournalRecord) -> Bool) async throws {
        try await eventually(what) { self.events(key).contains(where: match) }
    }

    func waitForSeq(_ key: SessionKey, _ seq: Seq) async throws {
        try await eventually("seq \(seq) of \(key)") { (self.events(key).last?.seq ?? 0) >= seq }
    }

    func close() async {
        await client.close()
    }
}

extension JournalRecord {
    var ompType: String? { kind == .omp ? payload["type"]?.stringValue : nil }
    var daemonEvent: DaemonEvent? { kind == .daemon ? try? payload.decode(DaemonEvent.self) : nil }
}

/// Byte encoding of records, as the journal and the wire produce them.
func recordBytes(_ records: [JournalRecord]) throws -> [Data] {
    let encoder = IDECoding.encoder()
    return try records.map { try encoder.encode($0) }
}

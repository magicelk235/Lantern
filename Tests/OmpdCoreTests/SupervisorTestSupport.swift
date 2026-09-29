import Darwin
import Foundation
import IDEProtocol
import os
import Testing

@testable import OmpdCore

// MARK: - Fake omp

/// A `/bin/sh` stand-in for omp's TUI, run on a session PTY. Everything it does is recorded in files of its directory
/// (passed as `$FAKE_OMP_DIR`):
/// - `argv`: each invocation's arguments, one line per spawn; `env.<pid>`: each spawn's environment.
/// - `session.<pid>`: the session file that spawn serves (its `--resume` file, else a new `session-<pid>.jsonl`), created
///   on start the way the bridge's first-run ensureOnDisk would.
/// - `input`: every line typed into its terminal; `events`: `graceful` (SIGUSR1, what `ScriptedBridge` sends for
///   `session.shutdown`) or `hup`.
/// Typed `exit` quits normally (as omp's `/exit`), `crash` exits 3; anything else is echoed as `echo:<line>`. A graceful
/// stop or a normal quit appends `session_exit {kind:"normal"}` to the session file, SIGHUP one with kind `signal` and
/// exit 129 (omp's postmortem). `$FAKE_OMP_HUP=ignore` ignores SIGHUP; a `crash-at-start` file in its directory
/// makes it exit 3 before doing anything. Its signal handling is in place before `session.<pid>` exists (which is what
/// the scripted hello waits for), so a stop right after the hello is handled like omp handles it.
struct FakeOmp: Sendable {
    let directory: URL
    let executable: String

    static let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "omp/18.3.1"; exit 0; fi
        dir="$FAKE_OMP_DIR"
        session="$dir/session-$$.jsonl"
        previous=""
        for argument in "$@"; do
          if [ "$previous" = "--resume" ]; then session="$argument"; fi
          previous="$argument"
        done
        record_exit() {
          ts=$(perl -MTime::HiRes=time -MPOSIX=strftime -e 'my $t = time; printf "%s.%03dZ", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), int(($t - int($t)) * 1000)')
          printf '{"type":"custom","customType":"session_exit","data":{"reason":"%s","kind":"%s","recordedAt":"%s"}}\n' "$1" "$2" "$ts" >> "$session"
        }
        trap 'printf "graceful\n" >> "$dir/events"; record_exit dispose normal; exit 0' USR1
        if [ "$FAKE_OMP_HUP" = ignore ]; then
          trap '' HUP
        else
          trap 'printf "hup\n" >> "$dir/events"; record_exit sighup signal; exit 129' HUP
        fi
        printf '%s\n' "$*" >> "$dir/argv"
        env > "$dir/env.$$"
        if [ -f "$dir/crash-at-start" ]; then exit 3; fi
        : >> "$session"
        printf '%s' "$session" > "$dir/.session.$$" && mv "$dir/.session.$$" "$dir/session.$$"
        printf 'fake omp %s\n' "$$"
        while :; do
          if ! IFS= read -r line; then sleep 1; continue; fi
          printf '%s\n' "$line" >> "$dir/input"
          case "$line" in
            exit) record_exit dispose normal; exit 0 ;;
            crash) exit 3 ;;
            *) printf 'echo:%s\n' "$line" ;;
          esac
        done
        """#

    init(in root: URL) throws {
        directory = root.appending(path: "fake-omp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "omp", directoryHint: .notDirectory)
        try Self.script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        executable = file.path(percentEncoded: false)
    }

    /// The daemon environment omp starts from in these tests.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("OMP_IDE_") && !$0.key.hasPrefix("FAKE_OMP") }
        var path = directory.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        environment["FAKE_OMP_DIR"] = path
        return environment
    }

    func file(_ name: String) -> URL { directory.appending(path: name, directoryHint: .notDirectory) }

    func lines(_ name: String) -> [String] {
        guard let text = try? String(contentsOf: file(name), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Environment of the spawn with `pid`.
    func environment(of pid: Int32) -> [String: String] {
        Dictionary(lines("env.\(pid)").compactMap { line in
            line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
        }, uniquingKeysWith: { _, last in last })
    }

    /// The session file the spawn with `pid` serves, once it started.
    func sessionFile(of pid: Int32) -> String? {
        (try? String(contentsOf: file("session.\(pid)"), encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Pids of every spawn that started so far (wrote its `session.<pid>`).
    func startedPIDs() -> Set<Int32> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return Set(names.compactMap { $0.hasPrefix("session.") ? Int32($0.dropFirst("session.".count)) : nil })
    }

    /// `session_exit` kinds recorded in `path`.
    static func sessionExits(_ path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  entry["customType"] == "session_exit" else { return nil }
            return entry["data"]?["kind"]?.stringValue
        }
    }
}

// MARK: - Scripted bridge and locks

/// Scripted `SessionBridgeLink` for the fake omp: the `hello` arrives once the spawn registered by `setExpectedPID`
/// started (only when `connects`; else the wait fails at once like a timeout) and names the session file that spawn
/// serves. `session.shutdown` (advertised when `shutdown`) makes the fake exit like omp's dispose. Unless `pausable` is
/// off it plays omp's pause gate like the ide-bridge: `session.pause`/`session.resume` flip it and push `pause` events,
/// and `userPause`/`userResume` are the user's /pause and pause screen. Calls are recorded; other events are pushed by
/// the test. `terminalOmpSaysHello` is a fake omp the user started in a terminal PTY saying hello in terminal mode; the
/// daemon's verdict lands in `adoptions` or `refusals`, and an adopted omp's event stream finishes when its process is
/// gone, as the real bridge's socket closes with it.
actor ScriptedBridge: SessionBridgeLink {
    private let connects: Bool
    private let shutdown: Bool
    private let pausable: Bool
    /// Advertised on top of the defaults (`session.prompt`, `agent.message`, `entry.append`, …).
    private let extraCapabilities: [String: Bool]
    private let omp: FakeOmp
    private var pids: [SessionKey: Int32] = [:]
    private var streams: [SessionKey: (stream: AsyncStream<JSONValue>, sink: AsyncStream<JSONValue>.Continuation)] = [:]
    /// Who holds each spawn's pause gate closed.
    private var paused: [SessionKey: PauseOwner] = [:]
    private(set) var calls: [String] = []
    /// `calls` with the session each went to.
    private(set) var sessionCalls: [(sessionKey: SessionKey, method: String)] = []
    /// `calls` with their params.
    private(set) var requests: [(method: String, params: JSONValue)] = []
    /// Terminal PTYs with credentials (`expectTerminal`, until `forgetTerminal`).
    private(set) var terminals: Set<PTYID> = []
    private let terminalHelloStream: AsyncStream<TerminalHello>
    private let terminalHelloSink: AsyncStream<TerminalHello>.Continuation
    private var lastPeerID = 0
    /// Terminal hellos awaiting the daemon's verdict, by peer.
    private var pending: Set<Int> = []
    private(set) var adoptions: [(ptyId: PTYID, sessionKey: SessionKey)] = []
    private(set) var refusals: [(ptyId: PTYID, reason: String)] = []

    init(omp: FakeOmp, connects: Bool, shutdown: Bool = true, pausable: Bool = true, capabilities: [String: Bool] = [:]) {
        self.omp = omp
        self.connects = connects
        self.shutdown = shutdown
        self.pausable = pausable
        extraCapabilities = capabilities
        (terminalHelloStream, terminalHelloSink) = AsyncStream.makeStream(of: TerminalHello.self)
    }

    func expect(sessionKey: SessionKey) -> BridgeCredentials {
        streams.removeValue(forKey: sessionKey)?.sink.finish()
        let (stream, sink) = AsyncStream.makeStream(of: JSONValue.self)
        streams[sessionKey] = (stream, sink)
        paused[sessionKey] = nil
        return BridgeCredentials(socketPath: "/fake/bridge.sock", sessionKey: sessionKey, token: String(repeating: "0", count: 64), daemonPID: getpid())
    }

    func setExpectedPID(_ pid: Int32, for sessionKey: SessionKey) { pids[sessionKey] = pid }

    func waitForHello(_ sessionKey: SessionKey, timeout: Duration) async throws -> BridgeHello {
        guard connects, let pid = pids[sessionKey] else { throw BridgeError.helloTimeout }
        let omp = omp
        let file = try await eventuallyValue("fake omp \(pid) to start", timeout: timeout) { omp.sessionFile(of: pid) }
        return BridgeHello(
            sessionKey: sessionKey, ptyId: nil, pid: pid, ompVersion: "18.3.1",
            capabilities: [
                "session.info": true, "session.shutdown": shutdown, "events.activity": true, "events.title": true,
                "session.pause": pausable,
            ].merging(extraCapabilities) { $1 },
            sessionId: "fake-session",
            sessionFile: file, onDisk: true, cwd: "/", artifactsDir: nil, title: nil, pausedBy: nil, raw: ["t": "hello"])
    }

    func call(_ sessionKey: SessionKey, method: String, params: JSONValue, timeout: Duration) throws -> JSONValue {
        calls.append(method)
        sessionCalls.append((sessionKey, method))
        requests.append((method, params))
        switch method {
        case "session.shutdown":
            guard let pid = pids[sessionKey] else { return [:] }
            kill(pid, SIGUSR1)
            return ["accepted": true]
        case "session.pause" where pausable:
            let changed = paused[sessionKey] == nil
            if changed { setGate(sessionKey, .daemon) }
            return pauseResult(sessionKey, changed: changed)
        case "session.resume" where pausable:
            let guardOwner = params["ifPausedBy"]?.stringValue.flatMap(PauseOwner.init(rawValue:))
            let changed = paused[sessionKey] != nil && (guardOwner == nil || paused[sessionKey] == guardOwner)
            if changed { setGate(sessionKey, nil) }
            return pauseResult(sessionKey, changed: changed)
        case "entry.append":
            // As omp's appendCustomEntry + flush: a `custom` line in the session file.
            guard let pid = pids[sessionKey], let file = omp.sessionFile(of: pid) else { return [:] }
            let entry: JSONValue = [
                "type": "custom", "customType": params["customType"] ?? .null, "data": params["data"] ?? .null,
                "timestamp": .string(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
            ]
            if let line = try? JSONEncoder().encode(entry), let handle = FileHandle(forWritingAtPath: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line + Data("\n".utf8))
                try? handle.close()
            }
            return ["entryId": "fake"]
        case "session.watchStall":
            return ["stalled": true]
        default:
            return [:]
        }
    }

    /// The user's /pause in the session's TUI.
    func userPause(_ sessionKey: SessionKey) {
        if paused[sessionKey] == nil { setGate(sessionKey, .user) }
    }

    /// The user dismissed omp's pause screen.
    func userResume(_ sessionKey: SessionKey) {
        if paused[sessionKey] != nil { setGate(sessionKey, nil, by: .user) }
    }

    func pausedBy(_ sessionKey: SessionKey) -> PauseOwner? { paused[sessionKey] }

    /// Closes (`owner`) or opens (nil) the gate and pushes `pause {paused, by}` as the bridge's gate listener does.
    private func setGate(_ sessionKey: SessionKey, _ owner: PauseOwner?, by opener: PauseOwner = .daemon) {
        paused[sessionKey] = owner
        push("pause", ["paused": .bool(owner != nil), "by": .string((owner ?? opener).rawValue)], to: sessionKey)
    }

    private func pauseResult(_ sessionKey: SessionKey, changed: Bool) -> JSONValue {
        ["paused": .bool(paused[sessionKey] != nil), "pausedBy": paused[sessionKey].map { .string($0.rawValue) } ?? .null,
         "changed": .bool(changed), "screen": .bool(paused[sessionKey] != nil)]
    }

    func events(_ sessionKey: SessionKey) -> AsyncStream<JSONValue> {
        streams[sessionKey]?.stream ?? AsyncStream { $0.finish() }
    }

    /// Delivers an `evt` push the way the bridge sends it.
    func push(_ kind: String, _ data: JSONValue, to sessionKey: SessionKey, agentId: String = "Main") {
        streams[sessionKey]?.sink.yield(["t": "evt", "seq": 1, "ts": 0, "agentId": .string(agentId), "kind": .string(kind), "data": data])
    }

    func forget(_ sessionKey: SessionKey) {
        streams.removeValue(forKey: sessionKey)?.sink.finish()
        pids[sessionKey] = nil
        paused[sessionKey] = nil
    }

    // MARK: - Terminals

    func expectTerminal(ptyId: PTYID) -> TerminalCredentials {
        terminals.insert(ptyId)
        return TerminalCredentials(socketPath: "/fake/bridge.sock", ptyId: ptyId, token: String(repeating: "0", count: 64), daemonPID: getpid())
    }

    func forgetTerminal(ptyId: PTYID) {
        terminals.remove(ptyId)
    }

    func terminalHellos() -> AsyncStream<TerminalHello> {
        terminalHelloStream
    }

    /// The fake omp `pid`, started by the user in terminal `ptyId` and serving `sessionFile` in `cwd`, says hello.
    @discardableResult
    func terminalOmpSaysHello(
        ptyId: PTYID, pid: Int32, sessionFile: String, cwd: String, sessionId: String = "terminal-session", title: String? = nil,
        pausedBy: PauseOwner? = nil
    ) -> TerminalHello {
        lastPeerID += 1
        let hello = BridgeHello(
            sessionKey: "", ptyId: ptyId, pid: pid, ompVersion: "18.3.1",
            capabilities: [
                "session.info": true, "session.shutdown": shutdown, "events.activity": true, "events.title": true,
                "session.pause": pausable,
            ],
            sessionId: sessionId, sessionFile: sessionFile, onDisk: true, cwd: cwd, artifactsDir: nil, title: title,
            pausedBy: pausedBy, raw: ["t": "hello"])
        let request = TerminalHello(ptyId: ptyId, hello: hello, peerID: lastPeerID)
        pending.insert(lastPeerID)
        terminalHelloSink.yield(request)
        return request
    }

    func adoptTerminalHello(_ hello: TerminalHello, as sessionKey: SessionKey) -> BridgeHello? {
        guard pending.remove(hello.peerID) != nil else { return nil }
        streams.removeValue(forKey: sessionKey)?.sink.finish()
        let (stream, sink) = AsyncStream.makeStream(of: JSONValue.self)
        streams[sessionKey] = (stream, sink)
        pids[sessionKey] = hello.hello.pid
        paused[sessionKey] = hello.hello.pausedBy
        adoptions.append((hello.ptyId, sessionKey))
        var accepted = hello.hello
        accepted.sessionKey = sessionKey
        // The bridge's socket closes with its omp.
        let pid = hello.hello.pid
        Task { [weak self] in
            while kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            await self?.ompGone(sessionKey, pid: pid, sink: sink)
        }
        return accepted
    }

    func refuseTerminalHello(_ hello: TerminalHello, reason: String) {
        guard pending.remove(hello.peerID) != nil else { return }
        refusals.append((hello.ptyId, reason))
    }

    private func ompGone(_ sessionKey: SessionKey, pid: Int32, sink: AsyncStream<JSONValue>.Continuation) {
        sink.finish()
        guard pids[sessionKey] == pid else { return }
        streams[sessionKey] = nil
        pids[sessionKey] = nil
    }
}

/// In-memory `SessionLockProvider` that records every acquisition.
final class FakeLocks: SessionLockProvider {
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onAcquire: (@Sendable (String) -> Void)?

    private struct State: Sendable {
        var held: Set<String> = []
        var acquired: [String] = []
    }

    init(onAcquire: (@Sendable (String) -> Void)? = nil) {
        self.onAcquire = onAcquire
    }

    var held: Set<String> { state.withLock { $0.held } }
    var acquired: [String] { state.withLock { $0.acquired } }

    /// Someone else owns `file`.
    func holdElsewhere(_ file: String) { _ = state.withLock { $0.held.insert(file) } }

    func acquire(sessionFile: String, sessionId: String?, sessionKey: SessionKey) throws -> any SessionLockHandle {
        onAcquire?(sessionFile)
        try state.withLock { s in
            guard s.held.insert(sessionFile).inserted else {
                throw DaemonError(.sessionBusy, "\(sessionFile) is owned by another process")
            }
            s.acquired.append(sessionFile)
        }
        return Handle(file: sessionFile, owner: self)
    }

    fileprivate func release(_ file: String) { _ = state.withLock { $0.held.remove(file) } }

    private final class Handle: SessionLockHandle {
        let file: String
        let owner: FakeLocks
        init(file: String, owner: FakeLocks) {
            self.file = file
            self.owner = owner
        }
        func release() { owner.release(file) }
    }
}

// MARK: - Fixtures

/// A short directory under /tmp (unix socket paths must stay under 104 bytes), removed on release.
final class ShortTempDir: Sendable {
    let url: URL
    var path: String { url.path(percentEncoded: false) }

    init() throws {
        url = URL(filePath: "/tmp/od-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func directory(_ name: String) throws -> String {
        let directory = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path(percentEncoded: false)
    }
}

/// One supervisor over the fake omp, with its own PTY pool and manifest.
struct SupervisorFixture {
    let temp: ShortTempDir
    let omp: FakeOmp
    let pool: PTYPool
    let manifest: ManifestPublisher
    let bridge: ScriptedBridge
    let locks: FakeLocks
    /// Notices the supervisor sent (`SupervisorContext.notify`).
    let notices = Box<[DaemonNotice]>([])
    let persistenceFailures = Box<[String]>([])
    /// Manifest and PTY-list changes in publication order (what the daemon broadcasts as `sessions` and `ptys`).
    let published = Box<[Published]>([])
    let workspace: String
    let key: SessionKey = "session-1"
    let supervisor: SessionSupervisor

    init(
        bridgeConnects: Bool = true, shutdownCapable: Bool = true, locks: FakeLocks = FakeLocks(),
        timings: SupervisorTimings = .fastTests, environment extra: [String: String] = [:],
        bridgeCapabilities: [String: Bool] = [:], services: any ServiceControl = FakeServices(),
        restorePolicy: RestorePolicy = RestorePolicy(),
        entry configure: (inout SessionManifestEntry) -> Void = { _ in }
    ) async throws {
        temp = try ShortTempDir()
        omp = try FakeOmp(in: temp.url)
        workspace = try temp.directory("workspace")
        pool = PTYPool(snapshotDirectory: temp.url.appending(path: "pty"), snapshotInterval: .seconds(3600))
        bridge = ScriptedBridge(omp: omp, connects: bridgeConnects, shutdown: shutdownCapable, capabilities: bridgeCapabilities)
        self.locks = locks
        manifest = ManifestPublisher(store: ManifestStore(url: temp.url.appending(path: "sessions.json")))
        var entry = SessionManifestEntry(
            sessionKey: key, workspace: workspace,
            launch: LaunchSpec(
                ompPath: omp.executable, ompVersion: "18.3.1", approvalMode: "yolo", model: "anthropic/claude-haiku-4-5",
                extraArgs: ["--thinking", "off"], env: ["OMP_PROFILE": "work"],
                sessionDir: temp.url.appending(path: "omp-sessions").path(percentEncoded: false)),
            createdAt: Date())
        configure(&entry)
        let seeded = entry
        try await manifest.update {
            $0.sessions = [seeded]
            $0.restorePolicy = restorePolicy
        }
        let published = published
        let key = key
        manifest.setSink { list in
            guard let entry = list.sessions.first(where: { $0.sessionKey == key }) else { return }
            published.mutate { $0.append(.sessions(ptyId: entry.ptyId, status: entry.status)) }
        }
        await pool.setChangeHandler { list in published.mutate { $0.append(.ptys(list.map(\.ptyId))) } }
        let notices = notices
        let persistenceFailures = persistenceFailures
        let context = SupervisorContext(
            manifest: manifest, ptys: pool, bridge: bridge, locks: locks, bridgeExtension: "/fake/ide-bridge.ts",
            baseEnvironment: omp.environment.merging(extra) { $1 }, timings: timings, services: services,
            persistenceFailed: { error in persistenceFailures.mutate { $0.append("\(error)") } },
            notify: { notice in notices.mutate { $0.append(notice) } })
        supervisor = SessionSupervisor(entry: seeded, context: context)
    }

    var entry: SessionManifestEntry {
        get async throws { try #require(await manifest.entry(key)) }
    }

    func waitForStatus(_ status: SessionStatus, timeout: Duration = .seconds(10)) async throws {
        try await eventually("status \(status.rawValue)", timeout: timeout) { await manifest.entry(key)?.status == status }
    }

    /// The session's current PTY.
    func pty() async throws -> PTYInfo {
        let id = try #require(try await entry.ptyId)
        return try #require(await pool.info(id))
    }

    /// Types `line` (and Return) into the session's TUI.
    func type(_ line: String) async throws {
        try await pool.write(try await pty().ptyId, Data((line + "\n").utf8))
    }

    /// Stops what is still running (every test ends here, also on failure paths that return early).
    func finish() async {
        await supervisor.stop(.daemonShutdown)
        try? await pool.shutdown()
    }
}

enum Published: Sendable, Equatable {
    case sessions(ptyId: PTYID?, status: SessionStatus)
    case ptys([PTYID])
}

extension SupervisorTimings {
    static let fastTests = SupervisorTimings(
        hello: .seconds(5), bridgeCall: .seconds(5), stop: .seconds(3), hangup: .seconds(1), healthCheck: .seconds(2),
        respawnWindow: .seconds(60), maxRespawns: 3, resumeQuietPeriod: .milliseconds(50))
}

// MARK: - Waiting

struct Timeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` until it holds (tests only: the daemon itself never polls).
func eventually(
    _ what: String, timeout: Duration = .seconds(10), _ condition: @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw Timeout(what: what)
}

/// Polls until `value` returns non-nil.
func eventuallyValue<T: Sendable>(_ what: String, timeout: Duration = .seconds(10), _ value: @Sendable () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let found = try await value() { return found }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw Timeout(what: what)
}

/// A value shared between test code and callbacks.
final class Box<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        state = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Value { state.withLock { $0 } }

    func mutate(_ body: @Sendable (inout Value) -> Void) {
        state.withLock { body(&$0) }
    }
}

/// Text of a serialized screen replayed into a fresh terminal: logical lines, soft wraps joined.
func screenLines(_ attach: PTYAttach.Result) -> [String] {
    let mirror = TerminalMirror(cols: attach.info.cols, rows: attach.info.rows)
    mirror.feed([UInt8](attach.screen))
    var lines: [String] = []
    for (row, text) in bufferText(mirror.terminal).enumerated() {
        if row > 0, mirror.terminal.bufferLine(atRow: row)!.isWrapped {
            lines[lines.count - 1] += text
        } else {
            lines.append(text)
        }
    }
    return lines
}

/// Scripted `ServiceControl`: the broker's states per service name, and the outcome of a restart per name
/// (`.restarted` when not listed); restarts are recorded.
final class FakeServices: ServiceControl {
    let states: [String: String]
    let outcomes: [String: ServiceRestart]
    let restarts = Box<[String]>([])

    init(states: [String: String] = [:], outcomes: [String: ServiceRestart] = [:]) {
        self.states = states
        self.outcomes = outcomes
    }

    func states(workspace: String, omp: String, environment: [String: String]) async throws -> [String: String] { states }

    func restart(_ name: String, workspace: String, omp: String, environment: [String: String]) async throws -> ServiceRestart {
        restarts.mutate { $0.append(name) }
        return outcomes[name] ?? .restarted
    }
}

import Foundation
import IDEProtocol
import os
import Testing

@testable import OmpdCore

// MARK: - Fake omp

/// A `/bin/sh` stand-in for `omp --mode rpc-ui` that speaks the ready/response protocol. Everything it does is driven
/// by and recorded in files of its directory (passed as `$FAKE_OMP_DIR`):
/// - `argv`: each invocation's arguments, one line per spawn.
/// - `stdin`: every line it received.
/// - `events`: `eof` once stdin closed.
/// - `prompt`: frames printed after acknowledging a `prompt` (`__ID__` = the prompt's id); default: one complete turn.
/// - `answered`: frames printed after an `extension_ui_response`/`host_tool_result` (`__ID__` = its id,
///   `__PROMPT__` = the last prompt's id).
/// - `session.jsonl`: the session file `get_state` reports; created on the first prompt; on stdin EOF a
///   `session_exit {kind:"normal"}` entry is appended, as omp does.
/// `$FAKE_OMP_EOF=ignore` keeps it alive after EOF (a straggler); `$FAKE_OMP_EOF_DELAY` delays its exit. The command
/// `crash` makes it exit 3 without answering; `fail` is answered with a failure response.
struct FakeOmp: Sendable {
    let directory: URL
    let executable: String

    static let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "omp/18.3.1"; exit 0; fi
        dir="$FAKE_OMP_DIR"
        session="$dir/session.jsonl"
        printf '%s\n' "$*" >> "$dir/argv"
        printf '{"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1],"maxFrameBytes":1048576}\n'
        emit() {
          if [ -f "$1" ]; then sed "s/__ID__/$2/g; s/__PROMPT__/$3/g" "$1"; fi
        }
        last_prompt=""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$dir/stdin"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
          type=$(printf '%s' "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
          case "$type" in
            get_state)
              printf '{"id":"%s","type":"response","command":"get_state","success":true,"data":{"sessionFile":"%s","sessionId":"fake-session","isStreaming":false,"isSettled":true,"hasPendingAsyncWork":false}}\n' "$id" "$session" ;;
            get_entries)
              printf '{"id":"%s","type":"response","command":"get_entries","success":true,"data":{"entries":[{"type":"session","id":"root"}],"leafId":"root"}}\n' "$id" ;;
            prompt)
              last_prompt="$id"
              : >> "$session"
              printf '{"id":"%s","type":"response","command":"prompt","success":true}\n' "$id"
              if [ -f "$dir/prompt" ]; then
                emit "$dir/prompt" "$id" "$id"
              else
                printf '{"type":"agent_start"}\n{"type":"message_update","messageId":"m-%s","assistantMessageEvent":{"type":"text_delta","delta":"hi"}}\n{"type":"agent_end","messages":[],"isTerminal":true,"yielded":true}\n{"type":"prompt_result","id":"%s","agentInvoked":true,"status":"completed","sessionSettled":true}\n{"type":"session_settled"}\n' "$id" "$id"
              fi ;;
            extension_ui_response|host_tool_result)
              emit "$dir/answered" "$id" "$last_prompt" ;;
            fail)
              printf '{"id":"%s","type":"response","command":"fail","success":false,"error":"scripted failure","code":"E_FAKE"}\n' "$id" ;;
            crash)
              exit 3 ;;
            *)
              printf '{"id":"%s","type":"response","command":"%s","success":true}\n' "$id" "$type" ;;
          esac
        done
        printf 'eof\n' >> "$dir/events"
        if [ "$FAKE_OMP_EOF" = ignore ]; then exec sleep 30; fi
        if [ -n "$FAKE_OMP_EOF_DELAY" ]; then sleep "$FAKE_OMP_EOF_DELAY"; fi
        ts=$(perl -MTime::HiRes=time -MPOSIX=strftime -e 'my $t = time; printf "%s.%03dZ", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), int(($t - int($t)) * 1000)')
        printf '{"type":"custom","customType":"session_exit","data":{"reason":"dispose","kind":"normal","recordedAt":"%s"}}\n' "$ts" >> "$session"
        exit 0
        """#

    init(in root: URL) throws {
        directory = root.appending(path: "fake-omp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "omp", directoryHint: .notDirectory)
        try Self.script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        executable = file.path(percentEncoded: false)
    }

    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var path = directory.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        environment["FAKE_OMP_DIR"] = path
        return environment
    }

    var sessionFile: String { directory.appending(path: "session.jsonl").path(percentEncoded: false) }

    func file(_ name: String) -> URL { directory.appending(path: name, directoryHint: .notDirectory) }

    func lines(_ name: String) -> [String] {
        guard let text = try? String(contentsOf: file(name), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Received stdin lines, decoded.
    var received: [JSONValue] {
        lines("stdin").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    func script(_ name: String, _ frames: [String]) throws {
        try (frames.joined(separator: "\n") + "\n").write(to: file(name), atomically: true, encoding: .utf8)
    }
}

// MARK: - Fake bridge and locks

enum FakeBridgeError: Error { case noHello }

/// Scripted `SessionBridgeLink`: `hello` succeeds only when `connects`; calls are recorded (and may run a hook).
actor FakeBridge: SessionBridgeLink {
    private let connects: Bool
    private var pids: [SessionKey: Int32] = [:]
    private var streams: [SessionKey: AsyncStream<JSONValue>.Continuation] = [:]
    private(set) var calls: [String] = []
    private var onCall: (@Sendable (String) -> Void)?
    let sessionFile: String

    init(connects: Bool, sessionFile: String = "/nonexistent/session.jsonl") {
        self.connects = connects
        self.sessionFile = sessionFile
    }

    func setOnCall(_ hook: @escaping @Sendable (String) -> Void) { onCall = hook }

    func prepareSpawn(of sessionKey: SessionKey) -> [String: String] { ["FAKE_BRIDGE_SESSION_KEY": sessionKey] }

    func spawned(_ sessionKey: SessionKey, pid: Int32) { pids[sessionKey] = pid }

    func hello(_ sessionKey: SessionKey, timeout: Duration) throws -> BridgeSessionInfo {
        guard connects else { throw FakeBridgeError.noHello }
        return BridgeSessionInfo(
            pid: pids[sessionKey] ?? 0, ompVersion: "18.3.1", capabilities: ["ensureOnDisk": true],
            sessionId: "fake-session", sessionFile: sessionFile, onDisk: false, raw: ["t": "hello"])
    }

    func call(_ sessionKey: SessionKey, method: String, params: JSONValue, timeout: Duration) -> JSONValue {
        calls.append(method)
        onCall?(method)
        return [:]
    }

    func events(_ sessionKey: SessionKey) -> AsyncStream<JSONValue> {
        let (stream, continuation) = AsyncStream.makeStream(of: JSONValue.self)
        streams[sessionKey] = continuation
        return stream
    }

    func push(_ event: JSONValue, to sessionKey: SessionKey) {
        streams[sessionKey]?.yield(event)
    }

    func forget(_ sessionKey: SessionKey) {
        streams.removeValue(forKey: sessionKey)?.finish()
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

/// One supervisor over the fake omp, with its own manifest and journal directory.
struct SupervisorFixture {
    let temp: ShortTempDir
    let omp: FakeOmp
    let manifest: ManifestPublisher
    let bridge: FakeBridge
    let locks: FakeLocks
    let readOnly = ReadOnlyMode()
    let workspace: String
    let key: SessionKey = "session-1"
    let supervisor: SessionSupervisor

    init(
        bridgeConnects: Bool = false, locks: FakeLocks = FakeLocks(), timings: SupervisorTimings = .fastTests,
        entry configure: (inout SessionManifestEntry) -> Void = { _ in }
    ) async throws {
        temp = try ShortTempDir()
        omp = try FakeOmp(in: temp.url)
        workspace = try temp.directory("workspace")
        bridge = FakeBridge(connects: bridgeConnects, sessionFile: omp.sessionFile)
        self.locks = locks
        manifest = ManifestPublisher(store: ManifestStore(url: temp.url.appending(path: "sessions.json")))
        var entry = SessionManifestEntry(
            sessionKey: key, workspace: workspace,
            launch: LaunchSpec(ompPath: omp.executable, ompVersion: "18.3.1", sessionDir: temp.url.appending(path: "omp-sessions").path(percentEncoded: false)),
            createdAt: Date())
        configure(&entry)
        let seeded = entry
        try await manifest.update { $0.sessions = [seeded] }
        let context = SupervisorContext(
            manifest: manifest, journalDirectory: temp.url.appending(path: "journal"), bridge: bridge, locks: locks,
            bridgeExtension: "/fake/ide-bridge.ts", baseEnvironment: omp.environment, timings: timings,
            readOnly: readOnly, journalFailed: { _, _ in })
        supervisor = try SessionSupervisor(entry: seeded, context: context)
    }

    var entry: SessionManifestEntry {
        get async throws { try #require(await manifest.entry(key)) }
    }

    func records() async throws -> [JournalRecord] {
        try #require(try await supervisor.journal.records(after: 0))
    }

    func daemonEvents() async throws -> [DaemonEvent] {
        try await records().filter { $0.kind == .daemon }.compactMap { try? $0.payload.decode(DaemonEvent.self) }
    }

    func ompFrames() async throws -> [JSONValue] {
        try await records().filter { $0.kind == .omp }.map(\.payload)
    }
}

extension SupervisorTimings {
    static let fastTests = SupervisorTimings(ready: .seconds(10), hello: .milliseconds(200), bridgeCall: .seconds(5), stop: .seconds(5), healthCheck: .seconds(2))
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

/// Runs `body`, failing with `Timeout` instead of hanging the suite.
func within<T: Sendable>(_ what: String, timeout: Duration = .seconds(10), _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw Timeout(what: what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
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

/// Records the order of events seen by different components.
final class Order: Sendable {
    private let state = Box<[String]>([])
    func note(_ value: String) { state.mutate { $0.append(value) } }
    var values: [String] { state.value }
}

/// What the fake omp owning `sessionFile` (its `session.jsonl`) recorded in `name` so far.
func fakeOmpLines(nextTo sessionFile: String, _ name: String) -> [String] {
    let url = URL(filePath: sessionFile).deletingLastPathComponent().appending(path: name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

import Foundation
@testable import IDEModel
import IDETransport
import os
import Testing

/// Journal fixtures. Each `.jsonl` is a capture of real omp runs (an approved bash call, an aborted pending ask,
/// extension methods, a SIGKILL mid-stream and its `--resume` run) turned into the records ompd journals:
/// every omp stdout frame verbatim as `.omp` — minus `assistantMessageEvent.partial` (a copy of `message`), command
/// catalogs and non-prompt responses — client answers as `.daemon uiAnswered` (protocol 1 form, without `response`), and process lifecycle as
/// `.daemon spawned/exited/lost`. `snapshot-*.json` are `session.snapshot` results built from the `get_entries` /
/// `get_state` responses of the resumed process after EOF and SIGKILL mid-tool.
enum Fixture {
    static func records(_ name: String) throws -> [JournalRecord] {
        let decoder = IDECoding.decoder()
        return try String(contentsOf: url(name, "jsonl"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(JournalRecord.self, from: Data($0.utf8)) }
    }

    static func snapshot(_ name: String) throws -> SessionSnapshot.Result {
        try IDECoding.decoder().decode(SessionSnapshot.Result.self, from: Data(contentsOf: url(name, "json")))
    }

    private static func url(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), "fixture \(name).\(ext)")
    }
}

let testDate = Date(timeIntervalSince1970: 1_790_330_000)

func record(_ seq: Seq, _ payload: JSONValue, kind: JournalRecord.Kind = .omp, at date: Date = testDate) -> JournalRecord {
    JournalRecord(sessionKey: "s1", seq: seq, ts: date, kind: kind, payload: payload)
}

func record(_ seq: Seq, _ event: DaemonEvent, at date: Date = testDate) throws -> JournalRecord {
    JournalRecord(sessionKey: "s1", seq: seq, ts: date, kind: .daemon, payload: try JSONValue(encoding: event))
}

func reduce(_ records: some Sequence<JournalRecord>) -> TranscriptReducer {
    var reducer = TranscriptReducer()
    for record in records { reducer.apply(record) }
    return reducer
}

func manifestEntry(_ key: SessionKey, workspace: String = "/tmp/workspace", status: SessionStatus = .settled) -> SessionManifestEntry {
    SessionManifestEntry(
        sessionKey: key, workspace: workspace, launch: LaunchSpec(ompPath: "/opt/homebrew/bin/omp", ompVersion: "18.3.1"),
        status: status, createdAt: testDate)
}

extension TranscriptItem {
    var user: UserMessage? { if case .user(let message) = content { message } else { nil } }
    var assistant: AssistantMessage? { if case .assistant(let message) = content { message } else { nil } }
    var tool: ToolCall? { if case .tool(let tool) = content { tool } else { nil } }
    var dialog: Dialog? { if case .dialog(let dialog) = content { dialog } else { nil } }
    var notice: Notice? { if case .notice(let notice) = content { notice } else { nil } }
}

extension AssistantMessage {
    func text(_ kind: Block.Kind) -> String { blocks.filter { $0.kind == kind }.map(\.text).joined() }
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

// MARK: - SessionBackend double

/// Records every call a `SessionViewModel` makes; `subscribe` succeeds at once, `snapshot` returns `snapshotResult`.
@MainActor
final class RecordingBackend: SessionBackend {
    var subscribes: [Subscribe.Params] = []
    var snapshots: [SessionKey] = []
    var commands: [JSONValue] = []
    var responses: [UIRespond.Params] = []
    var snapshotResult: SessionSnapshot.Result?
    /// Errors the next `snapshot` calls throw, in order.
    var snapshotFailures: [any Error] = []

    func subscribe(_ sessionKey: SessionKey, since: Seq) async throws -> Subscribe.Result {
        subscribes.append(.init(sessionKey: sessionKey, since: since))
        return .init(replayedThrough: since)
    }

    func snapshot(_ sessionKey: SessionKey) async throws -> SessionSnapshot.Result {
        snapshots.append(sessionKey)
        if !snapshotFailures.isEmpty { throw snapshotFailures.removeFirst() }
        guard let snapshotResult else { throw DaemonError(.noSuchSession, "no snapshot scripted") }
        return snapshotResult
    }

    func send(_ command: JSONValue, to sessionKey: SessionKey) async throws -> JSONValue {
        commands.append(command)
        return .null
    }

    func respond(to requestId: String, in sessionKey: SessionKey, with response: JSONValue) async throws {
        responses.append(.init(sessionKey: sessionKey, requestId: requestId, response: response))
    }
}

// MARK: - In-process daemon

/// A daemon made of the real `IDEServer` + `IDERouter`: serves a manifest and per-session journals, replays on
/// `subscribe`, and records every request it gets.
final class FakeDaemon: IDERequestHandler {
    let router = IDERouter()
    private let state: OSAllocatedUnfairLock<State>

    private struct State: Sendable {
        var sessions: [SessionManifestEntry]
        var journal: [SessionKey: [JournalRecord]]
        var subscribers: [SessionKey: [IDEConnection]] = [:]
        var subscribes: [Subscribe.Params] = []
        var ompCommands: [OmpCommand.Params] = []
        var snapshots: [SessionKey] = []
        var creates: [SessionCreate.Params] = []
    }

    init(sessions: [SessionManifestEntry], journal: [SessionKey: [JournalRecord]] = [:]) {
        let state = OSAllocatedUnfairLock(initialState: State(sessions: sessions, journal: journal))
        self.state = state
        router.on(Subscribe.self) { params, connection in
            state.withLock { s in
                s.subscribes.append(params)
                s.subscribers[params.sessionKey, default: []].append(connection)
                // Replayed under the lock so a concurrent `append` goes out after the replay, never inside it.
                let replay = (s.journal[params.sessionKey] ?? []).filter { $0.seq > params.since }
                for record in replay { connection.send(.event(record)) }
                return Subscribe.Result(replayedThrough: replay.last?.seq ?? params.since)
            }
        }
        router.on(OmpCommand.self) { params, _ in
            state.withLock { $0.ompCommands.append(params) }
            return ["accepted": true]
        }
        router.on(SessionSnapshot.self) { params, _ in
            state.withLock { $0.snapshots.append(params.sessionKey) }
            throw DaemonError(.internal, "snapshot not scripted")
        }
        router.on(SessionCreate.self) { params, _ in
            state.withLock { s in
                var entry = manifestEntry("created-\(s.creates.count + 1)", workspace: params.workspace, status: .starting)
                entry.launch.approvalMode = params.approvalMode
                s.creates.append(params)
                s.sessions.append(entry)
                return entry
            }
        }
    }

    var subscribes: [Subscribe.Params] { state.withLock { $0.subscribes } }
    var ompCommands: [OmpCommand.Params] { state.withLock { $0.ompCommands } }
    var snapshots: [SessionKey] { state.withLock { $0.snapshots } }
    var creates: [SessionCreate.Params] { state.withLock { $0.creates } }

    /// Journals `record` and pushes it to the session's live subscribers.
    func append(_ record: JournalRecord) {
        state.withLock { s in
            s.journal[record.sessionKey, default: []].append(record)
            for connection in s.subscribers[record.sessionKey] ?? [] { connection.send(.event(record)) }
        }
    }

    func sessionsForWelcome() async -> [SessionManifestEntry] { state.withLock { $0.sessions } }

    func handle(_ request: Request, from connection: IDEConnection) async -> Response {
        await router.route(request, from: connection)
    }

    func connectionClosed(_ connection: IDEConnection) async {
        state.withLock { s in
            for key in s.subscribers.keys { s.subscribers[key]?.removeAll { $0 == connection } }
        }
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

    func startServer(_ daemon: FakeDaemon, startedAt: Date = testDate) async throws -> IDEServer {
        let server = IDEServer(
            socketPath: paths.socket.path(percentEncoded: false), token: Self.token, daemonVersion: "fake-ompd",
            startedAt: startedAt, handler: daemon)
        try await server.start()
        return server
    }

    func remove() {
        try? FileManager.default.removeItem(at: paths.root)
    }
}

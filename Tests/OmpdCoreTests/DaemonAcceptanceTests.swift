import Darwin
import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// Acceptance with the real `ompd` binary, real omp and `anthropic/claude-haiku-4-5` (costs model
/// calls, ~2–4 min). Not part of the default run: `scripts/acceptance.sh` builds ompd and runs it with
/// `OMPD_ACCEPTANCE=1`. Uses the dev LaunchAgent `com.omp-ide.ompd.dev` (installed and removed by the test) and only
/// signals processes it started.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OMPD_ACCEPTANCE"] == "1", "set OMPD_ACCEPTANCE=1 (scripts/acceptance.sh)"))
struct DaemonAcceptanceTests {
    static let prompt = """
        Use the task tool exactly once to run 3 subagents in parallel, with ids Sleeper1, Sleeper2 and Sleeper3. \
        Each subagent's assignment: run the bash command `/bin/sleep 5` (exactly that command, nothing else), then \
        reply with just its own id. When all three have finished, reply with exactly FANOUT-DONE and nothing else.
        """

    @Test(.timeLimit(.minutes(20))) func fanOutSurvivesReconnectAndDaemonRestart() async throws {
        let rig = try AcceptanceRig()
        defer {
            // The run's home, journals and omp session files: removed unless OMPD_ACCEPTANCE_KEEP=1.
            if ProcessInfo.processInfo.environment["OMPD_ACCEPTANCE_KEEP"] == "1" {
                print("acceptance: evidence kept in \(rig.root.path(percentEncoded: false))")
            } else {
                rig.remove()
            }
        }
        let phase1Key = try await replayMatchesAnAlwaysConnectedClient(rig)
        try await kickstartResumesTheSession(rig, alsoRestoring: phase1Key)
    }

    /// Clients A (always connected) and B (drops mid-run, resubscribes with its last seq) see the same records.
    private func replayMatchesAnAlwaysConnectedClient(_ rig: AcceptanceRig) async throws -> SessionKey {
        let daemon = try rig.launchDaemon(log: "phase1.log")
        defer { if daemon.isRunning { kill(daemon.processIdentifier, SIGTERM) } }
        let a = try await rig.connect()
        let entry = try await a.client.call(
            SessionCreate.self, .init(workspace: rig.workspace, approvalMode: "yolo", model: "anthropic/claude-haiku-4-5"))
        let key = entry.sessionKey
        _ = try await a.client.call(Subscribe.self, .init(sessionKey: key, since: 0))
        let b = try await rig.connect()
        _ = try await b.client.call(Subscribe.self, .init(sessionKey: key, since: 0))
        let started = ContinuousClock.now
        _ = try await a.client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "prompt", "message": .string(Self.prompt)]))

        try await eventually("a subagent running /bin/sleep", timeout: .seconds(240)) { b.events(key).contains(where: isSubagentSleep) }
        let beforeDrop = b.events(key)
        let dropSeq = try #require(beforeDrop.last?.seq)
        await b.close()
        try await Task.sleep(for: .seconds(3))
        let b2 = try await rig.connect()
        let resubscribed = try await b2.client.call(Subscribe.self, .init(sessionKey: key, since: dropSeq))

        try await eventually("session_settled", timeout: .seconds(300)) { a.events(key).contains { $0.ompType == "session_settled" } }
        try await Task.sleep(for: .seconds(2)) // trailing records (status change, widgets)
        let aRecords = a.events(key)
        let lastSeq = try #require(aRecords.last?.seq)
        try await eventually("B caught up to seq \(lastSeq)") { (b2.events(key).last?.seq ?? 0) >= lastSeq }
        let bRecords = beforeDrop + b2.events(key).filter { $0.seq <= lastSeq }

        #expect(aRecords.map(\.seq) == Array(1...lastSeq))
        #expect(bRecords.map(\.seq) == Array(1...lastSeq))
        let aBytes = try recordBytes(aRecords)
        #expect(try recordBytes(bRecords) == aBytes)
        let disk = try rig.journalLines(key)
        #expect(Array(disk.prefix(aBytes.count)) == aBytes)
        let spawns = aRecords.compactMap { if case .spawned(let pid, _, _)? = $0.daemonEvent { pid } else { nil } }
        #expect(spawns.count == 1)
        #expect(!aRecords.contains { if case .exited? = $0.daemonEvent { true } else { false } })
        let subagents = Set(aRecords.filter { $0.ompType == "subagent_lifecycle" }.compactMap { $0.payload["payload"]?["id"]?.stringValue })
        #expect(subagents.count >= 3)

        let elapsed = ContinuousClock.now - started
        print("""
            acceptance phase 1 (direct child ompd pid \(daemon.processIdentifier), session \(key)):
              records 1...\(lastSeq) in \(elapsed); kinds \(histogram(aRecords.map(\.kind.rawValue)))
              omp frame types \(histogram(aRecords.compactMap(\.ompType)))
              subagents \(subagents.sorted()); omp spawned once (pid \(spawns.first ?? -1)), no exits
              B dropped after seq \(dropSeq) (\(beforeDrop.count) records), resubscribed since \(dropSeq): replayedThrough \
            \(resubscribed.replayedThrough), then live to \(lastSeq)
              B == A byte-for-byte for all \(lastSeq) records: \(try recordBytes(bRecords) == aBytes); wire == journal file: \
            \(Array(disk.prefix(aBytes.count)) == aBytes)
              final reply: \(finalAssistantText(aRecords) ?? "?")
            """)
        await a.close()
        await b2.close()

        // Graceful SIGTERM path: omp gets stdin EOF and records session_exit {kind:"normal"}; ompd exits 0.
        let sessionFile = try #require(try rig.manifest().sessions.first { $0.sessionKey == key }?.sessionFile)
        let signalled = Date()
        kill(daemon.processIdentifier, SIGTERM)
        let status = try await rig.waitForExit(daemon, timeout: .seconds(30))
        let exitKind = SessionFileTail.sessionExitKind(path: sessionFile, recordedSince: signalled)
        let journaledExit = try rig.journalRecords(key).last { if case .exited? = $0.daemonEvent { true } else { false } }?.daemonEvent
        #expect(status == 0)
        #expect(exitKind == "normal")
        #expect(journaledExit == .exited(code: 0, signal: nil, sessionExitKind: "normal"))
        print("  SIGTERM: ompd exit \(status); session JSONL session_exit kind \(exitKind ?? "none"); journal \(String(describing: journaledExit))")
        return key
    }

    /// `launchctl kickstart -k` of the dev LaunchAgent mid-fan-out: omp ends on stdin EOF (`session_exit` normal) and
    /// the restarted daemon resumes the session with `--resume`.
    private func kickstartResumesTheSession(_ rig: AcceptanceRig, alsoRestoring phase1Key: SessionKey) async throws {
        defer { _ = try? rig.agent("uninstall") }
        try rig.agent("install", rig.home.path(percentEncoded: false), "--", arguments: rig.ompdArguments)
        let first = try await rig.connect(timeout: .seconds(60))
        let firstStatus = try await first.client.call(DaemonStatus.self, Empty())
        try await eventually("phase-1 session resumed", timeout: .seconds(60)) {
            try await first.client.call(ListSessions.self, Empty()).sessions.first { $0.sessionKey == phase1Key }?.status == .settled
        }
        let entry = try await first.client.call(
            SessionCreate.self, .init(workspace: rig.workspace, approvalMode: "yolo", model: "anthropic/claude-haiku-4-5"))
        let key = entry.sessionKey
        _ = try await first.client.call(Subscribe.self, .init(sessionKey: key, since: 0))
        _ = try await first.client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "prompt", "message": .string(Self.prompt)]))
        try await eventually("a subagent running /bin/sleep", timeout: .seconds(240)) { first.events(key).contains(where: isSubagentSleep) }
        let preKick = try #require(first.events(key).last?.seq)
        let oldOmp = first.events(key).compactMap { if case .spawned(let pid, _, _)? = $0.daemonEvent { pid } else { nil } }.last

        let kicked = Date()
        try rig.agent("kickstart")
        let second = try await eventuallyValue("restarted daemon", timeout: .seconds(90)) { () -> Connected? in
            guard let client = try? await rig.connect(timeout: .seconds(2)),
                  let status = try? await client.client.call(DaemonStatus.self, Empty()), status.pid != firstStatus.pid
            else { return nil }
            return client
        }
        _ = try await second.client.call(Subscribe.self, .init(sessionKey: key, since: preKick))
        try await eventually("resumed spawn", timeout: .seconds(90)) {
            second.events(key).contains { if case .spawned(_, _, true)? = $0.daemonEvent { true } else { false } }
        }
        try await eventually("settled after resume", timeout: .seconds(120)) {
            try await second.client.call(ListSessions.self, Empty()).sessions.first { $0.sessionKey == key }?.status == .settled
        }
        let afterKick = second.events(key)
        let manifestEntry = try #require(try await second.client.call(ListSessions.self, Empty()).sessions.first { $0.sessionKey == key })
        let sessionFile = try #require(manifestEntry.sessionFile)
        let exitKind = SessionFileTail.sessionExitKind(path: sessionFile, recordedSince: kicked)
        let newOmp = afterKick.compactMap { if case .spawned(let pid, _, true)? = $0.daemonEvent { pid } else { nil } }.last
        let newArgv = try newOmp.map { try rig.run("/bin/ps", ["-o", "command=", "-p", String($0)]).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let statusJSON = try rig.run(rig.ompd, ["status", "--json"], environment: ["OMPD_HOME": rig.home.path(percentEncoded: false)]).stdout
        let statusTable = try rig.run(rig.ompd, ["status"], environment: ["OMPD_HOME": rig.home.path(percentEncoded: false)]).stdout
        let cliStatus = try IDECoding.decoder().decode(DaemonStatus.Result.self, from: Data(statusJSON.utf8))

        #expect(exitKind == "normal")
        #expect(afterKick.contains { $0.daemonEvent == .exited(code: 0, signal: nil, sessionExitKind: "normal") })
        // The prompt in flight is completed as aborted: by omp itself on stdin EOF, or else by ompd's synthesized one.
        #expect(afterKick.contains { $0.ompType == "prompt_result" && $0.payload["status"] == "aborted" })
        #expect(afterKick.contains { $0.daemonEvent == .statusChanged(.resuming) })
        #expect(afterKick.contains { if case .notice("info", let message)? = $0.daemonEvent { message.contains("resuming") } else { false } })
        #expect(newArgv?.contains("--resume ") == true && newArgv?.contains(URL(filePath: sessionFile).lastPathComponent) == true)
        #expect(cliStatus.pid != firstStatus.pid)
        #expect(cliStatus.sessions.first { $0.sessionKey == key }?.status == .settled)
        #expect(cliStatus.sessions.first { $0.sessionKey == key }?.closedByUser == false)

        let log = (try? String(contentsOf: rig.home.appending(path: "ompd.log"), encoding: .utf8)) ?? ""
        print("""
            acceptance phase 2 (LaunchAgent com.omp-ide.ompd.dev):
              ompd pid \(firstStatus.pid) -> \(cliStatus.pid) after kickstart -k; omp pid \(oldOmp ?? -1) -> \(newOmp ?? -1)
              journal after seq \(preKick): \(afterKick.compactMap { $0.daemonEvent.map(describe) ?? ($0.ompType == "prompt_result" ? "prompt_result \($0.payload["status"]?.stringValue ?? "?")\($0.payload["synthesized"] == true ? " (synthesized by ompd)" : " (from omp)")" : nil) })
              session JSONL \(sessionFile): newest session_exit since the kick has kind \(exitKind ?? "none")
              resumed omp argv: \(newArgv ?? "?")
            ompd status:
            \(statusTable)
            ompd status --json (sessions): \(cliStatus.sessions.map { "\($0.sessionKey) \($0.status.rawValue) lastSeq \($0.lastSeq)" })
            ompd.log:
            \(log)
            """)
        await first.close()
        await second.close()

        let daemonPID = cliStatus.pid
        try rig.agent("uninstall")
        try await eventually("dev ompd gone after bootout", timeout: .seconds(30)) { kill(daemonPID, 0) != 0 }
        if let newOmp { try await eventually("omp gone after bootout", timeout: .seconds(30)) { kill(newOmp, 0) != 0 } }
        print("  uninstall: ompd \(daemonPID) and omp \(newOmp ?? -1) exited")
    }
}

/// A subagent's `bash` tool starting (the fan-out is under way), from `subagent_event` frames.
private func isSubagentSleep(_ record: JournalRecord) -> Bool {
    guard record.ompType == "subagent_event", let event = record.payload["payload"]?["event"] else { return false }
    return event["type"] == "tool_execution_start" && event["toolName"] == "bash"
}

private func finalAssistantText(_ records: [JournalRecord]) -> String? {
    for record in records.reversed() where record.ompType == "message_end" {
        guard let message = record.payload["message"], message["role"] == "assistant" else { continue }
        let text = (message["content"]?.arrayValue ?? []).compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined()
        if !text.isEmpty { return text }
    }
    return nil
}

private func histogram(_ values: [String]) -> String {
    Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
}

private func describe(_ event: DaemonEvent) -> String {
    switch event {
    case .spawned(let pid, let version, let resumed): "spawned(pid \(pid), omp \(version), resumed \(resumed))"
    case .exited(let code, let signal, let kind): "exited(code \(code.map(String.init) ?? "-"), signal \(signal.map(String.init) ?? "-"), session_exit \(kind ?? "-"))"
    case .statusChanged(let status): "status \(status.rawValue)"
    case .notice(let level, let message): "notice[\(level)] \(message)"
    case .uiAnswered(let id): "uiAnswered \(id)"
    case .uiAbandoned(let id): "uiAbandoned \(id)"
    case .lost(let from, let to, let reason): "lost \(from)...\(to) \(reason)"
    }
}

/// Paths, binaries and helpers of one acceptance run under a short `/tmp` root.
struct AcceptanceRig {
    let root: URL
    let home: URL
    let paths: AppSupportPaths
    let sessions: String
    let workspace: String
    let overlay: String
    let ompd: String
    let agentScript: String

    init() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        ompd = environment["OMPD_BINARY"] ?? repository.appending(path: ".build/out/Products/Debug/ompd").path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: ompd) else { throw Timeout(what: "an ompd binary at \(ompd) (swift build --product ompd)") }
        agentScript = repository.appending(path: "scripts/dev-launchagent.sh").path(percentEncoded: false)
        root = URL(filePath: "/tmp/oa-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        paths = AppSupportPaths(root: home)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        sessions = root.appending(path: "sessions").path(percentEncoded: false)
        workspace = root.appending(path: "workspace").path(percentEncoded: false)
        try fileManager.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        overlay = root.appending(path: "omp-config.yml").path(percentEncoded: false)
        // Test overlay: no memory/autolearn writes to the user's stores, every role pinned to haiku.
        try """
            memory:
              backend: off
            autolearn:
              enabled: false
            modelRoles:
              default: anthropic/claude-haiku-4-5
              smol: anthropic/claude-haiku-4-5
              slow: anthropic/claude-haiku-4-5
              plan: anthropic/claude-haiku-4-5
              web: anthropic/claude-haiku-4-5
            task:
              enableEffort: false
              agentModelOverrides:
                task: anthropic/claude-haiku-4-5
                sonic: anthropic/claude-haiku-4-5
                scout: anthropic/claude-haiku-4-5
                reviewer: anthropic/claude-haiku-4-5
                security-reviewer: anthropic/claude-haiku-4-5

            """.write(toFile: overlay, atomically: true, encoding: .utf8)
    }

    /// `ompd run` arguments: private session dir, the overlay, and no user extensions/skills/rules/LSP.
    var ompdArguments: [String] {
        ["--session-dir", sessions]
            + ["--config", overlay, "--thinking", "off", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp"].flatMap { ["--omp-arg", $0] }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// `ompd run` as a child of this process, with the agent shell's markers dropped from its environment.
    func launchDaemon(log: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: ompd)
        process.arguments = ["run"] + ompdArguments
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("__XPC_")
                && !["OMPCODE", "CLAUDECODE", "CI", "ORCA_PI_STATUS_OWNED", "AGENT", "OMPD_ACCEPTANCE", "OMPD_BINARY"].contains(key)
        }
        environment[AppSupportPaths.homeEnvironmentKey] = home.path(percentEncoded: false)
        process.environment = environment
        let logURL = root.appending(path: log)
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    func waitForExit(_ process: Process, timeout: Duration) async throws -> Int32 {
        try await eventually("ompd \(process.processIdentifier) exit", timeout: timeout) { !process.isRunning }
        return process.terminationStatus
    }

    /// A client of the daemon on `home`, retried until the daemon accepts it.
    func connect(timeout: Duration = .seconds(30)) async throws -> Connected {
        try await eventuallyValue("ompd accepting clients", timeout: timeout) { () -> Connected? in
            guard let token = try? String(contentsOf: paths.token, encoding: .utf8) else { return nil }
            let client = IDEClient(socketPath: paths.socket.path(percentEncoded: false), token: token, clientVersion: "acceptance")
            guard let welcome = try? await client.connect() else { return nil }
            return Connected(client: client, welcome: welcome)
        }
    }

    func manifest() throws -> SessionManifest {
        try IDECoding.decoder().decode(SessionManifest.self, from: Data(contentsOf: paths.manifest))
    }

    func journalLines(_ key: SessionKey) throws -> [Data] {
        let data = try Data(contentsOf: paths.journalDir.appending(path: "\(key).jsonl"))
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    func journalRecords(_ key: SessionKey) throws -> [JournalRecord] {
        let decoder = IDECoding.decoder()
        return try journalLines(key).map { try decoder.decode(JournalRecord.self, from: $0) }
    }

    /// `scripts/dev-launchagent.sh <verb> [<args>...]` with this run's ompd binary.
    @discardableResult
    func agent(_ verb: String, _ leading: String..., arguments: [String] = []) throws -> String {
        let result = try run(agentScript, [verb] + leading + arguments, environment: ["OMPD_BINARY": ompd])
        guard result.status == 0 else { throw Timeout(what: "dev-launchagent.sh \(verb) (exit \(result.status)): \(result.stderr)") }
        return result.stdout
    }

    /// Runs a short command to completion.
    func run(_ executable: String, _ arguments: [String], environment extra: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

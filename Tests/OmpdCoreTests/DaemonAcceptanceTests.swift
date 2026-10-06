import Darwin
import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// Acceptance for TUI sessions, with the real `ompd` binary, real omp and `anthropic/claude-haiku-4-5`
/// (costs model calls, a few minutes). Not part of the default run: `scripts/acceptance.sh` builds ompd and runs it with
/// `OMPD_ACCEPTANCE=1`. Uses the dev LaunchAgent `com.magicelklabs.lantern.ompd.dev` (installed and removed by the test) and only
/// signals processes it started.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OMPD_ACCEPTANCE"] == "1", "set OMPD_ACCEPTANCE=1 (scripts/acceptance.sh)"))
struct DaemonAcceptanceTests {
    static let prompt = """
        Use the task tool exactly once to run one subagent with id Sleeper. Its assignment: run the bash command \
        `/bin/sleep 10` (exactly that command, nothing else), then reply with just its own id. When it has finished, \
        reply with exactly NESTED-DONE and nothing else.
        """

    @Test(.timeLimit(.minutes(20))) func tuiSessionSurvivesReattachAndDaemonRestart() async throws {
        let rig = try AcceptanceRig()
        defer {
            // The run's home and omp session files: removed unless OMPD_ACCEPTANCE_KEEP=1.
            if ProcessInfo.processInfo.environment["OMPD_ACCEPTANCE_KEEP"] == "1" {
                print("acceptance: evidence kept in \(rig.root.path(percentEncoded: false))")
            } else {
                rig.remove()
            }
        }
        let phase1Key = try await reattachMidRunShowsTheTUI(rig)
        try await kickstartResumesTheSession(rig, alsoRestoring: phase1Key)
    }

    /// A client drops and re-attaches while a nested subagent runs `/bin/sleep 10`: the repaint is the TUI, nothing in
    /// omp noticed, and the turn completes. Then SIGTERM takes the graceful path.
    private func reattachMidRunShowsTheTUI(_ rig: AcceptanceRig) async throws -> SessionKey {
        let daemon = try rig.launchDaemon(log: "phase1.log")
        defer { if daemon.isRunning { kill(daemon.processIdentifier, SIGTERM) } }
        let a = try await rig.connect()
        let started = ContinuousClock.now
        let (key, ptyId, sessionFile) = try await rig.startSession(a)
        let ompPID = try await rig.pid(of: ptyId, a)
        try await rig.prompt(a, ptyId)
        try await a.waitForStatus(key, .busy, timeout: .seconds(60))
        // The bridge wrote the session file at the first run: a crash during this turn would resume, not start over.
        try await eventually("session file on disk during the first turn", timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: sessionFile)
        }
        let sleeper = try await eventuallyValue("a subagent running /bin/sleep 10", timeout: .seconds(240)) {
            try rig.descendant(of: ompPID, command: "/bin/sleep 10")
        }

        let b = try await rig.connect()
        let before = screenLines(try await b.client.call(PTYAttach.self, .init(ptyId: ptyId)))
        await b.close()
        try await Task.sleep(for: .seconds(2))
        let b2 = try await rig.connect()
        let after = screenLines(try await b2.client.call(PTYAttach.self, .init(ptyId: ptyId))).joined(separator: "\n")
        #expect(after.contains("NESTED-DONE"), "the typed prompt is on the TUI's screen")
        #expect(after.contains("Haiku"), "omp's status line is on the screen")
        #expect(kill(sleeper, 0) == 0, "the subagent's tool kept running while the client was away")
        #expect(try await a.entry(key).ptyId == ptyId && kill(ompPID, 0) == 0, "omp was never touched")

        try await a.waitForStatus(key, .idle, timeout: .seconds(300))
        let finished = try await a.entry(key)
        let reply = try rig.assistantTexts(sessionFile).last ?? ""
        #expect(reply.contains("NESTED-DONE"))
        #expect(finished.title != nil && finished.lastActiveAt != nil)
        print("""
            acceptance phase 1 (direct child ompd pid \(daemon.processIdentifier), session \(key), omp pid \(ompPID)):
              turn with nested /bin/sleep 10 (pid \(sleeper)) done in \(ContinuousClock.now - started); title "\(finished.title ?? "-")"
              B attached (\(before.count) lines), dropped mid-run, re-attached: screen shows the TUI (prompt + status line): \
            \(after.contains("NESTED-DONE") && after.contains("Haiku"))
              final reply: \(reply)
            """)
        await a.close()
        await b2.close()

        // Graceful SIGTERM path: the bridge disposes omp (`session_exit {kind:"normal"}`); ompd exits 0.
        let signalled = Date()
        kill(daemon.processIdentifier, SIGTERM)
        let status = try await rig.waitForExit(daemon, timeout: .seconds(30))
        let exitKind = SessionFileTail.sessionExitKind(path: sessionFile, recordedSince: signalled)
        #expect(status == 0)
        #expect(exitKind == "normal")
        #expect(kill(ompPID, 0) != 0)
        print("  SIGTERM: ompd exit \(status); session JSONL session_exit kind \(exitKind ?? "none"); omp \(ompPID) gone")
        return key
    }

    /// `launchctl kickstart -k` of the dev LaunchAgent mid-run: omp is disposed through its bridge (`session_exit`
    /// normal) and the restarted daemon respawns the session with `--resume` into a new PTY.
    private func kickstartResumesTheSession(_ rig: AcceptanceRig, alsoRestoring phase1Key: SessionKey) async throws {
        defer { _ = try? rig.agent("uninstall") }
        try rig.agent("install", rig.home.path(percentEncoded: false), "--", arguments: rig.ompdArguments)
        let first = try await rig.connect(timeout: .seconds(60))
        let firstStatus = try await first.client.call(DaemonStatus.self, Empty())
        try await first.waitForStatus(phase1Key, .idle, timeout: .seconds(60))
        let restoredPhase1 = try await first.entry(phase1Key)

        let (key, oldPTY, sessionFile) = try await rig.startSession(first)
        let oldOmp = try await rig.pid(of: oldPTY, first)
        try await rig.prompt(first, oldPTY)
        let sleeper = try await eventuallyValue("a subagent running /bin/sleep 10", timeout: .seconds(240)) {
            try rig.descendant(of: oldOmp, command: "/bin/sleep 10")
        }

        let kicked = Date()
        try rig.agent("kickstart")
        let second = try await eventuallyValue("restarted daemon", timeout: .seconds(90)) { () -> Connected? in
            guard let client = try? await rig.connect(timeout: .seconds(2)),
                  let status = try? await client.client.call(DaemonStatus.self, Empty()), status.pid != firstStatus.pid
            else { return nil }
            return client
        }
        try await second.waitForStatus(key, .idle, timeout: .seconds(120))
        let resumed = try await second.entry(key)
        let newPTY = try #require(resumed.ptyId)
        let newOmp = try await rig.pid(of: newPTY, second)
        let newArgv = try rig.run("/bin/ps", ["-o", "command=", "-p", String(newOmp)]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let exitKind = SessionFileTail.sessionExitKind(path: sessionFile, recordedSince: kicked)
        let screen = screenLines(try await second.client.call(PTYAttach.self, .init(ptyId: newPTY)))
        let statusJSON = try rig.run(rig.ompd, ["status", "--json"], environment: ["OMPD_HOME": rig.home.path(percentEncoded: false)]).stdout
        let statusTable = try rig.run(rig.ompd, ["status"], environment: ["OMPD_HOME": rig.home.path(percentEncoded: false)]).stdout
        let cliStatus = try IDECoding.decoder().decode(DaemonStatus.Result.self, from: Data(statusJSON.utf8))

        #expect(newPTY != oldPTY)
        #expect(exitKind == "normal")
        #expect(kill(oldOmp, 0) != 0 && kill(sleeper, 0) != 0, "the old omp and its tool processes are gone")
        #expect(newArgv.contains("--resume ") && newArgv.contains(URL(filePath: sessionFile).lastPathComponent))
        #expect(screen.contains("— terminal restarted —"), "the new PTY continues the old screen")
        #expect(cliStatus.pid != firstStatus.pid)
        #expect(cliStatus.sessions.first { $0.sessionKey == key }.map { $0.status == .idle && !$0.closedByUser } == true)
        #expect(cliStatus.ptys.first { $0.ptyId == newPTY }?.sessionKey == key)

        let log = (try? String(contentsOf: rig.home.appending(path: "ompd.log"), encoding: .utf8)) ?? ""
        print("""
            acceptance phase 2 (LaunchAgent com.magicelklabs.lantern.ompd.dev):
              phase-1 session \(phase1Key) resumed at daemon start: \(restoredPhase1.status.rawValue), pty \(restoredPhase1.ptyId ?? "-")
              ompd pid \(firstStatus.pid) -> \(cliStatus.pid) after kickstart -k; session \(key): pty \(oldPTY) -> \(newPTY), \
            omp pid \(oldOmp) -> \(newOmp) (sleep \(sleeper) gone: \(kill(sleeper, 0) != 0))
              session JSONL \(sessionFile): newest session_exit since the kick has kind \(exitKind ?? "none")
              resumed omp argv: \(newArgv)
              new PTY screen has the restart divider: \(screen.contains("— terminal restarted —"))
            ompd status:
            \(statusTable)
            ompd.log:
            \(log)
            """)
        await first.close()
        await second.close()

        let daemonPID = cliStatus.pid
        try rig.agent("uninstall")
        try await eventually("dev ompd gone after bootout", timeout: .seconds(30)) { kill(daemonPID, 0) != 0 }
        try await eventually("omp gone after bootout", timeout: .seconds(30)) { kill(newOmp, 0) != 0 }
        print("  uninstall: ompd \(daemonPID) and omp \(newOmp) exited")
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
            !key.hasPrefix("DYLD_") && !key.hasPrefix("__XPC_") && !key.hasPrefix("LANTERN_")
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

    /// A new session on haiku (yolo approvals), attached by `client`, once its TUI is idle.
    func startSession(_ client: Connected) async throws -> (SessionKey, PTYID, String) {
        let entry = try await client.client.call(
            SessionCreate.self, .init(workspace: workspace, approvalMode: "yolo", model: "anthropic/claude-haiku-4-5", cols: 120, rows: 40))
        let ptyId = try #require(entry.ptyId)
        _ = try await client.client.call(PTYAttach.self, .init(ptyId: ptyId))
        try await client.waitForStatus(entry.sessionKey, .idle, timeout: .seconds(60))
        let sessionFile = try #require(try await client.entry(entry.sessionKey).sessionFile)
        return (entry.sessionKey, ptyId, sessionFile)
    }

    /// Types `DaemonAcceptanceTests.prompt` into the TUI and submits it, as a user at the keyboard would.
    func prompt(_ client: Connected, _ ptyId: PTYID) async throws {
        _ = try await client.client.call(PTYWrite.self, .init(ptyId: ptyId, data: Data(DaemonAcceptanceTests.prompt.utf8)))
        try await Task.sleep(for: .milliseconds(500))
        _ = try await client.client.call(PTYWrite.self, .init(ptyId: ptyId, data: Data("\r".utf8)))
    }

    func pid(of ptyId: PTYID, _ client: Connected) async throws -> Int32 {
        try #require(try await client.client.call(PTYList.self, Empty()).ptys.first { $0.ptyId == ptyId }?.pid)
    }

    /// A process below `ancestor` whose command line is exactly `command`.
    func descendant(of ancestor: Int32, command: String) throws -> Int32? {
        let rows = try run("/bin/ps", ["-axo", "pid=,ppid=,command="]).stdout.split(separator: "\n").compactMap { line -> (Int32, Int32, String)? in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return (pid, ppid, String(fields[2]))
        }
        let parents = Dictionary(rows.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        for (pid, _, line) in rows where line == command {
            var cursor = pid
            while let parent = parents[cursor], parent > 1 {
                if parent == ancestor { return pid }
                cursor = parent
            }
        }
        return nil
    }

    /// Text of every assistant message in an omp session JSONL, in order.
    func assistantTexts(_ sessionFile: String) throws -> [String] {
        try String(contentsOfFile: sessionFile, encoding: .utf8).split(separator: "\n").compactMap { line -> String? in
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), entry["type"] == "message",
                  let message = entry["message"], message["role"] == "assistant" else { return nil }
            let text = (message["content"]?.arrayValue ?? []).compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined()
            return text.isEmpty ? nil : text
        }
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

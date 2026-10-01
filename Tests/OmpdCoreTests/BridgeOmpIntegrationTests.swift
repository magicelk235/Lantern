import Darwin
import Foundation
import IDEProtocol
import os
import Testing
@testable import OmpdCore

/// The installed omp: `$OMP_BINARY`, else the first `omp` on `PATH` or in Homebrew's prefixes.
private let ompExecutable: URL? = {
    let environment = ProcessInfo.processInfo.environment
    if let explicit = environment["OMP_BINARY"], FileManager.default.isExecutableFile(atPath: explicit) {
        return URL(filePath: explicit)
    }
    let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    return directories.lazy.map { URL(filePath: $0).appending(path: "omp") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
}()

/// A spawned omp: stdout lines, stderr and exit are recorded; stdin takes RPC commands.
private final class OmpChild {
    let pid: Int32
    private let process = Process()
    private let input: FileHandle
    private let output = OSAllocatedUnfairLock(initialState: Output())
    private let exit = OSAllocatedUnfairLock<Exit?>(initialState: nil)

    struct Exit: Sendable, Equatable {
        var status: Int32
        var reason: Process.TerminationReason
    }

    private struct Output: Sendable {
        var pending: [UInt8] = []
        var lines: [String] = []
        var stderr = Data()
    }

    init(_ executable: URL, _ arguments: [String], environment: [String: String], cwd: URL) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let output = output
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            output.withLock { o in
                o.pending += data
                while let newline = o.pending.firstIndex(of: 0x0A) {
                    o.lines.append(String(decoding: o.pending[..<newline], as: UTF8.self))
                    o.pending.removeFirst(newline + 1)
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            output.withLock { $0.stderr += data }
        }
        let exit = exit
        process.terminationHandler = { finished in
            exit.withLock { $0 = Exit(status: finished.terminationStatus, reason: finished.terminationReason) }
        }
        try process.run()
        pid = process.processIdentifier
        input = stdin.fileHandleForWriting
    }

    var stderrText: String { output.withLock { String(decoding: $0.stderr, as: UTF8.self) } }

    func send(_ command: JSONValue) throws {
        var line = try JSONEncoder().encode(command)
        line.append(0x0A)
        try input.write(contentsOf: line)
    }

    func closeStdin() {
        try? input.close()
    }

    /// The first stdout JSON line matching `predicate`.
    func frame(_ what: String, seconds: Double = 60, where predicate: @escaping @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
        let output = output
        return try await bridgeWithin(what, seconds: seconds) {
            while true {
                let lines = output.withLock { $0.lines }
                for line in lines {
                    if let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), predicate(frame) { return frame }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func waitForExit(seconds: Double = 30) async throws -> Exit {
        let exit = exit
        do {
            return try await bridgeWithin("omp pid \(pid) to exit", seconds: seconds) {
                while true {
                    if let status = exit.withLock({ $0 }) { return status }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            let lines = output.withLock { $0.lines.suffix(5) }
            let arguments = (process.arguments ?? []).filter { !$0.hasPrefix("/") }.joined(separator: " ")
            throw ExitTimeout(description: "\(error) (omp \(arguments)); stderr: \(stderrText.suffix(1500)); last stdout: \(lines)")
        }
    }

    struct ExitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// SIGKILLs the child if it is still running (only processes this test spawned).
    func killIfRunning() {
        if exit.withLock({ $0 }) == nil { kill(pid, SIGKILL) }
    }
}

/// Private omp surroundings: IDE home (`OMPD_HOME`), session dir, workspace, settings overlay, terminal id.
private struct Sandbox {
    let dir: StorageTempDir
    let paths: AppSupportPaths
    let sessions: URL
    let workspace: URL
    let overlay: URL
    let bridge: URL
    let terminal: TerminalIdentity

    init() throws {
        dir = try StorageTempDir()
        paths = AppSupportPaths(root: dir.url.appending(path: "home", directoryHint: .isDirectory))
        try paths.prepare()
        sessions = dir.url.appending(path: "sessions", directoryHint: .isDirectory)
        workspace = dir.url.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        overlay = dir.url.appending(path: "overlay.yml")
        // Keep the run off the user's memory / auto-learn surface; no model turn happens anyway.
        try Data("memory:\n  backend: \"off\"\nautolearn:\n  enabled: false\n".utf8).write(to: overlay)
        bridge = try BridgeInstaller.stage(into: paths)
        terminal = TerminalIdentity()
    }

    /// `extensions` load in order; the default is ompd's staged copy.
    func arguments(_ extra: [String] = [], extensions: [URL]? = nil) -> [String] {
        [
            "--mode", "rpc", "--no-ui",
            "--cwd", workspace.path(percentEncoded: false),
            "--session-dir", sessions.path(percentEncoded: false),
            "--config", overlay.path(percentEncoded: false),
        ]
            + (extensions ?? [bridge]).flatMap { ["-e", $0.path(percentEncoded: false)] }
            + [
                "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-title",
                "--model", "anthropic/claude-haiku-4-5", "--thinking", "off",
            ] + extra
    }

    /// Variables omp derives a terminal id from when it has no TTY (session-switching-and-recent-listing.md).
    static let terminalIdentifiers = [
        "TERM_SESSION_ID", "TMUX_PANE", "ZELLIJ_PANE_ID", "CMUX_SURFACE_ID", "KITTY_WINDOW_ID", "WEZTERM_PANE", "WT_SESSION",
    ]

    /// The test's environment without any daemon wiring, pointed at this sandbox's `OMPD_HOME` and terminal id, plus
    /// `adding`.
    func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("OMP_IDE_") && !Self.terminalIdentifiers.contains($0.key)
        }
        environment[AppSupportPaths.homeEnvironmentKey] = paths.root.path(percentEncoded: false)
        environment["PI_NO_TITLE"] = "1"
        environment["TERM_SESSION_ID"] = terminal.id
        return environment.merging(extra) { _, new in new }
    }

    func spawn(
        _ omp: URL, _ extra: [String] = [], extensions: [URL]? = nil, adding environment: [String: String] = [:]
    ) throws -> OmpChild {
        try OmpChild(omp, arguments(extra, extensions: extensions), environment: self.environment(adding: environment), cwd: workspace)
    }
}

/// The terminal a sandbox's omps say they run in. omp keeps a `--continue` breadcrumb per terminal
/// (`~/.omp/agent/terminal-sessions/apple-<TERM_SESSION_ID>`): with the terminal running the tests they would share
/// (and overwrite) the user's own, and with each other `--continue` would follow another test's session. Without any
/// id `--continue` falls back to the newest session omp knows of, which under a busy test run is not reliably this
/// sandbox's. A fresh id per sandbox makes `--continue` follow this sandbox's own last session; its breadcrumb is
/// removed with the sandbox.
private final class TerminalIdentity: Sendable {
    let id = UUID().uuidString

    deinit {
        let breadcrumb = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".omp/agent/terminal-sessions/apple-\(id)", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: breadcrumb)
    }
}

private let requiredCapabilities = [
    "session.info", "session.ensureOnDisk", "session.flush", "entry.append", "jobs.snapshot", "agents.snapshot",
    "agents.loadPersisted", "agent.revive", "agent.park", "agent.kill", "agent.prompt", "agent.message", "introspect",
    "events.registry", "session.pause", "events.attention", "events.jobs", "service.mode",
]

/// Real `omp --mode rpc --no-ui -e <staged ide-bridge.ts>`; no model call is made. Skipped when omp is not installed.
@Suite(.enabled(if: ompExecutable != nil, "omp is not installed"), .timeLimit(.minutes(3)))
struct BridgeOmpIntegrationTests {
    @Test func bridgeServesTheOmpItWasSpawnedWith() async throws {
        let omp = try #require(ompExecutable)
        let sandbox = try Sandbox()
        let server = BridgeServer(socketPath: bridgeSocketPath())
        try await server.start()
        let credentials = await server.expect(sessionKey: "itest")
        // As in production, the lock-mode copy from the agent's extensions dir loads first and ompd's `-e` copy last:
        // one module evaluation must own the process, so there is exactly one hello and no duplicate events.
        let global = try BridgeInstaller.installGlobal(agentDir: sandbox.dir.url.appending(path: "agent", directoryHint: .isDirectory))
        let child = try sandbox.spawn(omp, extensions: [global, sandbox.bridge], adding: credentials.environment)
        defer { child.killIfRunning() }
        do {
            // ompd's order: spawn, RPC `ready` and a first round trip, only then setExpectedPID. The bridge must not hold
            // omp's RPC loop while its hello waits for the pid.
            _ = try await child.frame("ready") { $0["type"] == "ready" }
            try child.send(["id": "state", "type": "get_state"])
            let state = try await child.frame("get_state response", seconds: 10) { $0["id"] == "state" }
            await server.setExpectedPID(child.pid, for: "itest")
            let hello = try await server.waitForHello("itest", timeout: .seconds(60))
            #expect(state["data"]?["sessionFile"]?.stringValue == hello.sessionFile)
            #expect(hello.pid == child.pid)
            #expect(!hello.ompVersion.isEmpty && hello.ompVersion != "unknown")
            for capability in requiredCapabilities { #expect(hello.capabilities[capability] == true, "\(capability)") }
            #expect(hello.onDisk == false)
            #expect(OwnershipLock.canonicalPath(hello.cwd) == OwnershipLock.canonicalPath(sandbox.workspace.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: hello.sessionFile))

            let info = try await server.call("itest", method: "session.ensureOnDisk")
            #expect(info["file"]?.stringValue == hello.sessionFile)
            #expect(info["onDisk"] == true)
            #expect(hello.attention.isEmpty && info["attention"] == [], "nothing waits for the user")
            #expect(FileManager.default.fileExists(atPath: hello.sessionFile))

            let agents = try await server.call("itest", method: "agents.snapshot")["agents"]?.arrayValue ?? []
            let main = agents.first { $0["id"] == "Main" }
            #expect(main?["kind"] == "main")
            #expect(main?["hasSession"] == true)

            let introspection = try await server.call("itest", method: "introspect")
            #expect(introspection["pid"]?.intValue == Int(child.pid))
            #expect(introspection["capabilities"]?["agent.revive"] == true)
            #expect(introspection["internalErrors"] == [:])

            let appended = try await server.call(
                "itest", method: "entry.append", params: ["customType": "com.omp-ide.test", "data": ["marker": "bridge-itest"]])
            let entryId = try #require(appended["entryId"]?.stringValue)
            let entries = try String(contentsOfFile: hello.sessionFile, encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            let entry = entries.first { $0["id"]?.stringValue == entryId }
            #expect(entry?["type"] == "custom")
            #expect(entry?["customType"] == "com.omp-ide.test")
            #expect(entry?["data"]?["marker"] == "bridge-itest")

            await #expect(throws: BridgeError.callFailed(method: "no.such.method", message: "unknown method: no.such.method")) {
                try await server.call("itest", method: "no.such.method")
            }

            child.closeStdin()
            #expect(try await child.waitForExit() == .init(status: 0, reason: .exit))
            let events = try await bridgeCollect(server.events("itest"))
            #expect(events.first?["kind"] == "session_start")
            #expect(events.first?["agentId"] == "Main")
            #expect(events.filter { $0["kind"] == "session_start" }.count == 1)
            #expect(events.contains { $0["kind"] == "session_shutdown" && $0["agentId"] == "Main" })
            #expect(events.compactMap { $0["seq"]?.intValue } == Array(1..<(events.count + 1)))
            #expect(!child.stderrText.contains("ide-bridge"), "\(child.stderrText)")
            await #expect(throws: BridgeError.disconnected) { try await server.call("itest", method: "session.info") }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    /// omp's pause gate through the bridge. Without a TUI (RPC mode) there is no pause screen: the gate alone.
    @Test func pauseClosesOmpsGateAndEveryFlipIsPushed() async throws {
        let omp = try #require(ompExecutable)
        let sandbox = try Sandbox()
        let server = BridgeServer(socketPath: bridgeSocketPath())
        try await server.start()
        let credentials = await server.expect(sessionKey: "pause")
        let child = try sandbox.spawn(omp, adding: credentials.environment)
        defer { child.killIfRunning() }
        do {
            await server.setExpectedPID(child.pid, for: "pause")
            let hello = try await server.waitForHello("pause", timeout: .seconds(60))
            #expect(hello.pausedBy == nil)

            let paused = try await server.call("pause", method: "session.pause")
            #expect(paused == ["paused": true, "pausedBy": "daemon", "changed": true, "screen": false])
            let info = try await server.call("pause", method: "session.info")
            #expect(info["paused"] == true && info["pausedBy"] == "daemon")
            #expect(try await server.call("pause", method: "session.pause")["changed"] == false)
            // A guard naming someone else leaves ompd's pause in place.
            let guarded = try await server.call("pause", method: "session.resume", params: ["ifPausedBy": "user"])
            #expect(guarded == ["paused": true, "pausedBy": "daemon", "changed": false, "screen": false])
            let resumed = try await server.call("pause", method: "session.resume", params: ["ifPausedBy": "daemon"])
            #expect(resumed == ["paused": false, "pausedBy": .null, "changed": true, "screen": false])
            #expect(try await server.call("pause", method: "session.resume")["changed"] == false)
            await #expect(throws: BridgeError.self) {
                try await server.call("pause", method: "session.resume", params: ["ifPausedBy": "robot"])
            }

            child.closeStdin()
            #expect(try await child.waitForExit().status == 0)
            let flips = try await bridgeCollect(server.events("pause")).filter { $0["kind"] == "pause" }
            #expect(flips.compactMap { $0["data"] } == [["paused": true, "by": "daemon"], ["paused": false, "by": "daemon"]])
            #expect(flips.allSatisfy { $0["agentId"] == "Main" })
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    /// Terminal mode: an omp started with a terminal's credentials (`TerminalCredentials`, no session key, no parent
    /// check) says hello naming the terminal; adopted, it is served like a spawned omp; refused, it runs on in lock mode
    /// and dials nobody. Credentials of a dead daemon (a pid nobody has) mean lock mode from the start.
    @Test func terminalModeDialsTheDaemonAndFallsBackToLockModeWhenRefused() async throws {
        let omp = try #require(ompExecutable)
        let sandbox = try Sandbox()
        let server = BridgeServer(socketPath: bridgeSocketPath())
        try await server.start()
        let hellos = Box<[TerminalHello]>([])
        let taking = Task { for await hello in await server.terminalHellos() { hellos.mutate { $0.append(hello) } } }
        defer { taking.cancel() }
        let credentials = await server.expectTerminal(ptyId: "term-1")
        let global = try BridgeInstaller.installGlobal(agentDir: sandbox.dir.url.appending(path: "agent", directoryHint: .isDirectory))
        // As in a terminal: only the globally installed copy loads (ompd passes no `-e`).
        let adoptee = try sandbox.spawn(omp, extensions: [global], adding: credentials.environment)
        defer { adoptee.killIfRunning() }
        do {
            let request = try await eventuallyValue("the terminal hello", timeout: .seconds(60)) { hellos.value.first }
            #expect(request.ptyId == "term-1" && request.hello.pid == adoptee.pid && request.hello.sessionKey.isEmpty)
            #expect(request.hello.capabilities["session.pause"] == true && request.hello.capabilities["session.shutdown"] == true)
            let accepted = try #require(await server.adoptTerminalHello(request, as: "adopted"))
            #expect(accepted.sessionKey == "adopted")
            let info = try await server.call("adopted", method: "session.info")
            #expect(info["file"]?.stringValue == accepted.sessionFile)
            #expect(try await server.call("adopted", method: "session.pause")["paused"] == true)
            #expect(try await server.call("adopted", method: "session.resume", params: ["ifPausedBy": "daemon"])["paused"] == false)
            adoptee.closeStdin()
            #expect(try await adoptee.waitForExit() == .init(status: 0, reason: .exit))
            let events = try await bridgeCollect(server.events("adopted"))
            #expect(events.first?["kind"] == "session_start" && events.contains { $0["kind"] == "session_shutdown" })
            #expect(events.filter { $0["kind"] == "pause" }.count == 2)
            #expect(!adoptee.stderrText.contains("ide-bridge"), "terminal mode stays silent: \(adoptee.stderrText)")

            // Refused (a second omp in the same terminal): lock mode, and a fresh session file is nobody's, so it runs on.
            let refused = try sandbox.spawn(omp, extensions: [global], adding: credentials.environment)
            defer { refused.killIfRunning() }
            let second = try await eventuallyValue("the second terminal hello", timeout: .seconds(60)) { hellos.value.count > 1 ? hellos.value[1] : nil }
            await server.refuseTerminalHello(second, reason: "terminal term-1 already runs omp session adopted")
            _ = try await refused.frame("ready") { $0["type"] == "ready" }
            try refused.send(["id": "state", "type": "get_state"])
            _ = try await refused.frame("get_state response", seconds: 10) { $0["id"] == "state" }
            refused.closeStdin()
            #expect(try await refused.waitForExit() == .init(status: 0, reason: .exit))
            #expect(!refused.stderrText.contains("ide-bridge"), "\(refused.stderrText)")

            // A dead daemon's credentials: lock mode from the start, no dialing.
            var stale = credentials.environment
            stale[BridgeCredentials.daemonPIDVariable] = "2147483000"
            let orphan = try sandbox.spawn(omp, extensions: [global], adding: stale)
            defer { orphan.killIfRunning() }
            _ = try await orphan.frame("ready") { $0["type"] == "ready" }
            orphan.closeStdin()
            #expect(try await orphan.waitForExit() == .init(status: 0, reason: .exit))
            #expect(hellos.value.count == 2)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test func lockModeRefusesSessionsTheDaemonOwns() async throws {
        let omp = try #require(ompExecutable)
        let sandbox = try Sandbox()
        let server = BridgeServer(socketPath: bridgeSocketPath())
        try await server.start()
        do {
            // A real session file, created the way ompd does it.
            let credentials = await server.expect(sessionKey: "owner")
            let creator = try sandbox.spawn(omp, adding: credentials.environment)
            defer { creator.killIfRunning() }
            await server.setExpectedPID(creator.pid, for: "owner")
            let hello = try await server.waitForHello("owner", timeout: .seconds(60))
            _ = try await server.call("owner", method: "session.ensureOnDisk")
            _ = try await server.call("owner", method: "entry.append", params: ["customType": "com.omp-ide.test", "data": [:]])
            creator.closeStdin()
            #expect(try await creator.waitForExit().status == 0)
            let sessionFile = hello.sessionFile
            let sessionURL = URL(filePath: sessionFile)

            let lock = try OwnedSessionLock.acquire(
                sessionFile: sessionFile, sessionId: hello.sessionId, sessionKey: "owner", dir: sandbox.paths.ownedSessions)
            let before = try Data(contentsOf: sessionURL)

            // Refused at load time: `--resume <file>`.
            let resumed = try sandbox.spawn(omp, ["--resume", sessionFile])
            defer { resumed.killIfRunning() }
            #expect(try await resumed.waitForExit() == .init(status: SIGKILL, reason: .uncaughtSignal))
            #expect(resumed.stderrText.contains("is open in omp IDE (--resume)"))
            #expect(try Data(contentsOf: sessionURL) == before)

            // Refused at session_start: `--continue` only resolves the file after loading.
            let continued = try sandbox.spawn(omp, ["--continue"])
            defer { continued.killIfRunning() }
            #expect(try await continued.waitForExit() == .init(status: SIGKILL, reason: .uncaughtSignal))
            #expect(continued.stderrText.contains("is open in omp IDE (session_start)"))
            #expect(try Data(contentsOf: sessionURL) == before)

            // A daemon-mode omp the daemon rejects gets the same treatment.
            let rejectedCredentials = await server.expect(sessionKey: "rejected")
            await server.setExpectedPID(1, for: "rejected")
            let rejected = try sandbox.spawn(omp, ["--resume", sessionFile], adding: rejectedCredentials.environment)
            defer { rejected.killIfRunning() }
            #expect(try await rejected.waitForExit() == .init(status: SIGKILL, reason: .uncaughtSignal))
            #expect(rejected.stderrText.contains("rejected by the omp IDE daemon"))
            await #expect(throws: BridgeError.unauthorized) { try await server.waitForHello("rejected", timeout: .milliseconds(10)) }
            #expect(try Data(contentsOf: sessionURL) == before)

            // An omp started by a process ompd spawned (a bash tool running `omp --resume`) inherits OMP_IDE_* but is
            // not ompd's child: lock mode, refused at load, and it never dials the daemon.
            let inheritedCredentials = await server.expect(sessionKey: "inherited")
            let shell = try OmpChild(
                URL(filePath: "/bin/sh"),
                ["-c", "\"$0\" \"$@\"; exit $?", omp.path(percentEncoded: false)] + sandbox.arguments(["--resume", sessionFile]),
                environment: sandbox.environment(adding: inheritedCredentials.environment), cwd: sandbox.workspace)
            defer { shell.killIfRunning() }
            #expect(try await shell.waitForExit() == .init(status: 128 + SIGKILL, reason: .exit))
            #expect(shell.stderrText.contains("is open in omp IDE (--resume)"))
            await #expect(throws: BridgeError.helloTimeout) { try await server.waitForHello("inherited", timeout: .milliseconds(10)) }
            #expect(try Data(contentsOf: sessionURL) == before)

            // Switching an unrelated omp into the owned file is vetoed.
            let switcher = try sandbox.spawn(omp)
            defer { switcher.killIfRunning() }
            _ = try await switcher.frame("ready") { $0["type"] == "ready" }
            try switcher.send(["id": "switch", "type": "switch_session", "sessionPath": .string(sessionFile)])
            let response = try await switcher.frame("switch_session response") { $0["id"] == "switch" }
            #expect(response["success"] == true)
            #expect(response["data"]?["cancelled"] == true)
            switcher.closeStdin()
            #expect(try await switcher.waitForExit().status == 0)
            #expect(try Data(contentsOf: sessionURL) == before)

            // Released: the same resume is admitted.
            lock.release()
            let admitted = try sandbox.spawn(omp, ["--resume", sessionFile])
            defer { admitted.killIfRunning() }
            _ = try await admitted.frame("ready") { $0["type"] == "ready" }
            admitted.closeStdin()
            #expect(try await admitted.waitForExit() == .init(status: 0, reason: .exit))
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}

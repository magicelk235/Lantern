import Darwin
import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// Chaos matrix acceptance for every reset that can be staged on this machine, with the
/// real `ompd` binary, real omp and `anthropic/claude-haiku-4-5` (costs model calls, several minutes per row). Not part
/// of the default run: `scripts/chaos.sh` builds ompd and runs it with `OMPD_CHAOS=1`.
///
/// One row per death (the app going away, omp SIGKILL/SIGTERM, ompd SIGKILL/SIGTERM), each over one daemon hosting a
/// session per moment (idle after a finished turn, streaming a reply, mid-tool, mid-subagent, a pending `ask`, a
/// pending approval, a named service running) plus a plain terminal. The restore policy is `auto` for both, so every
/// interrupted agent is continued. Logout, reboot, power loss and sleep need a VM and are not staged here.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OMPD_CHAOS"] == "1", "set OMPD_CHAOS=1 (scripts/chaos.sh)"))
struct ChaosMatrixTests {
    enum Death: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case appGone = "app gone", ompKill = "omp SIGKILL", ompTerm = "omp SIGTERM", ompdKill = "ompd SIGKILL", ompdTerm = "ompd SIGTERM"
        var testDescription: String { rawValue }
        var regimeA: Bool { self == .appGone }
        var killsDaemon: Bool { self == .ompdKill || self == .ompdTerm }
    }

    enum Moment: String, CaseIterable, Sendable {
        case idle, streaming, midTool = "mid-tool", midSubagent = "mid-subagent", pendingAsk = "pending ask"
        case pendingApproval = "pending approval", service = "named service"

        var approvalMode: String { self == .pendingApproval ? "always-ask" : "yolo" }

        /// Tool commands that run long enough for every other moment to be reached before the death.
        static let toolSleep = "/bin/sleep 45"
        static let subagentSleep = "/bin/sleep 40"

        var prompt: String {
            switch self {
            case .idle: "Do not use any tools. Reply with exactly IDLE-OK."
            case .streaming: "Do not use any tools. Write a story of about 2500 words about a lighthouse keeper, then end with a line containing only STORY-END."
            case .midTool: "Use the bash tool once to run exactly: \(Self.toolSleep); echo TOOL-DONE. Then reply with exactly TOOL-DONE."
            case .midSubagent: DaemonAcceptanceTests.prompt.replacingOccurrences(of: "/bin/sleep 10", with: Self.subagentSleep)
            case .pendingAsk: "Use the ask tool once to ask me which color I prefer, with the options red and blue. Then reply with my answer."
            case .pendingApproval: "Use the bash tool once to run exactly: /bin/echo APPROVED-RUN. Then reply with exactly APPROVED-DONE."
            case .service: "Use the bash tool with name chaos-web and ready port \(ChaosMatrixTests.servicePort) to start the service: python3 -m http.server \(ChaosMatrixTests.servicePort) --bind 127.0.0.1. Then reply with exactly SERVICE-UP."
            }
        }

        /// The agent was mid-turn at the death, so a Regime-B restore continues it.
        var interrupts: Bool { ![.idle, .service].contains(self) }
        /// The continued turn can finish on its own (no dialog waits for the user).
        var finishes: Bool { [.streaming, .midTool, .midSubagent].contains(self) }
    }

    static let servicePort = 18000 + Int(getpid() % 900)

    /// The rows to run: every death, or those named in `OMPD_CHAOS_ONLY` (comma-separated `Death` raw values).
    static let deaths: [Death] = {
        guard let only = ProcessInfo.processInfo.environment["OMPD_CHAOS_ONLY"], !only.isEmpty else { return Death.allCases }
        let names = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return Death.allCases.filter { names.contains($0.rawValue) }
    }()

    struct Cell: Sendable {
        let moment: Moment
        let key: SessionKey
        let ptyId: PTYID
        let sessionFile: String
        let ompPID: Int32
    }

    @Test(.timeLimit(.minutes(30)), arguments: deaths)
    func matrix(_ death: Death) async throws {
        let rig = try AcceptanceRig()
        defer {
            _ = try? rig.run("/usr/bin/env", ["omp", "ps", "stop", "chaos-web", "--dir", rig.workspace])
            if ProcessInfo.processInfo.environment["OMPD_ACCEPTANCE_KEEP"] == "1" {
                print("chaos \(death.rawValue): evidence kept in \(rig.root.path(percentEncoded: false))")
            } else {
                rig.remove()
            }
        }
        var daemon = try rig.launchDaemon(log: "ompd-1.log")
        defer { if daemon.isRunning { kill(daemon.processIdentifier, SIGTERM) } }
        var app = try await rig.connect()
        _ = try await app.client.call(RestorePolicySet.self, RestorePolicy(main: .auto, subagents: .auto))

        // Every moment reached, one session each, plus a terminal with a mark on its screen. A reply streams for
        // seconds only, so the streaming session is started last, once the others hold.
        let terminal = try await app.client.call(PTYOpen.self, .init(cwd: rig.workspace, cols: 100, rows: 30))
        _ = try await app.client.call(PTYAttach.self, .init(ptyId: terminal.ptyId))
        let mark = "TERM-MARK-\(UUID().uuidString.prefix(6))"
        _ = try await app.client.call(PTYWrite.self, .init(ptyId: terminal.ptyId, data: Data("echo \(mark)\r".utf8)))
        var cells: [Cell] = []
        let first = app
        try await withThrowingTaskGroup(of: Cell.self) { group in
            for moment in Moment.allCases where moment != .streaming {
                group.addTask { try await Self.reach(moment, rig, first) }
            }
            for try await cell in group { cells.append(cell) }
        }
        cells.append(try await Self.reach(.streaming, rig, app))
        // PTY snapshots are written every 5 s while dirty; a daemon death loses at most that.
        try await Task.sleep(for: .seconds(6))
        cells.sort { $0.moment.rawValue < $1.moment.rawValue }
        for cell in cells where !(try await Self.holds(cell, rig, app)) {
            Issue.record("\(death.rawValue): \(cell.moment.rawValue) no longer holds at the death; its row checks something else")
        }
        let deathAt = Date()
        print("chaos \(death.rawValue): \(cells.count) moments reached; killing at \(deathAt)")

        switch death {
        case .appGone:
            await app.close()
            let observer = try await Self.cliClient(rig)
            try await eventually("every session paused without a window", timeout: .seconds(20)) {
                let sessions = try await observer.client.call(ListSessions.self, Empty()).sessions
                return sessions.allSatisfy { $0.status == .paused }
            }
            try await Task.sleep(for: .seconds(5))
            await observer.close()
            app = try await rig.connect()
        case .ompKill, .ompTerm:
            for cell in cells { kill(cell.ompPID, death == .ompKill ? SIGKILL : SIGTERM) }
        case .ompdKill, .ompdTerm:
            await app.close()
            kill(daemon.processIdentifier, death == .ompdKill ? SIGKILL : SIGTERM)
            let status = try await rig.waitForExit(daemon, timeout: .seconds(40))
            let ompPIDs = cells.map(\.ompPID)
            try await eventually("every omp of the dead daemon gone", timeout: .seconds(40)) {
                ompPIDs.allSatisfy { kill($0, 0) != 0 }
            }
            print("chaos \(death.rawValue): ompd exited \(status); restarting it (launchd KeepAlive's part)")
            daemon = try rig.launchDaemon(log: "ompd-2.log")
            app = try await rig.connect(timeout: .seconds(60))
        }

        var failures: [String] = []
        for cell in cells {
            do {
                if death.regimeA {
                    try await Self.verifyUntouched(cell, app, rig)
                } else {
                    try await Self.verifyResumed(cell, death, since: deathAt, app, rig)
                }
                print("  ✓ \(cell.moment.rawValue)")
            } catch {
                failures.append("\(cell.moment.rawValue): \(error)")
                print("  ✗ \(cell.moment.rawValue): \(error)")
            }
        }
        try await Self.verifyTerminal(terminal, mark: mark, death, app)
        #expect(failures.isEmpty, "\(death.rawValue): \(failures.joined(separator: "; "))")

        await app.close()
        kill(daemon.processIdentifier, SIGTERM)
        _ = try await rig.waitForExit(daemon, timeout: .seconds(40))
    }

    // MARK: - Reaching a moment

    /// A session brought to `moment`: its prompt typed into the TUI, then waited on until omp is in that state.
    private static func reach(_ moment: Moment, _ rig: AcceptanceRig, _ app: Connected) async throws -> Cell {
        let entry = try await app.client.call(
            SessionCreate.self,
            .init(workspace: rig.workspace, approvalMode: moment.approvalMode, model: "anthropic/claude-haiku-4-5", cols: 120, rows: 40))
        let key = entry.sessionKey
        let ptyId = try #require(entry.ptyId)
        _ = try await app.client.call(PTYAttach.self, .init(ptyId: ptyId))
        try await app.waitForStatus(key, .idle, timeout: .seconds(60))
        let ompPID = try await rig.pid(of: ptyId, app)
        try await type(moment.prompt, into: ptyId, app)
        try await app.waitForStatus(key, .busy, timeout: .seconds(60))
        let file = try await eventuallyValue("\(moment.rawValue): session file", timeout: .seconds(30)) { () -> String? in
            guard let file = try await app.entry(key).sessionFile, FileManager.default.fileExists(atPath: file) else { return nil }
            return file
        }
        let wait = Duration.seconds(240)
        switch moment {
        case .idle:
            try await app.waitForStatus(key, .idle, timeout: wait)
        case .streaming:
            try await Task.sleep(for: .seconds(2))
        case .midTool:
            _ = try await eventuallyValue("mid-tool: sleep running", timeout: wait) { try rig.descendant(of: ompPID, command: Moment.toolSleep) }
        case .midSubagent:
            _ = try await eventuallyValue("mid-subagent: sleep running", timeout: wait) { try rig.descendant(of: ompPID, command: Moment.subagentSleep) }
        case .pendingAsk:
            try await eventually("pending ask", timeout: wait) { toolStarted("ask", in: file) }
        case .pendingApproval:
            try await eventually("pending approval", timeout: wait) { toolStarted("bash", command: "APPROVED-RUN", in: file) }
        case .service:
            try await eventually("named service recorded", timeout: wait) {
                try await app.entry(key).services.contains { $0.id == "chaos-web" && $0.desiredRunning }
            }
            try await app.waitForStatus(key, .idle, timeout: wait)
        }
        try await Task.sleep(for: .seconds(1))
        return Cell(moment: moment, key: key, ptyId: ptyId, sessionFile: file, ompPID: ompPID)
    }

    /// `cell` is still in its moment (checked right before the death, so a moment that ended early is not mistaken
    /// for the one under test).
    private static func holds(_ cell: Cell, _ rig: AcceptanceRig, _ app: Connected) async throws -> Bool {
        let status = try await app.entry(cell.key).status
        switch cell.moment {
        case .idle, .service: return status == .idle
        case .streaming:
            // Streaming text is never persisted: the turn's prompt is still the newest message.
            let messages = entries(cell.sessionFile).filter { $0["type"] == "message" }
            return status == .busy && messages.last?["message"]?["role"] == "user"
        case .midTool: return try rig.descendant(of: cell.ompPID, command: Moment.toolSleep) != nil
        case .midSubagent: return try rig.descendant(of: cell.ompPID, command: Moment.subagentSleep) != nil
        case .pendingAsk, .pendingApproval: return status == .busy
        }
    }

    private static func type(_ text: String, into ptyId: PTYID, _ app: Connected) async throws {
        _ = try await app.client.call(PTYWrite.self, .init(ptyId: ptyId, data: Data(text.utf8)))
        try await Task.sleep(for: .milliseconds(500))
        _ = try await app.client.call(PTYWrite.self, .init(ptyId: ptyId, data: Data("\r".utf8)))
    }

    /// omp recorded the start of a `tool` call (whose command contains `command`, if given) in `file`.
    private static func toolStarted(_ tool: String, command: String? = nil, in file: String) -> Bool {
        entries(file).contains { entry in
            entry["customType"] == "tool_execution_start" && entry["data"]?["toolName"]?.stringValue == tool
                && command.map { entry["data"]?["args"]?["command"]?.stringValue?.contains($0) == true } != false
        }
    }

    // MARK: - Invariants

    /// Regime A: the same omp on the same PTY, nothing appended by ompd, the screen repainted, and the work carries on
    /// once a window is back.
    private static func verifyUntouched(_ cell: Cell, _ app: Connected, _ rig: AcceptanceRig) async throws {
        let entry = try await app.entry(cell.key)
        try check(entry.ptyId == cell.ptyId && kill(cell.ompPID, 0) == 0, "omp \(cell.ompPID) on \(cell.ptyId) untouched")
        let screen = screenLines(try await app.client.call(PTYAttach.self, .init(ptyId: cell.ptyId))).joined(separator: "\n")
        try check(screen.contains("Haiku"), "the TUI repainted on reattach")
        if cell.moment.finishes {
            try await app.waitForStatus(cell.key, .idle, timeout: .seconds(300))
        } else if cell.moment == .pendingAsk || cell.moment == .pendingApproval {
            try await eventually("\(cell.moment.rawValue) running again after the pause", timeout: .seconds(20)) {
                try await app.entry(cell.key).status == .busy
            }
        }
        let all = entries(cell.sessionFile)
        try check(!all.contains { $0["customType"] == .string(InterruptionAnalyzer.markerType) }, "no interruption marker")
        try check(continuationPrompts(all).isEmpty, "no continuation prompt")
        if cell.moment == .service { try check(try serviceIsLive(rig), "chaos-web still running") }
    }

    /// Regime B: resumed from its file in a new PTY that continues the old screen, never twice; an agent that was
    /// mid-turn continued exactly once, told which calls may not have completed; an idle one left alone; its services
    /// running.
    private static func verifyResumed(_ cell: Cell, _ death: Death, since: Date, _ app: Connected, _ rig: AcceptanceRig) async throws {
        let entry = try await eventuallyValue("\(cell.moment.rawValue): resumed", timeout: .seconds(120)) { () -> SessionManifestEntry? in
            let entry = try await app.entry(cell.key)
            return entry.ptyId != cell.ptyId && [.idle, .busy].contains(entry.status) ? entry : nil
        }
        let ptyId = try #require(entry.ptyId)
        let ompPID = try await rig.pid(of: ptyId, app)
        let argv = try rig.run("/bin/ps", ["-o", "command=", "-p", String(ompPID)]).stdout
        try check(argv.contains("--resume ") && argv.contains(URL(filePath: cell.sessionFile).lastPathComponent), "resumed from its file: \(argv)")
        let screen = screenLines(try await app.client.call(PTYAttach.self, .init(ptyId: ptyId)))
        try check(screen.contains("— terminal restarted —"), "the new PTY continues the old screen (\(screen.count) lines, first: \(screen.prefix(3)), last: \(screen.suffix(3)))")
        try check(try ompProcesses(serving: cell.sessionFile, rig) == 1, "one omp serves \(cell.sessionFile)")

        if cell.moment.interrupts {
            let prompt = try await eventuallyValue("\(cell.moment.rawValue): continuation prompt", timeout: .seconds(120)) {
                continuationPrompts(entries(cell.sessionFile)).first
            }
            let markers = entries(cell.sessionFile).filter { $0["customType"] == .string(InterruptionAnalyzer.markerType) }
            let marker = try #require(markers.last?["data"], "an interruption marker")
            try check(markers.count == 1 && marker["decision"] == "continued", "one marker, continued: \(markers.count)")
            let pending = (marker["pendingToolCalls"]?.arrayValue ?? []).map {
                "\($0["toolName"]?.stringValue ?? "?"): \($0["summary"]?.stringValue ?? "")"
            }
            let agents = (marker["agents"]?.arrayValue ?? []).compactMap(\.stringValue)
            switch cell.moment {
            case .midTool: try check(pending.contains { $0.contains(Moment.toolSleep) }, "the sleep reported: \(pending)")
            case .pendingAsk: try check(pending.contains { $0.hasPrefix("ask:") }, "the ask reported: \(pending)")
            case .pendingApproval: try check(pending.contains { $0.contains("APPROVED-RUN") }, "the unapproved call reported: \(pending)")
            case .midSubagent:
                // Every subagent the death left unfinished (a transcript with no output and no tombstone; one that
                // already yielded, e.g. after backgrounding its sleep, is done) is continued.
                let unfinished = unfinishedSubagents(of: cell.sessionFile, before: since)
                try check(Set(unfinished).isSubset(of: Set(agents)), "unfinished subagents \(unfinished) continued: \(agents)")
            default: break
            }
            // The continued turn went to the model and came back (a context with a dangling tool call would be refused).
            try await eventually("\(cell.moment.rawValue): a reply to the continuation", timeout: .seconds(240)) {
                assistantMessagesAfter(prompt, in: entries(cell.sessionFile)) > 0
            }
            if cell.moment.finishes { try await app.waitForStatus(cell.key, .idle, timeout: .seconds(300)) }
            try check(continuationPrompts(entries(cell.sessionFile)).count == 1, "continued exactly once")
            let reply = (try? rig.assistantTexts(cell.sessionFile).last) ?? ""
            print("    \(cell.moment.rawValue): pending \(pending), agents \(agents); reply: \(reply.prefix(100))")
        } else {
            try await Task.sleep(for: .seconds(3))
            let all = entries(cell.sessionFile)
            try check(continuationPrompts(all).isEmpty, "an idle agent is not prompted")
            try check(!all.contains { $0["customType"] == .string(InterruptionAnalyzer.markerType) }, "no interruption marker")
        }
        if cell.moment == .service {
            try await eventually("chaos-web running after the restore", timeout: .seconds(60)) { try serviceIsLive(rig) }
        }
    }

    /// A plain terminal: untouched by omp deaths and the app going away; after a daemon death recreated from its
    /// snapshot, the old screen above the restart divider.
    private static func verifyTerminal(_ terminal: PTYInfo, mark: String, _ death: Death, _ app: Connected) async throws {
        let ptys = try await app.client.call(PTYList.self, Empty()).ptys.filter { $0.sessionKey == nil }
        let current = try #require(death.killsDaemon ? ptys.first : ptys.first { $0.ptyId == terminal.ptyId }, "the terminal is listed")
        let screen = screenLines(try await app.client.call(PTYAttach.self, .init(ptyId: current.ptyId)))
        #expect(screen.contains { $0.contains(mark) }, "the terminal's screen kept \(mark)")
        if death.killsDaemon {
            #expect(screen.contains("— terminal restarted —") && current.running, "recreated with the restart divider")
        } else {
            #expect(current.pid == terminal.pid && current.running, "the terminal's shell never noticed")
        }
    }

    // MARK: - Helpers

    private struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: Bool, _ what: String) throws {
        if !condition { throw Failed(description: what) }
    }

    /// Entries of an omp session JSONL.
    private static func entries(_ file: String) -> [JSONValue] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// Indices of ompd's continuation prompts (user messages starting with `[Lantern]`).
    private static func continuationPrompts(_ entries: [JSONValue]) -> [Int] {
        entries.indices.filter { index in
            let message = entries[index]["message"]
            guard entries[index]["type"] == "message", message?["role"] == "user" else { return false }
            let text = (message?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
            return text.hasPrefix("[Lantern]")
        }
    }

    private static func assistantMessagesAfter(_ index: Int, in entries: [JSONValue]) -> Int {
        entries[(index + 1)...].filter { $0["type"] == "message" && $0["message"]?["role"] == "assistant" }.count
    }

    /// Subagents of `sessionFile` that existed at `death` and had not finished by then: no output (`<id>.md`) written
    /// before it and no tombstone.
    private static func unfinishedSubagents(of sessionFile: String, before death: Date) -> [String] {
        let directory = URL(filePath: String(sessionFile.dropLast(".jsonl".count)))
        let fm = FileManager.default
        func attributes(_ url: URL) -> [FileAttributeKey: Any]? { try? fm.attributesOfItem(atPath: url.path(percentEncoded: false)) }
        let names = (try? fm.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }.compactMap { name in
            let transcript = directory.appending(path: name)
            guard let created = attributes(transcript)?[.creationDate] as? Date, created < death else { return nil }
            if let tombstone = attributes(transcript.appendingPathExtension("tombstone")), (tombstone[.modificationDate] as? Date).map({ $0 < death }) ?? false {
                return nil
            }
            let output = attributes(transcript.deletingPathExtension().appendingPathExtension("md"))
            if let output, (output[.size] as? Int ?? 0) > 0, (output[.modificationDate] as? Date).map({ $0 < death }) ?? false {
                return nil
            }
            return String(name.dropLast(".jsonl".count))
        }.sorted()
    }

    /// omp processes whose command line resumes `sessionFile` (a new session's omp names no file and is not counted).
    private static func ompProcesses(serving sessionFile: String, _ rig: AcceptanceRig) throws -> Int {
        let name = URL(filePath: sessionFile).lastPathComponent
        return try rig.run("/bin/ps", ["-axo", "command="]).stdout.split(separator: "\n")
            .filter { $0.contains("--resume") && $0.contains(name) && !$0.contains("/bin/ps") }.count
    }

    private static func serviceIsLive(_ rig: AcceptanceRig) throws -> Bool {
        let output = try rig.run("/usr/bin/env", ["omp", "ps", "--json", "--dir", rig.workspace]).stdout
        return try OmpServiceControl.parseRecords(output).contains { $0.name == "chaos-web" && $0.supervised && liveServiceStates.contains($0.state) }
    }

    /// An observer that is not a window (`cli`), so it does not keep the sessions running.
    private static func cliClient(_ rig: AcceptanceRig) async throws -> Connected {
        let token = try String(contentsOf: rig.paths.token, encoding: .utf8)
        let client = IDEClient(
            socketPath: rig.paths.socket.path(percentEncoded: false), token: token, clientVersion: "chaos", clientKind: .cli, hasWindow: false)
        return Connected(client: client, welcome: try await client.connect())
    }
}
